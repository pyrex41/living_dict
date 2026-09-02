# `wasm-durable-v1`

Reference semantics for Living Dictionary's deterministic product runtime.
Design and history: [`docs/design/DURABLE_WASM_GOAL.md`](../../docs/design/DURABLE_WASM_GOAL.md);
plan: [`docs/design/DURABLE_SYSTEM_PLAN.md`](../../docs/design/DURABLE_SYSTEM_PLAN.md).

## Toolchain

`rust-toolchain.toml` pins Rust 1.95.0 with the `wasm32-unknown-unknown`
target; guests are built with `cargo-component` 0.21.1 (`nix develop` here
provides both). Wasmtime is pinned at 48.0.1 and that pin is asserted by a
test against `Cargo.lock`.

```sh
make build          # guests (kv, order, bad-snapshot) + ld-wasm
make test           # cargo test --workspace --locked
make durable-gate   # positive runs, negative fixture, kill matrix
```

## Commands

```
ld-wasm run      --workspace DIR --run-dir DIR --config FILE [--kill-at POINT]
ld-wasm resume   --workspace DIR --run-dir DIR --config FILE
ld-wasm provider --socket PATH --scenario FILE --log FILE
ld-wasm engine
```

`run` prints one `ld.runtime.receipt/v1` and leaves the evidence in the run
directory. `--kill-at` aborts the process at one of `before-intent`,
`after-intent`, `during-provider`, `after-provider-before-commit`,
`after-commit-before-deliver`, `after-transition-before-checkpoint` (the
scenario's `kill_effect` names the effect). `resume` completes such a run in
a fresh process. `provider` is spawned automatically by `run` when the
scenario declares providers; it outlives an aborted runner so `resume`
finds the same idempotency state. `engine` prints the attestation that is
embedded in every receipt.

## Routes and evidence

One scenario runs as several routes over the same events:

| route | mode | what it establishes |
|---|---|---|
| `parent` | live | effects through the write-ahead journal to the provider; checkpoint of guest bytes plus host state after `checkpoint_index` events |
| `replay-N` | journal | `replay-stable`: identical outputs, snapshot hash, host state; zero live calls |
| `recovered` | journal, from checkpoint | `checkpoint-recovered`: restored guest bytes and host clock/RNG/cursors continue the suffix identically |
| `fork` | journal prefix, live suffix | `fork-diverged`; branch manifest with parent lineage |

Evidence files (all hash-linked, all recomputed by
`beam/lib/ld_host/runtime_evidence.ex`):

- `oplog.jsonl` (`ld.oplog/v2`): every entry appended online and fsync'd;
  kinds include `effect-intent`, `effect-commit` (with the result bytes),
  `checkpoint`, `snapshot-roundtrip`, `fault-injection`, `resume`.
- `provider-calls.jsonl` (`ld.provider/v1`): the provider's own chained log;
  `executed` per key is the external count.
- `checkpoint.json` (`ld.checkpoint/v1` schema version 2): guest bytes and
  `host` `{time, rng_seed, rng_word_pos, event_index, effect_index}`.
- `branches/fork/manifest.json`, `run.json`.

Effect keys are host-derived:
`sha256(jcs({run_id, branch, component_hash, event_index, effect_index}))`;
the guest's `business-key` is metadata. Snapshots are hashed by the host,
restored into a throwaway instance, and re-snapshotted; the bytes must match.
The guest's `state-hash` is advisory (`guest-hash-discriminates`).

`guests/bad-snapshot` is the negative fixture: lossy snapshot, non-invertible
restore, constant state hash. The gate requires it to fail.
