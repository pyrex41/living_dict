# The BEAM body

The live Living Dictionary host: the whole machine — Forth VM, typed
Shen critic, capability host, gates, ledgers, tuple space, obligation
agents, benchmark harnesses — in one Elixir/OTP application. No Python,
no external runtimes on the hot path. The Python tree (`../harness/`) is
the frozen semantic reference this was ported against.

The trinity, each in its right place:

- **Forth** — the untyped, concatenative plan language the model emits.
  Cheap tokens, composition by juxtaposition, one envelope per episode.
- **Typed Shen** — the rigid specification. One critic source
  (`../shen/critic/validate.shen`, fully typed, machine-checked by
  `yggdrasil check` at build time, types erased in the shake) compiled
  by shen-erl to BEAM bytecode and loaded into this VM.
- **OTP/Jido** — the actor substrate. Supervision, monitors, timers,
  and preemption are what leases, fencing, and crash-isolation are made
  of; none of it is hand-rolled.

## The loop (`run.ex`)

```
goal + observation ──▶ planner (grok-4.6; the ONLY model-facing module)
        │ envelope {program, artifacts, rationale}   fingerprinted; identical
        ▼                                            resubmission is blocked
   critic.validate(program, catalog)  ──reject──▶ next episode's feedback
        │ (prelude is bound, never concatenated)
        │ accept (native BEAM call, ~54-157µs)
        ▼
   Forth VM executes host words     ← model switched off; policy-fenced
        │                             workspace writes; effects gated
        ▼
   gates: contract check commands   ← exit 0 = pass; judge provenance
        │                             labeled (approved vs model-authored)
        ▼
   typed promotion                  ← contract required + claims
                                      discharged, else quarantined
```

Every episode lands in a per-run `events.jsonl` (closed kind set,
monotonic sequence, single writer) + `trace.jsonl`.

The critic validates `envelope.program` against the bound catalog. Colon
bodies are checked at promotion (`validate/6` of `: NAME (c) body ;`).
Load requires a parseable `--` contract and does not walk bodies.

## Modules

| Module | Role |
|---|---|
| `forth.ex` | VM port of the reference: same tokens, trap codes, messages |
| `critic.ex` | engine ladder: shen-erl BEAM bytecode → luerl probe → node/JS |
| `host.ex` / `policy.ex` | capability words, fnmatch-parity globs, workspace confinement |
| `gates.ex` / `cmd.ex` | executable contract claims, bounded shell execution |
| `ledger.ex` | kernel event log + trace, single-writer by construction |
| `run.ex` | the kernel loop; duplicate blocking; planner retry w/ backoff |
| `dictionary.ex` / `contracts.ex` | warm dictionary, in-band contracts, topo-ordered prelude |
| `space.ex` | Linda tuple space: generation-fenced leases (OTP timers), specificity-ordered handoff, obligation kind accepted |
| `obligation.ex` / `dispatcher.ex` | Jido agents per obligation, lease heartbeats, deny-by-default gate |
| `verdict.ex` | preregistered warm-dictionary go/no-go thresholds |
| `demo.ex` / `bench/polyglot.ex` / `bench/grok_arm.ex` | arms races: vendored eval + Aider Polyglot, grok CLI baseline |
| `cli.ex` | release entry (`bin/ld_host eval "LdHost.CLI.main_from_env()"`) |

## Commands

```bash
mix test                                   # 50+ tests (e2e excluded by default)
mix test --only e2e                        # oracle/reference-solution proofs
mix ld.run --goal "..." --cwd PATH [--contract claims.json]
mix ld.demo --tasks graph-01,... [--arms grok,cold,warm]
mix ld.polyglot --langs rust,go,cpp [--arms cold,warm,grok] [--grok-sample N]
```

## Benchmarks

Adapters and results:

- **Aider Polyglot** — `bench/polyglot.ex` loads exercises straight from
  a sibling `polyglot-benchmark` clone; hidden judge = the full test
  suite (rust with `--include-ignored`); warm dictionary per language
  track.
- **Terminal-Bench via Harbor** — `../bench/harbor_ld_beam.py` (the one
  Python shim harbor requires) installs a self-contained linux release
  (`make beam-release`, both arches; amd64 is cross-assembled: compiled
  natively, ERTS+libs from a digest-pinned amd64 stage) and always exits
  0 so Harbor's hidden verifier judges.

Numbers live in [RESULTS.md](RESULTS.md). Headline: same model,
identical-or-better correctness, **~7.6–19× fewer input tokens** than
the ReAct baseline; first Terminal-Bench campaign at mean reward 0.133.

## The type hole, closed

The reason this body exists: promoted colon words used to bind
`Contract(0,0,∅)` — bodies unchecked, arities unknown. Now a promoted
word's `( ins -- outs | effects )` contract is proved against its body
by the critic at accept time, persisted in-band, re-bound on load, and
a starved call is rejected **before any I/O** (see
`test/run_test.exs:"starved call..."` — workspace provably untouched).
