use crate::livingdict::durable::capabilities;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
wit_bindgen::generate!({ path: "../../wit", world: "product" });
#[derive(Default, Serialize, Deserialize)]
struct State {
    version: u32,
    seed: u64,
    status: String,
    order_id: String,
    /// Logical time observed at reservation: exercises host clock restore.
    reserved_at: u64,
    /// Seeded bytes drawn at charge: exercises host RNG position restore.
    charge_nonce: String,
    last_audit_at: u64,
    audit_nonce: String,
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
fn nonce() -> String {
    capabilities::seeded_random(8)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
struct Component;
impl Guest for Component {
    fn init(seed: u64) {
        with_state(|s| {
            *s = State {
                version: 1,
                seed,
                status: "created".into(),
                order_id: String::new(),
                reserved_at: 0,
                charge_nonce: String::new(),
                last_audit_at: 0,
                audit_nonce: String::new(),
            }
        })
    }
    fn handle(frame: Vec<u8>) -> Result<Vec<u8>, String> {
        let v: Value = serde_json::from_slice(&frame).map_err(|e| format!("invalid frame: {e}"))?;
        if v["v"] != 1 {
            return Err("unsupported frame version".into());
        }
        with_state(|s| {
            let op = v["op"].as_str().ok_or("missing op")?;
            match op {
                "create" if s.status == "created" => {
                    s.order_id = v["order_id"].as_str().ok_or("missing order_id")?.into();
                    Ok(json!({"v":1,"status":s.status}))
                }
                "reserve" if s.status == "created" => {
                    s.reserved_at = capabilities::virtual_time();
                    capabilities::external_effect(
                        "inventory.reserve",
                        &format!("{}:reserve", s.order_id),
                        &frame,
                    )
                    .map_err(|e| e)?;
                    s.status = "inventory-reserved".into();
                    Ok(json!({"v":1,"status":s.status}))
                }
                "charge" if s.status == "inventory-reserved" => {
                    s.charge_nonce = nonce();
                    let r = capabilities::external_effect(
                        "payment.charge",
                        &format!("{}:charge", s.order_id),
                        &frame,
                    )
                    .map_err(|e| e)?;
                    let x: Value = serde_json::from_slice(&r).map_err(|e| e.to_string())?;
                    s.status = if x["approved"].as_bool() == Some(true) {
                        "payment-committed"
                    } else {
                        "payment-declined"
                    }
                    .into();
                    Ok(json!({"v":1,"status":s.status}))
                }
                "charge-declined" if s.status == "inventory-reserved" => {
                    s.charge_nonce = nonce();
                    let r = capabilities::external_effect(
                        "payment.charge.declined",
                        &format!("{}:charge", s.order_id),
                        &frame,
                    )
                    .map_err(|e| e)?;
                    let x: Value = serde_json::from_slice(&r).map_err(|e| e.to_string())?;
                    s.status = if x["approved"].as_bool() == Some(true) {
                        "payment-committed"
                    } else {
                        "payment-declined"
                    }
                    .into();
                    Ok(json!({"v":1,"status":s.status}))
                }
                "receipt" if s.status == "payment-committed" => {
                    capabilities::external_effect(
                        "receipt.send",
                        &format!("{}:receipt", s.order_id),
                        &frame,
                    )
                    .map_err(|e| e)?;
                    s.status = "receipt-sent".into();
                    Ok(json!({"v":1,"status":s.status}))
                }
                // Post-checkpoint observation of both host capabilities: a
                // restored instance whose clock or RNG position was reset
                // produces a different frame and a different snapshot here.
                "audit" => {
                    s.last_audit_at = capabilities::virtual_time();
                    s.audit_nonce = nonce();
                    Ok(json!({"v":1,"status":s.status,"audited_at":s.last_audit_at,"audit_nonce":s.audit_nonce}))
                }
                "status" => Ok(json!({"v":1,"status":s.status,"reserved_at":s.reserved_at,"charge_nonce":s.charge_nonce,"audited_at":s.last_audit_at,"audit_nonce":s.audit_nonce})),
                _ => Err("invalid order transition".into()),
            }
            .and_then(|x| serde_json::to_vec(&x).map_err(|e| e.to_string()))
        })
    }
    fn snapshot() -> Vec<u8> {
        with_state(|s| serde_json::to_vec(s).unwrap())
    }
    fn restore(b: Vec<u8>) -> Result<(), String> {
        let s: State = serde_json::from_slice(&b).map_err(|e| e.to_string())?;
        if s.version != 1 {
            return Err("snapshot version mismatch".into());
        }
        with_state(|x| *x = s);
        Ok(())
    }
    fn state_hash() -> Vec<u8> {
        with_state(|s| Sha256::digest(serde_json::to_vec(s).unwrap()).to_vec())
    }
}
export!(Component);
