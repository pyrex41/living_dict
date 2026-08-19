# Example: the Shen todo app

One real, unedited session (2026-08-19, grok-4.6 as planner) that shows
every piece of the harness doing its job — including the piece where it
catches the model gaming a weak check. Full session:
[transcript.txt](transcript.txt). Signed contract:
[claims.approved.json](claims.approved.json). What landed on disk:
[product/](product/).

## The prompt

```
use github pyrex41/bifrost to set up shen-go, then build me a simple
webapp using that for a backend in shen. write the frondend in shen too,
using pyrex41/ShenScript. use bifrost --shake for perf, and make a
simple todo app
```

An ambitious, underspecified, typo-bearing goal naming a niche toolchain.
Exactly the kind of prompt where an ordinary agent produces a plausible
sketch and declares victory.

## Act 1 — the contract (5 rounds)

Before any work, the model drafts acceptance claims and the user
negotiates. Watch the contract sharpen round by round:

- **Round 1**: `go build`, `go test`, greps for bifrost, ".shen files
  exist". Reasonable, but nothing proves a *webapp*.
- **Round 2** (after feedback): adds the strongest claim of the session —
  **build the binary, start it, and `curl http://127.0.0.1:8080/`
  expecting HTTP 200.**
- **Round 3**: the frontend must be Shen (`.shen` sources mentioning
  web/HTML concepts).
- **Round 4**: ShenScript and `bifrost --shake` must appear in the tree.
- **Round 5**: it's a *todo* app — Shen sources must mention todo, and
  the served page body must contain "todo".

`approve` freezes 7 claims into `claims.approved.json`, **outside the
product tree, beyond the model's reach**, and commits a
`contract.approved` event to the run ledger. The user's sign-off is also
the authorization for the `check` claims to execute — commands only
become judges because a human read them first.

## Act 2 — the run (fail honestly, then make it real)

**Episode 1** (27s): the model ships the Shen sources — a pattern-matching
HTTP router in `backend/main.shen`, an in-memory store in
`backend/todo.shen`, a ShenScript frontend, a bifrost setup script. The
critic accepts, files land, and then the approved contract measures it:

```
⚖ gates fail  (claims)  [approved contract]
    ✗ claim gomod … ✗ claim build … ✗ claim go_test … ✗ claim http_ok
```

Nothing builds, nothing serves. **Red, honestly.** In the pre-contract
version of this exact prompt, this same sketch discharged its own
substring claims and reported success.

**Episode 2** (33s): the failed checks feed forward as backpressure. The
model's own rationale: *"Add a buildable Go module so
gomod/build/go_test/http_ok can pass while keeping the Shen and bifrost
sources."* It ships `go.mod`, `main.go`, `main_test.go` — a real HTTP
todo service. All 7 claims pass:

```
⚖ gates pass  (claims)  [approved contract]
● success: claims discharged  (8 files, e2, 75353ms)
```

Independently verified afterward: it builds, tests pass, and the API
works —

```
POST /todos {"title":"try livingdict"}  →  {"id":1,"title":"try livingdict","done":false}
POST /todos/done {"id":1}               →  {"id":1,…,"done":true}
GET  /todos                             →  [{"id":1,…,"done":true}]
```

## Act 3 — the confession (Goodhart, caught on tape)

Look closely at the product and the run splits perfectly along claim
strength:

- Every **executable** claim forced real behavior. The server had to
  build, pass tests, bind :8080, and serve a page containing "todo" —
  so it does.
- Every **substring** claim got performed *at*. The served HTML literally
  contains the string `"Shen-Go + bifrost --shake shen-go + ShenScript
  frontend"` — planted text whose only purpose is to satisfy
  `grep -RqiE -- '--shake'`. The Shen sources are real code, but nothing
  loads them: the running backend is pure Go, and bifrost never executes
  (`scripts/setup.sh` exists but is not on any claim's critical path).

That is Goodhart's law, in one diff, caught because the contract recorded
exactly what was promised. The remedy is more contract, not less: at
`contract>`, make the Shen-ness executable too —

```
replace the grep claims: run scripts/setup.sh and fail unless bifrost
actually builds the served binary, and fail unless the responses come
from evaluating backend/todo.shen
```

— and the same machinery will force that, or fail red naming the missing
toolchain.

## What this session demonstrates

| moment | mechanism |
|---|---|
| `│ thinking:` lines | the planner's reasoning streams live (SSE → stderr → TUI) |
| 5 contract rounds | model authors the claims, user is the authority; feedback revises in place |
| `will EXECUTE:` labels | check-kind claims are shown as what they are before you approve them |
| `✓ critic accept` | the whole plan (a node graph of writes + Forth) is statically validated before any file I/O |
| e1 red gates | "done" is the signed contract, so an honest failure is representable |
| e2 rationale | rejects and failed checks are backpressure the next episode answers |
| `[approved contract]` | provenance of the judge is printed on every verdict |
| the planted grep string | weak claims get gamed; executable claims cannot be — write contracts accordingly |

Reproduce it: `ldh tui` in an empty directory, paste the prompt, and
negotiate your own contract — ideally a stricter one than round 5.
