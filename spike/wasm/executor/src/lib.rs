//! `wasm-durable-v1` executor.
//!
//! One guest component, one scenario, several routes over the same events:
//!
//! * `parent`: live run; effects go to the out-of-process provider through a
//!   write-ahead intent/commit journal; a checkpoint of guest bytes *and* host
//!   state is taken mid-route
//! * `replay-N`: genesis replay from the journal; no provider exists
//! * `recovered`: fresh instance restored from the checkpoint (guest bytes,
//!   logical clock, RNG position, event and effect indexes), then the suffix
//!   replayed from the journal
//! * `fork`: the parent prefix replayed, then a different live suffix on
//!   branch `fork`
//!
//! Every entry is appended to `oplog.jsonl` online and fsync'd, so a process
//! kill at any declared point leaves a journal that `resume` completes in a
//! new process. The executor also computes advisory properties, but the BEAM
//! verifier (`LdHost.RuntimeEvidence`) re-derives every one of them from the
//! files; the receipt's `passed` is not the verdict.

use anyhow::{Result, anyhow};
use rand_chacha::ChaCha20Rng;
use rand_core::{RngCore, SeedableRng};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Component as PathComponent, Path, PathBuf},
};
use wasmtime::component::{Component, HasSelf, Linker};

wasmtime::component::bindgen!({path:"../wit",world:"product"});

pub mod provider;

pub const RECEIPT: &str = "ld.runtime.receipt/v1";
pub const OPLOG: &str = "ld.oplog/v2";
pub const CHECKPOINT: &str = "ld.checkpoint/v1";
pub const CHECKPOINT_VERSION: u64 = 2;
pub const RUN_STATE: &str = "ld.run/v1";
pub const PROFILE: &str = "wasm-durable-v1";
pub const MACHINE_SCHEMA: &str = "livingdict.machine/v1";
pub const WORLD: &str = "livingdict:durable/product@0.2.0";
/// Pinned by a test against `Cargo.lock`.
pub const WASMTIME_VERSION: &str = "48.0.1";
pub const WIT_SOURCE: &str = include_str!("../../wit/durable.wit");
pub const TOOLCHAIN_SOURCE: &str = include_str!("../../rust-toolchain.toml");
pub const CARGO_LOCK_SOURCE: &str = include_str!("../../Cargo.lock");

pub const KINDS: [&str; 15] = [
    "worker-creation",
    "invocation",
    "capability-request",
    "capability-result",
    "effect-intent",
    "effect-reissue",
    "effect-commit",
    "semantic-output",
    "checkpoint",
    "snapshot-roundtrip",
    "fault-injection",
    "resume",
    "claim-observation",
    "exit",
    "trap",
];

