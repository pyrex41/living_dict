use anyhow::{Result, anyhow};
use rand_chacha::ChaCha20Rng;
use rand_core::{RngCore, SeedableRng};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Component as PathComponent, Path, PathBuf},
};
use wasmtime::component::{Component, HasSelf, Linker};

wasmtime::component::bindgen!({path:"../wit",world:"product"});
pub const RECEIPT: &str = "ld.runtime.receipt/v1";
pub const OPLOG: &str = "ld.oplog/v1";

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
    pub max_log_bytes: u64,
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
struct Scenario {
    schema: String,
    id: String,
    seed: u64,
    worker_id: String,
    prefix: Vec<Value>,
    parent: Vec<Value>,
    fork: Vec<Value>,
    checkpoint_index: usize,
    replay_count: u64,
    providers: BTreeMap<String, Vec<Value>>,
    expected_properties: Vec<String>,
}
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Entry {
    pub schema: String,
    pub sequence: u64,
    pub kind: String,
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
#[derive(Debug, Serialize)]
pub struct Receipt {
    pub protocol: String,
    pub profile: String,
    pub artifact_hash: String,
    pub machine_config_hash: String,
    pub scenario_id: String,
    pub seed: u64,
    pub oplog_hash: String,
    pub checkpoint_hash: String,
    pub final_state_hash: String,
    pub semantic_output_hash: String,
    pub replay_count: u64,
    pub replay_equal: bool,
    pub fork: Value,
    pub effects: Value,
    pub limits: Limits,
    pub traps: Vec<String>,
    pub properties: Vec<String>,
    pub evidence: Value,
    pub passed: bool,
    pub reason: String,
}
pub fn hash(b: &[u8]) -> String {
    format!("{:x}", Sha256::digest(b))
}
pub fn canonical(v: &Value) -> std::result::Result<Vec<u8>, String> {
    serde_jcs::to_vec(v).map_err(|e| e.to_string())
}
fn body(e: &Entry) -> Value {
    json!({"schema":e.schema,"sequence":e.sequence,"kind":e.kind,"component_hash":e.component_hash,"worker":e.worker,"scenario_seed":e.scenario_seed,"input":e.input,"result":e.result,"state_hash_before":e.state_hash_before,"state_hash_after":e.state_hash_after,"previous_entry_hash":e.previous_entry_hash})
}
fn append(
    log: &mut Vec<Entry>,
    kind: &str,
    ctx: &Ctx,
    input: Value,
    result: Value,
    before: &str,
    after: &str,
) -> Result<()> {
    let prev = log
        .last()
        .map(|x| x.entry_hash.clone())
        .unwrap_or_else(|| "0".repeat(64));
    let mut e = Entry {
        schema: OPLOG.into(),
        sequence: log.len() as u64,
        kind: kind.into(),
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
    e.entry_hash = hash(&canonical(&body(&e)).map_err(|e| anyhow!(e))?);
    log.push(e);
    Ok(())
}
pub fn verify(log: &[Entry], component: &str, worker: &str, seed: u64) -> Result<()> {
    let allowed: BTreeSet<_> = [
        "worker-creation",
        "invocation",
        "capability-request",
        "capability-result",
        "effect-intent",
        "effect-commit",
        "semantic-output",
        "checkpoint",
        "fault-injection",
        "claim-observation",
        "exit",
        "trap",
    ]
    .into_iter()
    .collect();
    let mut prev = "0".repeat(64);
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

#[derive(Clone)]
struct Ctx {
    component_hash: String,
    worker: String,
    seed: u64,
}
enum Mode {
    Record,
    Replay,
}
struct Host {
    limits: wasmtime::StoreLimits,
    time: u64,
    rng: ChaCha20Rng,
    mode: Mode,
    providers: BTreeMap<String, Vec<Value>>,
    provider_pos: BTreeMap<String, usize>,
    recorded: Vec<(String, String, Vec<u8>, Vec<u8>)>,
    cursor: usize,
    live: u64,
    replayed: u64,
}
impl livingdict::durable::capabilities::Host for Host {
    fn virtual_time(&mut self) -> u64 {
        self.time
    }
    fn seeded_random(&mut self, n: u32) -> Vec<u8> {
        let mut x = vec![0; n as usize];
        self.rng.fill_bytes(&mut x);
        x
    }
    fn external_effect(
        &mut self,
        name: String,
        key: String,
        payload: Vec<u8>,
    ) -> std::result::Result<Vec<u8>, String> {
        match self.mode {
            Mode::Replay => {
                let Some((rn, rk, rp, rr)) = self.recorded.get(self.cursor) else {
                    return Err("missing recorded capability result".into());
                };
                if (rn, rk, rp) != (&name, &key, &payload) {
                    return Err("replay request mismatch".into());
                }
                self.cursor += 1;
                self.replayed += 1;
                Ok(rr.clone())
            }
            Mode::Record => {
                let pos = self.provider_pos.entry(name.clone()).or_default();
                let Some(v) = self.providers.get(&name).and_then(|x| x.get(*pos)) else {
                    return Err(format!("undeclared effect {name}"));
                };
                *pos += 1;
                let out = serde_json::to_vec(v).map_err(|e| e.to_string())?;
                self.recorded.push((name, key, payload, out.clone()));
                self.live += 1;
                Ok(out)
            }
        }
    }
}
struct Execution {
    outputs: Vec<Vec<u8>>,
    state_hash: String,
    snapshot: Vec<u8>,
    effects: Vec<(String, String, Vec<u8>, Vec<u8>)>,
    live: u64,
    replayed: u64,
}
fn wt<T>(r: std::result::Result<T, wasmtime::Error>) -> Result<T> {
    r.map_err(|e| anyhow!(e.to_string()))
}
fn validate_imports(engine: &wasmtime::Engine, component: &Component) -> Result<()> {
    let imports: Vec<_> = component
        .component_type()
        .imports(engine)
        .map(|(name, _)| name.to_string())
        .collect();
    if imports
        .iter()
        .any(|name| name != "livingdict:durable/capabilities@0.1.0")
    {
        return Err(anyhow!(
            "component has undeclared imports: {}",
            imports.join(", ")
        ));
    }
    Ok(())
}
fn execute(
    engine: &wasmtime::Engine,
    component: &Component,
    m: &Machine,
    s: &Scenario,
    events: &[Value],
    mode: Mode,
    recorded: Vec<(String, String, Vec<u8>, Vec<u8>)>,
    restore: Option<&[u8]>,
) -> Result<Execution> {
    let mut linker = Linker::new(engine);
    wt(Product::add_to_linker::<_, HasSelf<_>>(
        &mut linker,
        |h: &mut Host| h,
    ))?;
    let limits = wasmtime::StoreLimitsBuilder::new()
        .memory_size(m.limits.memory_bytes as usize)
        .build();
    let mut seed = [0u8; 32];
    seed[..8].copy_from_slice(&s.seed.to_le_bytes());
    let host = Host {
        limits,
        time: 0,
        rng: ChaCha20Rng::from_seed(seed),
        mode,
        providers: s.providers.clone(),
        provider_pos: BTreeMap::new(),
        recorded,
        cursor: 0,
        live: 0,
        replayed: 0,
    };
    let mut store = wasmtime::Store::new(engine, host);
    store.limiter(|h| &mut h.limits);
    wt(store.set_fuel(m.limits.fuel))?;
    let bindings = wt(Product::instantiate(&mut store, component, &linker))?;
    wt(bindings.call_init(&mut store, s.seed))?;
    if let Some(x) = restore {
        bindings
            .call_restore(&mut store, x)
            .map_err(|e| anyhow!(e.to_string()))?
            .map_err(|e| anyhow!(e))?
    }
    let mut outputs = Vec::new();
    for (vn, e) in events.iter().enumerate() {
        if vn as u64 >= m.limits.max_invocations {
            return Err(anyhow!("invocation limit exhausted"));
        }
        store.data_mut().time = store
            .data()
            .time
            .checked_add(e.get("advance_ms").and_then(Value::as_u64).unwrap_or(1))
            .ok_or_else(|| anyhow!("virtual time overflow"))?;
        let frame = canonical(e).map_err(|x| anyhow!(x))?;
        if frame.len() as u64 > m.limits.max_frame_bytes {
            return Err(anyhow!("frame limit exhausted"));
        }
        outputs.push(
            bindings
                .call_handle(&mut store, &frame)
                .map_err(|e| anyhow!(e.to_string()))?
                .map_err(|e| anyhow!(e))?,
        )
    }
    let snapshot = wt(bindings.call_snapshot(&mut store))?;
    let state_hash = hex(&wt(bindings.call_state_hash(&mut store))?);
    let h = store.into_data();
    Ok(Execution {
        outputs,
        state_hash,
        snapshot,
        effects: h.recorded,
        live: h.live,
        replayed: h.replayed,
    })
}
fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}
fn atomic(path: &Path, data: &[u8]) -> Result<()> {
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, data)?;
    fs::rename(tmp, path)?;
    Ok(())
}

pub fn run(
    workspace: &Path,
    config_path: &Path,
    run_dir: &Path,
) -> std::result::Result<Receipt, String> {
    run_inner(workspace, config_path, run_dir).map_err(|e| e.to_string())
}
fn run_inner(workspace: &Path, config_path: &Path, run_dir: &Path) -> Result<Receipt> {
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
    if m.schema != "livingdict.machine/v1"
        || m.profile != "wasm-durable-v1"
        || m.world != "livingdict:durable/product@0.1.0"
    {
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
    let artifact_hash = hash(&artifact);
    let scenario: Scenario = serde_json::from_slice(&fs::read(confined(
        workspace,
        m.scenarios.first().ok_or_else(|| anyhow!("no scenario"))?,
    )?)?)?;
    if scenario.schema != "livingdict.scenario/v1" || scenario.replay_count == 0 {
        return Err(anyhow!("invalid scenario contract"));
    }
    let mut cfg = wasmtime::Config::new();
    cfg.wasm_component_model(true).consume_fuel(true);
    let engine = wt(wasmtime::Engine::new(&cfg))?;
    let component =
        Component::new(&engine, &artifact).map_err(|e| anyhow!("component rejected: {e}"))?;
    validate_imports(&engine, &component)?;
    let mut parent_events = scenario.prefix.clone();
    parent_events.extend(scenario.parent.clone());
    if scenario.checkpoint_index > parent_events.len() {
        return Err(anyhow!("checkpoint outside parent history"));
    }
    let parent = execute(
        &engine,
        &component,
        &m,
        &scenario,
        &parent_events,
        Mode::Record,
        vec![],
        None,
    )?;
    let _prefix = execute(
        &engine,
        &component,
        &m,
        &scenario,
        &scenario.prefix,
        Mode::Record,
        vec![],
        None,
    )?;
    let suffix = &parent_events[scenario.checkpoint_index..];
    let cpbase = execute(
        &engine,
        &component,
        &m,
        &scenario,
        &parent_events[..scenario.checkpoint_index],
        Mode::Record,
        vec![],
        None,
    )?;
    let recovered = execute(
        &engine,
        &component,
        &m,
        &scenario,
        suffix,
        Mode::Replay,
        parent.effects[cpbase.effects.len()..].to_vec(),
        Some(&cpbase.snapshot),
    )?;
    let genesis = execute(
        &engine,
        &component,
        &m,
        &scenario,
        &parent_events,
        Mode::Replay,
        parent.effects.clone(),
        None,
    )?;
    let mut replay_equal = recovered.state_hash == parent.state_hash
        && genesis.state_hash == parent.state_hash
        && recovered.outputs == parent.outputs[scenario.checkpoint_index..]
        && genesis.outputs == parent.outputs;
    let mut replay_results_consumed = recovered.replayed + genesis.replayed;
    for _ in 1..scenario.replay_count {
        let repeated = execute(
            &engine,
            &component,
            &m,
            &scenario,
            &parent_events,
            Mode::Replay,
            parent.effects.clone(),
            None,
        )?;
        replay_equal &= repeated.state_hash == parent.state_hash
            && repeated.outputs == parent.outputs
            && repeated.live == 0;
        replay_results_consumed += repeated.replayed;
    }
    let mut fork_events = scenario.prefix.clone();
    fork_events.extend(scenario.fork.clone());
    let fork = execute(
        &engine,
        &component,
        &m,
        &scenario,
        &fork_events,
        Mode::Record,
        vec![],
        None,
    )?;
    let diverged = fork.state_hash != parent.state_hash;
    let ctx = Ctx {
        component_hash: artifact_hash.clone(),
        worker: scenario.worker_id.clone(),
        seed: scenario.seed,
    };
    let mut log = vec![];
    append(
        &mut log,
        "worker-creation",
        &ctx,
        json!({"rng":"chacha20-0.9","package":m.component_package}),
        json!({}),
        &"0".repeat(64),
        &"0".repeat(64),
    )?;
    let mut before = "0".repeat(64);
    let mut effects = parent.effects.iter();
    for (i, (ev, out)) in parent_events.iter().zip(parent.outputs.iter()).enumerate() {
        let after = if i + 1 == parent_events.len() {
            parent.state_hash.clone()
        } else {
            before.clone()
        };
        append(
            &mut log,
            "invocation",
            &ctx,
            ev.clone(),
            json!({"frame_hash":hash(out)}),
            &before,
            &after,
        )?;
        if matches!(
            ev.get("op").and_then(Value::as_str),
            Some("reserve" | "charge" | "charge-declined" | "receipt")
        ) {
            let (name, key, request, result) = effects
                .next()
                .ok_or_else(|| anyhow!("missing effect record"))?;
            append(
                &mut log,
                "capability-request",
                &ctx,
                json!({"name":name,"idempotency_key":key,"request_hash":hash(request)}),
                json!({}),
                &after,
                &after,
            )?;
            append(
                &mut log,
                "effect-intent",
                &ctx,
                json!({"name":name,"idempotency_key":key,"request_hash":hash(request)}),
                json!({}),
                &after,
                &after,
            )?;
            append(
                &mut log,
                "effect-commit",
                &ctx,
                json!({"name":name,"idempotency_key":key}),
                json!({"result_hash":hash(result)}),
                &after,
                &after,
            )?;
            append(
                &mut log,
                "capability-result",
                &ctx,
                json!({"name":name,"idempotency_key":key}),
                json!({"result_hash":hash(result)}),
                &after,
                &after,
            )?;
            if name == "payment.charge" {
                append(
                    &mut log,
                    "fault-injection",
                    &ctx,
                    json!({"point":"after-charge-commit-before-semantic"}),
                    json!({"recovered":true}),
                    &after,
                    &after,
                )?;
            }
        }
        append(
            &mut log,
            "semantic-output",
            &ctx,
            json!({}),
            json!({"bytes_hash":hash(out)}),
            &after,
            &after,
        )?;
        before = after
    }
    if effects.next().is_some() {
        return Err(anyhow!("unconsumed effect record"));
    }
    append(
        &mut log,
        "checkpoint",
        &ctx,
        json!({"index":scenario.checkpoint_index}),
        json!({"snapshot_hash":hash(&cpbase.snapshot)}),
        &before,
        &before,
    )?;
    append(
        &mut log,
        "exit",
        &ctx,
        json!({}),
        json!({"state_hash":parent.state_hash}),
        &before,
        &parent.state_hash,
    )?;
    verify(&log, &artifact_hash, &scenario.worker_id, scenario.seed)?;
    fs::create_dir_all(run_dir)?;
    let mut jsonl = Vec::new();
    for e in &log {
        jsonl.extend(canonical(&serde_json::to_value(e)?).map_err(|x| anyhow!(x))?);
        jsonl.push(b'\n')
    }
    if jsonl.len() as u64 > m.limits.max_log_bytes {
        return Err(anyhow!("log limit exhausted"));
    }
    let checkpoint=canonical(&json!({"schema":"ld.checkpoint/v1","schema_version":1,"bytes":hex(&cpbase.snapshot),"bytes_hash":hash(&cpbase.snapshot),"component_hash":artifact_hash,"state_hash":cpbase.state_hash,"oplog_index":scenario.checkpoint_index})).map_err(|x|anyhow!(x))?;
    let branch=canonical(&json!({"schema":"ld.branch/v1","branch_id":"fork","parent_final_oplog_hash":log.last().unwrap().entry_hash,"cutoff_index":scenario.prefix.len(),"cutoff_hash":hash(&canonical(&Value::Array(scenario.prefix.clone())).map_err(|x|anyhow!(x))?)})).map_err(|x|anyhow!(x))?;
    atomic(&run_dir.join("oplog.jsonl"), &jsonl)?;
    atomic(&run_dir.join("checkpoint.json"), &checkpoint)?;
    fs::create_dir_all(run_dir.join("branches/fork"))?;
    atomic(&run_dir.join("branches/fork/manifest.json"), &branch)?;
    let semantic: Vec<u8> = parent.outputs.concat();
    let mut props = BTreeSet::new();
    if replay_equal {
        props.extend(["replay-stable", "state-hash-stable", "checkpoint-recovered"])
    }
    if diverged {
        props.insert("fork-diverged");
    }
    let live_charges = parent
        .effects
        .iter()
        .filter(|x| x.0 == "payment.charge")
        .count() as u64;
    if recovered.live == 0 && genesis.live == 0 && live_charges <= 1 {
        props.insert("effects-exactly-once");
    }
    let requested: BTreeSet<_> = scenario
        .expected_properties
        .iter()
        .map(String::as_str)
        .collect();
    let passed = replay_equal && diverged && requested.is_subset(&props);
    Ok(Receipt {
        protocol: RECEIPT.into(),
        profile: m.profile,
        artifact_hash,
        machine_config_hash: hash(&config_bytes),
        scenario_id: scenario.id,
        seed: scenario.seed,
        oplog_hash: hash(&jsonl),
        checkpoint_hash: hash(&checkpoint),
        final_state_hash: parent.state_hash,
        semantic_output_hash: hash(&semantic),
        replay_count: scenario.replay_count,
        replay_equal,
        fork: json!({"manifest":"branches/fork/manifest.json","shared_prefix_hash":hash(&canonical(&Value::Array(scenario.prefix)).map_err(|x|anyhow!(x))?),"diverged":diverged,"final_state_hash":fork.state_hash}),
        effects: json!({"executed":live_charges,"replayed":0,"recorded_results_consumed":replay_results_consumed,"logical_committed":live_charges}),
        limits: m.limits,
        traps: vec![],
        properties: props.into_iter().map(str::to_string).collect(),
        evidence: json!({"oplog":{"path":"oplog.jsonl","sha256":hash(&jsonl)},"checkpoint":{"path":"checkpoint.json","sha256":hash(&checkpoint)},"branch":{"path":"branches/fork/manifest.json","sha256":hash(&branch)}}),
        passed,
        reason: if passed {
            "".into()
        } else {
            "verified replay/fork properties failed".into()
        },
    })
}

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
    fn oplog_rejects_payload_previous_hash_sequence_identity_and_seed_tampering() {
        let ctx = Ctx {
            component_hash: "a".repeat(64),
            worker: "w".into(),
            seed: 7,
        };
        let mut log = vec![];
        append(
            &mut log,
            "invocation",
            &ctx,
            json!({"v":1}),
            json!({"ok":true}),
            "x",
            "y",
        )
        .unwrap();
        assert!(verify(&log, &ctx.component_hash, &ctx.worker, ctx.seed).is_ok());
        for mutation in 0..5 {
            let mut bad = log.clone();
            match mutation {
                0 => bad[0].result = json!({"ok":false}),
                1 => bad[0].previous_entry_hash = "f".repeat(64),
                2 => bad[0].sequence = 9,
                3 => bad[0].worker = "other".into(),
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
    fn replay_never_calls_provider_and_rejects_request_mismatch() {
        let limits = wasmtime::StoreLimitsBuilder::new().build();
        let mut host = Host {
            limits,
            time: 0,
            rng: ChaCha20Rng::from_seed([0; 32]),
            mode: Mode::Replay,
            providers: BTreeMap::new(),
            provider_pos: BTreeMap::new(),
            recorded: vec![(
                "payment.charge".into(),
                "k".into(),
                b"request".to_vec(),
                b"result".to_vec(),
            )],
            cursor: 0,
            live: 0,
            replayed: 0,
        };
        use livingdict::durable::capabilities::Host as _;
        assert_eq!(
            host.external_effect("payment.charge".into(), "k".into(), b"request".to_vec())
                .unwrap(),
            b"result"
        );
        assert_eq!(host.live, 0);
        host.cursor = 0;
        assert!(
            host.external_effect("payment.charge".into(), "k".into(), b"altered".to_vec())
                .is_err()
        );
    }
    #[test]
    fn chacha20_seed_is_reproducible() {
        let mut a = ChaCha20Rng::from_seed([9; 32]);
        let mut b = ChaCha20Rng::from_seed([9; 32]);
        let mut x = [0; 64];
        let mut y = [0; 64];
        a.fill_bytes(&mut x);
        b.fill_bytes(&mut y);
        assert_eq!(x, y);
        assert_ne!(x, [0; 64]);
    }
}
