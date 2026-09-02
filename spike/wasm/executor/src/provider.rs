//! Out-of-process effect provider.
//!
//! The executor never holds canned provider responses. It sends every
//! external effect over a Unix socket to this server, which is idempotent by
//! the host-derived effect key and appends a hash-chained log of every
//! request it receives. "At most one externally visible operation per key"
//! is therefore measured by a process that does not run the guest.

use crate::{canonical, hash, hex, unhex};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    fs::{self, OpenOptions},
    io::{BufRead, BufReader, Write},
    os::unix::net::{UnixListener, UnixStream},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{Duration, Instant},
};

pub const PROVIDER_LOG: &str = "ld.provider/v1";

/// Client side: one connection per request. `kill_during` aborts the process
/// after the request bytes are on the wire and before any reply is read.
pub struct ProviderClient {
    pub socket: PathBuf,
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
        kill_during: bool,
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
        if kill_during {
            std::process::abort();
        }
        let mut line = String::new();
        BufReader::new(&stream).read_line(&mut line)?;
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
        let mut line = String::new();
        let _ = BufReader::new(&stream).read_line(&mut line);
        Ok(())
    }
}

/// Connect to a provider already listening on `socket`, or spawn one from
/// `exe` (normally the current executable) and wait for it to listen. A
/// provider spawned here deliberately outlives an aborting executor so that
/// `resume` finds the same idempotency state.
pub fn ensure(exe: &Path, socket: &Path, scenario: &Path, log: &Path) -> Result<ProviderClient> {
    if ProviderClient::connectable(socket) {
        return Ok(ProviderClient {
            socket: socket.to_path_buf(),
        });
    }
    let _ = fs::remove_file(socket);
    Command::new(exe)
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
            });
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    Err(anyhow!("provider did not start"))
}

struct Server {
    canned: BTreeMap<String, Vec<Value>>,
    consumed: BTreeMap<String, usize>,
    executed: BTreeMap<String, Vec<u8>>,
    log_path: PathBuf,
    seq: u64,
    previous: String,
}

impl Server {
    fn record(&mut self, mut body: Value) -> Result<()> {
        body["schema"] = json!(PROVIDER_LOG);
        body["sequence"] = json!(self.seq);
        body["previous_hash"] = json!(self.previous);
        let entry_hash = hash(&canonical(&body).map_err(|e| anyhow!(e))?);
        body["entry_hash"] = json!(entry_hash);
        let mut bytes = canonical(&body).map_err(|e| anyhow!(e))?;
        bytes.push(b'\n');
        let mut f = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.log_path)?;
        f.write_all(&bytes)?;
        f.sync_data()?;
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
        if let Some(result) = self.executed.get(&key).cloned() {
            self.record(json!({
                "kind":"request","key":key,"name":name,"business_key":business_key,
                "request_hash":request_hash,"status":"duplicate","result_hash":hash(&result)
            }))?;
            return Ok(json!({"status":"duplicate","result_hex":hex(&result)}));
        }
        let pos = self.consumed.entry(name.clone()).or_default();
        let Some(value) = self.canned.get(&name).and_then(|x| x.get(*pos)) else {
            self.record(json!({
                "kind":"request","key":key,"name":name,"business_key":business_key,
                "request_hash":request_hash,"status":"rejected","result_hash":Value::Null
            }))?;
            return Ok(json!({"error":format!("undeclared effect {name}")}));
        };
        *pos += 1;
        let result = serde_json::to_vec(value)?;
        self.executed.insert(key.clone(), result.clone());
        self.record(json!({
            "kind":"request","key":key,"name":name,"business_key":business_key,
            "request_hash":request_hash,"status":"executed","result_hash":hash(&result)
        }))?;
        Ok(json!({"status":"executed","result_hex":hex(&result)}))
    }
}

/// Serve canned responses until a shutdown request arrives. Blocks.
pub fn serve(socket: &Path, canned: BTreeMap<String, Vec<Value>>, log: &Path) -> Result<()> {
    let _ = fs::remove_file(socket);
    let listener = UnixListener::bind(socket)?;
    let mut server = Server {
        canned,
        consumed: BTreeMap::new(),
        executed: BTreeMap::new(),
        log_path: log.to_path_buf(),
        seq: 0,
        previous: "0".repeat(64),
    };
    server.record(json!({"kind":"start"}))?;
    for stream in listener.incoming() {
        let stream = match stream {
            Ok(s) => s,
            Err(_) => continue,
        };
        let mut line = String::new();
        if BufReader::new(&stream).read_line(&mut line).is_err() {
            continue;
        }
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
        let reply = match server.handle(&request) {
            Ok(r) => r,
            Err(e) => json!({"error":e.to_string()}),
        };
        let mut s = &stream;
        let _ = s.write_all(&serde_json::to_vec(&reply)?);
        let _ = s.write_all(b"\n");
    }
    Ok(())
}

/// Parse the provider log written by `serve`.
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