// ---------------------------------------------------------------- config

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Machine {
    pub schema: String,
    pub profile: String,
    pub component_package: String,
    pub component: String,
    pub world: String,
    pub scenarios: Vec<String>,
    pub limits: Limits,
    pub capabilities: Capabilities,
}
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Limits {
    pub fuel: u64,
    pub memory_bytes: u64,
    pub max_invocations: u64,
    pub max_frame_bytes: u64,
    /// Oplog budget, enforced before every append.
    pub max_log_bytes: u64,
    /// Largest output frame a guest may return.
    #[serde(default = "d_output")]
    pub max_output_bytes: u64,
    /// Largest snapshot a guest may return.
    #[serde(default = "d_snapshot")]
    pub max_snapshot_bytes: u64,
    /// Largest effect payload or provider result.
    #[serde(default = "d_effect")]
    pub max_effect_bytes: u64,
    /// Cumulative output bytes retained across all routes.
    #[serde(default = "d_total_output")]
    pub max_total_output_bytes: u64,
    /// Upper bound on the scenario's replay_count.
    #[serde(default = "d_replays")]
    pub max_replay_count: u64,
}
fn d_output() -> u64 {
    65536
}
fn d_snapshot() -> u64 {
    1 << 20
}
fn d_effect() -> u64 {
    65536
}
fn d_total_output() -> u64 {
    8 << 20
}
fn d_replays() -> u64 {
    8
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Capabilities {
    pub clock: String,
    pub random: String,
    pub filesystem: String,
    pub network: String,
    pub environment: String,
    pub threads: String,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Scenario {
    pub schema: String,
    pub id: String,
    pub seed: u64,
    pub worker_id: String,
    pub prefix: Vec<Value>,
    pub parent: Vec<Value>,
    pub fork: Vec<Value>,
    pub checkpoint_index: usize,
    pub replay_count: u64,
    pub providers: BTreeMap<String, Vec<Value>>,
    pub expected_properties: Vec<String>,
    /// Effect name the kill matrix targets (first occurrence on `parent`).
    #[serde(default)]
    pub kill_effect: Option<String>,
    /// Witnesses for `effects-exactly-once`: effect name -> minimum number
    /// of logical commits the parent history must contain. Empty means the
    /// property cannot be granted (it would be vacuous).
    #[serde(default)]
    pub expected_effects: BTreeMap<String, u64>,
    /// SHA-256 of the scenario file bytes; filled by `load`, never parsed.
    #[serde(skip)]
    pub hash: String,
}

/// Evidence hashes are RFC 8785 canonical JSON; the BEAM verifier refuses
/// floats rather than approximating ES6 number formatting, so the producer
/// refuses them first.
pub fn no_floats(v: &Value) -> bool {
    match v {
        Value::Number(n) => n.is_i64() || n.is_u64(),
        Value::Array(a) => a.iter().all(no_floats),
        Value::Object(o) => o.values().all(no_floats),
        _ => true,
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum KillPoint {
    BeforeIntent,
    AfterIntent,
    DuringProvider,
    AfterProviderBeforeCommit,
    AfterCommitBeforeDeliver,
    AfterTransitionBeforeCheckpoint,
}
impl KillPoint {
    pub const ALL: [KillPoint; 6] = [
        KillPoint::BeforeIntent,
        KillPoint::AfterIntent,
        KillPoint::DuringProvider,
        KillPoint::AfterProviderBeforeCommit,
        KillPoint::AfterCommitBeforeDeliver,
        KillPoint::AfterTransitionBeforeCheckpoint,
    ];
    pub fn parse(s: &str) -> Result<Self> {
        serde_json::from_value(Value::String(s.into()))
            .map_err(|_| anyhow!("unknown kill point {s}"))
    }
    pub fn name(self) -> String {
        serde_json::to_value(self)
            .ok()
            .and_then(|v| v.as_str().map(str::to_string))
            .unwrap_or_default()
    }
}

// ---------------------------------------------------------------- hashing

pub fn hash(b: &[u8]) -> String {
    format!("{:x}", Sha256::digest(b))
}
pub fn canonical(v: &Value) -> std::result::Result<Vec<u8>, String> {
    serde_jcs::to_vec(v).map_err(|e| e.to_string())
}
pub fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
pub fn unhex(s: &str) -> Result<Vec<u8>> {
    if !s.len().is_multiple_of(2) {
        return Err(anyhow!("odd hex"));
    }
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).map_err(|e| anyhow!("bad hex: {e}")))
        .collect()
}
fn zero() -> String {
    "0".repeat(64)
}

/// Run identity: config bytes, scenario bytes, scenario id, seed.
/// Deterministic across replays and resumes, so effect keys are stable, and
/// bound to the exact scenario document.
pub fn run_id(config_hash: &str, scenario_hash: &str, scenario_id: &str, seed: u64) -> String {
    hash(
        &canonical(
            &json!({"config_hash":config_hash,"scenario_hash":scenario_hash,
                           "scenario_id":scenario_id,"seed":seed}),
        )
        .unwrap(),
    )
}

/// Host-derived effect identity. The guest's business key is metadata.
pub fn effect_key(
    run_id: &str,
    branch: &str,
    component_hash: &str,
    event_index: u64,
    effect_index: u64,
) -> String {
    hash(
        &canonical(&json!({
            "run_id":run_id,"branch":branch,"component_hash":component_hash,
            "event_index":event_index,"effect_index":effect_index
        }))
        .unwrap(),
    )
}

// ---------------------------------------------------------------- engine

/// Every Wasmtime setting the profile depends on, hashed into the receipt.
pub fn engine_settings() -> Value {
    json!({
        "wasmtime": WASMTIME_VERSION,
        "strategy": "cranelift",
        "opt_level": "speed",
        "wasm_component_model": true,
        "consume_fuel": true,
        "cranelift_nan_canonicalization": true,
        "wasm_relaxed_simd": false,
        "relaxed_simd_deterministic": true,
        "wasm_threads": false,
        "wasm_memory64": false,
        "wasm_multi_memory": false,
        "epoch_interruption": false,
        "parallel_compilation": false
    })
}
pub fn engine_config_hash() -> String {
    hash(&canonical(&engine_settings()).unwrap())
}
pub fn engine_attestation() -> Value {
    json!({
        "profile": PROFILE,
        "profile_schema": MACHINE_SCHEMA,
        "wasmtime_version": WASMTIME_VERSION,
        "config_hash": engine_config_hash(),
        "settings": engine_settings(),
        "target_triple": env!("LD_TARGET_TRIPLE"),
        "rustc": env!("LD_RUSTC_VERSION"),
        "toolchain_hash": hash(TOOLCHAIN_SOURCE.as_bytes()),
        "cargo_lock_hash": hash(CARGO_LOCK_SOURCE.as_bytes()),
        "executor_source_hash": env!("LD_EXECUTOR_SOURCE_HASH"),
        "world": WORLD,
        "world_hash": hash(WIT_SOURCE.as_bytes())
    })
}
fn engine() -> Result<wasmtime::Engine> {
    let mut cfg = wasmtime::Config::new();
    cfg.strategy(wasmtime::Strategy::Cranelift)
        .cranelift_opt_level(wasmtime::OptLevel::Speed)
        .wasm_component_model(true)
        .consume_fuel(true)
        .cranelift_nan_canonicalization(true)
        .wasm_relaxed_simd(false)
        .relaxed_simd_deterministic(true)
        // Threads are compiled out (no `threads` crate feature), so the
        // proposal cannot be enabled at all; the setting is still recorded.
        .wasm_memory64(false)
        .wasm_multi_memory(false)
        .epoch_interruption(false);
    // `parallel_compilation` is compiled out (no `parallel-compilation`
    // feature), so compilation is serial; recorded in the settings hash.
    wt(wasmtime::Engine::new(&cfg))
}

// ---------------------------------------------------------------- oplog

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entry {
    pub schema: String,
    pub sequence: u64,
    pub kind: String,
    pub route: String,
    pub component_hash: String,
    pub worker: String,
    pub scenario_seed: u64,
    pub input: Value,
    pub result: Value,
    pub state_hash_before: String,
    pub state_hash_after: String,
    pub previous_entry_hash: String,
    pub entry_hash: String,
}
fn body(e: &Entry) -> Value {
    json!({"schema":e.schema,"sequence":e.sequence,"kind":e.kind,"route":e.route,"component_hash":e.component_hash,"worker":e.worker,"scenario_seed":e.scenario_seed,"input":e.input,"result":e.result,"state_hash_before":e.state_hash_before,"state_hash_after":e.state_hash_after,"previous_entry_hash":e.previous_entry_hash})
}

#[derive(Clone)]
pub struct Ctx {
    pub component_hash: String,
    pub worker: String,
    pub seed: u64,
    pub run_id: String,
}

/// Append-only, fsync-per-entry oplog. `None` file means in-memory only
/// (used for the throwaway round-trip instance, which appends nothing).
pub struct OplogWriter {
    file: Option<File>,
    pub entries: Vec<Entry>,
    pub bytes: u64,
    max_bytes: u64,
}
impl OplogWriter {
    pub fn create(path: &Path, max_bytes: u64) -> Result<Self> {
        let file = OpenOptions::new()
            .create_new(true)
            .append(true)
            .open(path)?;
        file.sync_all()?;
        let parent = path
            .parent()
            .ok_or_else(|| anyhow!("oplog path has no parent"))?;
        File::open(parent)?.sync_all()?;
        Ok(Self {
            file: Some(file),
            entries: vec![],
            bytes: 0,
            max_bytes,
        })
    }
    pub fn open_existing(path: &Path, ctx: &Ctx, max_bytes: u64) -> Result<Self> {
        let raw = fs::read(path)?;
        let complete = if raw.is_empty() || raw.last() == Some(&b'\n') {
            raw.len()
        } else {
            raw.iter().rposition(|b| *b == b'\n').map_or(0, |i| i + 1)
        };
        if complete != raw.len() {
            let file = OpenOptions::new().write(true).open(path)?;
            file.set_len(complete as u64)?;
            file.sync_all()?;
        }
        let text = std::str::from_utf8(&raw[..complete])?;
        let mut entries = vec![];
        for line in text.lines() {
            entries.push(serde_json::from_str::<Entry>(line)?);
        }
        verify(&entries, &ctx.component_hash, &ctx.worker, ctx.seed)?;
        let file = OpenOptions::new().append(true).open(path)?;
        Ok(Self {
            file: Some(file),
            bytes: text.len() as u64,
            entries,
            max_bytes,
        })
    }
    fn memory() -> Self {
        Self {
            file: None,
            entries: vec![],
            bytes: 0,
            max_bytes: u64::MAX,
        }
    }
    #[allow(clippy::too_many_arguments)]
    pub fn append(
        &mut self,
        kind: &str,
        route: &str,
        ctx: &Ctx,
        input: Value,
        result: Value,
        before: &str,
        after: &str,
    ) -> Result<()> {
        let prev = self
            .entries
            .last()
            .map(|x| x.entry_hash.clone())
            .unwrap_or_else(zero);
        let mut e = Entry {
            schema: OPLOG.into(),
            sequence: self.entries.len() as u64,
            kind: kind.into(),
            route: route.into(),
            component_hash: ctx.component_hash.clone(),
            worker: ctx.worker.clone(),
            scenario_seed: ctx.seed,
            input,
            result,
            state_hash_before: before.into(),
            state_hash_after: after.into(),
            previous_entry_hash: prev,
            entry_hash: String::new(),
        };
        e.entry_hash = hash(&canonical(&body(&e)).map_err(|x| anyhow!(x))?);
        if let Some(f) = self.file.as_mut() {
            let mut line = canonical(&serde_json::to_value(&e)?).map_err(|x| anyhow!(x))?;
            line.push(b'\n');
            if self.bytes + line.len() as u64 > self.max_bytes {
                return Err(anyhow!("log limit exhausted"));
            }
            f.write_all(&line)?;
            f.sync_data()?;
            self.bytes += line.len() as u64;
        }
        self.entries.push(e);
        Ok(())
    }
    pub fn last_hash(&self) -> String {
        self.entries
            .last()
            .map(|x| x.entry_hash.clone())
            .unwrap_or_else(zero)
    }
}

pub fn verify(log: &[Entry], component: &str, worker: &str, seed: u64) -> Result<()> {
    let allowed: BTreeSet<_> = KINDS.into_iter().collect();
    let mut prev = zero();
    for (i, e) in log.iter().enumerate() {
        if e.schema != OPLOG
            || e.sequence != i as u64
            || e.previous_entry_hash != prev
            || e.component_hash != component
            || e.worker != worker
            || e.scenario_seed != seed
            || !allowed.contains(e.kind.as_str())
            || hash(&canonical(&body(e)).map_err(|x| anyhow!(x))?) != e.entry_hash
        {
            return Err(anyhow!("invalid oplog entry {i}"));
        }
        prev = e.entry_hash.clone()
    }
    Ok(())
}

/// Committed effects, keyed by host effect key, rebuilt from the oplog.
#[derive(Clone, Debug)]
pub struct Committed {
    pub name: String,
    pub business_key: String,
    pub request_hash: String,
    pub result: Vec<u8>,
}
/// A journaled intent that has no commit yet. Re-issue after a crash must
/// carry exactly this request; anything else is a different effect.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Intent {
    pub name: String,
    pub business_key: String,
    pub request_hash: String,
    pub branch: String,
    pub event_index: u64,
    pub effect_index: u64,
}
pub struct Journal {
    pub committed: BTreeMap<String, Committed>,
    pub intents: BTreeMap<String, Intent>,
}
impl Journal {
    fn empty() -> Self {
        Self {
            committed: BTreeMap::new(),
            intents: BTreeMap::new(),
        }
    }
}
pub fn journal_from(entries: &[Entry]) -> Result<Journal> {
    let mut committed = BTreeMap::new();
    let mut intents = BTreeMap::new();
    for e in entries {
        let key = e.input["key"].as_str().unwrap_or("").to_string();
        match e.kind.as_str() {
            "effect-intent" => {
                intents.insert(
                    key,
                    Intent {
                        name: e.input["name"].as_str().unwrap_or("").into(),
                        business_key: e.input["business_key"].as_str().unwrap_or("").into(),
                        request_hash: e.input["request_hash"].as_str().unwrap_or("").into(),
                        branch: e.input["branch"].as_str().unwrap_or("").into(),
                        event_index: e.input["event_index"].as_u64().unwrap_or(u64::MAX),
                        effect_index: e.input["effect_index"].as_u64().unwrap_or(u64::MAX),
                    },
                );
            }
            "effect-commit" => {
                intents.remove(&key);
                committed.insert(
                    key,
                    Committed {
                        name: e.input["name"].as_str().unwrap_or("").into(),
                        business_key: e.input["business_key"].as_str().unwrap_or("").into(),
                        request_hash: e.input["request_hash"].as_str().unwrap_or("").into(),
                        result: unhex(e.result["result_hex"].as_str().unwrap_or(""))?,
                    },
                );
            }
            _ => {}
        }
    }
    Ok(Journal { committed, intents })
}

// ---------------------------------------------------------------- host

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HostState {
    pub time: u64,
    pub rng_seed: u64,
    /// ChaCha20 word position, decimal string (u128).
    pub rng_word_pos: String,
    pub event_index: u64,
    pub effect_index: u64,
}
impl HostState {
    fn genesis(seed: u64) -> Self {
        Self {
            time: 0,
            rng_seed: seed,
            rng_word_pos: "0".into(),
            event_index: 0,
            effect_index: 0,
        }
    }
}
fn rng_from(state: &HostState) -> Result<ChaCha20Rng> {
    let mut seed = [0u8; 32];
    seed[..8].copy_from_slice(&state.rng_seed.to_le_bytes());
    let mut rng = ChaCha20Rng::from_seed(seed);
    let pos: u128 = state
        .rng_word_pos
        .parse()
        .map_err(|_| anyhow!("bad rng position"))?;
    rng.set_word_pos(pos);
    Ok(rng)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Checkpoint {
    pub schema: String,
    pub schema_version: u64,
    pub bytes: String,
    pub bytes_hash: String,
    pub component_hash: String,
    pub guest_state_hash: String,
    pub oplog_index: u64,
    pub host: HostState,
    pub branch: String,
    pub world_hash: String,
    pub run_id: String,
    pub scenario_hash: String,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mode {
    Record,
    Replay,
}
/// How the kill matrix takes the process down. `Abort` journals a
/// `fault-injection` annotation first; `Sigkill` writes nothing and, when
/// asked, takes the provider down too, so recovery is exercised the way a
/// real crash leaves things.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KillMode {
    Abort,
    Sigkill,
}
impl KillMode {
    pub fn parse(s: &str) -> Result<Self> {
        match s {
            "abort" => Ok(KillMode::Abort),
            "sigkill" => Ok(KillMode::Sigkill),
            _ => Err(anyhow!("unknown kill mode {s}")),
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            KillMode::Abort => "abort",
            KillMode::Sigkill => "sigkill",
        }
    }
}
#[derive(Clone, Copy)]
struct Kill {
    point: KillPoint,
    mode: KillMode,
    kill_provider: bool,
}

struct Host {
    limits: wasmtime::StoreLimits,
    state: HostState,
    rng: ChaCha20Rng,
    branch: String,
    route: String,
    mode: Mode,
    provider: Option<provider::ProviderClient>,
    journal: BTreeMap<String, Committed>,
    intents: BTreeMap<String, Intent>,
    log: OplogWriter,
    ctx: Ctx,
    current_state_hash: String,
    kill: Option<Kill>,
    kill_effect: String,
    max_effect_bytes: u64,
    live: u64,
    replayed: u64,
    effects: Vec<(String, String, String)>, // (key, name, status)
}

impl Host {
    fn append(&mut self, kind: &str, input: Value, result: Value) -> Result<()> {
        let before = self.current_state_hash.clone();
        let route = self.route.clone();
        let ctx = self.ctx.clone();
        self.log
            .append(kind, &route, &ctx, input, result, &before, &before)
    }
    fn maybe_kill(&mut self, point: KillPoint, effect: &str, key: &str) -> Result<()> {
        let Some(k) = self.kill else { return Ok(()) };
        if k.point != point {
            return Ok(());
        }
        if point != KillPoint::AfterTransitionBeforeCheckpoint && effect != self.kill_effect {
            return Ok(());
        }
        provider::die(self.death(point, effect, key)?);
    }
    /// The action for a kill point: an annotated abort, or an unannounced
    /// SIGKILL (optionally taking the provider down first).
    fn death(&mut self, point: KillPoint, effect: &str, key: &str) -> Result<provider::MidCall> {
        let k = self.kill.expect("kill configured");
        match k.mode {
            KillMode::Abort => {
                self.append(
                    "fault-injection",
                    json!({"point":point.name(),"effect":effect,"key":key,"mode":"abort"}),
                    json!({"aborting":true}),
                )?;
                Ok(provider::MidCall::Abort)
            }
            KillMode::Sigkill => Ok(provider::MidCall::Sigkill {
                provider_pid: if k.kill_provider {
                    self.provider.as_ref().and_then(|p| p.pid)
                } else {
                    None
                },
            }),
        }
    }
}

impl livingdict::durable::capabilities::Host for Host {
    fn virtual_time(&mut self) -> u64 {
        self.state.time
    }
    fn seeded_random(&mut self, n: u32) -> Vec<u8> {
        let mut x = vec![0; n as usize];
        self.rng.fill_bytes(&mut x);
        self.state.rng_word_pos = self.rng.get_word_pos().to_string();
        x
    }
    fn external_effect(
        &mut self,
        name: String,
        business_key: String,
        payload: Vec<u8>,
    ) -> std::result::Result<Vec<u8>, String> {
        self.effect(name, business_key, payload)
            .map_err(|e| e.to_string())
    }
}

impl Host {
    fn effect(&mut self, name: String, business_key: String, payload: Vec<u8>) -> Result<Vec<u8>> {
        let key = effect_key(
            &self.ctx.run_id,
            &self.branch,
            &self.ctx.component_hash,
            self.state.event_index,
            self.state.effect_index,
        );
        self.state.effect_index += 1;
        if payload.len() as u64 > self.max_effect_bytes {
            return Err(anyhow!("effect payload limit exhausted"));
        }
        let request_hash = hash(&payload);
        let meta = json!({
            "key":key,"name":name,"business_key":business_key,"request_hash":request_hash,
            "branch":self.branch,"event_index":self.state.event_index,
            "effect_index":self.state.effect_index-1
        });
        self.append("capability-request", meta.clone(), json!({}))?;
        if let Some(c) = self.journal.get(&key).cloned() {
            if c.name != name || c.business_key != business_key || c.request_hash != request_hash {
                return Err(anyhow!("journal mismatch for effect {name}"));
            }
            self.append(
                "capability-result",
                json!({"key":key,"name":name,"source":"journal"}),
                json!({"result_hash":hash(&c.result)}),
            )?;
            self.replayed += 1;
            self.effects.push((key, name, "journal".into()));
            return Ok(c.result);
        }
        if self.mode == Mode::Replay {
            return Err(anyhow!("missing committed effect for replay of {name}"));
        }
        let intent = Intent {
            name: name.clone(),
            business_key: business_key.clone(),
            request_hash: request_hash.clone(),
            branch: self.branch.clone(),
            event_index: self.state.event_index,
            effect_index: self.state.effect_index - 1,
        };
        if let Some(journaled) = self.intents.get(&key) {
            if *journaled != intent {
                return Err(anyhow!(
                    "reissue of {name} differs from the journaled intent at the same position"
                ));
            }
            if self.provider.is_none() {
                return Err(anyhow!("no provider for live effect {name}"));
            }
            self.append("effect-reissue", meta.clone(), json!({}))?;
        } else {
            if self.provider.is_none() {
                return Err(anyhow!("no provider for live effect {name}"));
            }
            self.maybe_kill(KillPoint::BeforeIntent, &name, &key)?;
            self.append("effect-intent", meta.clone(), json!({}))?;
            self.intents.insert(key.clone(), intent);
            self.maybe_kill(KillPoint::AfterIntent, &name, &key)?;
        }
        let kill_during = matches!(self.kill, Some(k) if k.point == KillPoint::DuringProvider)
            && name == self.kill_effect;
        let mid = if kill_during {
            // The process dies inside the provider call, after the request
            // bytes are on the wire. In abort mode the annotation is written
            // first; in sigkill mode nothing is.
            self.death(KillPoint::DuringProvider, &name, &key)?
        } else {
            provider::MidCall::Proceed
        };
        let (status, result) =
            self.provider
                .as_ref()
                .unwrap()
                .call(&key, &name, &business_key, &payload, mid)?;
        if result.len() as u64 > self.max_effect_bytes {
            return Err(anyhow!("effect result limit exhausted"));
        }
        self.maybe_kill(KillPoint::AfterProviderBeforeCommit, &name, &key)?;
        self.append(
            "effect-commit",
            meta,
            json!({"result_hash":hash(&result),"result_hex":hex(&result),"provider_status":status}),
        )?;
        self.intents.remove(&key);
        self.journal.insert(
            key.clone(),
            Committed {
                name: name.clone(),
                business_key,
                request_hash,
                result: result.clone(),
            },
        );
        self.maybe_kill(KillPoint::AfterCommitBeforeDeliver, &name, &key)?;
        self.append(
            "capability-result",
            json!({"key":key,"name":name,"source":"provider"}),
            json!({"result_hash":hash(&result)}),
        )?;
        self.live += 1;
        self.effects.push((key, name, status));
        Ok(result)
    }
}

// ---------------------------------------------------------------- routes

fn wt<T>(r: std::result::Result<T, wasmtime::Error>) -> Result<T> {
    r.map_err(|e| anyhow!(e.to_string()))
}
fn validate_imports(engine: &wasmtime::Engine, component: &Component) -> Result<()> {
    let ty = component.component_type();
    let names: Vec<String> = ty.imports(engine).map(|(n, _)| n.to_string()).collect();
    let allowed = format!(
        "livingdict:durable/capabilities@{}",
        WORLD.rsplit('@').next().unwrap()
    );
    for n in &names {
        if n != &allowed {
            return Err(anyhow!("undeclared import {n}"));
        }
    }
    Ok(())
}
fn confined(root: &Path, rel: &str) -> Result<PathBuf> {
    if Path::new(rel).is_absolute()
        || Path::new(rel)
            .components()
            .any(|c| matches!(c, PathComponent::ParentDir))
    {
        return Err(anyhow!("path escapes workspace"));
    }
    let root = root.canonicalize()?;
    let p = root.join(rel).canonicalize()?;
    if !p.starts_with(&root) {
        return Err(anyhow!("path escapes workspace"));
    }
    Ok(p)
}

pub struct Segment<'a> {
    pub events: &'a [Value],
    pub branch: &'a str,
    pub mode: Mode,
}
pub struct RouteSpec<'a> {
    pub route: &'a str,
    pub segments: Vec<Segment<'a>>,
    pub resume_from: Option<&'a Checkpoint>,
    pub checkpoint_after: Option<u64>,
    kill: Option<Kill>,
    pub kill_effect: String,
}
pub struct RouteResult {
    pub outputs: Vec<Vec<u8>>,
    pub snapshot: Vec<u8>,
    pub snapshot_hash: String,
    pub guest_state_hash: String,
    pub live: u64,
    pub replayed: u64,
    pub checkpoint: Option<Checkpoint>,
    pub roundtrips_ok: bool,
    pub host: HostState,
    pub effects: Vec<(String, String, String)>,
    /// (event_index, frame_hash, snapshot_hash_after)
    pub transitions: Vec<(u64, String, String)>,
}

