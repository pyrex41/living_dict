# Side-by-side harness compare

Same prompt, three isolated workspaces:

| arm | what actually runs |
|---|---|
| `grok` | `grok -p --output-format json --always-approve --cwd <arm>` |
| `pi` | `pi -p --mode json --no-session --no-approve --no-context-files` in `<arm>` |
| `livingdict` | `livingdict -p --cwd <arm> --max-turns N --run-dir <arm>/.livingdict-run` |

This is how you tell whether Living Dictionary is a real coding harness or just a chat UI around leftover product. Grok and Pi keep their own loops. Living Dictionary keeps Forth + critic + `RUN-GATES`. The prompt string is identical.

## Run

No OpenResty host is required. The livingdict arm is an argv peer of `grok -p`.

```bash
python3 client/compare.py --dry-run

python3 client/compare.py \
  --prompt "Write hello.txt containing hello world." \
  --max-turns 4 \
  --timeout 180

# or
make compare PROMPT='Write hello.txt containing hello world.'
```

Flags worth knowing:

| flag | meaning |
|---|---|
| `--prompt` / `--prompt-file` | the shared goal |
| `--seed DIR` | copy this tree into every arm (default: empty workspace) |
| `--arms grok,pi,livingdict` | subset |
| `--parallel` | run arms at the same time (default is serial — kinder to API limits) |
| `--max-turns N` | grok `--max-turns` and livingdict episodes (default 8; halt ≠ done) |
| `--timeout SEC` | wall clock per arm (default 600) |
| `--claims FILE` | hidden `claims.json` scored on every arm after it finishes |
| `--gates` | run Living Dictionary `RUN-GATES` on each finished workspace |
| `--grok-model` / `--pi-model` / `--pi-provider` | pin models |
| `--out DIR` | default `compare/runs/<utc-stamp>/` |

Output:

```
compare/runs/<stamp>/
  prompt.txt
  summary.md
  summary.json
  grok/          pi/          livingdict/
    <product files>
    _compare.json
    _stdout.txt
    _stderr.txt
```

`livingdict` also gets a private `.dictionary/` and `.livingdict-run/` so a compare does not write into `apps/studio` or the host's shared dictionary.

## Fairness

- **Same prompt.** No extra wrapper on grok/pi. Living Dictionary still has its planner SYSTEM; that *is* the harness.
- **Isolated trees.** `node_modules`, `dist`, `.git`, `.sb` are not copied from `--seed`. Snapshot diffs skip those too.
- **Pi does not inherit this repo's AGENTS.md.** `--no-context-files` and `--no-approve`.
- **Do not seed `apps/studio` unless you mean to.** That tree is leftover product. Default seed is empty.
- **Hidden claims are the shared judge.** `--claims` is applied *after* each arm, then restored. Grok/Pi are not required to invent `claims.json`. Without `--claims`, the scoreboard is "did it run" + files changed.
- **Pi can share Grok OAuth.** If `pi` has no login but `~/.grok/auth.json` exists, compare reuses that bearer as `XAI_API_KEY` and defaults `--pi-provider xai` so the three arms can share grok-4.6.

Example hidden claims:

```json
{
  "claims": [
    {"id": "hello", "kind": "file", "path": "hello.txt", "any": ["hello world"], "min_bytes": 11}
  ]
}
```

```bash
python3 client/compare.py \
  --prompt "Write hello.txt containing hello world." \
  --claims path/to/claims.json \
  --max-turns 2
```

## What this is not

It is not the 40-task eval suite (`eval/`). It is a live three-way on *your* prompt, the way you would actually use each tool.

A green `ok` means that arm's process finished. Goal discharge is either hidden `--claims` or, for Living Dictionary, the last episode's `RUN-GATES` claims.
