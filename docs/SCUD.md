# SCUD seam

SCUD owns goal/DAG orchestration; livingdict owns bounded episode
execution; the Shen critic is the policy evaluator at both seams.

SCUD never writes its in-process Go `executor.Request` to the child.
The child reads one `rho.run/v1` `wireRequest` JSON object and writes
a `ConsumeRhoV1` JSONL stream. Eval adapter 1.0 (`request.json` /
trace / receipt / exit) is a different contract and is unchanged.

## Ownership

| Owner | What it decides |
|---|---|
| SCUD | goals, obligation DAG, wave/backpressure, when to exec a runner, parent-side Authorize |
| livingdict | one bounded run: critic → artifacts → Forth → `RUN-GATES` → livingdict receipt |
| Shen critic (`preflight.validate`) | Accept/Reject of a program's effects and globs, both inside an episode and via `livingdict-policy` |

## Child invocation

Default spawn (empty Command/Args on the parent maps to this argv):

```
livingdict run --request-file - --events jsonl
```

- stdin: one JSON object (`wireRequest`). Not JSONL. Not a prompt string.
- stdout: JSONL events consumed by `ConsumeRhoV1`.
- stderr: captured by the parent; never parsed.
- cwd: parent `cmd.Dir` / livingdict `--cwd`. Working directory is **not** a JSON field.
  Bare-cwd fallback is gated: without `context.working_dir` or an explicit `--cwd`,
  the process cwd is used only when it lies inside an absolute `grant.write_roots`
  / `read_roots` entry (SCUD's normal shape). Otherwise the run refuses with
  `invalid_request: workspace is ambiguous` before any effect.
- `--planner-cmd` file args are resolved from the invocation directory (then the livingdict repo), **before** `--cwd` / `os.chdir`. The planner process still runs with cwd = workspace.
- exit 0 after a single terminal event, including `run.failed` / `run.cancelled`.

## wireRequest → livingdict

| `wireRequest` field | livingdict use |
|---|---|
| `protocol` | must be `rho.run/v1` |
| `run_id` | echoed on every event; stored on the CLI receipt |
| `model.provider`, `model.id` | required; copied onto `run.started` |
| `input[0].content[0].text` | user goal (same text `livingdict -p` would take) |
| `system` | optional planner observation `system` |
| `limits` | always present (may be `{}`); `max_turns` caps episodes; `deadline` cancels |
| `grant.grant_id` | recorded on the grant object; not interpreted as a path |
| `grant.expires_at` | RFC3339 UTC; refuse if missing in require-mode or if it is in the past |
| `grant.providers`, `grant.models`, `grant.tools` | enforced when non-empty: a provider/model outside the list refuses with `grant_invalid`. Without `--planner-cmd`, only providers the default live planner serves (`xai`) are accepted — anything else refuses with `provider_unmapped` before any planner spawn |
| `grant.read_roots`, `grant.write_roots` | mapped to workspace-relative allowed globs |
| `grant.network.mode` | carried; default from SCUD is `provider_only` |
| `grant.witness` | required when `RHO_PROTOCOL_GRANT_MODE=require` |
| `context` | omitempty; swarm may send `scud.tag`, `scud.task_id`, `scud.mode` |

`AllowedTools` on the parent Go `Request` is **not** a child field. If
the parent slice is non-empty, SCUD overwrites `grant.tools` before
stdin is written.

## stdout events

| `type` | `data` | role |
|---|---|---|
| `run.started` | `{provider, id}` | first event |
| kernel kinds (`episode.planned`, `critic.accepted`, `artifacts.applied`, `gates.measured`, …) | kernel payload | pass-through; unknown types are valid |
| `livingdict.receipt` | CLI receipt (`changed_files`, `decision`, `request_sha256`, …) | pre-terminal; **not** the `run.completed` payload |
| `message.delta` | `{text}` | concatenated by the parent |
| `run.completed` | `{status: "succeeded", usage?}` | only success terminal; extra keys ignored; receipt-shaped data is invalid |
| `run.failed` | `{code, message}` | protocol-valid failure; process still exits 0 |
| `run.cancelled` | `{reason}` | deadline / interrupt |

Exactly one terminal. No events after it. `seq` is a strictly increasing
`uint64` (gaps allowed; first seq may be 0).

## Grant verification (current level)

Parent, when `Authorize` is set: canonicalize the **unsigned** request
(witness omitted), obtain `(witness, issuerPubkey)`, write witness onto
`grant`, and if the issuer key is non-empty set:

```
RHO_PROTOCOL_GRANT_MODE=require
RHO_PROTOCOL_GRANT_PUBKEY=<BIP340 x-only issuer public key>
```

Child, in `verify_witness`:

1. Structural: `grant.witness` present; env pubkey is a 32-byte x-only
   key; `grant.issuer_pubkey` / `grant.pubkey`, if present, equals that
   key; `expires_at` is in the future.
2. Re-serialize the request with `grant.witness` stripped, object keys
   sorted lexicographically at every level, no insignificant whitespace
   (same rule as SCUD `canonicalJSON`).
3. Record `request_sha256` (hex SHA-256 of those canonical bytes) on the
   livingdict receipt so an auditor can match the signed bytes.
4. BIP340-verify that digest against `grant.witness` and
   `RHO_PROTOCOL_GRANT_PUBKEY` using the in-tree, dependency-free
   verifier. `grant_verification` is written as `bip340` **only** after
   this step returns. Failures never set that field and never claim a
   signature was verified.

Require-mode without a witness, a mismatched pubkey field, an expired
grant, or a failing BIP340 check refuses the run **before** any
effectful episode (no planner, no artifact writes). This child does not
speak td's HTTP Authorize API.

## Policy evaluator

`bin/livingdict-policy` (or `livingdict policy`) is the process form of
SCUD's v2 Shen `Evaluator.Evaluate`. One JSON object on stdin:

```json
{
  "run_id": "<string>",
  "action": "execute",
  "resource": "<obligation id>",
  "attributes": {
    "goal_id": "",
    "capability_ref": "",
    "policy_ref": "",
    "grant_ref": ""
  }
}
```

Stdout is exactly `{allowed, reason, constraints}`. Action `execute` on
a resource is allowed iff the attributes' globs/effects (and optional
`program` / `artifacts` / `nodes`) pass `preflight.validate`. A deny
uses the critic's typed reason string (`effects not allowed: …`,
`forbidden path: …`, …). Evaluate errors (malformed stdin) exit
non-zero; a deny is exit 0 with `allowed: false`.

