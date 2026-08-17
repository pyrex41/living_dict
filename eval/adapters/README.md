# Harness adapters

An adapter translates the suite's command protocol into one invocation of a
coding harness. The runner starts the adapter in a fresh task workspace and
appends the absolute path to `request.json` as its final argument.

`noop.py` is a protocol smoke test. It intentionally changes nothing and must
score 0/40 on the generated benchmark.

To integrate a harness:

1. copy `command_template.py`;
2. implement `run_harness(request)` without changing the request format;
3. emit JSONL telemetry to `request["trace_path"]`;
4. constrain file writes to `request["task"]["allowed_globs"]`; and
5. preserve `request["dictionary_dir"]` semantics for warm runs.

Keep model selection and credentials in the adapter or its environment, not
in task prompts. See `docs/ADAPTER_PROTOCOL.md` for the complete contract.

Implementations living next to this suite (not in `adapters/`):

| Command | Arm | Critic |
|---|---|---|
| `../../harness/adapters/forth.py` | `forth` | none |
| `../../harness/adapters/forth_shen.py` | `forth-shen` | Python `livingdict.preflight` |
| `../../openresty/bin/livingdict-resty` | `forth-shen` | shen-lua `validate` |

Pass the envelope with `LIVINGDICT_ENVELOPE` or `dictionary_dir/envelope.json`.
