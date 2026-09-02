# Durable Wasm Execution Profile for Living Dictionary

> **Status (2026-09-02):** this is the record of what shipped in PR #14.
> Several claims below were ahead of that implementation (host-derived
> effect identity, host-state checkpoints, process-kill fault injection).
> They are now implemented; the current runtime is described in
> [`../../spike/wasm/README.md`](../../spike/wasm/README.md) and the plan
> that drove the change is [`DURABLE_SYSTEM_PLAN.md`](DURABLE_SYSTEM_PLAN.md),
> answering [`reviews/durable-runtime.md`](reviews/durable-runtime.md).
> The WIT world is now `livingdict:durable/product@0.2.0` and the oplog is
> `ld.oplog/v2`.

## Goal

Ship an opt-in `wasm-durable-v1` product runtime beneath Living Dictionary's existing planner, typed critic, frozen six-word Forth ABI, `RUN-GATES`, and claim-discharge loop. The guarantee is **controlled semantic execution with seeded replay**, not universal instruction-level determinism. Golem's operation-log, checkpoint recovery, and fork/revert model is the architectural reference; Golem is not a deployed dependency.

The implementation lives in `spike/wasm/`: a pinned Rust workspace, reusable executor, `ld-wasm` CLI, WIT, guest SDK, KV and order products, scenarios, evidence, Nix tooling, and Make gates. Planner/model execution stays outside the product runtime. No Forth words are added and `claims_discharged` is unchanged. Python is a frozen reference; generic dispatch belongs in the live BEAM gate body.

## Runtime contract

The WIT world `livingdict:durable/product@0.1.0` imports only virtual time, seeded random bytes, and named external effects. It exports `init`, `handle`, `snapshot`, `restore`, and `state-hash`. Frames are versioned opaque bytes with canonical JSON representations. Guests receive no ambient filesystem, sockets, clocks, random, environment, stdio, or threads.

Every run creates a fresh Wasmtime Component Model boundary and admits only a configured component whose SHA-256 was recorded. Configuration fixes fuel, memory, invocation, frame, and log limits. Builds use fixed `cargo component build --release --locked --offline`; `machine.toml` never supplies a command. All paths resolve beneath the workspace. Security/capability tables reject unknown keys.

Virtual time advances only through scenario events. Randomness uses a pinned seeded algorithm. External effects record intent, stable idempotency key, result, and commit; replay returns recorded results and never calls a provider. Undeclared imports, component mismatches, corrupt checkpoints, broken chains, missing capabilities, and exhausted limits fail closed.

## Durable evidence

Evidence is host-owned under `.livingdict-run/runtime/<claim-id>/<run-id>/`. `ld.oplog/v1` is append-only canonical JSONL. Each entry contains sequence/kind, component hash, worker, scenario seed, canonical input/result, state hashes before/after, previous hash, and current hash. RFC 8785 canonicalization plus SHA-256 applies to entries, semantic output, state, checkpoints, and receipts. Host time, paths, banners, and process IDs are excluded from semantic hashes.

Kinds include worker creation/invocation, capability request/result, effect intent/commit, semantic output, checkpoint, fault injection, claim observation, and exit/trap. A checkpoint records versioned guest state bytes, state hash, component hash, and oplog index. Recovery must agree from checkpoint plus suffix and from genesis. Forks reference parent hash/cutoff and append a new suffix; revert is a new branch, never truncation.

## Generic claim boundary

Approved/hidden contracts may include:

```json
{"id":"durable-campaign","kind":"runtime","profile":"wasm-durable-v1","config":"machine.toml","must":["replay-stable","fork-diverged","state-hash-stable","effects-exactly-once"]}
```

The BEAM gate maps literal host-known profiles to executors and passes workspace, host-owned run directory, claim ID, config, and timeout. It captures one JSON receipt and bounded diagnostics. Unknown profiles, malformed/missing evidence, timeout, failed properties, and artifact mismatch fail closed. Runtime claims have the same authority requirement as executable checks and count as behavioral evidence.

`ld.runtime.receipt/v1` carries profile/protocol, artifact and machine hashes, scenario/seed, oplog/checkpoint/state/output hashes, replay equality/count, fork lineage/divergence, effect counts, limits/traps/properties, and bounded pass/failure reason. The runtime result remains inside the existing claims gate; `RUN-GATES` remains the only Forth-visible measurement.

## Demonstrations and acceptance

KV implements `PUT`, `GET`, `DELETE`, `DUMP`, and `HALT` with byte-sorted keys. A checkpoint follows the shared `a`/`b` prefix; parent and delete-`b` fork replay three times, share the prefix, and diverge in final state/output. Altered input is a negative control and overlapping transcripts match the Unikraft fixture.

Order creates an order, reserves inventory, charges payment, and sends a receipt. A crash after charge commit but before the next frame restores without a second provider call. The idempotency key derives from worker and effect-log position. Approved and declined forks share the pre-charge prefix and diverge afterward. One live charge, zero replayed live charges, and one logical commit are required; an undeclared effect is rejected.

Tests cover canonicalization/chains, seeded RNG/time, capability denial, limits, record/playback, recovery, fork lineage, effect crash recovery, tampering, malformed config/path escape, authority, allowlisting, receipt conversion, timeout/malformed/failure handling, behavioral classification, unchanged ordinary claims, frozen Forth ABI, and unchanged discharge.

Required gates:

```sh
nix develop ./spike/wasm --command cargo test --workspace --locked
make -C spike/wasm durable-gate
make -C spike/unikraft product-gate
make -C spike/unikraft test
make test
```

The final proof is an isolated LD job using an approved runtime claim and canned planner; exit zero requires present runtime evidence and discharged claims.

Future backends use the same request/receipt and runtime claim: `gvisor-mediated-v1` records selected syscall effects; `microvm-snapshot-v1` restores identical copy-on-write snapshots and mediates network/fault events. Composition is deferred until a standalone backend ships.

Launch form:

```sh
codex exec -C /Users/reuben/projects/living_dict-unikraft-spike \
  - < /Users/reuben/projects/living_dict-unikraft-spike/docs/design/DURABLE_WASM_GOAL.md
```
