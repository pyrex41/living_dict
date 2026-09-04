//! Out-of-process effect provider.
//!
//! The executor never holds canned provider responses. It sends every
//! external effect over a Unix socket to this server, which is idempotent by
//! the host-derived effect key and appends a hash-chained log of every
//! request it receives. "At most one externally visible operation per key"
//! is therefore measured by a process that does not run the guest.
//!
//! Idempotency is durable: on start the server rebuilds its state (executed
//! keys, the request each key is bound to, the result bytes, per-name
//! consumption positions, sequence and previous hash) from an existing log,
//! after verifying its chain. A provider that is killed and restarted
//! therefore still answers a repeated key with the original result and
//! refuses a key reused for a different request.

use crate::{canonical, hash, hex, unhex};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{BufRead, BufReader, Read, Write},
    os::unix::net::{UnixListener, UnixStream},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

pub const PROVIDER_LOG: &str = "ld.provider/v1";
/// Largest request or reply line either side will read.
pub const MAX_LINE_BYTES: u64 = 4 * 1024 * 1024;

/// Client side: one connection per request.
pub struct ProviderClient {
    pub socket: PathBuf,
    /// Set when this executor spawned the provider (so a kill-matrix run can
    /// take the provider down with it).
    pub pid: Option<u32>,
}

/// What to do after the request bytes are on the wire (kill matrix).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MidCall {
    Proceed,
    Abort,
    Sigkill { provider_pid: Option<u32> },
}

fn read_line_bounded(stream: &UnixStream) -> Result<String> {
    let mut line = String::new();
    BufReader::new(stream.take(MAX_LINE_BYTES)).read_line(&mut line)?;
    if !line.ends_with('\n') {
        return Err(anyhow!("provider line too long or truncated"));
    }
    Ok(line)
}

/// Terminate this process without writing anything further: SIGKILL to self
/// (and, first, to the provider when asked). This is the "real crash" path
/// of the kill matrix; nothing is journaled about it.
pub fn die(action: MidCall) -> ! {
    if let MidCall::Sigkill { provider_pid } = action {
        if let Some(pid) = provider_pid {
            let _ = Command::new("kill")
                .args(["-KILL", &pid.to_string()])
                .status();
        }
        let _ = Command::new("kill")
            .args(["-KILL", &std::process::id().to_string()])
            .status();
        std::thread::sleep(Duration::from_secs(5));
    }
    std::process::abort();
}

impl ProviderClient {
    pub fn connectable(socket: &Path) -> bool {
        UnixStream::connect(socket).is_ok()
    }

    pub fn call(
        &self,
        key: &str,
        name: &str,
        business_key: &str,
        payload: &[u8],
        mid: MidCall,
    ) -> Result<(String, Vec<u8>)> {
        let mut stream = UnixStream::connect(&self.socket)
            .map_err(|e| anyhow!("provider unavailable at {}: {e}", self.socket.display()))?;
        let request = json!({
            "op":"effect","key":key,"name":name,"business_key":business_key,
            "request_hex":hex(payload),"request_hash":hash(payload)
        });
        stream.write_all(&serde_json::to_vec(&request)?)?;
        stream.write_all(b"\n")?;
        stream.flush()?;
        if mid != MidCall::Proceed {
            die(mid);
        }
        let line = read_line_bounded(&stream)?;
        let reply: Value = serde_json::from_str(line.trim_end())
            .map_err(|e| anyhow!("provider reply unreadable: {e}"))?;
        if let Some(err) = reply.get("error").and_then(Value::as_str) {
            return Err(anyhow!("{err}"));
        }
        let status = reply["status"]
            .as_str()
            .ok_or_else(|| anyhow!("provider reply missing status"))?
            .to_string();
        let result = unhex(
            reply["result_hex"]
                .as_str()
                .ok_or_else(|| anyhow!("provider reply missing result"))?,
        )?;
        Ok((status, result))
    }

    pub fn shutdown(&self) -> Result<()> {
        let mut stream = UnixStream::connect(&self.socket)?;
        stream.write_all(b"{\"op\":\"shutdown\"}\n")?;
        stream.flush()?;
        let _ = read_line_bounded(&stream);
        Ok(())
    }
}

