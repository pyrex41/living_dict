# From one durable component to a checked deterministic system

Status: plan, revision 2, with Phases 1 and 2 landed (see section 0).
Supersedes the phase ordering in
[`DURABLE_WASM_GOAL.md`](DURABLE_WASM_GOAL.md) (which remains the record of
what `wasm-durable-v1` shipped in PR #14) and the "what to port" list in
[`UNIKRAFT.md`](UNIKRAFT.md). Written against `main` at `c67513d` in answer to
the source-level review in
[`reviews/durable-runtime.md`](reviews/durable-runtime.md).

The review's thesis is accepted: the project has a deterministic component
behind an approved claim, not yet a composed deterministic system whose
architecture, components, implementation, and evidence form one checked
refinement chain. This document turns the review into work items with file
targets, gates, and exit conditions, and records where the plan departs from
the review's suggestions.

## 0. Status after the execution pass

Landed on this branch, verified by `make -C spike/wasm durable-gate`,
`cargo test --workspace --locked`, and the BEAM tests (`jcs_test`,
`substrates_test`, `elaborate_test`, `runtime_evidence_test`, `gates_test`
including the `:durable` end-to-end case):

| item | state |
|---|---|
| 1a whole-machine checkpoint (guest bytes + clock, RNG position, event/effect cursors); order guest observes both after the checkpoint | done, `spike/wasm/executor/src/lib.rs` (`HostState`, `Checkpoint`) |
| 1b write-ahead intent/commit journal, out-of-process provider with its own chained call log, six-point kill matrix with `ld-wasm resume` in a fresh process | done, `executor/src/provider.rs`, `spike/wasm/Makefile` `kill-matrix` |
| 1c host-derived effect keys `(run, branch, component, event, effect)`; guest key is metadata; WIT world `0.2.0` | done |
| 1d host-hashed snapshots, restore-and-resnapshot round trips at checkpoint and exit, `guests/bad-snapshot` negative fixture rejected by the gate | done |
| 1e explicit Wasmtime profile (NaN canonicalization, relaxed SIMD off and deterministic, memory64/multi-memory off, epochs off, Cranelift speed), receipt `engine` attestation, allowlisted in BEAM | done; threads and parallel compilation are compiled out and recorded as such |
| 1f independent verifier in BEAM | done, `beam/lib/ld_host/runtime_evidence.ex` re-derives every property; `RuntimeProfiles` passes a claim only on verified properties |
| 1g positive BEAM test, revalidation from files, greedy-claim rejection, gates in `make test` | done; `beam-durable-e2e` target; `make test` now runs `wasm-test` and `durable-gate` and fails loudly without the toolchain |
| 2a `ld-system/v1` manifest and schema doc | done, `beam/lib/ld_host/system_manifest.ex`, `docs/design/schema/ld-system-v1.md`, `examples/orders/ld-system.json` |
| 2b substrate capability vectors with per-dimension lattice; `unikraft-confined-transducer-experimental` registered and not claim-capable; claims carry `requires` | done, `beam/lib/ld_host/substrates.ex` |
| 2c substrate behaviour interface | not done; the kernel (Phase 3) is its first consumer |
| 2d elaborator producing canonical derivations and obligations | done twice: typed Shen (`shen/critic/elaborate.shen`, typechecked and shaken by the pinned `tools/critic` toolchain, suite `shen/critic/elaborate-tests.shen`) and Elixir (`beam/lib/ld_host/elaborate.ex`, `mix ld.elaborate`); `beam/test/elaborate_shen_test.exs` requires them to agree on every step, failed judgment, and obligation |
| Phases 3 to 6 | not started |

Phase 2 exit condition holds: the orders manifest is accepted with a stable
derivation hash, and moving the payment broker to the experimental profile
is rejected naming `payment.external_effects`.

Not reproduced here: the Unikraft QEMU gate (`make -C spike/unikraft
product-gate`) needs Nix and Kraft, which this environment does not have.
Its rename to experimental is text and registry only.

## 1. What shipped, and what the review found

Every gap the review names was re-checked against the source. All hold.

| # | Review finding | Verified where |
|---|---|---|
| 1 | Checkpoint restores guest state only; host clock, RNG, provider cursor are rebuilt fresh on every route | `spike/wasm/executor/src/lib.rs:283-327`: `execute` builds `Host{time: 0, rng: from_seed(seed), provider_pos: {}}` for every route, then calls guest `restore` |
| 2 | "Exactly once" is a replay simulation inside one process; provider is canned; fault injection is a log entry, not a kill | `lib.rs:202-254` (`Host.providers` from the scenario), `lib.rs:602-609` (`fault-injection` appended post hoc) |
| 3 | Guest supplies its own idempotency key, contrary to `DURABLE_WASM_GOAL.md` ("derives from worker and effect-log position") | `spike/wasm/guests/order/src/lib.rs:48-52,58-62` builds `"{order_id}:charge"` in the guest |
| 4 | Guest supplies `snapshot` and `state-hash`; host never restores-then-resnapshots to prove the snapshot is complete and invertible | `spike/wasm/wit/durable.wit` exports; `lib.rs:346-357` returns guest `state_hash` and compares it across routes |
| 5 | Wasmtime determinism settings not explicit | `lib.rs:430-431`: only `wasm_component_model(true).consume_fuel(true)` |
| 6 | BEAM validates receipt shape and file hashes but does not re-derive semantic claims from the oplog | `beam/lib/ld_host/runtime_profiles.ex` (`validate/2`, `validate_hashes/3`); no oplog walk |
| 7 | No positive BEAM test of an approved runtime claim passing | `beam/test/gates_test.exs:17-48` covers authority denial and path traversal only |
| 8 | Wasm and Unikraft product gates are outside `make test` | `Makefile:62` (`test:` lists `unikraft-spike`, the Lua selftest, and not `wasm-test`, `durable-gate`, or `product-gate`) |
| 9 | Unikraft loader is not content-pinned and exposes RDRAND/RDSEED | `spike/unikraft/product/loader/Kraftfile:3` (`base:latest`), `product/gate.sh:87` (`+rdrand,+rdseed`) |
| 10 | Lua simulator applies artifacts directly and passes gates when no expected tree is supplied | `spike/unikraft/lua/organs.lua:43-52`, `organs.lua:94-95` (`passed = expect == nil or ...`) |
| 11 | Formal artifacts are adjacent, not one chain | `spike/unikraft/model/Episode.tla` (71 lines), `fabric.netkat` (32), `component.shen` (47); nothing relates them mechanically |

One nuance on finding 1: the effect replay cursor *is* positioned correctly
for the recovered route, because `run_inner` slices `parent.effects` at the
checkpoint's effect count (`lib.rs:472-481`). Clock and RNG are the parts
that reset. The KV and order guests never call `virtual-time` or
`seeded-random`, which is why the gate cannot see it.

What is sound and must not regress:

- Runtime claims enter only through approved or hidden contracts, dispatch
  to a literal host-owned profile, and are judged by BEAM after hash checks.
  The model cannot select or describe a runtime.
- The WIT world imports exactly three capabilities and no WASI. Nondeterminism
  is withheld, not intercepted.
- Six-word Forth ABI, `RUN-GATES` as the only Forth-visible measurement,
  `claims_discharged` unchanged. `eval/` untouched.
- Evidence is host-owned under `.livingdict-run/runtime/<claim>/<nonce>/`,
  canonical JSONL, hash-linked.

## 2. Principles this revision adds

1. **Wasm is the reference semantics.** Every other substrate is a profile
   of the contract Wasm defines. No new substrate lands until Phase 1 exits.
2. **A profile name is a behavioral contract, bound in the receipt.** If the
   receipt does not pin the engine, its configuration, the toolchain, and the
   WIT world hash, the profile name is a launcher label.
3. **The executor is not the judge.** Whatever produces execution and
   provider calls does not also decide `passed`. BEAM re-derives every
   property from the evidence files, or the property is not a property.
4. **A checkpoint is the whole machine.** Guest bytes plus host clock, RNG
   state, effect journal position, and event index, at one logical boundary.
   Later: plus queues, timers, scheduler state, branch identity, manifest hash.
5. **Effect identity is host-derived.** The guest may pass a business key as
   metadata; the harness keys the journal on logical position.
6. **Every runtime gate is a release blocker.** If a gate is worth writing it
   is in `make test`, or it is labeled experimental and excluded from claims.
7. **Weaker guarantees get weaker names.** `experimental` in the profile
   name until the exit condition for that profile is met.

## 3. Phase 1: make `wasm-durable-v1` crash-complete

Everything below is a change to `spike/wasm/` and `beam/lib/ld_host/`. No new
Forth words, no new claim kinds, no new substrates.

### 1a. Whole-machine checkpoint

- Add `HostState { time, rng: ChaCha20 (seed, word_pos, stream), event_index,
  effect_index }` serialized into `ld.checkpoint/v1` next to the guest bytes.
  ChaCha20 position is a counter, so the checkpoint records the counter, not
  the keystream.
- `execute` gains a `resume: Option<Checkpoint>` that restores host state and
  guest bytes together. Remove the `restore: Option<&[u8]>` path.
- Extend the order guest so `reserve` reads `virtual-time` and `charge` draws
  `seeded-random` bytes into its state. The recovered route now diverges if
  host state is not restored. That is the regression test for this seam.
- Scenario events keep `advance_ms`; the checkpoint records the accumulated
  time so the suffix continues rather than restarts.

### 1b. Online intent/commit journal and kill injection

- Replace the post hoc assembly in `run_inner` with a write-ahead journal:
  `effect-intent` is fsync'd before the provider is called, `effect-commit`
  after the result is in hand, and the guest sees the result only after
  commit. This is the protocol `DURABLE_WASM_GOAL.md` already specifies.
- Move providers out of the executor process. A `ld-wasm provider` subcommand
  serves the canned responses over a Unix socket and counts every call it
  receives, so "at most one externally visible operation" is measured by a
  process that the executor cannot edit.
- Add `ld-wasm run --kill-at <point>` where point is one of:
  `before-intent`, `after-intent`, `during-provider`, `after-provider-before-commit`,
  `after-commit-before-deliver`, `after-transition-before-checkpoint`.
  The runner exits via `std::process::abort()` at that point. A second
  `ld-wasm resume --run-dir` in a fresh process reads the journal and either
  completes the effect (intent without commit and provider reports zero
  calls), replays the committed result (commit present), or suppresses the
  call (provider reports one call, no commit: reconcile via the provider's
  idempotent lookup by host key).
- `durable-gate` runs the six-point matrix on the order scenario. For each
  point it asserts: provider call count is exactly one, final state hash
  equals the unkilled run, chain verifies, and zero live calls occurred in
  any replay route.

### 1c. Host-derived effect identity

- Journal key is `sha256(run_id ‖ branch ‖ component_hash ‖ event_index ‖
  effect_index)`. The guest's string becomes `business_key` metadata in the
  intent entry and is required to be stable across replay, but nothing keys
  on it.
- `durable.wit` keeps `idempotency-key: string` in the import for source
  compatibility, documented as metadata. Bump the world to `@0.2.0` because
  the host state now participates in checkpoints; the receipt binds the world
  hash (1e).

### 1d. Host-owned snapshot evidence

- After each route, the executor: hashes the raw snapshot bytes; restores
  them into a fresh instance; snapshots again; asserts byte equality; runs
  the same suffix; asserts identical outputs. A guest whose `snapshot` omits
  state or whose `restore` is not invertible fails here.
- `state-hash` from the guest becomes `guest_state_hash` in the receipt, an
  additional signal. `final_state_hash` is the host's hash of snapshot bytes.
- Add a deliberately broken guest fixture (`guests/bad-snapshot`, constant
  state hash and lossy snapshot) that the gate must reject.

### 1e. Explicit engine profile and attestation

`wasm-durable-v1` engine config, set explicitly in `run_inner` and hashed
into the receipt:

```
wasm_component_model(true)
consume_fuel(true)
cranelift_nan_canonicalization(true)
wasm_relaxed_simd(false)        # or relaxed_simd_deterministic(true)
wasm_threads(false)
wasm_memory64(false)
wasm_multi_memory(false)
epoch_interruption(false)
strategy(Cranelift)
```

Receipt gains an `engine` object: `wasmtime_version`, `config_hash`,
`target_triple`, `component_model_version`, `world_hash`, `toolchain`
(`rust-toolchain.toml` hash, `cargo component` version), `profile_schema`.
BEAM refuses a receipt whose `engine.config_hash` is not in its allowlist for
the profile. Memory growth is already bounded by `StoreLimits`; record the
limits in `engine` too so growth failure points are reproducible.

### 1f. Independent verification lives in BEAM

The review proposes a second Rust binary. This plan puts the checker in
`beam/lib/ld_host/runtime_evidence.ex` instead, because BEAM is already the
judge, already holds `verify_receipt/4`, and has no execution or provider
authority. The Rust `verify()` in the executor stays as the executor's own
self-check; it is not evidence.

`RuntimeEvidence.verify(evidence_dir, receipt)` re-derives from files:

- oplog hash chain and sequence continuity;
- every `effect-intent` has exactly one `effect-commit` or an explicit
  `effect-abandoned` with a kill point;
- provider call log (from the provider process) agrees with committed
  effects: one call per key;
- checkpoint references a real oplog index and its host-state fields;
- snapshot hash in the checkpoint equals the hash of the stored bytes;
- replay routes in the oplog show zero live calls;
- fork manifest's parent hash and cutoff exist in the parent chain;
- `properties` in the receipt are each recomputed, and the receipt is
  rejected if it claims one the evidence does not support;
- `engine.config_hash` in the profile allowlist.

`RuntimeProfiles.run/2` calls this after `validate_hashes/3`. `passed` in
the receipt becomes advisory; BEAM's verdict is what the claim reports.

### 1g. Tests and gates

- `beam/test/gates_test.exs`: add the positive path. An approved contract
  with a `wasm-durable-v1` claim against a checked-in receipt and evidence
  fixture passes; the same fixture with one flipped byte in `oplog.jsonl`
  fails with the chain error; a receipt claiming `effects-exactly-once`
  over a journal with a duplicate commit fails.
- `beam/test/runtime_evidence_test.exs`: each bullet in 1f has a fixture that
  fails it.
- The end-to-end proof named in `DURABLE_WASM_GOAL.md` ("isolated LD job,
  approved runtime claim, canned planner, exit zero iff evidence present and
  claims discharged") becomes `make -C beam ld.durable-e2e` and a test.
- `Makefile:62` `test:` gains `wasm-test` and `durable-gate`. Because the
  Cargo workspace builds `--locked --offline`, vendor the crates
  (`cargo vendor` into `spike/wasm/vendor/`, committed) or provide them via
  the flake, so `make test` does not depend on network. If neither is
  acceptable in CI, `make test` fails loudly when `cargo` is missing rather
  than skipping.
- `apps/architecture/data/architecture.json` runtime row 7 and the durable
  runtime page: rewrite to describe present guarantees (replay-stable,
  fork-diverged, state-hash-stable within one process) until 1b lands, then
  update again. The page must not run ahead of the gate.

### Phase 1 exit

Every point in the kill matrix on the order scenario: killed, resumed in a
new process, verified by BEAM from files alone, provider called once, final
state equal to the unkilled run. `make test` red if any of that regresses.

## 4. Phase 2: `ld-system/v1` and capability matching

### 2a. The manifest

One typed, content-addressed description, checked in as
`docs/design/schema/ld-system-v1.md` and a JSON Schema. Fields in this
revision:

```
schema, system
components{name: contract, artifact(sha256), substrate, requires{...}}
channels{name: from, to, delivery, ordering, capacity, faults[]}
effects{name: owner, protocol, identity}
invariants[]
failure_model[]
```

`deployment` is deliberately absent in v1. The review includes Fargate
targets, IAM, and security groups in the manifest; those belong to a
production twin (Phase 6) and would force design decisions now that nothing
in Phases 1 to 5 consumes. The schema reserves the key.

### 2b. Substrate capability vector

Replace `RuntimeProfiles.executable/1`'s literal match with a registry
`beam/lib/ld_host/substrates.ex` where each profile declares:

```
isolation, clock, entropy, scheduler, filesystem, network,
external_effects, snapshot, global_checkpoint, floating_point,
memory_growth, replay, branching, fault_controls[], build_reproducibility
```

Values are a lattice per dimension (for example `snapshot: none < component
< whole-machine`). A component's `requires` must be ≤ the substrate's
guarantee in every dimension or the claim is rejected before dispatch.

Profiles registered in this phase:

- `wasm-durable-v1`: the Phase 1 vector, all dimensions filled.
- `unikraft-confined-transducer-experimental`: the existing product gate,
  honestly declared (`entropy: ambient-seeded`, `build_reproducibility:
  unpinned`, `snapshot: none`, `replay: rerun-only`). Rename the gate and
  README now; it cannot back a claim until Phase 6.

### 2c. Substrate behaviour interface

```elixir
@callback capabilities(config) :: capability_vector()
@callback build(component, config) :: {:ok, receipt} | {:error, term}
@callback start(component, checkpoint | nil, config) :: instance
@callback deliver(instance, event) :: transition
@callback checkpoint(instance) :: checkpoint
@callback stop(instance) :: receipt
```

`LdHost.Substrate.WasmDurable` wraps `ld-wasm` over the socket protocol from
1b (one process per instance, driven event by event). The layers above see
`deliver/2` returning `{new_state_hash, emitted[], effects[], timers[],
assertions[]}`, which is the transducer shape the kernel needs in Phase 3.

### 2d. Shen judgments

Extend the typed critic with a second entry point, `elaborate-system`, that
takes the manifest and the substrate registry and returns a derivation, not
`Accept | Reject`:

```
Accepted {derivation_hash, assumptions, obligations[], unresolved[]}
Rejected {derivation_hash, reason}
```

Judgments in this phase: component contract types compose across each
channel; every `requires` dimension is satisfied by the assigned substrate;
every effect has exactly one owner; every invariant references only
declared components, channels, and effects. Obligations name what later
phases must discharge (`tla:delivery(order-commands)`,
`netkat:isolated(api, card-provider)`, `runtime:exactly-once(charge-card)`).

Proof search is bounded and rule order is canonical; the derivation is
canonical JSON hashed into the ledger. The plan opts for bit-identical
derivations, not merely equivalent ones, because everything else in the
ledger is byte-hashed.

### Phase 2 exit

The order manifest with all three components on `wasm-durable-v1` is
accepted with a deterministic derivation hash. The same manifest with the
payment broker moved to the Unikraft experimental profile is rejected with
the dimension that failed (`external_effects`). Both derivations land in the
ledger.

## 5. Phase 3: the composition kernel

Three Wasm components (api, worker, payment broker), typed messages, no
sockets. `beam/lib/ld_host/kernel/` owns logical reality; substrates own
nothing but their instance.

- One explicit event queue. The schedule is data: a `choice log` of
  `{deliver, duplicate, drop, delay, reorder, crash, restart, timer, effect-result}`
  entries. BEAM processes execute, but ordering comes from the log, never
  from mailbox arrival.
- Channels from the manifest, with the declared delivery and ordering
  semantics enforced by the kernel and the declared faults available as
  choices.
- Timers are logical; `virtual-time` for every component is the kernel's
  clock.
- Effect broker: the 1b journal, generalized across components, keyed by
  the 1c identity.
- Global checkpoint = `GlobalCheckpoint` from the review, including every
  component's 1a checkpoint, queues, timers, choice-log index, and the
  manifest hash.
- Branch = parent checkpoint hash plus a choice-log suffix. Revert is a new
  branch. Same rule as today's fork manifest.
- Event footprints. Each transition records `{reads, writes, emits,
  effects, timers}`. This is the runtime analogue of the envelope graph's
  declared writes and waves (`GRAPH.md`); the wave machinery's conflict
  rejection is reused for commuting-transition detection.
- Global state hash over component snapshot hashes, queues, timers, and
  journal head.

### Phase 3 exit

Two runs from the same manifest and choice log produce identical global
state hashes and identical evidence chains. A global restore at any
checkpoint followed by the remaining choices reproduces the same terminal
hash. A branch at a choice point diverges and both branches verify.

## 6. Phase 4: attach the real formal tools

- **TLA+.** Generate transition modules from the manifest (channels,
  effect protocol, crash and restart) into `spike/formal/tla/`. Invariants
  from the manifest are transcribed into a separately approved module that
  generation never overwrites. Run TLC (Apalache later) in the flake; store
  tool version, bounds, config, result, and any counterexample as evidence
  under the obligation id from 2d.
- **NetKAT.** Generate topology and policy from channels and effect owners.
  Replace `spike/unikraft/lua/netkat.lua` as the oracle with an actual
  verifier (KATch) invoked from the flake; keep the Lua subset as a fast
  pre-check. Obligations: isolation (api cannot reach card provider),
  waypoint (worker to payment passes the broker), equivalence between the
  declared topology and the generated policy.
- **Trace validation.** Project the kernel's choice log and state hashes
  into TLA+ states and validate observed traces. Turn TLC counterexamples
  into choice logs the kernel can execute.
- **Evidence hierarchy in the ledger.** Distinct kinds:
  `type-check`, `model-check`, `refinement`, `network-policy`,
  `trace-validation`, `exploration`. No aggregate `proved`.

### Phase 4 exit

Mutating the worker's retry logic, a channel's delivery semantics, the
topology, or the effect protocol makes the corresponding obligation fail
automatically, and the ledger names which one.

## 7. Phase 5: exploration

Seeded random search over the choice log, bounded depth, then state-hash
deduplication, trace shrinking, and partial-order reduction from Phase 3's
footprints. Branch points: message choice, drop, delay, duplicate, reorder,
timer ordering, crash, restart checkpoint, partition and heal, provider
result, resource exhaustion, retry timing.

Exit: a deliberately planted double-charge under crash-after-provider-success
is found, shrunk to a minimal choice log, and reproduced exactly in a
separate process.

## 8. Phase 6: substrates as profiles, and the twin

Only now: Unikraft as `unikraft-confined-v1` (image by digest, pinned
toolchain, no RDRAND/RDSEED, no RTC, fixed CPU model and device topology,
framed protocol not output scraping, verifier separate from the boot
runner), then `gvisor-mediated-v1` and `microvm-snapshot-v1`, each declaring
its honest vector and each running the Phase 1 kill matrix against the same
order scenario. The production twin (deployment fields in the manifest,
generated Fargate definitions checked against the NetKAT policy, production
traces normalized into the choice-log schema) follows.

## 9. Where this plan departs from the review

- **Verifier in BEAM, not a second Rust binary.** Same separation of
  authority, one fewer trust root, and it reuses `verify_receipt/4`.
- **Manifest and kernel are sequenced, not merged.** Phase 2 lands the
  manifest and capability matching with a single-component consumer so the
  schema is exercised before the kernel exists. Phase 3 consumes it.
- **Deployment is out of the v1 manifest.** Reserved key; nothing before
  Phase 6 reads it.
- **Scenario format survives.** `livingdict.scenario/v1` stays for
  single-component claims; the kernel's choice log is a new schema, and a
  scenario is compiled into a one-component choice log rather than kept as a
  parallel path.
- **Bit-identical Shen derivations.** The review leaves the choice open; this
  plan closes it in favour of bytes, to match the ledger.
- **Two elaborators, one conformance suite.** The judgments live in typed
  Shen (`shen/critic/elaborate.shen`, the specification) and in Elixir
  (`LdHost.Elaborate`, the executing body inside the BEAM host, which also
  does the JSON and hashing). `make beam-elaborate-conformance` runs both
  over the same flattened manifests and fails on any differing step. The
  shen-erl BEAM target of the elaborator is not built yet (its toolchain
  needs `shenlanguage.org`, unreachable from the execution environment), so
  BEAM executes the Elixir body rather than the shaken Shen.

## 10. Not in this plan

The inference-scheduler co-design thread (session affinity, KV prefetch,
speculative tool calls, colocated subagents) is orthogonal to the runtime
work. The product runtime executes with the model off, so none of it touches
Phases 1 to 6. Its touchpoints in this repo remain the planner's stable
prefix and the bounded OODA investigator, tracked under
[`LATEST_BENCHMARK_CAMPAIGN.md`](LATEST_BENCHMARK_CAMPAIGN.md). The one item
that could later fold in is constrained decoding of the envelope grammar,
which would remove malformed-envelope critic rejections at the sampler; it is
a planner concern and is not scheduled here.

## 11. Gates after Phase 1

```sh
nix develop ./spike/wasm --command cargo test --workspace --locked
make durable-gate            # kill matrix, provider counts, bad-snapshot rejection
make beam-durable-e2e        # approved runtime claim through Gates, BEAM verdict from files
make elaborate-example       # orders manifest -> ld.derivation/v1
make critic-suite            # packed Shen critic and elaborator suites (ShenScript host)
make elaborate-js-nix        # typecheck + shake the Shen elaborator (nix)
make beam-elaborate-conformance   # Elixir vs Shen, step for step
make -C spike/unikraft product-gate       # experimental; not a claim backend
make -C spike/unikraft test
make test                                 # includes wasm-test and durable-gate
```

Launch form for the next execution pass:

```sh
codex exec -C <checkout> - < docs/design/DURABLE_SYSTEM_PLAN.md
```
