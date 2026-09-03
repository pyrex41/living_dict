# Living Dictionary client

Turn-based front end for the OpenResty host. A normal turn is a **goal**:
the host calls the configured model, Shen checks the envelope, Forth runs. Forth is
the harness. The goal is whatever product you want built.

Auth (server-side, never in the page):

Choose a provider (xAI remains the default):

```bash
export LIVINGDICT_PROVIDER=xai       # XAI_API_KEY or: grok login --oauth
export LIVINGDICT_PROVIDER=anthropic # ANTHROPIC_API_KEY
export LIVINGDICT_PROVIDER=openai    # OPENAI_API_KEY, or Codex OAuth below
export LIVINGDICT_MODEL=<model-id>    # optional provider-specific override
```

For OpenAI OAuth, install the official Codex CLI and run either `codex login`
or `python3 client/planner.py --login openai`. Living Dictionary delegates each
OAuth-backed inference call to `codex exec` in a read-only sandbox and never
reads Codex's credential files. Set `LIVINGDICT_OPENAI_AUTH=api_key|oauth|auto`
to override the default (`auto`, preferring `OPENAI_API_KEY` when present).

## CLI

Needs `make openresty-serve` in another terminal.

```bash
python3 client/livingdict.py
python3 client/livingdict.py -e '3 4 +'
python3 client/livingdict.py --load openresty/examples/config-01.envelope.json
python3 client/livingdict.py --health
```

In the REPL:

| | |
|---|---|
| `migrate the timeout field` | planner + /think |
| `/forth 3 4 +` | skip planner |
| `/load FILE.json` | canned envelope |
| `/paste` … `.` | multiline Forth |
| `/health` | critic status |
| `/quit` | leave |

```bash
python3 client/livingdict.py -g 'define SQUARE then compute 12 SQUARE'
```

## Compare (grok / pi / livingdict CLI)

Same prompt, three isolated workspaces. Living Dictionary is `bin/livingdict -p`,
not `POST /think`. See [`docs/COMPARE.md`](../docs/COMPARE.md).

```bash
python3 client/compare.py --dry-run
python3 client/compare.py --prompt 'Write hello.txt containing hello world.'
make compare PROMPT='Write hello.txt containing hello world.'
```

## Browser

Svelte chat at <http://127.0.0.1:8080/> (built into `openresty/public`).

```bash
make client-web          # rebuild the chat UI
make openresty-serve
```

Dev with proxy (host must still be on :8080):

```bash
cd client/web && npm install && npm run dev
```

Type a goal and Send. Check **Forth** to skip the planner. Load an envelope JSON for a canned program.