struct Instance {
    store: wasmtime::Store<Host>,
    bindings: Product,
}
fn instantiate(
    engine: &wasmtime::Engine,
    component: &Component,
    m: &Machine,
    host: Host,
) -> Result<Instance> {
    let mut linker = Linker::new(engine);
    wt(Product::add_to_linker::<_, HasSelf<_>>(
        &mut linker,
        |h: &mut Host| h,
    ))?;
    let mut store = wasmtime::Store::new(engine, host);
    store.limiter(|h| &mut h.limits);
    wt(store.set_fuel(m.limits.fuel))?;
    let bindings = wt(Product::instantiate(&mut store, component, &linker))?;
    Ok(Instance { store, bindings })
}
fn limits(m: &Machine) -> wasmtime::StoreLimits {
    wasmtime::StoreLimitsBuilder::new()
        .memory_size(m.limits.memory_bytes as usize)
        .build()
}

/// Restore `bytes` into a throwaway instance and snapshot again. The guest's
/// `snapshot`/`restore` pair must round-trip byte for byte.
fn roundtrip(
    engine: &wasmtime::Engine,
    component: &Component,
    m: &Machine,
    ctx: &Ctx,
    seed: u64,
    bytes: &[u8],
) -> Result<bool> {
    let host = Host {
        limits: limits(m),
        state: HostState::genesis(seed),
        rng: rng_from(&HostState::genesis(seed))?,
        branch: "roundtrip".into(),
        route: "roundtrip".into(),
        mode: Mode::Replay,
        provider: None,
        journal: BTreeMap::new(),
        intents: BTreeMap::new(),
        log: OplogWriter::memory(),
        ctx: ctx.clone(),
        current_state_hash: zero(),
        kill: None,
        kill_effect: String::new(),
        max_effect_bytes: m.limits.max_effect_bytes,
        live: 0,
        replayed: 0,
        effects: vec![],
    };
    let mut inst = instantiate(engine, component, m, host)?;
    wt(inst.bindings.call_init(&mut inst.store, seed))?;
    inst.bindings
        .call_restore(&mut inst.store, bytes)
        .map_err(|e| anyhow!(e.to_string()))?
        .map_err(|e| anyhow!(e))?;
    let again = wt(inst.bindings.call_snapshot(&mut inst.store))?;
    Ok(again == bytes)
}

