# Adapter protocol 1.0

An adapter is an executable command bridging a coding harness to this suite.
The runner appends one argument: the absolute path of `request.json`. It also
sets `LDEVAL_REQUEST`, `LDEVAL_WORKSPACE`, and `LDEVAL_TRACE`.

The adapter runs with the task workspace as its current directory.

## Request

Important fields:

```json
{
  "protocol_version": "1.0",
  "run_id": "config-01-1234567890",
  "arm": "forth-shen",
  "memory_mode": "warm",
  "resume": false,
  "task": {
    "id": "config-01",
    "family": "config_migration",
    "sequence": 1,
    "mechanisms": ["routine_change", "warm_dictionary"],
    "allowed_effects": ["read", "write", "exec"],
    "allowed_globs": ["app/config.py"],
    "forbidden_globs": ["tests/**"]
  },
  "workspace": "/absolute/run/workspace",
  "prompt_path": "/absolute/run/workspace/TASK.md",
  "trace_path": "/absolute/run/trace.jsonl",
  "receipt_path": "/absolute/run/receipt.json",
  "dictionary_dir": "/absolute/run/dictionary",
  "graph_path": null
}
```

The adapter may modify only the workspace paths allowed by the request. It may
persist executable procedures in `dictionary_dir` during warm runs.

## Trace

Write one JSON object per line to `trace_path`. Every event has:

```json
{"type":"event.name","timestamp":"2026-08-13T12:00:00Z","data":{}}
```

Recognized event types:

| Event | Expected data |
|---|---|
| `llm.response` | `input_tokens`, `output_tokens`, optional `cost_usd` |
| `tool.call` | tool name and arguments or argument hash |
| `mutation.applied` | changed path or patch hash |
| `execution.trap` | typed reason and relevant receipt |
| `plan.replan` | old/new plan IDs or reason |
| `preflight.rejected` | stack, effect, contract, or policy error |
| `dictionary.retrieve` | query and candidate word IDs |
| `dictionary.reuse` | reused word ID and version |
| `dictionary.promote` | promoted word ID, evidence, and version |
| `graph.node.start` | node ID and worker ID |
| `graph.node.finish` | node ID, status, and worker ID |

Do not put secrets or complete model prompts into benchmark traces. Hash or
redact sensitive tool arguments.

## Crash and resume

Sequence-5 tasks declare `fault.after_event = "mutation.applied"`. With
`--inject-faults`, the runner watches the trace and terminates the adapter after
that event. It then relaunches the same command against the same workspace and
dictionary with `request.resume=true`.

An adapter claiming crash recovery should:

1. checkpoint before or atomically with mutation;
2. make mutations idempotent;
3. inspect current state when `resume=true`; and
4. continue verification without duplicating or corrupting work.

If the adapter never emits the configured event, no crash is injected and the
result records that fact.

## Receipt

The adapter may write `receipt.json` using `schemas/receipt.schema.json`. If it
does not, the runner creates a minimal receipt after verification. The runner's
protected result remains authoritative.

## Exit behavior

Exit zero means the adapter believes it finished. It does not mean the task
passed. Nonzero exit codes are recorded; the verifier still runs so partial or
misreported outcomes remain observable.

## Implementations in this repository

These commands already speak protocol 1.0. They are not part of the eval
package; they live beside it.

| Command | Notes |
|---|---|
| `harness/adapters/forth.py` | Forth, no critic |
| `harness/adapters/forth_shen.py` | Forth + Python preflight |
| `openresty/bin/livingdict-resty` | Forth + shen-lua `validate`; needs LuaJIT and a shen-lua checkout |

Envelope: `LIVINGDICT_ENVELOPE` or `dictionary_dir/envelope.json`. See
[`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md).

