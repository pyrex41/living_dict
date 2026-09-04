use sha2::{Digest, Sha256};
use std::{env, fs, process::Command};

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=../wit/durable.wit");
    println!("cargo:rerun-if-changed=../rust-toolchain.toml");
    println!("cargo:rerun-if-changed=src/lib.rs");
    println!("cargo:rerun-if-changed=src/provider.rs");
    // Source digest of the executor crate, bound into every receipt.
    let mut h = Sha256::new();
    for f in ["build.rs", "src/lib.rs", "src/provider.rs", "Cargo.toml"] {
        h.update(f.as_bytes());
        h.update(fs::read(f).unwrap_or_default());
    }
    println!("cargo:rustc-env=LD_EXECUTOR_SOURCE_HASH={:x}", h.finalize());
    let target = env::var("TARGET").unwrap_or_else(|_| "unknown".into());
    println!("cargo:rustc-env=LD_TARGET_TRIPLE={target}");
    let rustc = env::var("RUSTC").unwrap_or_else(|_| "rustc".into());
    let version = Command::new(rustc)
        .arg("-vV")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.lines().next().map(str::to_string))
        .unwrap_or_else(|| "unknown".into());
    println!("cargo:rustc-env=LD_RUSTC_VERSION={version}");
}
