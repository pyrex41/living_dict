# Harness

The Python Living Dictionary agent. [`../eval`](../eval) is the lab.
[`../openresty`](../openresty) is the shen-lua body of the same ABI.

Every arm mutates the workspace only through `CapabilityHost`. Forth is the
action IR. The eval-harness `forth-shen` critic is `livingdict.preflight`.
OpenResty runs the same Accept | Reject interface in shen-lua
(`openresty/shen/preflight.shen`). See [`shen/README.md`](shen/README.md) and
[`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md).

```bash
# canned envelope (no model)
export LIVINGDICT_ENVELOPE=/path/to/envelope.json
python3 adapters/forth_shen.py /path/to/request.json
```

| Module | Role |
|---|---|
| `host.py` | six capabilities + glob/effect policy + intern |
| `forth.py` | hosted Forth |
| `preflight.py` | Python critic (declared topology; never the space) |
| `envelope.py` | `{ language, program, artifacts }` |
| `kernel.py` | event-sourced reducer; `events.jsonl` is the tx log |
| `store.py` | CAS blobs/trees, `facts()`, `as_of(seq)` |
| `space.py` | in-process `out` / `rd` / `take` + leases |
| `wave.py` / `execute.py` | Kahn waves; dispatch via `take` |
| `cli.py` | `livingdict -p` loop; additive `tree_*` on receipts |
| `rho.py` / `runner.py` | `rho.run/v1` child (`livingdict run`) |
| `adapter.py` | ldeval glue |
| `adapters/forth.py` | no preflight |
| `adapters/forth_shen.py` | Python preflight |

`LIVINGDICT_OBJECTS` points several runs at one store. Default is
`run_dir/objects`. Corrupt blobs raise `StoreCorruption` on read.
`dictionary.promoted` is a kernel kind so word provenance is a derived
fact. Scheduling records (`space.*`) are traces, not kernel kinds.

`RUN-TESTS` sets `PYTHONDONTWRITEBYTECODE=1` so ldeval does not see `__pycache__`
as a policy violation.
