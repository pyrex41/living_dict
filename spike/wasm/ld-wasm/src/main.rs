use std::{env, path::PathBuf, process};
fn value(args: &[String], key: &str) -> Result<PathBuf, String> {
    args.iter()
        .position(|x| x == key)
        .and_then(|i| args.get(i + 1))
        .map(PathBuf::from)
        .ok_or_else(|| format!("missing {key}"))
}
fn main() {
    let a: Vec<String> = env::args().collect();
    let result = (|| {
        if a.get(1).map(String::as_str) != Some("run") {
            return Err("usage: ld-wasm run --workspace DIR --run-dir DIR --config FILE".into());
        }
        let w = value(&a, "--workspace")?;
        let r = value(&a, "--run-dir")?;
        let c = value(&a, "--config")?;
        ld_durable_executor::run(&w, &c, &r)
    })();
    match result {
        Ok(x) => println!("{}", serde_json::to_string(&x).unwrap()),
        Err(e) => {
            let reason: String = e.chars().take(500).collect();
            let zero = "0".repeat(64);
            let receipt = serde_json::json!({
                "protocol":"ld.runtime.receipt/v1","profile":"wasm-durable-v1",
                "artifact_hash":zero,"machine_config_hash":zero,"scenario_id":"initialization-failed","seed":0,
                "oplog_hash":zero,"checkpoint_hash":zero,"final_state_hash":zero,"semantic_output_hash":zero,
                "replay_count":0,"replay_equal":false,"fork":{"diverged":false},"effects":{"executed":0,"replayed":0,"logical_committed":0},
                "limits":{},"traps":[reason.clone()],"properties":[],"evidence":{},"passed":false,"reason":reason
            });
            println!("{}", serde_json::to_string(&receipt).unwrap());
            eprintln!("{}", receipt["reason"].as_str().unwrap_or("runtime failed"));
            process::exit(1)
        }
    }
}