/// Connect to a provider already listening on `socket`, or spawn one from
/// `exe` (normally the current executable) and wait for it to listen. A
/// provider spawned here deliberately outlives an aborting executor; if it
/// was killed too, the new one rebuilds its idempotency state from `log`.
pub fn ensure(exe: &Path, socket: &Path, scenario: &Path, log: &Path) -> Result<ProviderClient> {
    if ProviderClient::connectable(socket) {
        return Ok(ProviderClient {
            socket: socket.to_path_buf(),
            pid: None,
        });
    }
    let _ = fs::remove_file(socket);
    let child = Command::new(exe)
        .args([
            "provider",
            "--socket",
            &socket.display().to_string(),
            "--scenario",
            &scenario.display().to_string(),
            "--log",
            &log.display().to_string(),
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| anyhow!("cannot spawn provider: {e}"))?;
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if ProviderClient::connectable(socket) {
            return Ok(ProviderClient {
                socket: socket.to_path_buf(),
                pid: Some(child.id()),
            });
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    Err(anyhow!("provider did not start"))
}

#[derive(Clone)]
struct Bound {
    name: String,
    business_key: String,
    request_hash: String,
    result: Vec<u8>,
}

struct Server {
    canned: BTreeMap<String, Vec<Value>>,
    consumed: BTreeMap<String, usize>,
    executed: BTreeMap<String, Bound>,
    log_path: PathBuf,
    seq: u64,
    previous: String,
}

impl Server {
    /// Rebuild from a verified existing log, or start fresh.
    fn open(canned: BTreeMap<String, Vec<Value>>, log_path: &Path) -> Result<Self> {
        let mut server = Server {
            canned,
            consumed: BTreeMap::new(),
            executed: BTreeMap::new(),
            log_path: log_path.to_path_buf(),
            seq: 0,
            previous: "0".repeat(64),
        };
        if log_path.exists() {
            truncate_torn_tail(log_path)?;
            let entries = read_log(log_path)?;
            for e in &entries {
                if e["status"] == "executed" {
                    let result = unhex(e["result_hex"].as_str().unwrap_or(""))?;
                    server.executed.insert(
                        e["key"].as_str().unwrap_or("").to_string(),
                        Bound {
                            name: e["name"].as_str().unwrap_or("").into(),
                            business_key: e["business_key"].as_str().unwrap_or("").into(),
                            request_hash: e["request_hash"].as_str().unwrap_or("").into(),
                            result,
                        },
                    );
                    *server
                        .consumed
                        .entry(e["name"].as_str().unwrap_or("").to_string())
                        .or_default() += 1;
                }
                server.seq = e["sequence"].as_u64().unwrap_or(0) + 1;
                server.previous = e["entry_hash"].as_str().unwrap_or("").to_string();
            }
            server.record(json!({"kind":"restart","rebuilt_keys":server.executed.len()}))?;
        } else {
            server.record(json!({"kind":"start"}))?;
        }
        Ok(server)
    }

    fn record(&mut self, mut body: Value) -> Result<()> {
        body["schema"] = json!(PROVIDER_LOG);
        body["sequence"] = json!(self.seq);
        body["previous_hash"] = json!(self.previous);
        let entry_hash = hash(&canonical(&body).map_err(|e| anyhow!(e))?);
        body["entry_hash"] = json!(entry_hash);
        let mut bytes = canonical(&body).map_err(|e| anyhow!(e))?;
        bytes.push(b'\n');
        let created = !self.log_path.exists();
        let mut f = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.log_path)?;
        f.write_all(&bytes)?;
        f.sync_data()?;
        if created {
            let parent = self
                .log_path
                .parent()
                .ok_or_else(|| anyhow!("provider log path has no parent"))?;
            File::open(parent)?.sync_all()?;
        }
        self.seq += 1;
        self.previous = entry_hash;
        Ok(())
    }

    fn handle(&mut self, request: &Value) -> Result<Value> {
        let key = request["key"]
            .as_str()
            .ok_or_else(|| anyhow!("missing key"))?
            .to_string();
        let name = request["name"]
            .as_str()
            .ok_or_else(|| anyhow!("missing name"))?
            .to_string();
        let business_key = request["business_key"].as_str().unwrap_or("").to_string();
        let request_hash = request["request_hash"].as_str().unwrap_or("").to_string();
        let claimed_bytes = unhex(request["request_hex"].as_str().unwrap_or(""))?;
        if hash(&claimed_bytes) != request_hash {
            return Ok(json!({"error":"request hash does not match request bytes"}));
        }
        let meta = json!({
            "kind":"request","key":key,"name":name,"business_key":business_key,
            "request_hash":request_hash
        });
        if let Some(bound) = self.executed.get(&key).cloned() {
            if bound.name != name
                || bound.business_key != business_key
                || bound.request_hash != request_hash
            {
                let mut e = meta.clone();
                e["status"] = json!("mismatch");
                e["result_hash"] = Value::Null;
                e["bound_request_hash"] = json!(bound.request_hash);
                self.record(e)?;
                return Ok(json!({"error":"effect key is bound to a different request"}));
            }
            let mut e = meta;
            e["status"] = json!("duplicate");
            e["result_hash"] = json!(hash(&bound.result));
            self.record(e)?;
            return Ok(json!({"status":"duplicate","result_hex":hex(&bound.result)}));
        }
        let pos = self.consumed.get(&name).copied().unwrap_or_default();
        let Some(value) = self.canned.get(&name).and_then(|x| x.get(pos)) else {
            let mut e = meta;
            e["status"] = json!("rejected");
            e["result_hash"] = Value::Null;
            self.record(e)?;
            return Ok(json!({"error":format!("undeclared effect {name}")}));
        };
        let result = serde_json::to_vec(value)?;
        let bound = Bound {
            name: name.clone(),
            business_key: business_key.clone(),
            request_hash: request_hash.clone(),
            result: result.clone(),
        };
        let mut e = meta;
        e["status"] = json!("executed");
        e["result_hash"] = json!(hash(&result));
        e["result_hex"] = json!(hex(&result));
        // The durable record is the commit point. Never publish volatile
        // exactly-once state before the append and sync have succeeded.
        self.record(e)?;
        self.consumed.insert(name, pos + 1);
        self.executed.insert(key, bound);
        Ok(json!({"status":"executed","result_hex":hex(&result)}))
    }
}

/// Serve canned responses until a shutdown request arrives. Blocks.
pub fn serve(socket: &Path, canned: BTreeMap<String, Vec<Value>>, log: &Path) -> Result<()> {
    let _ = fs::remove_file(socket);
    let listener = UnixListener::bind(socket)?;
    let mut server = Server::open(canned, log)?;
    for stream in listener.incoming() {
        let stream = match stream {
            Ok(s) => s,
            Err(_) => continue,
        };
        let line = match read_line_bounded(&stream) {
            Ok(l) => l,
            Err(_) => continue,
        };
        let request: Value = match serde_json::from_str(line.trim_end()) {
            Ok(v) => v,
            Err(_) => continue,
        };
        if request["op"] == "shutdown" {
            server.record(json!({"kind":"shutdown"}))?;
            let mut s = &stream;
            let _ = s.write_all(b"{\"status\":\"bye\"}\n");
            let _ = fs::remove_file(socket);
            return Ok(());
        }
        // Execute and log before replying, so a client that dies mid-call
        // still leaves the effect executed exactly once.
        // A durability error makes the provider's state uncertain. Fail
        // closed instead of serving further requests from volatile state.
        let reply = server.handle(&request)?;
        let mut s = &stream;
        let _ = s.write_all(&serde_json::to_vec(&reply)?);
        let _ = s.write_all(b"\n");
    }
    Ok(())
}

fn truncate_torn_tail(path: &Path) -> Result<()> {
    let bytes = fs::read(path)?;
    if bytes.is_empty() || bytes.last() == Some(&b'\n') {
        return Ok(());
    }
    let complete = bytes.iter().rposition(|b| *b == b'\n').map_or(0, |i| i + 1);
    let file = OpenOptions::new().write(true).open(path)?;
    file.set_len(complete as u64)?;
    file.sync_all()?;
    Ok(())
}

/// Parse and chain-verify the provider log written by `serve`.
pub fn read_log(path: &Path) -> Result<Vec<Value>> {
    let text = fs::read_to_string(path)?;
    let mut out = vec![];
    let mut previous = "0".repeat(64);
    for (i, line) in text.lines().enumerate() {
        let mut v: Value = serde_json::from_str(line)?;
        let claimed = v["entry_hash"].as_str().unwrap_or("").to_string();
        v.as_object_mut().unwrap().remove("entry_hash");
        if v["schema"] != PROVIDER_LOG
            || v["sequence"] != json!(i as u64)
            || v["previous_hash"] != json!(previous)
            || hash(&canonical(&v).map_err(|e| anyhow!(e))?) != claimed
        {
            return Err(anyhow!("invalid provider log entry {i}"));
        }
        v["entry_hash"] = json!(claimed);
        previous = claimed;
        out.push(v);
    }
    Ok(out)
}
