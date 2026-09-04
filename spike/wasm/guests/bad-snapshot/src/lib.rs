//! Negative fixture: a KV guest that lies about its state.
//!
//! * `snapshot` drops the largest key, so a restored instance has less state
//!   than the running one;
//! * `restore` leaves a marker that the next `snapshot` includes, so
//!   snapshot -> restore -> snapshot is not byte-identical;
//! * `state-hash` is a constant.
//!
//! The host must reject all three without trusting anything the guest says.
use serde_json::{Value, json};
use std::collections::BTreeMap;

wit_bindgen::generate!({ path: "../../wit", world: "product" });

#[derive(Default)]
struct State {
    seed: u64,
    restored: bool,
    entries: BTreeMap<String, String>,
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
                seed,
                ..State::default()
            }
        });
    }
    fn handle(frame: Vec<u8>) -> Result<Vec<u8>, String> {
        let v: Value = serde_json::from_slice(&frame).map_err(|e| format!("invalid frame: {e}"))?;
        with_state(|s| {
            let op = v["op"].as_str().ok_or("missing op")?;
            let key = || v["key"].as_str().map(str::to_string).ok_or("missing key");
            let out = match op {
                "put" => {
                    s.entries
                        .insert(key()?, v["value"].as_str().unwrap_or("").to_string());
                    json!({"v":1,"op":"put","ok":true})
                }
                "get" => json!({"v":1,"op":"get","key":key()?,"value":s.entries.get(&key()?)}),
                "delete" => {
                    json!({"v":1,"op":"delete","deleted":s.entries.remove(&key()?).is_some()})
                }
                "dump" => json!({"v":1,"op":"dump","entries":s.entries}),
                _ => return Err("unknown operation".into()),
            };
            serde_json::to_vec(&out).map_err(|e| e.to_string())
        })
    }
    fn snapshot() -> Vec<u8> {
        with_state(|s| {
            let mut entries = s.entries.clone();
            if entries.len() > 1 {
                let last = entries.keys().next_back().cloned().unwrap();
                entries.remove(&last);
            }
            serde_json::to_vec(&json!({"seed":s.seed,"restored":s.restored,"entries":entries}))
                .unwrap()
        })
    }
    fn restore(bytes: Vec<u8>) -> Result<(), String> {
        let v: Value = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
        let entries: BTreeMap<String, String> =
            serde_json::from_value(v["entries"].clone()).map_err(|e| e.to_string())?;
        with_state(|s| {
            s.seed = v["seed"].as_u64().unwrap_or(0);
            s.entries = entries;
            s.restored = true;
        });
        Ok(())
    }
    fn state_hash() -> Vec<u8> {
        vec![0; 32]
    }
}
export!(Component);
