# Living Dictionary Eval

A mechanism-focused benchmark for comparing coding-agent control languages and
harnesses: stepwise ReAct, complete JSON plans, restricted Python plans, Forth
programs, Forth with Shen-style preflight checks, and a persistent executable
dictionary.

The suite contains **40 deterministic repository tasks** in five ordered
families. It is deliberately small enough to run repeatedly while measuring
properties that patch-only benchmarks usually hide: model/tool round trips,
plan rejection before mutation, policy enforcement, crash recovery, graph
execution, and reuse or negative transfer from learned procedures.

## What is included

- 40 task repositories with visible prompts and public tests.
- Protected verifiers and oracle solutions kept outside agent workspaces.
- Cold and warm procedural-memory modes.
- Sequence-5 crash/resume experiments in every family.
- Sequence-8 false friends in every family.
- Workspace change-policy enforcement.
- A command-adapter protocol usable by any local coding harness.
- JSONL trace and receipt conventions.
- Machine-readable request, trace, receipt, and result schemas.
- Aggregate scoring and paired bootstrap comparisons.
- A small straight-line Forth stack/effect checker for smoke testing plans.
- Oracle, no-op, policy, telemetry, and crash-recovery self-tests.

See [TASKS.md](TASKS.md), [docs/EVALUATION.md](docs/EVALUATION.md), and
[docs/ADAPTER_PROTOCOL.md](docs/ADAPTER_PROTOCOL.md).

`examples/experiment.toml` is a preregisterable six-arm experiment sketch, and
`examples/forth-plan.fs` shows the smallest capability program accepted by the
included straight-line checker.

## Quick start

Python 3.11 or newer is the only runtime dependency.

```bash
python -m ldeval list
python -m ldeval run --oracle --arm oracle --output runs/oracle
python -m unittest discover -s tests -v
```

Install the `ldeval` command if desired:

```bash
python -m pip install -e .
ldeval list
```

Run a harness adapter:

```bash
python -m ldeval run \
  --agent-command "python /absolute/path/to/your_adapter.py" \
  --arm react \
  --memory-mode cold \
  --output runs/react-cold
```

The runner appends an absolute `request.json` path to the configured command.
It does not invoke a shell.

In this repository the OpenResty host is already wired:

```bash
# from the repo root; needs luajit + a shen-lua checkout
make eval-resty-config-01
```

That runs `config-01` with `../openresty/bin/livingdict-resty` and the canned
envelope `../openresty/examples/config-01.envelope.json`. See
[`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md).

## Recommended experimental arms

| Arm | Execution interface |
|---|---|
| `react` | One model-mediated JSON tool action at a time |
| `json-plan` | One complete structured action sequence |
| `python-plan` | Restricted executable Python plan |
| `forth` | Executable Forth capability program |
| `forth-shen` | Forth plus stack/effect/contract preflight |
| `living-dictionary` | Forth/Shen with family-persistent promoted words |

Keep the model, tool implementations, workspace, verifier, budgets, and base
prompt constant. Only the control representation should change.

## Running subsets

```bash
# One family in sequence order
python -m ldeval run --oracle --families parser_repair --output runs/parser

# Mechanism subset
python -m ldeval run --oracle --mechanisms prompt_injection --output runs/safety

# Explicit tasks
python -m ldeval run --oracle --tasks config-01,config-08 --output runs/config-pair

# Fault injection; sequence-5 tasks are terminated after mutation.applied,
# then relaunched with request.resume=true
python -m ldeval run --agent-command "..." --inject-faults \
  --mechanisms crash_recovery --output runs/crash
```

## Cold and warm dictionary experiments

Cold mode gives every task a new empty dictionary directory:

```bash
python -m ldeval run --agent-command "..." --arm living-dictionary \
  --memory-mode cold --output runs/dictionary-cold
```

Warm mode gives the eight ordered members of each family one shared dictionary
directory. Families remain isolated from one another:

```bash
python -m ldeval run --agent-command "..." --arm living-dictionary \
  --memory-mode warm --output runs/dictionary-warm
```

Compare paired results:

```bash
python -m ldeval compare runs/dictionary-cold runs/dictionary-warm
```

## Primary outcome

A task succeeds only when:

1. every protected behavioral check passes;
2. no forbidden or out-of-scope file changed; and
3. the run did not time out.

An agent exit code is recorded but is not treated as proof. Evidence wins.

## Public-benchmark bridge

This suite is intended as a diagnostic gate before expensive external runs.
Once a mechanism survives here, use the same adapter with:

- [SWE-bench Verified Mini](https://hal.cs.princeton.edu/swebench_verified_mini)
- [SWE-bench](https://github.com/swe-bench/SWE-bench)
- [Terminal-Bench](https://github.com/harbor-framework/terminal-bench)
- [HAL harness](https://github.com/princeton-pli/hal-harness)

Those benchmarks answer “does the agent solve real tasks?” This suite adds
“what did the harness buy, and why?”

## Regenerating fixtures

Task generation is deterministic:

```bash
python tools/build_tasks.py
```

Oracle and no-op checks should then produce 100% and 0% success respectively.

## Security boundary

The runner detects unauthorized workspace mutations but is not an OS sandbox.
Run untrusted agents inside Docker, a VM, or another appropriate sandbox. The
protected verifier is not copied into the agent workspace, but a host process
with unrestricted filesystem access is inherently capable of searching for it.

## License

MIT.
