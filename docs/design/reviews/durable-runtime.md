# Source-level review: durable Wasm, Unikraft, and the formal layer

Reviewed tree: `main` at `c67513d` (after PR #14 "Add deterministic Unikraft
and durable Wasm runtimes" and PR #15 "Document durable Wasm runtime").
Review date: 2026-09-02. The reviewer did not execute the QEMU/Unikraft
toolchain; runtime observations come from the implementation and its gates.
The revised plan that answers this review is
[`../DURABLE_SYSTEM_PLAN.md`](../DURABLE_SYSTEM_PLAN.md).

---

This is a source-level review of the current main branch, including the BEAM integration, durable-Wasm executor, both Unikraft experiments, Shen critic, TLA+ sketch, NetKAT subset, gates, receipts, and test entry points. I did not independently execute the QEMU/Unikraft toolchain in this environment, so observations about runtime behavior are based on the implementation and its gates rather than a separate reproduction.

## Bottom line

The idea is real, and the new work materially strengthens the project. wasm-durable-v1 is the first credible implementation of the thing you have been describing: generated product logic placed behind an intentionally deterministic capability boundary, invoked only by an approved contract, with replay evidence returned to the existing Living Dictionary judge.

But the repository has not yet crossed from:

> a deterministic component as one approved claim

to:

> a composed deterministic system whose architecture, inter-component behavior, implementation, and runtime evidence form a checked refinement chain.

The gap is principally three things:

1. Make the durable-Wasm semantics genuinely crash-complete.
2. Introduce one typed system description from which all the component, TLA+, NetKAT, deployment, and evidence obligations derive.
3. Build a global deterministic composition kernel: schedule, messages, timers, effects, failures, checkpoints, and branching.

My strongest recommendation is to pause adding new substrates after the current spikes. Make Wasm the reference semantics, define the contract that other substrates must implement, and then add Unikraft, gVisor, and Firecracker as profiles of that contract. Otherwise, each substrate will quietly invent a different meaning of "deterministic."

## What is genuinely implemented now

### 1. The main Living Dictionary boundary remains sound

The BEAM path still preserves the project's strongest architectural property:

* the model emits artifacts and Forth;
* the Shen critic evaluates the proposal before mutation;
* accepted Forth is actually interpreted by the host;
* approved claims, rather than the model, judge completion;
* runtime claims are only available through the approved/hidden contract path.

That means the deterministic runtime has not been introduced as another model-selected tool call. It has been inserted behind the existing authority boundary, which is exactly the right location.

This is the most important part of the new work. The model cannot merely write a claim saying "run my special runtime and trust its answer." The contract selects a literal host-owned profile, and BEAM verifies the resulting receipt and evidence paths.

### 2. Durable Wasm is a real vertical slice

The Wasm component interface exposes only:

* virtual time;
* seeded random bytes;
* an explicitly mediated external-effect call;
* initialization, event handling, snapshot, restore, and state-hash exports.

There is no general WASI environment in that interface. That is the right application-native approach: nondeterminism is not intercepted after the fact; code simply is not given ambient clocks, entropy, filesystem, sockets, environment variables, or arbitrary syscalls in the first place.

The executor creates fresh Wasmtime stores and component instances for different execution routes, records evidence, hashes artifacts, and integrates through a literal wasm-durable-v1 profile in BEAM. That is more than a diagram or speculative design.

The architecture page describes the intended semantics more strongly (checkpoint recovery, branching, recorded effects, and replay without recontacting providers). That is the correct north star, although parts of that description are currently ahead of what the implementation actually establishes.

### 3. The Unikraft work is two useful experiments, not yet one backend

The project documentation is admirably explicit that Unikraft is primarily a confinement and packaging mechanism, not an automatic source of determinism. That is exactly right.

There are effectively two Unikraft tracks:

* A Lua architectural simulator with "organs," a small sequencing kernel, a tiny NetKAT-like language, Shen predicates, and a TLA+ model.
* A product gate that builds a simple C key-value command machine, boots it repeatedly under QEMU through a Unikraft base runtime, and compares its semantic transcript.

The product proof is useful: it demonstrates a deliberately narrow, state-machine-like C workload behaving consistently across fresh boots. But it currently cross-builds a static Linux PIE and loads it through the base runtime rather than building a native Unikraft application with a defined Living Dictionary component ABI.

So my classification would be:

> Wasm is an early runtime backend. Unikraft is currently a confinement proof and architecture laboratory.

That is a healthy state for a spike, as long as the distinction stays explicit.

## The important implementation gaps

### 1. A checkpoint does not yet capture the whole deterministic machine

This is the most important correctness seam I found.

The Wasm host state contains things such as:

* logical time;
* seeded RNG state;
* provider response cursors;
* recorded effects and replay cursors.

However, each execution route constructs a fresh host beginning with the original time and RNG seed. Restoring a checkpoint invokes the guest's restore export, but does not restore the host-side clock, RNG position, provider cursor, pending-effect state, or event-log position.

That means this sequence is not currently sound in general:

```
event 1 consumes random bytes
event 2 observes logical time
checkpoint
crash
restore checkpoint
event 3 consumes random bytes
```

After restoration, event 3 can observe the beginning of the random stream and a reset logical clock rather than the continuation.

The present fixtures do not reveal this. The key-value component does not use the host capabilities, and the current recovered suffix in the order scenario does not sufficiently exercise post-checkpoint clock/RNG/provider continuity.

A real checkpoint needs to contain something like:

```
GlobalCheckpoint {
  component_snapshots,
  logical_time,
  rng_state_or_counter,
  event_index,
  message_queues,
  timers,
  provider_cursors,
  pending_effect_intents,
  committed_effect_results,
  scheduler_state,
  branch_identity,
  system_manifest_hash
}
```

The operative word is global. Once multiple services exist, a collection of guest snapshots is not a system checkpoint unless the scheduler, messages, effects, and time are captured at the same logical boundary.

### 2. "Exactly once" is presently a replay simulation, not crash-safe effect durability

The design document specifies the right protocol:

```
persist intent
call provider
persist commit/result
resume or replay from committed result
```

It also calls for host-derived effect identities and actual crash recovery.

The implementation currently executes its routes and then assembles intent, commit, fault, and effect evidence from completed executions. It does not durably append an intent before a real provider call, kill the process at the relevant boundary, restart, inspect the journal, and complete or suppress the call. The provider itself is canned inside the host.

So the current demonstration establishes useful but narrower properties:

* replay can return a recorded effect result without invoking the replay provider;
* a scenario can produce a stable semantic transcript;
* effect records can be incorporated into a hash-linked receipt.

It does not yet establish exactly-once effects across process failure.

The necessary fault matrix should kill the runner at least at these positions:

```
before intent append
after intent append, before provider call
during provider call
after provider success, before commit append
after commit append, before guest receives result
after guest state transition, before checkpoint
```

For each point, the verifier should prove:

* at most one externally visible provider operation;
* the guest eventually receives the committed result;
* no replay performs a live provider call;
* the recovered evidence chain is valid;
* the final semantic state is identical where the failure model requires it.

Effect identity should also be host-derived from a stable logical location, for example:

```
(run, branch, component, event-sequence, effect-sequence)
```

The order guest currently supplies the idempotency key itself. That is useful application metadata, but it should not be the root of the harness's exactly-once guarantee.

### 3. The component under test still supplies too much of its own evidence

The guest exports both snapshot and state-hash. A well-behaved component can implement those correctly, but generated code can also return a constant state hash, omit part of its state from the snapshot, or make restoration non-invertible.

The host should independently:

1. hash the exact snapshot bytes;
2. restore those bytes into a fresh instance;
3. snapshot again and compare canonical bytes;
4. run the same suffix and compare outputs;
5. treat a guest-defined semantic state hash only as additional evidence.

Similarly, the BEAM verifier currently performs useful schema, path, component-hash, config-hash, and evidence-file-hash checks, but it does not independently reconstruct every semantic claim made by the executor. In effect, the runtime runner produces both the execution and much of the interpretation of that execution.

I would split this into two binaries or libraries:

```
ld-wasm-run       has execution/provider authority
ld-evidence-check has no execution/provider authority
```

The second should independently verify:

* the hash chain;
* sequence continuity;
* intent/commit state transitions;
* branch ancestry;
* checkpoint references;
* snapshot hashes;
* replay route equivalence;
* absence of forbidden live calls;
* profile and engine configuration;
* completeness of expected evidence files.

That mirrors Living Dictionary's larger principle: the entity doing the work should not be the sole judge of the work.

### 4. Wasm determinism needs to be a fully specified engine profile

The code correctly removes ambient imports and enables fuel, but I did not see the remaining Wasmtime determinism settings made explicit in the executor configuration.

Wasmtime's own guidance notes that fully deterministic execution also requires attention to:

* deterministic imports;
* NaN canonicalization;
* relaxed SIMD behavior;
* memory and table growth behavior.

Some of those deterministic options are not enabled by default.

The Living Dictionary profile should either enable deterministic behavior or prohibit the relevant features. Its receipt should bind:

```
Wasmtime version
engine configuration hash
target architecture
CPU feature policy
component-model version
compiler flags
component hash
WIT/world hash
profile schema version
```

Otherwise, wasm-durable-v1 means "this profile name was selected," not "this exact semantic machine was used."

This reinforces an important point: a runtime profile should be a behavioral contract, not a string identifying a launcher.

### 5. The Unikraft product gate is not reproducible enough to become a named guarantee

The current loader references unikraft.org/base:latest, which means the runtime image is not content-pinned. The QEMU path also exposes RDRAND and RDSEED, albeit with a fixed random seed, instead of denying entropy as an unavailable capability.

For a strict deterministic profile, I would require:

* image by digest, not latest;
* pinned compiler and linker;
* recorded ELF and runtime hashes;
* fixed CPU model;
* no RDRAND/RDSEED unless the harness owns and logs the deterministic stream;
* no RTC or ambient clock;
* fixed device topology;
* canonical serial transcript;
* an explicit component protocol rather than output scraping;
* a verifier independent of the boot runner.

The current C component itself is suitably narrow (single-threaded, in-memory, no network or clock), which is why the gate can demonstrate consistent command-machine semantics despite the broader environment.

I would name the present guarantee something like:

```
unikraft-confined-transducer-experimental
```

rather than treating it as equivalent to wasm-durable-v1.

### 6. The Lua Unikraft simulator is not conformant with the live Living Dictionary semantics

The simulator is useful as a fast architecture sketch, but two differences matter:

* the host validates Forth and then applies envelope artifacts directly rather than actually using the Forth program to drive those writes;
* the gate path can succeed without a meaningful expected-tree comparison in the normal sequence path.

That means it should not yet be treated as a second implementation of the same semantics.

This does not undermine the main BEAM host. The live BEAM implementation does execute the accepted Forth program.

The fix is not necessarily to make the Lua simulator production-quality. It may be better to label it explicitly as a model and give it a conformance suite against a canonical event/transition trace produced by the BEAM implementation.

### 7. The formal artifacts are adjacent, but not yet one proof chain

The current formal layer contains:

* a hand-written finite Shen model of component and message permissions;
* a small TLA+ episode model;
* a small NetKAT-like implementation with bounded iteration;
* a hand-written topology;
* a separate Lua reducer.

These are useful sketches, but there is no machine-checked relationship demonstrating:

```
TLA+ model
    refines high-level architecture
        and corresponds to
Lua/BEAM/Wasm transition semantics
```

The TLA+ specification is currently a very small episode-state model; it does not model multi-service queues, effect intent/commit, timers, crashes, retries, partitions, or a global scheduler.

The custom NetKAT subset is sufficient for the fixed example routes, but it is not equivalent to invoking a full NetKAT verifier for reachability, isolation, or program equivalence.

And the Shen critic is still principally a plan-language abstract interpreter: Forth stack behavior, effects, paths, artifacts, and typed words. Its source still identifies graph-validation parity work outside Shen; it does not yet express system-to-service-to-component refinement judgments.

This is the largest architectural gap, not because the formal tools are absent, but because they do not yet share a single semantic object.

## The missing centerpiece: ld-system/v1

You need one canonical, typed, content-addressed system description.

Not Forth. Not TLA+. Not an AWS task definition. Not a collection of adjacent files.

Something approximately like:

```yaml
schema: ld-system/v1
system: orders
components:
  api:
    contract: order-api/v1
    artifact: sha256:...
    substrate: wasm-durable-v1
    requires:
      clock: logical
      entropy: seeded-stream
      scheduling: host-event-loop
      network: typed-messages
      effects: durable-intent-commit
      snapshots: complete
      floating-point: canonical
  worker:
    contract: order-worker/v1
    artifact: sha256:...
    substrate: wasm-durable-v1
  payment:
    contract: payment-broker/v1
    artifact: sha256:...
    substrate: wasm-durable-v1
channels:
  order-commands:
    from: api.commands
    to: worker.commands
    delivery: at-least-once
    ordering: per-order
    capacity: 16
    faults: [drop, duplicate, delay, reorder]
effects:
  charge-card:
    owner: payment
    protocol: durable-intent-commit
    identity: host-derived
invariants:
  - no-double-charge
  - committed-order-has-reservation
  - terminal-orders-never-regress
  - only-payment-may-call-card-provider
failure-model:
  - crash-before-effect
  - crash-after-effect
  - crash-after-commit
  - message-duplicate
  - message-reorder
  - partition
  - heal
deployment:
  production-target: fargate
  deterministic-target: ld-sim
```

That artifact becomes the root of the refinement tree.

From it, the harness derives or checks:

```
component/WIT interfaces
serialization schemas
substrate requirements
TLA+ modules and refinement mappings
NetKAT topology and policy
Forth build/install/gate plans
runtime claims
fault-exploration choices
Fargate task/service definitions
security-group and IAM constraints
trace decoders
receipt obligations
```

Every generated artifact should contain the system-manifest hash, compiler version, and source obligation IDs. Any hand edit breaks provenance unless it is re-elaborated and re-approved.

## Where Shen fits

I agree with you that Shen is unusually well suited, but I would use that suitability in a disciplined way.

Shen should become the elaborator and refinement-judgment engine, not a replacement for every specialized formal tool.

The core judgments could look conceptually like:

```
Γ ⊢ component C : Contract T
Γ ⊢ substrate S satisfies requirements(C)
Γ ⊢ channel A → B : DeliverySemantics D
Γ ⊢ implementation I refines component contract C
Γ ⊢ subsystem L refines architecture H
Γ ⊢ obligation O discharged-by receipt R
```

Its type system and sequent-calculus orientation are useful for expressing the premises under which those judgments are valid. Embedded Prolog is useful for resolving relations such as compatible profiles, available refinement paths, or which proof obligations follow from an architecture.

But for architecture-level use, Shen should return more than `Accept | Reject`. It should return a canonical derivation or proof-obligation graph:

```
Accepted {
  derivation_hash,
  assumptions,
  obligations,
  generated_artifacts,
  external_oracles_required,
  unresolved_obligations
}
```

That derivation belongs in the Living Dictionary ledger.

There is one caution: Prolog-style search can itself produce different derivation orders or become unbounded. For this role, proof search needs explicit bounds, canonical rule ordering, and canonicalized output. The logical result may be equivalent while the evidence bytes differ; the project should decide whether it wants semantic equivalence or bit-identical derivations.

## Do not make TLA+ and NetKAT compete

They serve different parts of the system.

**TLA+** for: component and system state transitions; queues and delivery guarantees; retries; crashes and recovery; effect intent/commit; ordering; safety and liveness; refinement between high-level and lower-level protocols.

**NetKAT** for: reachability; isolation; permitted paths; required waypoints; equivalence between intended and generated network policy; perhaps resilience properties in suitable extensions.

NetKAT should answer questions such as: Can frontend traffic ever reach the payment provider directly? Must worker-to-database traffic pass through the intended policy point? Does the generated AWS network policy implement the declared topology?

It should not be forced to model: Did an order worker charge twice after an at-least-once delivery? That is a TLA+ and runtime-transition question.

**Shen connects them.** Shen's role is to enforce rules such as:

```
A channel may exist only if:
  its endpoints' types compose,
  its TLA+ delivery semantics are defined,
  its NetKAT path is permitted,
  its substrate profiles implement the required capabilities,
  and its generated deployment has corresponding evidence.
```

That is where your nested specification concept becomes genuinely distinctive.

## The deterministic composition kernel

A multi-component system needs one owner of logical reality.

Each component should behave approximately like a deterministic transducer:

```
step(
  component_state,
  input_event,
  deterministic_capabilities
)
→ {
    new_state,
    emitted_messages,
    requested_effects,
    timers,
    assertions
  }
```

The composition kernel, not the language runtime, owns: logical time; event ordering; message queues; message identifiers; timers; seeded choices; fault decisions; effect identities; intent/commit state; checkpoint boundaries; branch ancestry; global state hashes.

BEAM can remain the outer supervisor, process manager, evidence writer, and orchestration control plane. But the semantic ordering of the tested system should not depend on incidental BEAM process scheduling or mailbox arrival order. The deterministic schedule must be explicit data.

Initially, I would not simulate TCP. Start with typed application messages. The state space is far smaller, and the resulting trace corresponds directly to the architecture.

For example:

```
Deliver(order.created, api → worker)
Duplicate(order.created)
Crash(worker)
Restart(worker, checkpoint 17)
Deliver(order.created, api → worker)
RequestEffect(charge, key E-55)
CommitEffect(E-55, approved)
Crash(worker)
Restore(global checkpoint 18)
ReplayEffect(E-55, approved)
```

Later, gVisor or Firecracker profiles can provide more realistic socket/container execution, but they should adapt those sockets into the same logical channel model wherever possible.

## Determinism should be a capability vector, not a Boolean

The existing literal profile registry is a good deny-by-default beginning, but the next version should match component requirements against substrate guarantees. At present BEAM knows a single literal runtime profile rather than a general substrate capability model.

A profile should declare dimensions such as:

```
isolation: wasm-component
clock: logical
entropy: seeded-replayable
scheduler: host-serialized
filesystem: none
network: mediated-messages
external-effects: durable-intent-commit
snapshot: whole-component
global-checkpoint: supported
floating-point: canonical
memory-growth: deterministic
replay: cross-process
branching: supported
fault-controls: [crash, drop, duplicate, reorder]
build-reproducibility: pinned
```

That produces a set or lattice of guarantees, not a score.

* `wasm-durable-v1`: potentially strongest for newly generated components that can obey the WIT capability ABI.
* `unikraft-confined-v1`: potentially excellent isolation, startup, small surface, and native C execution. Determinism still depends on the guest ABI, scheduler, devices, clocks, entropy, and I/O mediation.
* `gvisor-mediated-v1`: useful for TypeScript, Python, PHP, Java, or conventional Linux workloads. It can strongly constrain and mediate syscalls, but should not claim deterministic scheduling merely because the system is sandboxed.
* `firecracker-snapshot-v1`: excellent process/VM isolation and reset/snapshot properties. Again, snapshotting and isolation are not equivalent to deterministic execution. A deterministic guest runtime can run inside it.
* `legacy-recorded-v1`: opaque container whose boundary I/O can be recorded and replayed, but whose internal state and scheduling are not claimed deterministic.

Shen can then reject:

```
component requires global-checkpoint
substrate supplies component-only snapshot
```

or:

```
component requires no ambient entropy
substrate exposes unrestricted getrandom()
```

That is much more scalable than hard-coding language-to-runtime choices.

## A practical roadmap

### Phase 1: Make durable Wasm the reference semantics

Before composition, close the single-component correctness loop.

Implement: complete host-plus-guest checkpoints; online write-ahead intent/commit logging; real process-kill injection; host-derived effect IDs; host-owned snapshot hashes; independent evidence verification; explicit Wasmtime determinism configuration; pinned build/runtime artifacts; engine and toolchain attestation; a successful BEAM-approved runtime-claim test; inclusion of the durable-Wasm gate in the normal CI/default gate path.

At present, the Wasm and stronger Unikraft product targets are separate from much of the normal default test path, so regressions in the new runtime work are not yet positioned as core release blockers.

Exit condition: every meaningful crash boundary in the order scenario can be injected, restarted in a new process, independently verified, and replayed without duplicate provider effects.

### Phase 2: Introduce ld-system/v1 and substrate-capability judgments

Add the typed system manifest and a substrate behavior interface.

The BEAM side should have something conceptually like:

```elixir
@callback capabilities(profile_config) :: capability_set()
@callback build(component, config) :: receipt()
@callback start(component, checkpoint, config) :: instance()
@callback deliver(instance, event) :: transition()
@callback snapshot(instance) :: snapshot()
@callback terminate(instance) :: receipt()
```

The exact API can differ, but the layers above it should not know whether they are invoking Wasmtime, QEMU, gVisor, or Firecracker.

Shen should check: component contract compatibility; channel type compatibility; required versus supplied runtime capabilities; architecture-level effects; allowable deployment mapping; which formal obligations must be discharged.

Exit condition: the same system manifest can correctly accept one substrate assignment and reject an incompatible one, with a deterministic derivation and content-addressed obligations.

### Phase 3: Build the global composition kernel

Begin with three Wasm components, not a mixed-runtime system.

Implement: one deterministic event queue; typed message channels; logical timers; explicit delivery choices; effect broker; complete global checkpoint; branchable choice log; parent/suffix evidence chains; global state hash; crash and restart transitions.

The current envelope graph machinery already has useful concepts: declared writes, dependencies, conflict rejection, and Kahn-style waves. Generalize that idea for runtime transitions:

```
event footprint:
  reads
  writes
  emits
  effects
  timers
```

If Shen can establish that two transitions are independent, the scheduler can: execute them concurrently but commit them canonically; avoid exploring both equivalent orderings; use the information later for partial-order reduction.

That is a very promising bridge between the present coding-agent graph and the future system simulator.

Exit condition: a three-component order system has exact replay, global restore, deterministic branching, and identical terminal state/evidence for identical choice traces.

### Phase 4: Connect the actual formal tools

Generate formal artifacts from the system IR, but keep user-approved properties independent.

For TLA+: generate lower-level transition modules; retain separately approved high-level invariants; define explicit refinement mappings; run TLC or Apalache; store tool version, bounds, configuration, result, and counterexample as evidence.

For NetKAT: generate topology and policy; invoke an actual verifier such as KATch rather than relying solely on the tiny embedded subset; check reachability, isolation, and equivalence against generated deployment policy.

For runtime conformance: project the deterministic event ledger into TLA+ states; validate concrete traces against the specification; turn TLA+ counterexamples into executable scheduler choices where possible.

TLA+ trace validation is useful for keeping implementation behavior synchronized with a specification, but it is not exhaustive by itself. It validates the observed traces, not every possible implementation execution.

So the evidence hierarchy should be explicit:

```
type/interface check
model-check result
refinement result
network-policy result
runtime trace validation
systematic exploration result
```

Do not merge all of those into a generic `proved: true`.

Exit condition: deliberately mutating retry, delivery, routing, or effect logic causes the corresponding TLA+, NetKAT, Shen, or trace-validation obligation to fail automatically.

### Phase 5: Add systematic schedule and fault exploration

This is the part required to obtain the broader benefit associated with Antithesis.

Deterministic replay gives you: "I can reproduce this execution." Systematic exploration gives you: "I can search executions that ordinary tests did not happen to produce."

Your kernel needs explicit branch points for: message choice; drop, delay, duplicate, and reorder; timer ordering; component crash; restart checkpoint; partition and heal; provider result; resource exhaustion; retry timing.

Start with seeded randomized search and bounded depth. Then add: state-hash deduplication; coverage guidance; trace shrinking; independence/commutativity information; partial-order reduction; invariant-directed search.

Exit condition: the system discovers a deliberately hidden distributed bug, emits a minimal choice trace, and reproduces it exactly in a separate run.

### Phase 6: Add heterogeneous runtimes and the production twin

Only after the semantics above are stable should you add broader language support.

The right target is not necessarily "The actual Fargate deployment is deterministic." It is "The same approved architecture and component contracts compile into both a deterministic system twin and a production Fargate deployment."

```
business core
 ├── deterministic adapter → Wasm/LD system
 └── production adapter    → HTTP/SQS/RDS/Fargate
```

Rust and suitable Go components may target Wasm directly. TypeScript, Python, PHP, or JVM services may initially run behind gVisor or Firecracker with generated SDKs that mediate time, entropy, messages, filesystem, and external effects. Their profile can truthfully advertise a weaker guarantee than the strict Wasm profile.

Production traces can then be normalized into the deterministic event schema and replayed in the twin.

Exit condition: one production-shaped multi-service topology is generated from the same system IR, its deployment network is checked against the NetKAT policy, and a captured production interaction can be replayed against the deterministic model.

## The flagship system I would build

Do not make another key-value store the north-star demo. Keep KV as a smoke test.

Use the existing order component as the seed for a five-part system:

```
API
  ↓ order-created
Order worker
  ├── Inventory
  ├── Payment broker → external card provider
  └── Notification
```

Give it: at-least-once command delivery; per-order ordering but no global ordering; worker crashes; duplicated commands; payment timeouts; crash after provider success but before local commit; inventory reservation expiry; notification as a non-transactional effect; a forbidden direct path from API to card provider.

The approved invariants could include:

* A payment authorization is externally performed at most once.
* A committed order has both a durable reservation and a committed payment.
* A terminal order never returns to a nonterminal state.
* Inventory never falls below zero.
* Only the payment broker can reach the card provider.
* Under eventual delivery and eventual provider availability, every accepted order eventually becomes committed or rejected.

That one example exercises every layer: Shen (contracts, runtime requirements, architecture composition, obligation graph); TLA+ (retries, ordering, failure, safety, and liveness); NetKAT (reachability, isolation, and required paths); Wasm (deterministic components and effects); Forth (authorized build/install/run procedure); BEAM (supervision, claims, evidence, and exploration orchestration); Unikraft (later replacement of one low-level component); gVisor or Firecracker (later replacement of one component with a conventional language runtime); Fargate generation (eventual production twin).

That would demonstrate an actual systems-engineering thesis, not simply another runtime benchmark.

## How this compares with Antithesis

Your intuition is right, with one important qualification.

Antithesis pays for a low-level deterministic environment partly so it can run substantially conventional software and explore it without requiring every application to be designed around a bespoke deterministic API. Its custom hypervisor is the foundation for rewind, alternate execution, fault injection, and reproduction.

Living Dictionary can make a different trade:

```
Antithesis:
  virtualize underneath largely existing software
Living Dictionary:
  generate software against explicit deterministic capabilities
```

For greenfield or agent-generated systems, the Living Dictionary approach may be more semantically powerful: "charge card" is visible as a typed effect, not merely a network packet; logical time is an architectural concept, not a virtualized timer register; message delivery is a declared contract, not inferred from socket behavior; checkpoints can correspond to business state; proof obligations can refer to architecture concepts; the agent can be prevented from generating ambient nondeterminism in the first place.

But the tax does not disappear. It moves:

```
deterministic hypervisor tax
          ↓
deterministic ABI + adapter + specification discipline
```

That is likely a favorable trade for Living Dictionary because you control code generation. You can force newly generated components to use the right boundaries from their first line of code.

The accurate eventual claim would be:

> Living Dictionary provides application-native deterministic simulation for systems generated against a checked capability and refinement ABI.

That is narrower than universal deterministic virtualization, and potentially much more interesting.

## My prioritized recommendation

The next work should be, in order:

1. Complete the Wasm durability semantics: whole-machine checkpoint, real intent/commit journal, kill injection, independent verifier.
2. Define ld-system/v1: components, ports, channels, effects, failure model, invariants, deployment, and runtime requirements.
3. Replace literal runtime identity with capability matching.
4. Build one global deterministic event scheduler and checkpoint format.
5. Create the three-component order-system proof before adding another substrate.
6. Connect real TLA+ and NetKAT tools through Shen-generated obligations and runtime trace validation.
7. Then add Unikraft, gVisor, and Firecracker as differently capable implementations of the same contract.

The project's biggest risk is no longer "these languages are too strange." Shen, Forth, and Elixir are defensible choices for their roles.

The biggest risk is accumulating several elegant artifacts that describe roughly the same system without any one of them being mechanically responsible for the correspondence between the others.

The north star should therefore be:

> Living Dictionary compiles an approved architecture into a deterministic executable system, checks each refinement into components and deployment, explores its failure behaviors, and preserves one evidence chain from intent through runtime state.

That would make it substantially more than an agent harness, and meaningfully different from both conventional formal-methods tooling and deterministic hypervisor testing.
