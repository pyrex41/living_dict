use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

wit_bindgen::generate!({ path: "../../wit", world: "product" });

#[derive(Default, Serialize, Deserialize)]
struct State {
    version: u32,
    seed: u64,
    halted: bool,
    entries: BTreeMap<Vec<u8>, Vec<u8>>,
}
static mut STATE: Option<State> = None;
fn with_state<R>(f: impl FnOnce(&mut State) -> R) -> R {
    unsafe {
        let state = &raw mut STATE;
        if (*state).is_none() {
            *state = Some(State::default());
        }
        f((*state).as_mut().unwrap())
    }
}

struct Component;
impl Guest for Component {
    fn init(seed: u64) {
        with_state(|s| {
            *s = State {
                version: 1,
                seed,
                ..State::default()
            }
        });
    }
    fn handle(frame: Vec<u8>) -> Result<Vec<u8>, String> {
        let v: Value = serde_json::from_slice(&frame).map_err(|e| format!("invalid frame: {e}"))?;
        if v.get("v").and_then(Value::as_u64) != Some(1) {
            return Err("unsupported frame version".into());
        }
        with_state(|s| {
            if s.halted {
                return Err("worker halted".into());
            }
            let op = v.get("op").and_then(Value::as_str).ok_or("missing op")?;
            let key = || {
                v.get("key")
                    .and_then(Value::as_str)
                    .map(|x| x.as_bytes().to_vec())
                    .ok_or("missing key")
            };
            let out = match op {
                "put" => {
                    let k = key()?;
                    let val = v
                        .get("value")
                        .and_then(Value::as_str)
                        .ok_or("missing value")?
                        .as_bytes()
                        .to_vec();
                    s.entries.insert(k, val);
                    json!({"v":1,"op":"put","ok":true})
                }
                "get" => {
                    let k = key()?;
                    json!({"v":1,"op":"get","key":String::from_utf8_lossy(&k),"value":s.entries.get(&k).map(|x|String::from_utf8_lossy(x).to_string())})
                }
                "delete" => {
                    let k = key()?;
                    json!({"v":1,"op":"delete","deleted":s.entries.remove(&k).is_some()})
                }
                "dump" => {
                    let rows: Vec<_> = s
                        .entries
                        .iter()
                        .map(|(k, v)| {
                            json!([String::from_utf8_lossy(k), String::from_utf8_lossy(v)])
                        })
                        .collect();
                    json!({"v":1,"op":"dump","entries":rows})
                }
                "halt" => {
                    s.halted = true;
                    json!({"v":1,"op":"halt"})
                }
                _ => return Err("unknown operation".into()),
            };
            serde_json::to_vec(&out).map_err(|e| e.to_string())
        })
    }
    fn snapshot() -> Vec<u8> {
        with_state(|s| {
            let entries: Vec<_> = s.entries.iter().map(|(k, v)| json!([k, v])).collect();
            serde_json::to_vec(
                &json!({"version":s.version,"seed":s.seed,"halted":s.halted,"entries":entries}),
            )
            .expect("state serializes")
        })
    }
    fn restore(bytes: Vec<u8>) -> Result<(), String> {
        let v: Value = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
        if v["version"].as_u64() != Some(1) {
            return Err("snapshot version mismatch".into());
        }
        let mut entries = BTreeMap::new();
        for row in v["entries"].as_array().ok_or("snapshot entries missing")? {
            let pair = row.as_array().ok_or("invalid snapshot entry")?;
            let k: Vec<u8> =
                serde_json::from_value(pair.first().ok_or("snapshot key missing")?.clone())
                    .map_err(|e| e.to_string())?;
            let val: Vec<u8> =
                serde_json::from_value(pair.get(1).ok_or("snapshot value missing")?.clone())
                    .map_err(|e| e.to_string())?;
            entries.insert(k, val);
        }
        let s = State {
            version: 1,
            seed: v["seed"].as_u64().ok_or("snapshot seed missing")?,
            halted: v["halted"].as_bool().ok_or("snapshot halted missing")?,
            entries,
        };
        with_state(|x| *x = s);
        Ok(())
    }
    fn state_hash() -> Vec<u8> {
        Sha256::digest(Self::snapshot()).to_vec()
    }
}
export!(Component);