#[allow(clippy::too_many_arguments)]
fn execute(
    engine: &wasmtime::Engine,
    component: &Component,
    m: &Machine,
    s: &Scenario,
    ctx: &Ctx,
    spec: RouteSpec,
    log: OplogWriter,
    journal: Journal,
    provider: Option<provider::ProviderClient>,
) -> Result<(
    RouteResult,
    OplogWriter,
    Journal,
    Option<provider::ProviderClient>,
)> {
    let state = spec
        .resume_from
        .map(|c| c.host.clone())
        .unwrap_or_else(|| HostState::genesis(s.seed));
    let rng = rng_from(&state)?;
    let host = Host {
        limits: limits(m),
        state,
        rng,
        branch: spec
            .resume_from
            .map(|c| c.branch.clone())
            .unwrap_or_else(|| "parent".into()),
        route: spec.route.into(),
        mode: Mode::Replay,
        provider,
        journal: journal.committed,
        intents: journal.intents,
        log,
        ctx: ctx.clone(),
        current_state_hash: zero(),
        kill: spec.kill,
        kill_effect: spec.kill_effect.clone(),
        max_effect_bytes: m.limits.max_effect_bytes,
        live: 0,
        replayed: 0,
        effects: vec![],
    };
    let mut inst = instantiate(engine, component, m, host)?;
    let route = spec.route.to_string();
    let initial_state = inst.store.data().state.clone();
    inst.store.data_mut().append(
        "worker-creation",
        json!({"rng":"chacha20-0.9","package":m.component_package,"resumed_from_checkpoint":spec.resume_from.is_some(),
               "host":initial_state}),
        json!({}),
    )?;
    wt(inst.bindings.call_init(&mut inst.store, s.seed))?;
    let mut roundtrips_ok = true;
    if let Some(cp) = spec.resume_from {
        let bytes = unhex(&cp.bytes)?;
        if hash(&bytes) != cp.bytes_hash {
            return Err(anyhow!("checkpoint bytes hash mismatch"));
        }
        inst.bindings
            .call_restore(&mut inst.store, &bytes)
            .map_err(|e| anyhow!(e.to_string()))?
            .map_err(|e| anyhow!(e))?;
        let again = wt(inst.bindings.call_snapshot(&mut inst.store))?;
        let ok = again == bytes;
        roundtrips_ok &= ok;
        inst.store.data_mut().current_state_hash = hash(&again);
        inst.store.data_mut().append(
            "snapshot-roundtrip",
            json!({"at":"restore","bytes_hash":cp.bytes_hash}),
            json!({"equal":ok,"resnapshot_hash":hash(&again)}),
        )?;
    }
    let mut outputs = vec![];
    let mut transitions = vec![];
    let mut checkpoint = None;
    let mut invocations = 0u64;
    let mut retained = 0u64;
    for seg in &spec.segments {
        {
            let h = inst.store.data_mut();
            h.branch = seg.branch.into();
            h.mode = seg.mode;
        }
        for e in seg.events {
            if invocations >= m.limits.max_invocations {
                return Err(anyhow!("invocation limit exhausted"));
            }
            invocations += 1;
            {
                let h = inst.store.data_mut();
                h.state.time = h
                    .state
                    .time
                    .checked_add(e.get("advance_ms").and_then(Value::as_u64).unwrap_or(1))
                    .ok_or_else(|| anyhow!("virtual time overflow"))?;
            }
            let frame = canonical(e).map_err(|x| anyhow!(x))?;
            if frame.len() as u64 > m.limits.max_frame_bytes {
                return Err(anyhow!("frame limit exhausted"));
            }
            let before = inst.store.data().current_state_hash.clone();
            let event_index = inst.store.data().state.event_index;
            let out = inst
                .bindings
                .call_handle(&mut inst.store, &frame)
                .map_err(|e| anyhow!(e.to_string()))?
                .map_err(|e| anyhow!(e))?;
            if out.len() as u64 > m.limits.max_output_bytes {
                return Err(anyhow!("output limit exhausted"));
            }
            retained += out.len() as u64;
            if retained > m.limits.max_total_output_bytes {
                return Err(anyhow!("total output limit exhausted"));
            }
            let snap = wt(inst.bindings.call_snapshot(&mut inst.store))?;
            if snap.len() as u64 > m.limits.max_snapshot_bytes {
                return Err(anyhow!("snapshot limit exhausted"));
            }
            let after = hash(&snap);
            {
                let h = inst.store.data_mut();
                h.current_state_hash = after.clone();
                h.state.event_index += 1;
                let st = h.state.clone();
                h.log.append(
                    "invocation",
                    &route,
                    ctx,
                    json!({"event_index":event_index,"branch":seg.branch,"frame":e,"mode":format!("{:?}",seg.mode).to_lowercase()}),
                    json!({"frame_hash":hash(&out),"snapshot_hash":after,"host":st}),
                    &before,
                    &after,
                )?;
                h.log.append(
                    "semantic-output",
                    &route,
                    ctx,
                    json!({"event_index":event_index}),
                    json!({"bytes_hash":hash(&out)}),
                    &after,
                    &after,
                )?;
            }
            transitions.push((event_index, hash(&out), after.clone()));
            outputs.push(out);
            let done = inst.store.data().state.event_index;
            if spec.checkpoint_after == Some(done) {
                inst.store.data_mut().maybe_kill(
                    KillPoint::AfterTransitionBeforeCheckpoint,
                    "",
                    "",
                )?;
                let guest_hash = hex(&wt(inst.bindings.call_state_hash(&mut inst.store))?);
                let cp = Checkpoint {
                    schema: CHECKPOINT.into(),
                    schema_version: CHECKPOINT_VERSION,
                    bytes: hex(&snap),
                    bytes_hash: after.clone(),
                    component_hash: ctx.component_hash.clone(),
                    guest_state_hash: guest_hash,
                    oplog_index: done,
                    host: inst.store.data().state.clone(),
                    branch: seg.branch.into(),
                    world_hash: hash(WIT_SOURCE.as_bytes()),
                    run_id: ctx.run_id.clone(),
                    scenario_hash: s.hash.clone(),
                };
                let ok = roundtrip(engine, component, m, ctx, s.seed, &snap)?;
                roundtrips_ok &= ok;
                inst.store.data_mut().append(
                    "checkpoint",
                    json!({"index":done,"host":cp.host,"branch":cp.branch}),
                    json!({"snapshot_hash":after,"guest_state_hash":cp.guest_state_hash}),
                )?;
                inst.store.data_mut().append(
                    "snapshot-roundtrip",
                    json!({"at":"checkpoint","bytes_hash":after}),
                    json!({"equal":ok}),
                )?;
                checkpoint = Some(cp);
            }
        }
    }
    let snapshot = wt(inst.bindings.call_snapshot(&mut inst.store))?;
    if snapshot.len() as u64 > m.limits.max_snapshot_bytes {
        return Err(anyhow!("snapshot limit exhausted"));
    }
    let snapshot_hash = hash(&snapshot);
    let guest_state_hash = hex(&wt(inst.bindings.call_state_hash(&mut inst.store))?);
    let ok = roundtrip(engine, component, m, ctx, s.seed, &snapshot)?;
    roundtrips_ok &= ok;
    inst.store.data_mut().append(
        "snapshot-roundtrip",
        json!({"at":"exit","bytes_hash":snapshot_hash}),
        json!({"equal":ok}),
    )?;
    let (live, replayed, final_host) = {
        let h = inst.store.data();
        (h.live, h.replayed, h.state.clone())
    };
    inst.store.data_mut().append(
        "exit",
        json!({"events":invocations}),
        json!({"snapshot_hash":snapshot_hash,"guest_state_hash":guest_state_hash,"live":live,"replayed":replayed,"host":final_host}),
    )?;
    let h = inst.store.into_data();
    Ok((
        RouteResult {
            outputs,
            snapshot,
            snapshot_hash,
            guest_state_hash,
            live: h.live,
            replayed: h.replayed,
            checkpoint,
            roundtrips_ok,
            host: h.state,
            effects: h.effects,
            transitions,
        },
        h.log,
        Journal {
            committed: h.journal,
            intents: h.intents,
        },
        h.provider,
    ))
}

