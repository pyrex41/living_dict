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
| `host.py` | six capabilities + glob/effect policy |
| `forth.py` | hosted Forth |
| `preflight.py` | Python critic |
| `envelope.py` | `{ language, program, artifacts }` |
| `execute.py` / `adapter.py` | run + ldeval glue |
| `adapters/forth.py` | no preflight |
| `adapters/forth_shen.py` | Python preflight |

`RUN-TESTS` sets `PYTHONDONTWRITEBYTECODE=1` so ldeval does not see `__pycache__`
as a policy violation.
