use ld_durable_executor::{KillPoint, RunOptions, engine_attestation, provider};
use std::{collections::BTreeMap, env, fs, path::PathBuf, process};

fn value(args: &[String], key: &str) -> Result<PathBuf, String> {
    args.iter()
        .position(|x| x == key)
        .and_then(|i| args.get(i + 1))
        .map(PathBuf::from)
        .ok_or_else(|| format!("missing {key}"))
}
fn optional(args: &[String], key: &str) -> Option<String> {
    args.iter()
        .position(|x| x == key)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

const USAGE: &str = "usage:\n  ld-wasm run --workspace DIR --run-dir DIR --config FILE [--kill-at POINT]\n  ld-wasm resume --workspace DIR --run-dir DIR --config FILE\n  ld-wasm provider --socket PATH --scenario FILE --log FILE\n  ld-wasm engine";

fn failure_receipt(reason: &str) -> serde_json::Value {
    let reason: String = reason.chars().take(500).collect();
    let zero = "0".repeat(64);
    serde_json::json!({
        "protocol":"ld.runtime.receipt/v1","profile":"wasm-durable-v1",
        "artifact_hash":zero,"machine_config_hash":zero,"scenario_id":"initialization-failed","seed":0,
        "run_id":zero,"oplog_hash":zero,"checkpoint_hash":zero,"final_state_hash":zero,"guest_state_hash":zero,
        "semantic_output_hash":zero,"replay_count":0,"replay_equal":false,"fork":{"diverged":false},
        "effects":{"executed":0,"replayed":0,"logical_committed":0},
        "limits":{},"traps":[reason.clone()],"properties":[],"evidence":{},
        "engine":engine_attestation(),"recovery":{"kill_point":null,"resumed":false},
        "passed":false,"reason":reason
    })
}

fn main() {
    let a: Vec<String> = env::args().collect();
    match a.get(1).map(String::as_str) {
        Some("engine") => {
            println!("{}", serde_json::to_string(&engine_attestation()).unwrap());
            return;
        }
        Some("provider") => {
            let result = (|| -> Result<(), String> {
                let socket = value(&a, "--socket")?;
                let scenario = value(&a, "--scenario")?;
                let log = value(&a, "--log")?;
                let text = fs::read(&scenario).map_err(|e| e.to_string())?;
                let v: serde_json::Value =
                    serde_json::from_slice(&text).map_err(|e| e.to_string())?;
                let canned: BTreeMap<String, Vec<serde_json::Value>> =
                    serde_json::from_value(v["providers"].clone()).map_err(|e| e.to_string())?;
                provider::serve(&socket, canned, &log).map_err(|e| e.to_string())
            })();
            if let Err(e) = result {
                eprintln!("{e}");
                process::exit(2)
            }
            return;
        }
        Some("run") | Some("resume") => {}
        _ => {
            eprintln!("{USAGE}");
            process::exit(2)
        }
    }
    let resume = a[1] == "resume";
    let result = (|| -> Result<_, String> {
        let w = value(&a, "--workspace")?;
        let r = value(&a, "--run-dir")?;
        let c = value(&a, "--config")?;
        let kill = match optional(&a, "--kill-at") {
            Some(p) if !resume => Some(KillPoint::parse(&p).map_err(|e| e.to_string())?),
            Some(_) => return Err("--kill-at is not accepted on resume".into()),
            None => None,
        };
        let exe = env::current_exe().map_err(|e| e.to_string())?;
        ld_durable_executor::run(&w, &c, &r, RunOptions { kill, resume, exe })
    })();
    match result {
        Ok(x) => println!("{}", serde_json::to_string(&x).unwrap()),
        Err(e) => {
            let receipt = failure_receipt(&e);
            println!("{}", serde_json::to_string(&receipt).unwrap());
            eprintln!("{}", receipt["reason"].as_str().unwrap_or("runtime failed"));
            process::exit(1)
        }
    }
}