// ---------------------------------------------------------------- run

#[derive(Debug, Serialize)]
pub struct Receipt {
    pub protocol: String,
    pub profile: String,
    pub artifact_hash: String,
    pub machine_config_hash: String,
    pub scenario_id: String,
    pub scenario_hash: String,
    pub seed: u64,
    pub run_id: String,
    pub executor_sha256: String,
    pub oplog_hash: String,
    pub checkpoint_hash: String,
    pub final_state_hash: String,
    pub guest_state_hash: String,
    pub semantic_output_hash: String,
    pub replay_count: u64,
    pub replay_equal: bool,
    pub fork: Value,
    pub effects: Value,
    pub limits: Limits,
    pub traps: Vec<String>,
    pub properties: Vec<String>,
    pub evidence: Value,
    pub engine: Value,
    pub recovery: Value,
    pub passed: bool,
    pub reason: String,
}

pub struct RunOptions {
    pub kill: Option<KillPoint>,
    pub kill_mode: KillMode,
    /// With `KillMode::Sigkill`: take the provider process down as well.
    pub kill_provider: bool,
    pub resume: bool,
    /// Executable to spawn as provider (normally `std::env::current_exe()`).
    pub exe: PathBuf,
}

pub fn run(
    workspace: &Path,
    config_path: &Path,
    run_dir: &Path,
    opts: RunOptions,
) -> std::result::Result<Receipt, String> {
    run_inner(workspace, config_path, run_dir, opts).map_err(|e| e.to_string())
}

struct Loaded {
    m: Machine,
    config_bytes: Vec<u8>,
    artifact: Vec<u8>,
    scenario: Scenario,
    scenario_path: PathBuf,
    scenario_bytes: Vec<u8>,
}
fn load(workspace: &Path, config_path: &Path) -> Result<Loaded> {
    let config_path = if config_path.is_absolute() {
        let c = config_path.canonicalize()?;
        if !c.starts_with(workspace.canonicalize()?) {
            return Err(anyhow!("config escapes workspace"));
        }
        c
    } else {
        confined(
            workspace,
            config_path
                .to_str()
                .ok_or_else(|| anyhow!("bad config path"))?,
        )?
    };
    let config_bytes = fs::read(&config_path)?;
    let m: Machine = toml::from_str(std::str::from_utf8(&config_bytes)?)?;
    if m.schema != MACHINE_SCHEMA || m.profile != PROFILE || m.world != WORLD {
        return Err(anyhow!("unsupported machine contract"));
    }
    if [
        m.limits.fuel,
        m.limits.memory_bytes,
        m.limits.max_invocations,
        m.limits.max_frame_bytes,
        m.limits.max_log_bytes,
    ]
    .contains(&0)
    {
        return Err(anyhow!("limits must be positive"));
    }
    if (
        m.capabilities.clock.as_str(),
        m.capabilities.random.as_str(),
        m.capabilities.filesystem.as_str(),
        m.capabilities.network.as_str(),
        m.capabilities.environment.as_str(),
        m.capabilities.threads.as_str(),
    ) != ("virtual", "seeded", "none", "none", "none", "forbidden")
    {
        return Err(anyhow!("ambient capability denied"));
    }
    let artifact = fs::read(confined(workspace, &m.component)?)?;
    let scenario_path = confined(
        workspace,
        m.scenarios.first().ok_or_else(|| anyhow!("no scenario"))?,
    )?;
    let scenario_bytes = fs::read(&scenario_path)?;
    let raw: Value = serde_json::from_slice(&scenario_bytes)?;
    if !no_floats(&raw) {
        return Err(anyhow!("scenario contains floating-point values"));
    }
    let mut scenario: Scenario = serde_json::from_value(raw)?;
    scenario.hash = hash(&scenario_bytes);
    if scenario.schema != "livingdict.scenario/v1" || scenario.replay_count == 0 {
        return Err(anyhow!("invalid scenario contract"));
    }
    if scenario.replay_count > m.limits.max_replay_count {
        return Err(anyhow!("replay count exceeds limit"));
    }
    if scenario.checkpoint_index > scenario.prefix.len() + scenario.parent.len() {
        return Err(anyhow!("checkpoint outside parent history"));
    }
    Ok(Loaded {
        m,
        config_bytes,
        artifact,
        scenario,
        scenario_path,
        scenario_bytes,
    })
}

fn write_run_state(run_dir: &Path, v: &Value) -> Result<()> {
    atomic(
        run_dir.join("run.json").as_path(),
        &canonical(v).map_err(|x| anyhow!(x))?,
    )
}
fn atomic(path: &Path, data: &[u8]) -> Result<()> {
    let tmp = path.with_extension("tmp");
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(&tmp)?;
    file.write_all(data)?;
    file.sync_all()?;
    drop(file);
    fs::rename(&tmp, path)?;
    let parent = path
        .parent()
        .ok_or_else(|| anyhow!("atomic path has no parent"))?;
    File::open(parent)?.sync_all()?;
    Ok(())
}

