# AGENTS.md

Instructions for AI coding agents (fx, Claude Code, pi, …) working in or
driving this repository.

## What this is

Living Dictionary: a coding harness where the model emits a plan envelope
(artifacts + optional Forth), a non-LLM critic Accepts/Rejects it before
any I/O, the host installs artifacts and runs the program with the model
off, and success is measured claim discharge — never "the model stopped".

## Driving livingdict (the usual reason you are here)

Headless, one goal, isolated workspace:

```bash
bin/livingdict -p "<goal>" --cwd <workspace> --max-turns 8 [--claims <claims.json>]
```

Exit 0 iff claims discharged. `halt_cap` / `blocked` exit non-zero. The
receipt (JSON on stdout) has `changed_files`, `decision`, `reason`,
`tree_before/tree_after`. Job state lands in `<workspace>/.livingdict-run/`
(events.jsonl is the ledger; trace.jsonl has tool/graph/space events).

Line TUI (goals from stdin; pipe-friendly):

```bash
echo "<goal>" | bin/livingdict tui --cwd <workspace> [--claims <claims.json>]
```

Deterministic runs without a live model — pass a canned planner:

```bash
--planner-cmd python3 harness/tests/fizzbuzz_planner.py   # fizzbuzz envelope
--planner-cmd python3 harness/tests/graph_planner.py      # graph-01 nodes/waves
```

SCUD/bounded-runner form (`rho.run/v1` on stdin, JSONL events on stdout)
and the policy evaluator are documented in `docs/SCUD.md`.

## Rules

- **Never edit `eval/`** — oracles, protected tests, schemas, and
  `task_graph.json` files are the benchmark. `compare/runs/` is history;
  do not touch it either.
- Use a scratch directory as `--cwd`, never the repo root. The workspace
  is the product; the repo is the harness.
- The eval 1.0 six-word ABI is frozen (`READ-FILE LIST-DIR SEARCH
  WRITE-FILE RUN-TESTS/RUN-GATES RECEIPT`). Do not add Forth words.
- `make test` must stay green (eval + harness + openresty + scudcheck);
  `make client-test` and `make browser-test` cover the other bodies.
- Design docs of record: `docs/ARCHITECTURE.md`, `docs/HARNESS.md`,
  `docs/SCUD.md`, `docs/design/STORE.md`, reviews in `docs/design/reviews/`.

## Layout (short)

- `harness/src/livingdict/` — Python body: kernel (event-sourced loop),
  preflight critic, Forth VM, waves, store, space, CLI/TUI/runner.
- `openresty/` — Lua body + shen-lua critic; `browser/` — JS body.
- `client/` — planner (the only model call), compare harness, web UI.
- `eval/` — the 40-task lab (read-only).
