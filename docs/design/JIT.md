# JIT harness evolution, with a critic underneath

Notes on [arXiv:2608.25593](https://arxiv.org/abs/2608.25593), *JIT-Agent:
Scaling Harness Intelligence via Just-in-Time Harness Evolution* (LV-NUS,
26 Aug 2026), and what it implies for this repo. Brainstorm, not a spec.

## What the paper claims

The harness — memory management, planning strategy, action protocol, tool
and skill orchestration — often dominates the model's contribution, and
harness design is manual, task-specific, and unscalable. So: make the
harness a **composable, machine-generatable artifact** under a fixed
four-module protocol (memory / planning / action / capability), and train a
model, JIT-Agent, to emit one per task. It does three things:

1. **customize** a harness for the task at hand,
2. **repair** a harness that executes unstably,
3. **self-evolve** by distilling performance signals from a growing archive
   of prior harness configurations.

Reported: DeepSeek-V4-Flash + JIT-Agent beats GPT-5.6 on DeepSearchQA
(+9.1) and OdysseyBench (+4.3); generated harnesses are competitive with
mature runtimes like OpenCode and Claude Code. The framing — harness
intelligence as a trainable, transferable, compounding axis orthogonal to
model scale — is the interesting part.

## Why this repo is already most of the substrate

Living Dictionary was built on the same premise from the other end. The
mapping is close enough to be uncomfortable:

| JIT-Agent module | organ here |
|---|---|
| memory | warm dictionary (`dictionary_dir/words/*.fs`) + event ledger + CAS store |
| planning | plan envelope: nodes, `depends_on`, Kahn waves (`docs/design/GRAPH.md`) |
| action | the frozen six-word ABI + Forth control program |
| capability | `host.py` capability view, effect ceiling, glob policy |
| repair | critic Reject → errors feed the next attempt; fingerprint block on resubmit |
| archive | `events.jsonl`, content-addressed snapshots, `as_of(seq)` |
| distillation | `promotion.py` evidence gates (written, not yet wired) |

Two differences matter, and they run in opposite directions.

**Against us:** JIT-Agent *trains* the harness generator. We prompt one.
Their compounding loop has gradients in it; ours has a directory of `.fs`
files. That is a real gap and no amount of architecture closes it.

**For us:** their generated harness is Python and config. Nothing checks it
before it runs. "Repair for stable and reliable execution" is a polite name
for *crash, observe, regenerate* — the failure has already happened, and
the artifact that caused it is unverifiable in principle. A synthesized
harness is exactly the object you least want to be unverifiable, because it
persists and it is reused.

That is the whole opening. **They evolve the harness and verify the
outcome. We can evolve the harness and verify the harness.**

## The blocker, and it is in-tree

Self-modifying Forth is the right substrate for this: a harness *is* a
dictionary of colon words, and "just-in-time harness synthesis" is
literally what `: NAME ... ;` does. We already persist accepted colon words
and reload them next turn. So JIT harness evolution is roughly two hundred
lines away.

Except for this, at the top of `shen/critic/validate.shen`:

```
\\ Colon bodies are not checked (Contract 0,0).
```

And the code that means it:

```shen
(define bind-word
  Name Words -> [[Name 0 0 []] | Words])
```

`skip-colon` walks past the body. `preflight.py::_skip_colon` does the
same. So every colon word is typed `( -- )` with the empty effect set, and
its body is never walked — no stack check, no `special-checks` on the
`WRITE-FILE` path literal, no contribution to the effect set that `finish`
compares against `allowed_effects`.

The floor still holds: `host.py::_require_effect` raises `CapabilityError`
at call time, so a colon word cannot actually escape its capability grant.
But that is a **trap during execution**, not a **reject before I/O** — and
the README's first promise is the second thing. Wrapping a plan body in a
colon definition converts cheap static backpressure into a mid-wave trap
with earlier nodes already committed.

Today that is a small hole, because the dictionary holds a handful of
skills. The moment the dictionary holds *the harness*, the entire JIT layer
lives inside the critic's one blind spot. Type the dictionary first.

## Design 1 — infer the contract, then pin it

Colon words should be typed the same way host words are. The typing table
is already there and already the right shape:

```shen
(define contract-inputs  "WRITE-FILE" -> 2 ...)
(define contract-outputs "WRITE-FILE" -> 1 ...)
(define contract-effect  "WRITE-FILE" -> ["write"] ...)
```

`[In Out Effects]` is a triple the walker already threads. Replace
`skip-colon` with `walk-colon`: run the same walk over the body against the
words bound so far, and bind the definition to its *inferred* triple
instead of `[0 0 []]`.

- **In / Out** — net depth of the body, with a hard requirement that
  `IF/ELSE/THEN` branches be depth-balanced (otherwise inference is not a
  function and we would be guessing). Unbalanced branch, reject, no
  exceptions. This is a restriction on generated harnesses and it is a
  cheap one.
- **Effects** — union of the body's effects. Now a colon word that writes
  carries `write`, `finish` sees it, and a read-only contract rejects
  statically instead of trapping at wave 3.
- **Path literals** — `literal-before` / `special-checks` already handle
  `S" path" WRITE-FILE`. Inside a colon body the literal is often not
  present (it came off the stack), so glob checking degrades to the host.
  That is the honest boundary: **static where the path is literal, dynamic
  where it is computed**, and the receipt should say which held.

Then persist it. A word in `dictionary_dir/words/` gets a sidecar
contract — inferred at admission, stored with the word's `sha256`, and
**re-derived on load and compared**. A mismatch is a reject, not a
recompute. That single rule is what makes a warm dictionary safe to grow:
you cannot smuggle a capability into a word by redefining it later, because
the contract is part of the word's identity.

Nice side effect: `used_names()` plus contracts gives the *declared type of
a run's harness* — a sentence like `( goal -- report ) [read write exec]`
that a human can sign off on before anything executes. That is a contract
negotiation over the harness, not just over the claims.

## Design 2 — evolve composition, freeze capability

JIT-Agent's fourth module is capability: the generator picks and wires
tools. `AGENTS.md` forbids exactly that — the six-word ABI is frozen, no
new Forth words.

Keep the freeze. It looks like a limitation and it is the safety argument:

> **Capabilities are fixed and audited. Only their composition evolves.**

Every synthesized harness word is, by construction, a composition of seven
capabilities whose effects are known. The reachable effect set of any
generated harness — however deep the definitions nest — is a subset of the
grant. You cannot say that about generated Python. It is not a proof of
correctness; it is a proof of confinement, and confinement is the property
you actually need before you let a model write your control plane and keep
it.

This also splits the dictionary into two populations that should not be
managed alike:

| | skill words | harness words |
|---|---|---|
| what | task-domain moves (`SCAFFOLD-FASTAPI`) | control-plane shape (`PLAN-THEN-VERIFY`, `FANOUT-REPAIR`) |
| scope | narrow, transfers badly | broad, transfers or poisons everything |
| eval risk | false friends (sequence-8) | silent global regression |
| promotion | per-family evidence | must beat cold on a held-out family |

The eval design already worries about warm-dictionary negative transfer.
Harness words are where that risk actually bites, and they need the
stricter gate.

## Design 3 — a proof-carrying archive

JIT-Agent's archive stores configurations plus performance signals, and
distills. Fitness only. A harness that scored well because the verifier was
weak is indistinguishable from one that scored well because it worked —
which is precisely the failure `examples/shen-todo` caught the model doing
by hand.

Our archive can carry more, because the ledger already does:

```
archive entry := { word, sha256, inferred_contract,
                   critic_verdict, claims_discharged,
                   contract_provenance,     \\ approved | model-authored
                   effects_used, policy_violations,
                   seq, replay_ok }
```

`promotion.py::PromotionEvidence` is this record minus the contract and the
provenance flag, and `eligible` is already the conjunction we want. Adding
`inferred_contract` and `contract_provenance` gives you a rule the paper's
archive cannot state:

> A harness word is promotable only if it was admitted by the critic, its
> inferred contract is stable across every episode that used it, and every
> episode that used it discharged claims from an **approved** contract.

Evidence, not score. Cheap to check, and it is the difference between a
compounding archive and a compounding delusion.

## What "provable" honestly means here

Shen's sequent calculus and `datatype` rules are strong, but let us not
oversell them in a doc we will reread:

- We are **not** proving harnesses correct. No dependent types, no
  semantics for `RUN-GATES`, and the interesting properties are about the
  workspace, not the program.
- We **are** deciding judgments: stack effect, effect confinement, path
  admissibility, acyclicity, artifact coverage. Decidable, total, fast, and
  currently written as ordinary Shen functions returning `accept` / `reject`.
- The upgrade worth making is to state the four-module protocol as a Shen
  `datatype` — inference rules for a well-formed harness — so a generated
  harness must typecheck against the protocol rather than merely match a
  JSON schema. That turns the paper's "fixed four-module protocol" from a
  convention into a judgment. Shen's `datatype` is the right tool and this
  is the one place the theorem-prover heritage earns its keep.
- Everything else Shen buys us is boring and valuable: one critic, shaken
  to Lua and JS, identical verdicts across three bodies.

## Experiment

The comparison is already designed; this is a fourth arm.

| arm | dictionary |
|---|---|
| cold | empty |
| warm | skill words only |
| **jit** | episode 0 synthesizes harness words, later episodes load them |
| oracle | hand-written harness words |

Measure with the thresholds already preregistered in
`eval/docs/EVALUATION.md` and encoded in `promotion.warm_run_allowed`:
≥25% cost reduction, ≤5 points correctness loss, no policy-violation
increase, no negative transfer on sequence-8 false friends.

Two questions the paper does not separate, and we can:

1. Does harness evolution help, or is it the archive's *task* memory doing
   the work? (jit vs warm isolates it.)
2. Is a synthesized harness word ever better than a hand-written one? If
   `oracle` dominates `jit` everywhere, harness intelligence here is a
   distillation target, not a runtime feature — and that is a fine outcome
   to learn cheaply.

The failure mode to watch: the loop synthesizes a harness that games the
gate rather than the task. The approved-contract split and
`contract_provenance` in the archive are what make that visible instead of
just profitable.

## Risks

- **Inference cost in the critic.** `walk-colon` makes validation
  proportional to the dictionary, not the program. Prelude words are
  re-walked every turn today too; cache the inferred contract by `sha256`.
- **Recursion.** Colon words calling themselves, or mutual recursion across
  prelude files, breaks the inductive walk and termination. Simplest rule:
  a word may only reference words bound *before* it (definition order is
  the well-founded order). Rejects a class of legal Forth; keeps inference
  total.
- **The blind spot moves, it does not close.** Computed paths still land on
  the host. Say so in the receipt.
- **Dictionary rot.** Harness words that transfer badly are worse than no
  dictionary. Needs eviction, not only promotion — an entry whose evidence
  goes stale should fall out.
- **We still have no gradients.** Prompted synthesis is not a trained
  harness model. If the compounding is real, the honest end state is that
  the archive becomes training data.

## Smallest useful next step

Not the harness generator. Do this first, in order, and each step is
independently worth having:

1. `walk-colon` in `shen/critic/validate.shen` + mirror in
   `preflight.py`; balanced-branch and definition-order rules; tests that a
   colon-wrapped `WRITE-FILE` now rejects under a read-only contract
   instead of trapping.
2. Inferred contract sidecars in `dictionary_dir/words/`, re-derived and
   compared on load.
3. Wire `promotion.py` into the loop, with `inferred_contract` and
   `contract_provenance` in the evidence record.

Only then is there anything safe to JIT.