fn run_inner(
    workspace: &Path,
    config_path: &Path,
    run_dir: &Path,
    opts: RunOptions,
) -> Result<Receipt> {
    let Loaded {
        m,
        config_bytes,
        artifact,
        scenario,
        scenario_path,
        scenario_bytes,
    } = load(workspace, config_path)?;
    let artifact_hash = hash(&artifact);
    let config_hash = hash(&config_bytes);
    let rid = run_id(&config_hash, &scenario.hash, &scenario.id, scenario.seed);
    let executor_sha256 = hash(&fs::read(&opts.exe)?);
    let kill = opts.kill.map(|point| Kill {
        point,
        mode: opts.kill_mode,
        kill_provider: opts.kill_provider,
    });
    let ctx = Ctx {
        component_hash: artifact_hash.clone(),
        worker: scenario.worker_id.clone(),
        seed: scenario.seed,
        run_id: rid.clone(),
    };
    let engine = engine()?;
    let component =
        Component::new(&engine, &artifact).map_err(|e| anyhow!("component rejected: {e}"))?;
    validate_imports(&engine, &component)?;
    fs::create_dir_all(run_dir)?;
    let oplog_path = run_dir.join("oplog.jsonl");
    let kill_effect = scenario.kill_effect.clone().unwrap_or_default();

    // Resume: verify the existing journal, mark the boundary, re-execute the
    // parent route from genesis with committed effects served from the
    // journal and dangling intents re-issued under the same host key.
    let (mut log, mut journal, resumed_from) = if opts.resume {
        let state: Value = serde_json::from_slice(&fs::read(run_dir.join("run.json"))?)?;
        if state["schema"] != RUN_STATE
            || state["run_id"] != rid
            || state["scenario_hash"] != scenario.hash
        {
            return Err(anyhow!("run state does not match this run"));
        }
        if state["status"] == "complete" {
            return Err(anyhow!("run already complete"));
        }
        let mut log = OplogWriter::open_existing(&oplog_path, &ctx, m.limits.max_log_bytes)?;
        let journal = journal_from(&log.entries)?;
        let killed_at = state["kill_point"].as_str().map(str::to_string);
        let killed_mode = state["kill_mode"].as_str().unwrap_or("abort").to_string();
        let killed_provider = state["kill_provider"].as_bool().unwrap_or(false);
        let pre: Vec<(u64, String, String)> = log
            .entries
            .iter()
            .filter(|e| e.route == "parent" && e.kind == "invocation")
            .map(|e| {
                (
                    e.input["event_index"].as_u64().unwrap_or(u64::MAX),
                    e.result["frame_hash"].as_str().unwrap_or("").to_string(),
                    e.state_hash_after.clone(),
                )
            })
            .collect();
        log.append(
            "resume",
            "parent",
            &ctx,
            json!({"kill_point":state["kill_point"],"oplog_entries":log.entries.len(),
                   "committed":journal.committed.len(),"dangling_intents":journal.intents.len()}),
            json!({}),
            &zero(),
            &zero(),
        )?;
        (
            log,
            journal,
            Some((pre, killed_at, killed_mode, killed_provider)),
        )
    } else {
        if oplog_path.exists() {
            return Err(anyhow!("run directory already holds an oplog"));
        }
        atomic(&run_dir.join("scenario.json"), &scenario_bytes)?;
        (
            OplogWriter::create(&oplog_path, m.limits.max_log_bytes)?,
            Journal::empty(),
            None,
        )
    };
    if hash(&fs::read(run_dir.join("scenario.json"))?) != scenario.hash {
        return Err(anyhow!(
            "evidence scenario copy does not match the workspace scenario"
        ));
    }
    write_run_state(
        run_dir,
        &json!({"schema":RUN_STATE,"run_id":rid,"profile":PROFILE,"config_hash":config_hash,
                "artifact_hash":artifact_hash,"scenario_id":scenario.id,"scenario_hash":scenario.hash,
                "kill_point":opts.kill.map(KillPoint::name),"kill_mode":opts.kill_mode.name(),
                "kill_provider":opts.kill_provider,"kill_effect":kill_effect,
                "status":"running","resumed":opts.resume}),
    )?;

    let provider_log = run_dir.join("provider-calls.jsonl");
    // Unix-domain socket paths are severely limited on macOS and Linux.
    // Evidence directories can be deeply nested, so keep the ephemeral
    // transport endpoint short while deriving it deterministically for a
    // provider that must survive executor restart.
    let socket_id = hash(run_dir.to_string_lossy().as_bytes());
    let provider_socket =
        std::env::temp_dir().join(format!("ld-provider-{}.sock", &socket_id[..16]));
    let mut provider = if scenario.providers.is_empty() {
        None
    } else {
        Some(provider::ensure(
            &opts.exe,
            &provider_socket,
            &scenario_path,
            &provider_log,
        )?)
    };

    let mut parent_events = scenario.prefix.clone();
    parent_events.extend(scenario.parent.clone());
    let mut fork_events = scenario.prefix.clone();
    fork_events.extend(scenario.fork.clone());

    // parent (live)
    let (parent, l, j, p) = execute(
        &engine,
        &component,
        &m,
        &scenario,
        &ctx,
        RouteSpec {
            route: "parent",
            segments: vec![Segment {
                events: &parent_events,
                branch: "parent",
                mode: Mode::Record,
            }],
            resume_from: None,
            checkpoint_after: Some(scenario.checkpoint_index as u64),
            kill,
            kill_effect: kill_effect.clone(),
        },
        log,
        journal,
        provider,
    )?;
    log = l;
    journal = j;
    provider = p;
    let checkpoint = parent
        .checkpoint
        .clone()
        .ok_or_else(|| anyhow!("checkpoint was not taken"))?;
    // Publish the checkpoint before any replay/fork work begins. A crash in
    // a later phase must not erase evidence that the checkpoint boundary was
    // durably reached.
    let checkpoint_bytes =
        canonical(&serde_json::to_value(&checkpoint)?).map_err(|x| anyhow!(x))?;
    atomic(&run_dir.join("checkpoint.json"), &checkpoint_bytes)?;
    // Lineage anchor for the fork: the parent route's final entry, captured
    // before any other route appends.
    let parent_exit_hash = log.last_hash();

    // genesis replays
    let mut replay_equal = parent.roundtrips_ok;
    let mut replayed_total = 0u64;
    let mut guest_hash_consistent = true;
    for n in 1..=scenario.replay_count {
        let name = format!("replay-{n}");
        let (r, l, j, p) = execute(
            &engine,
            &component,
            &m,
            &scenario,
            &ctx,
            RouteSpec {
                route: &name,
                segments: vec![Segment {
                    events: &parent_events,
                    branch: "parent",
                    mode: Mode::Replay,
                }],
                resume_from: None,
                checkpoint_after: None,
                kill: None,
                kill_effect: String::new(),
            },
            log,
            journal,
            provider,
        )?;
        log = l;
        journal = j;
        provider = p;
        replay_equal &= r.snapshot_hash == parent.snapshot_hash
            && r.outputs == parent.outputs
            && r.live == 0
            && r.roundtrips_ok
            && r.host == parent.host;
        guest_hash_consistent &= r.guest_state_hash == parent.guest_state_hash;
        replayed_total += r.replayed;
    }

    // recovered from checkpoint
    let suffix = &parent_events[scenario.checkpoint_index..];
    let (recovered, l, j, p) = execute(
        &engine,
        &component,
        &m,
        &scenario,
        &ctx,
        RouteSpec {
            route: "recovered",
            segments: vec![Segment {
                events: suffix,
                branch: "parent",
                mode: Mode::Replay,
            }],
            resume_from: Some(&checkpoint),
            checkpoint_after: None,
            kill: None,
            kill_effect: String::new(),
        },
        log,
        journal,
        provider,
    )?;
    log = l;
    journal = j;
    provider = p;
    let checkpoint_recovered = recovered.snapshot_hash == parent.snapshot_hash
        && recovered.outputs == parent.outputs[scenario.checkpoint_index..]
        && recovered.live == 0
        && recovered.roundtrips_ok
        && recovered.host == parent.host;
    replayed_total += recovered.replayed;

    // fork: replay prefix on branch parent, then live suffix on branch fork
    let (fork, l, j, p) = execute(
        &engine,
        &component,
        &m,
        &scenario,
        &ctx,
        RouteSpec {
            route: "fork",
            segments: vec![
                Segment {
                    events: &scenario.prefix,
                    branch: "parent",
                    mode: Mode::Replay,
                },
                Segment {
                    events: &scenario.fork,
                    branch: "fork",
                    mode: Mode::Record,
                },
            ],
            resume_from: None,
            checkpoint_after: None,
            kill: None,
            kill_effect: String::new(),
        },
        log,
        journal,
        provider,
    )?;
    drop(l);
    journal = j;
    provider = p;
    let diverged = fork.snapshot_hash != parent.snapshot_hash;
    let guest_hash_discriminates =
        guest_hash_consistent && (!diverged || fork.guest_state_hash != parent.guest_state_hash);

    if let Some(pr) = provider.as_ref() {
        let _ = pr.shutdown();
    }

    // crash recovery consistency: pre-crash parent transitions must match
    // the re-executed ones for the same event index.
    let killed_at = resumed_from
        .as_ref()
        .and_then(|(_, k, _, _)| k.clone())
        .or_else(|| opts.kill.map(KillPoint::name));
    let (kill_mode_name, kill_provider) = match resumed_from.as_ref() {
        Some((_, _, mode, prov)) => (mode.clone(), *prov),
        None => (opts.kill_mode.name().to_string(), opts.kill_provider),
    };
    let crash_recovered = resumed_from.as_ref().map(|(pre, _, _, _)| {
        pre.iter().all(|(i, frame, after)| {
            parent
                .transitions
                .iter()
                .any(|(j, f, a)| j == i && f == frame && a == after)
        })
    });

    // effects: provider log is the external count
    let provider_entries = if provider_log.exists() {
        provider::read_log(&provider_log)?
    } else {
        vec![]
    };
    let mut executed_keys = BTreeSet::new();
    let mut duplicate_requests = 0u64;
    let mut over_executed = false;
    for e in &provider_entries {
        match e["status"].as_str() {
            Some("executed")
                if !executed_keys.insert(e["key"].as_str().unwrap_or("").to_string()) =>
            {
                over_executed = true;
            }
            Some("duplicate") => duplicate_requests += 1,
            _ => {}
        }
    }
    let committed_keys: BTreeSet<_> = journal.committed.keys().cloned().collect();
    let mut commits_by_name: BTreeMap<String, u64> = BTreeMap::new();
    for c in journal.committed.values() {
        *commits_by_name.entry(c.name.clone()).or_default() += 1;
    }
    let witnessed = !scenario.expected_effects.is_empty()
        && scenario
            .expected_effects
            .iter()
            .all(|(name, min)| commits_by_name.get(name).copied().unwrap_or(0) >= *min);
    let effects_exactly_once = witnessed
        && !over_executed
        && executed_keys == committed_keys
        && journal.intents.is_empty()
        && recovered.live == 0;

    // evidence files
    let branch = canonical(&json!({
        "schema":"ld.branch/v1","branch_id":"fork","parent_final_oplog_hash":parent_exit_hash,
        "run_id":rid,"scenario_hash":scenario.hash,
        "cutoff_index":scenario.prefix.len(),
        "cutoff_hash":hash(&canonical(&Value::Array(scenario.prefix.clone())).map_err(|x|anyhow!(x))?),
        "final_snapshot_hash":fork.snapshot_hash
    }))
    .map_err(|x| anyhow!(x))?;
    fs::create_dir_all(run_dir.join("branches/fork"))?;
    atomic(&run_dir.join("branches/fork/manifest.json"), &branch)?;
    let jsonl = fs::read(&oplog_path)?;
    let provider_bytes = if provider_log.exists() {
        Some(fs::read(&provider_log)?)
    } else {
        None
    };

    let mut props = BTreeSet::new();
    if replay_equal {
        props.extend(["replay-stable", "state-hash-stable"]);
    }
    if checkpoint_recovered {
        props.insert("checkpoint-recovered");
    }
    if diverged {
        props.insert("fork-diverged");
    }
    if effects_exactly_once {
        props.insert("effects-exactly-once");
    }
    if guest_hash_discriminates {
        props.insert("guest-hash-discriminates");
    }
    if crash_recovered == Some(true) {
        props.insert("crash-recovered");
    }
    let requested: BTreeSet<_> = scenario
        .expected_properties
        .iter()
        .map(String::as_str)
        .collect();
    let passed = replay_equal
        && diverged
        && checkpoint_recovered
        && requested.is_subset(&props)
        && crash_recovered != Some(false);
    let reason = if passed {
        String::new()
    } else if !parent.roundtrips_ok || !recovered.roundtrips_ok {
        "snapshot round trip failed: guest snapshot/restore is not invertible".into()
    } else if !checkpoint_recovered {
        "checkpoint recovery mismatch: restored suffix diverged from parent".into()
    } else if !replay_equal {
        "replay diverged from parent".into()
    } else if crash_recovered == Some(false) {
        "recovery re-execution diverged from pre-crash transitions".into()
    } else {
        format!(
            "required properties not established: {}",
            requested
                .difference(&props)
                .cloned()
                .collect::<Vec<_>>()
                .join(", ")
        )
    };
    let mut evidence = json!({
        "oplog":{"path":"oplog.jsonl","sha256":hash(&jsonl)},
        "checkpoint":{"path":"checkpoint.json","sha256":hash(&checkpoint_bytes)},
        "branch":{"path":"branches/fork/manifest.json","sha256":hash(&branch)},
        "scenario":{"path":"scenario.json","sha256":scenario.hash}
    });
    if let Some(pb) = &provider_bytes {
        evidence["provider_calls"] = json!({"path":"provider-calls.jsonl","sha256":hash(pb)});
    }
    let semantic: Vec<u8> = parent.outputs.concat();
    write_run_state(
        run_dir,
        &json!({"schema":RUN_STATE,"run_id":rid,"profile":PROFILE,"config_hash":config_hash,
                "artifact_hash":artifact_hash,"scenario_id":scenario.id,"scenario_hash":scenario.hash,
                "kill_point":killed_at,"kill_mode":kill_mode_name,
                "kill_provider":kill_provider,"kill_effect":kill_effect,
                "status":"complete","resumed":opts.resume}),
    )?;
    Ok(Receipt {
        protocol: RECEIPT.into(),
        profile: m.profile,
        artifact_hash,
        machine_config_hash: config_hash,
        scenario_id: scenario.id,
        scenario_hash: scenario.hash.clone(),
        seed: scenario.seed,
        run_id: rid,
        executor_sha256,
        oplog_hash: hash(&jsonl),
        checkpoint_hash: hash(&checkpoint_bytes),
        final_state_hash: parent.snapshot_hash,
        guest_state_hash: parent.guest_state_hash,
        semantic_output_hash: hash(&semantic),
        replay_count: scenario.replay_count,
        replay_equal,
        fork: json!({"manifest":"branches/fork/manifest.json","shared_prefix_hash":hash(&canonical(&Value::Array(scenario.prefix)).map_err(|x|anyhow!(x))?),"diverged":diverged,"final_state_hash":fork.snapshot_hash}),
        effects: json!({
            "executed":executed_keys.len(),
            "logical_committed":journal.committed.len(),
            "by_name":commits_by_name,
            "expected":scenario.expected_effects,
            "replayed":replayed_total,
            "duplicate_provider_requests":duplicate_requests,
            "dangling_intents":journal.intents.len(),
            "fork_live":fork.live,
            "parent_live":parent.live
        }),
        limits: m.limits,
        traps: vec![],
        properties: props.into_iter().map(str::to_string).collect(),
        evidence,
        engine: engine_attestation(),
        recovery: json!({"kill_point":killed_at,"kill_mode":kill_mode_name,
                         "kill_provider":kill_provider,"resumed":opts.resume,
                         "consistent":crash_recovered}),
        passed,
        reason,
    })
}

