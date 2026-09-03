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
directory. `--kill-at` takes the process down at one of `before-intent`,
`after-intent`, `during-provider`, `after-provider-before-commit`,
`after-commit-before-deliver`, `after-transition-before-checkpoint` (the
scenario's `kill_effect` names the effect). `--kill-mode abort` (default)
journals a `fault-injection` annotation first; `--kill-mode sigkill` writes
nothing and dies by SIGKILL; `--kill-provider` (sigkill only) kills the
provider process too. `resume` completes such a run in a fresh process;
recovery never depends on the annotation, only on the chain-valid journal.
`provider` is spawned automatically by `run` when the scenario declares
providers; if it is gone at resume time a new one rebuilds its idempotency
state (executed keys, the request each is bound to, result bytes, sequence,
previous hash) from its own verified log. `engine` prints the attestation
that is embedded in every receipt.

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
`sha256(jcs({run_id, branch, component_hash, event_index, effect_index}))`
where `run_id = sha256(jcs({config_hash, scenario_hash, scenario_id, seed}))`;
the guest's `business-key` is metadata. A journaled intent carries the full
request; a reissue after a crash must match it exactly and the provider
refuses a key reused for a different request. `effects-exactly-once` is
never vacuous: the scenario's `expected_effects` names each effect and the
minimum commits it must show. Snapshots are hashed by the host, restored
into a throwaway instance, and re-snapshotted; the bytes must match. The
guest's `state-hash` is advisory (`guest-hash-discriminates`). Scenarios
may not contain floating-point values (the BEAM canonicaliser refuses them).

Limits (`[limits]` in `machine.toml`) bound input frames, output frames,
snapshots, effect payloads and results, cumulative retained output, the
oplog (checked before every append), and the replay count.

The receipt binds `scenario_hash`, `executor_sha256` (digest of the running
`ld-wasm`), and an `engine` attestation whose `config_hash` BEAM recomputes
from the settings object and whose toolchain, lockfile, and world hashes it
compares against the repository's own files. `scenario.json` is copied into
the evidence directory so offline revalidation has the exact input bytes.

`guests/bad-snapshot` is the negative fixture: lossy snapshot, non-invertible
restore, constant state hash. The gate requires it to fail.
