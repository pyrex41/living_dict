# STORE: a datom-shaped store and a Linda-shaped space

Two substrate moves, layered under the existing kernel. Neither changes a
model-facing surface, a wire contract, or the frozen eval 1.0 ABI.

The kernel already lives by these rules and does not know it:
`events.jsonl` is an append-only tx log with monotonic sequences and state
as a projection (`kernel.py`); receipts hash every file; `WRITE-FILE`
defines idempotency as identical bytes; the fingerprint guard is
identity-by-structure; td persists scud streams behind a CAS tail with
attempt/execution fencing (`docs/SCUD.md`). This document names that
discipline and gives it one home.

## Layer A — content-addressable store (datoms)

### Objects

```
run_dir/objects/<aa>/<sha256>     blob: raw bytes (artifact body, file
                                  content, dictionary word source)
tree object                       canonical JSON {path: sha256, ...},
                                  itself stored as a blob
```

- Blobs are immutable and deduplicated by construction. Interning the same
  artifact twice is a no-op; `WRITE-FILE`'s identical-bytes rule becomes
  structural (same hash = same object).
- A workspace snapshot is a tree object. "The workspace is the snapshot"
  becomes literal: receipts and `gates.measured` events reference
  `tree_before` / `tree_after` hashes instead of recomputing diffs.
- `LIVINGDICT_OBJECTS` may point several runs at one shared store
  (default stays per-run). Append-only; no GC.

### Tx log and datom view

`events.jsonl` stays the one transaction log. The datom view is derived,
never written directly: `facts(events)` yields `[e a v tx]` rows where
`tx` is the event sequence. Real kinds map as:

```
["episode/3"      :episode/fingerprint  "db4a76…"        7 ]
["episode/3"      :critic/verdict       :reject           8 ]
["episode/3"      :critic/error         "token 1: …"      8 ]
["ws/fizzbuzz.py" :file/content         blob:9388ec…     12 ]
["run"            :gates/passed         true             14 ]
["word/INSTALL"   :word/content         blob:ab12…       15 ]
["word/INSTALL"   :word/promoted-by     "episode/3"      15 ]
```

`as_of(seq)` reconstructs the workspace tree and job state at any episode
without copying trees — what crash/resume (eval sequence 5) and the
warm/cold matrix want. Dictionary provenance (which episode promoted a
word, what evidence, where reused, sequence-8 negative transfer) becomes
facts to query instead of trace archaeology — hypothesis 5's bookkeeping.

### What Layer A must NOT change

- The model-facing envelope keeps **full artifact bodies**. The model
  emits bytes; interning is the host's job on receipt.
- The eval 1.0 adapter contract (request / trace / `receipt.json` /
  checkpoint) stays byte-compatible. The store augments `run_dir`; it
  does not touch the adapter protocol.
- The product tree is usually a git repo. Do not rebuild git: trees here
  snapshot run state; git remains the product's history.
- Old runs replay without a store; events remain self-describing.

## Layer B — tuple space (Linda)

### Verbs

```
out(tuple)                 put
rd(pattern)                read a match, non-destructive
take(pattern, lease_s)     atomically remove a match; blocks if absent;
                           an expired lease returns the tuple
```

Patterns are dict-subset matches. (Shen is a pattern-matching language;
typed tuple patterns are a natural later extension of the critic —
`validate` with a second input shape. Not built yet.)

### Tuple shapes

```
{kind: "node.ready",    run: R, episode: N, wave: 2, node: "registry"}
{kind: "gate.result",   run: R, wave: 2, passed: false}
{kind: "critic.reject", run: R, episode: N, errors: [...]}
{kind: "obligation",    goal: G, id: "ob-7", grant: …}      # Layer C only
```

### Where it sits

- **Wave dispatch.** Inside a wave, the host `out`s ready nodes and
  workers `take` them. Atomic removal makes double execution
  unrepresentable, the same way disjoint write sets make conflicts
  unrepresentable. Wave barriers and wave-boundary `RUN-GATES` stay.
- **Backpressure.** Rejects, traps, and failed gates are tuples the next
  planner observation consumes. Same behavior as today, one mechanism.
- **Leases.** `take` carries a lease; a worker that dies returns its
  tuple to the space. This is td's attempt/execution fencing in local
  form, and the two must stay one concept at the scud seam.

### The determinism rule

`take` is inherently racy. The ledger is not. Every `out` / `take` /
lease expiry is recorded (`space.out`, `space.take`,
`space.lease_expired`) with the worker id. Runtime scheduling may race;
replay replays the **recorded** schedule; trace flush order stays
deterministic (buffered per node, flushed in wave/id order). Determinism
lives in the ledger, liveness lives in the space — the same trade the
wave trace merge already made.

### The guardrail

The critic's authority comes from **declared** topology checked
statically before any I/O. Nodes keep declaring `writes` and
`depends_on`; the critic keeps rejecting overlaps and cycles
pre-execution. The space is only the runtime realization of edges the
critic already approved. **Linda is the executor, never the planner.**
Emergent dataflow scheduling must not replace declarations.

## Layer C — cross-process (deferred)

Multiple runners sharing a space (`ngx.shared.DICT` on the resty body,
or td as the space), scud obligations as tuples, Shen patterns as the
tuple type system. Stays shut until all of:

1. Layers A and B ship with byte-identical external behavior,
2. a live three-way compare win is on record,
3. the warm-dictionary economics run (hypothesis 5) has numbers.

## What stays out

Query language over datoms (iteration + `as_of` is enough), garbage
collection, a store daemon, model-facing `TAKE` / `OUT` words (the
six-word ABI is frozen), replacing git, cross-process anything before
the Layer C gates open.

## Staging and exit tests

| stage | ships | exit test |
|---|---|---|
| A | `store.py` (blobs, trees, intern, `as_of`), events/receipts reference hashes, dictionary provenance facts | full suite green; fizzbuzz + graph-01 e2e byte-identical external behavior; `as_of(seq)` tree equals the recorded snapshot at every episode; interning idempotent |
| B | `space.py` (out/rd/take + leases), wave dispatch and backpressure routed through it, scheduling recorded | serial vs space-dispatched trees byte-identical; N contending workers, exactly one take per tuple; injected worker death → lease expiry → sibling completes it; scudcheck and ldeval contracts unchanged |