// ---------------------------------------------------------------- tests

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn canonical_sorted() {
        assert_eq!(
            canonical(&json!({"b":1,"a":2})).unwrap(),
            br#"{"a":2,"b":1}"#
        )
    }
    #[test]
    fn path_parent_rejected() {
        assert!(confined(Path::new("."), "../x").is_err())
    }
    #[test]
    fn wasmtime_version_is_pinned_by_lockfile() {
        let lock = include_str!("../../Cargo.lock");
        let pinned = lock
            .split("[[package]]")
            .find(|p| p.contains("name = \"wasmtime\"\n"))
            .and_then(|p| {
                p.lines().find(|l| l.starts_with("version = ")).map(|l| {
                    l.trim_start_matches("version = ")
                        .trim_matches('"')
                        .to_string()
                })
            })
            .expect("wasmtime in Cargo.lock");
        assert_eq!(pinned, WASMTIME_VERSION);
    }
    #[test]
    fn engine_hash_is_stable_and_bound_to_settings() {
        let a = engine_config_hash();
        assert_eq!(a, engine_config_hash());
        assert_eq!(engine_attestation()["config_hash"], json!(a));
        assert_eq!(
            engine_attestation()["world_hash"],
            json!(hash(WIT_SOURCE.as_bytes()))
        );
    }
    #[test]
    fn oplog_rejects_tampering() {
        let ctx = Ctx {
            component_hash: "a".repeat(64),
            worker: "w".into(),
            seed: 7,
            run_id: "r".into(),
        };
        let mut log = OplogWriter::memory();
        log.append(
            "invocation",
            "parent",
            &ctx,
            json!({"v":1}),
            json!({"ok":true}),
            "x",
            "y",
        )
        .unwrap();
        log.append("exit", "parent", &ctx, json!({}), json!({}), "y", "y")
            .unwrap();
        assert!(verify(&log.entries, &ctx.component_hash, &ctx.worker, ctx.seed).is_ok());
        for mutation in 0..7 {
            let mut bad = log.entries.clone();
            match mutation {
                0 => bad[0].result = json!({"ok":false}),
                1 => bad[0].previous_entry_hash = "f".repeat(64),
                2 => bad[0].sequence = 9,
                3 => bad[0].worker = "other".into(),
                4 => bad[0].route = "fork".into(),
                5 => bad[1].kind = "made-up".into(),
                _ => bad[0].scenario_seed = 8,
            }
            assert!(verify(&bad, &ctx.component_hash, &ctx.worker, ctx.seed).is_err());
        }
    }
    #[test]
    fn scenario_unknown_fields_are_rejected() {
        let value = json!({"schema":"livingdict.scenario/v1","id":"x","seed":1,"worker_id":"w","prefix":[],"parent":[],"fork":[],"checkpoint_index":0,"replay_count":1,"providers":{},"expected_properties":[],"surprise":true});
        assert!(serde_json::from_value::<Scenario>(value).is_err());
    }
    #[test]
    fn effect_key_is_host_derived_and_position_sensitive() {
        let a = effect_key("r", "parent", "c", 2, 0);
        assert_eq!(a, effect_key("r", "parent", "c", 2, 0));
        assert_ne!(a, effect_key("r", "fork", "c", 2, 0));
        assert_ne!(a, effect_key("r", "parent", "c", 2, 1));
        assert_ne!(a, effect_key("r", "parent", "c", 3, 0));
    }
    #[test]
    fn rng_position_round_trips_through_host_state() {
        let mut st = HostState::genesis(9);
        let mut rng = rng_from(&st).unwrap();
        let mut first = [0u8; 40];
        rng.fill_bytes(&mut first);
        st.rng_word_pos = rng.get_word_pos().to_string();
        let mut resumed = rng_from(&st).unwrap();
        let mut a = [0u8; 16];
        let mut b = [0u8; 16];
        rng.fill_bytes(&mut a);
        resumed.fill_bytes(&mut b);
        assert_eq!(a, b);
        let mut fresh = rng_from(&HostState::genesis(9)).unwrap();
        let mut c = [0u8; 16];
        fresh.fill_bytes(&mut c);
        assert_ne!(a, c, "a fresh stream must not equal the continuation");
    }
    fn test_host(mode: Mode, journal: BTreeMap<String, Committed>) -> Host {
        Host {
            limits: wasmtime::StoreLimitsBuilder::new().build(),
            state: HostState::genesis(1),
            rng: rng_from(&HostState::genesis(1)).unwrap(),
            branch: "parent".into(),
            route: "test".into(),
            mode,
            provider: None,
            journal,
            intents: BTreeMap::new(),
            log: OplogWriter::memory(),
            ctx: Ctx {
                component_hash: "c".into(),
                worker: "w".into(),
                seed: 1,
                run_id: "r".into(),
            },
            current_state_hash: zero(),
            kill: None,
            kill_effect: String::new(),
            max_effect_bytes: 65536,
            live: 0,
            replayed: 0,
            effects: vec![],
        }
    }
    #[test]
    fn reissue_must_match_the_journaled_intent() {
        let key = effect_key("r", "parent", "c", 0, 0);
        let mut host = test_host(Mode::Record, BTreeMap::new());
        host.intents.insert(
            key,
            Intent {
                name: "payment.charge".into(),
                business_key: "k".into(),
                request_hash: hash(b"original"),
                branch: "parent".into(),
                event_index: 0,
                effect_index: 0,
            },
        );
        let err = host
            .effect("payment.charge".into(), "k".into(), b"changed".to_vec())
            .unwrap_err();
        assert!(
            err.to_string()
                .contains("differs from the journaled intent"),
            "{err}"
        );
    }
    #[test]
    fn replay_serves_journal_and_refuses_unknown_or_mismatched_effects() {
        let key = effect_key("r", "parent", "c", 0, 0);
        let mut journal = BTreeMap::new();
        journal.insert(
            key,
            Committed {
                name: "payment.charge".into(),
                business_key: "k".into(),
                request_hash: hash(b"request"),
                result: b"result".to_vec(),
            },
        );
        let mut host = test_host(Mode::Replay, journal.clone());
        assert_eq!(
            host.effect("payment.charge".into(), "k".into(), b"request".to_vec())
                .unwrap(),
            b"result"
        );
        assert_eq!((host.live, host.replayed), (0, 1));
        let mut host = test_host(Mode::Replay, journal.clone());
        let err = host
            .effect("payment.charge".into(), "k".into(), b"altered".to_vec())
            .unwrap_err();
        assert!(err.to_string().contains("journal mismatch"));
        let mut host = test_host(Mode::Replay, BTreeMap::new());
        let err = host
            .effect("payment.charge".into(), "k".into(), b"request".to_vec())
            .unwrap_err();
        assert!(err.to_string().contains("missing committed effect"));
    }
    #[test]
    fn record_without_provider_cannot_perform_live_effects() {
        let mut host = test_host(Mode::Record, BTreeMap::new());
        let err = host
            .effect("payment.charge".into(), "k".into(), b"x".to_vec())
            .unwrap_err();
        assert!(err.to_string().contains("no provider"));
        assert!(
            host.intents.is_empty(),
            "no intent is journaled without a provider"
        );
    }
    fn start_provider(
        dir: &Path,
        canned: BTreeMap<String, Vec<Value>>,
    ) -> (PathBuf, PathBuf, std::thread::JoinHandle<()>) {
        let socket = dir.join("p.sock");
        let logp = dir.join("calls.jsonl");
        let (s2, l2) = (socket.clone(), logp.clone());
        let t = std::thread::spawn(move || provider::serve(&s2, canned, &l2).unwrap());
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !provider::ProviderClient::connectable(&socket) {
            assert!(std::time::Instant::now() < deadline);
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        (socket, logp, t)
    }
    fn canned_charge() -> BTreeMap<String, Vec<Value>> {
        let mut canned = BTreeMap::new();
        canned.insert(
            "payment.charge".to_string(),
            vec![json!({"approved":true}), json!({"approved":false})],
        );
        canned
    }
    #[test]
    fn provider_is_idempotent_by_host_key_binds_the_request_and_survives_restart() {
        let dir = std::env::temp_dir().join(format!("ld-prov-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let (socket, logp, t) = start_provider(&dir, canned_charge());
        let client = provider::ProviderClient {
            socket: socket.clone(),
            pid: None,
        };
        let (s1, r1) = client
            .call(
                "k1",
                "payment.charge",
                "b",
                b"x",
                provider::MidCall::Proceed,
            )
            .unwrap();
        let (s2, r2) = client
            .call(
                "k1",
                "payment.charge",
                "b",
                b"x",
                provider::MidCall::Proceed,
            )
            .unwrap();
        assert_eq!((s1.as_str(), s2.as_str()), ("executed", "duplicate"));
        assert_eq!(r1, r2);
        // Same key, different request: refused, never re-executed.
        let err = client
            .call(
                "k1",
                "payment.charge",
                "b",
                b"altered",
                provider::MidCall::Proceed,
            )
            .unwrap_err();
        assert!(err.to_string().contains("bound to a different request"));
        let err = client
            .call(
                "k2",
                "unknown.effect",
                "b",
                b"x",
                provider::MidCall::Proceed,
            )
            .unwrap_err();
        assert!(err.to_string().contains("undeclared effect"));
        client.shutdown().unwrap();
        t.join().unwrap();

        // A process may die halfway through its final append. Restart keeps
        // the verified newline-terminated prefix and discards only that tail.
        OpenOptions::new()
            .append(true)
            .open(&logp)
            .unwrap()
            .write_all(b"{\"schema\":\"torn")
            .unwrap();

        // Restart from the log: k1 is still bound and answered from the
        // log's result bytes; the second canned response is still available
        // for a new key; the chain continues rather than restarting.
        let (socket, logp2, t) = start_provider(&dir, canned_charge());
        assert_eq!(logp, logp2);
        let client = provider::ProviderClient { socket, pid: None };
        let (s3, r3) = client
            .call(
                "k1",
                "payment.charge",
                "b",
                b"x",
                provider::MidCall::Proceed,
            )
            .unwrap();
        assert_eq!((s3.as_str(), r3), ("duplicate", r1));
        let (s4, r4) = client
            .call(
                "k3",
                "payment.charge",
                "b",
                b"y",
                provider::MidCall::Proceed,
            )
            .unwrap();
        assert_eq!(s4, "executed");
        assert_eq!(r4, serde_json::to_vec(&json!({"approved":false})).unwrap());
        client.shutdown().unwrap();
        t.join().unwrap();

        let entries = provider::read_log(&logp).unwrap();
        let statuses: Vec<_> = entries
            .iter()
            .map(|e| {
                e["status"]
                    .as_str()
                    .unwrap_or(e["kind"].as_str().unwrap())
                    .to_string()
            })
            .collect();
        assert_eq!(
            statuses,
            [
                "start",
                "executed",
                "duplicate",
                "mismatch",
                "rejected",
                "shutdown",
                "restart",
                "duplicate",
                "executed",
                "shutdown"
            ]
        );
        assert_eq!(
            entries.iter().filter(|e| e["status"] == "executed").count(),
            2
        );
        let mut tampered = fs::read_to_string(&logp).unwrap();
        tampered = tampered.replacen("executed", "executex", 1);
        fs::write(&logp, tampered).unwrap();
        assert!(provider::read_log(&logp).is_err());
        let _ = fs::remove_dir_all(&dir);
    }
    #[test]
    fn floats_are_refused_before_execution() {
        assert!(no_floats(
            &json!({"a":[1,{"b":"x"}],"c":11400714819323198485u64})
        ));
        assert!(!no_floats(&json!({"amount":12.5})));
        assert!(!no_floats(&json!([1, [2.0]])));
    }
    #[test]
    fn oplog_budget_is_enforced_before_the_write() {
        let dir = std::env::temp_dir().join(format!("ld-oplog-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let ctx = Ctx {
            component_hash: "a".repeat(64),
            worker: "w".into(),
            seed: 7,
            run_id: "r".into(),
        };
        let path = dir.join("oplog.jsonl");
        let mut log = OplogWriter::create(&path, 600).unwrap();
        log.append(
            "invocation",
            "parent",
            &ctx,
            json!({"v":1}),
            json!({}),
            "x",
            "y",
        )
        .unwrap();
        let err = log
            .append(
                "invocation",
                "parent",
                &ctx,
                json!({"v":2}),
                json!({}),
                "y",
                "z",
            )
            .unwrap_err();
        assert!(err.to_string().contains("log limit"));
        assert_eq!(
            log.entries.len(),
            1,
            "the refused entry is not in memory either"
        );
        assert_eq!(fs::read_to_string(&path).unwrap().lines().count(), 1);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn oplog_resume_truncates_only_a_torn_final_record() {
        let dir = std::env::temp_dir().join(format!("ld-oplog-torn-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let ctx = Ctx {
            component_hash: "a".repeat(64),
            worker: "w".into(),
            seed: 7,
            run_id: "r".into(),
        };
        let path = dir.join("oplog.jsonl");
        let mut log = OplogWriter::create(&path, 4096).unwrap();
        log.append("invocation", "parent", &ctx, json!({}), json!({}), "x", "y")
            .unwrap();
        drop(log);
        OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(b"{\"schema\":\"torn")
            .unwrap();

        let recovered = OplogWriter::open_existing(&path, &ctx, 4096).unwrap();
        assert_eq!(recovered.entries.len(), 1);
        assert!(fs::read(&path).unwrap().ends_with(b"\n"));
        let _ = fs::remove_dir_all(&dir);
    }
}