Deny-by-default: `attributes.allowed_globs` (or `globs`) and
`attributes.allowed_effects` (or `effects`) are required. Stock SCUD
sends only the four ref strings, and that alone is **denied** — the
integration must map the obligation's grant onto explicit globs and
effects. A policy seam must never widen a request it does not
understand to `**`. The episode critic still runs inside
`livingdict run` regardless.

## Drive one obligation by hand

Workspace and run dir stay off the product tree:

```bash
cd /Users/reuben/projects/living_dict
mkdir -p /tmp/ld-rho-ws /tmp/ld-rho-run
python3 bin/livingdict run --request-file - --events jsonl \
  --cwd /tmp/ld-rho-ws --run-dir /tmp/ld-rho-run \
  --planner-cmd python3 harness/tests/fizzbuzz_planner.py <<'EOF'
{"protocol":"rho.run/v1","run_id":"fizzbuzz-1","model":{"provider":"test","id":"fizzbuzz"},"input":[{"role":"user","content":[{"type":"text","text":"Write a small Python fizzbuzz in this directory."}]}],"limits":{},"grant":{"grant_id":"scud-local","expires_at":"2030-01-01T00:00:00Z","providers":["test"],"models":["fizzbuzz"],"tools":[],"read_roots":["/tmp/ld-rho-ws"],"write_roots":["/tmp/ld-rho-ws"],"network":{"mode":"provider_only"}}}
EOF
```

Policy check for the same obligation (no workspace mutation):

```bash
python3 bin/livingdict-policy <<'EOF'
{"run_id":"fizzbuzz-1","action":"execute","resource":"write-fizzbuzz","attributes":{"goal_id":"demo","capability_ref":"livingdict","policy_ref":"critic","grant_ref":"scud-local","program":"RECEIPT","allowed_effects":"read,write,exec","allowed_globs":"**"}}
EOF
```

Require-mode refusal (missing `grant.witness`; no files written under the workspace):

```bash
RHO_PROTOCOL_GRANT_MODE=require \
RHO_PROTOCOL_GRANT_PUBKEY=F9308A019258C31049344F85F89D5229B531C845836F99B08601F113BCE036F9 \
python3 bin/livingdict run --request-file - --events jsonl \
  --cwd /tmp/ld-rho-ws --run-dir /tmp/ld-rho-run <<'EOF'
{"protocol":"rho.run/v1","run_id":"grant-missing","model":{"provider":"test","id":"fizzbuzz"},"input":[{"role":"user","content":[{"type":"text","text":"Write fizzbuzz."}]}],"limits":{},"grant":{"grant_id":"scud-local","expires_at":"2030-01-01T00:00:00Z","providers":["test"],"models":["fizzbuzz"],"tools":[],"read_roots":["/tmp/ld-rho-ws"],"write_roots":["/tmp/ld-rho-ws"],"network":{"mode":"provider_only"}}}
EOF
```
