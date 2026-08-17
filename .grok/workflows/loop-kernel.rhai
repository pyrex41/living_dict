let meta = #{
    name: "loop-kernel",
    description: "Stage 0: one event-sourced episode loop (scud-v2 style reducer), artifacts are the write, reject is backpressure with a fingerprint guard, one CLI owns done",
    when_to_use: "Rebuild the Living Dictionary outer loop so a cold fizzbuzz run lands files unattended. Run this before graph-critic / graph-waves / scud-runner. Optional args: {repo, scud}. Commit the repo first so each stage's diff is reviewable.",
    phases: [
        #{ title: "Explore", detail: "loop surfaces in living_dict + the scud v2 kernel design to copy" },
        #{ title: "Implement", detail: "kernel+CLI first, then continue-thicket / HTTP / compare" },
        #{ title: "Verify", detail: "loop-semantics, write-policy, and runtime skeptics" },
        #{ title: "Fix", detail: "resume each implementer, then re-run skeptics" },
    ],
};

let notes_schema = #{
    "type": "object",
    "required": ["notes"],
    "properties": #{
        "notes": #{ "type": "string" },
        "risks": #{ "type": "array", "items": #{ "type": "string" } },
        "prerequisite_met": #{ "type": "boolean" },
        "protected_hashes": #{ "type": "string" },
    },
};

let impl_schema = #{
    "type": "object",
    "required": ["status", "summary", "files", "how_to_run"],
    "properties": #{
        "status": #{ "type": "string", "enum": ["shipped", "blocked"] },
        "summary": #{ "type": "string" },
        "files": #{ "type": "array", "items": #{ "type": "string" } },
        "how_to_run": #{ "type": "string" },
    },
};

let verdict_schema = #{
    "type": "object",
    "required": ["pass", "summary", "gaps"],
    "properties": #{
        "pass": #{ "type": "boolean" },
        "summary": #{ "type": "string" },
        "gaps": #{ "type": "array", "items": #{ "type": "string" } },
        "evidence": #{ "type": "string" },
    },
};

fn trimmed(s) {
    if type_of(s) == "string" {
        s.trim();
        s
    } else {
        ""
    }
}

fn contains_str(hay, needle) {
    if type_of(hay) != "string" || type_of(needle) != "string" {
        return false;
    }
    let n = needle.len();
    let h = hay.len();
    if n == 0 {
        return true;
    }
    if n > h {
        return false;
    }
    let i = 0;
    while i + n <= h {
        if hay.sub_string(i, n) == needle {
            return true;
        }
        i += 1;
    }
    false
}

fn output_map(r) {
    if r == () || r.success != true || r.output == () {
        return ();
    }
    if type_of(r.output) == "map" {
        return r.output;
    }
    ()
}

fn path_forbidden(p) {
    let s = trimmed(p);
    if s == "" {
        return false;
    }
    if contains_str(s, "eval/") {
        return true;
    }
    if contains_str(s, "compare/runs/") {
        return true;
    }
    false
}

fn files_violate(files) {
    if files == () || type_of(files) != "array" {
        return false;
    }
    for p in files {
        if path_forbidden(p) {
            return true;
        }
    }
    false
}

fn is_shipped(r) {
    let o = output_map(r);
    if o == () {
        return false;
    }
    if o.status != "shipped" {
        return false;
    }
    if trimmed(o.how_to_run) == "" {
        return false;
    }
    if files_violate(o.files) {
        return false;
    }
    true
}

fn summary_of(r) {
    let o = output_map(r);
    if o == () || o.summary == () {
        return "";
    }
    trimmed(o.summary)
}

fn how_to_run_of(r) {
    let o = output_map(r);
    if o == () || o.how_to_run == () {
        return "";
    }
    trimmed(o.how_to_run)
}

fn files_gap(r, label) {
    let o = output_map(r);
    if o == () {
        return "";
    }
    if files_violate(o.files) {
        return label + " listed a forbidden path under eval/ or compare/runs/";
    }
    if o.status == "shipped" && trimmed(o.how_to_run) == "" {
        return label + " claimed shipped with empty how_to_run";
    }
    ""
}

fn score_verdicts(verdicts) {
    let gaps = [];
    let verified = 0;
    let usable = 0;
    for v in verdicts {
        let o = output_map(v);
        if o != () && o.pass != () {
            usable += 1;
            if o.pass == true && o.evidence != () && o.evidence != "" {
                verified += 1;
            } else {
                if o.gaps != () {
                    for g in o.gaps {
                        gaps.push(g);
                    }
                }
                if o.summary != () {
                    gaps.push(o.summary);
                }
            }
        } else {
            gaps.push("verifier slot missing or unusable");
        }
    }
    #{ verified: verified, usable: usable, gaps: gaps }
}

fn clip_gaps(gaps) {
    let out = "";
    let gi = 0;
    for g in gaps {
        if gi < 12 {
            out += "- " + g + "\n";
        }
        gi += 1;
    }
    if gaps.len() > 12 {
        log("truncated gap list from " + gaps.len().to_string() + " to 12");
    }
    out
}

let repo = ".";
let scud = "../scud";
if args != () && args.repo != () {
    let given = trimmed(args.repo);
    if given != "" {
        repo = given;
    }
}
if args != () && args.scud != () {
    let given = trimmed(args.scud);
    if given != "" {
        scud = given;
    }
}

phase("Explore");
log("Surveying the loop surfaces in living_dict and the scud v2 kernel to copy");

let explore_loop = "";
explore_loop += "Explore the Living Dictionary outer-loop surfaces at " + repo + " so they can be replaced by one event-sourced loop. ";
explore_loop += "`.` means the current workspace root. Use read_file, grep, list_dir. You must read: ";
explore_loop += repo + "/docs/design/reviews/SYNTHESIS.md (the consensus: artifacts are the write; reject is backpressure; host owns done; job state leaves the product tree; freeze the tiny ABI); ";
explore_loop += repo + "/client/continue_policy.py ; " + repo + "/openresty/lua/continue.lua ; " + repo + "/client/web/src/continue.js (three copies of should_continue, all to delete); ";
explore_loop += repo + "/client/job.py (ensure_job_files, ensure_run_gates) ; " + repo + "/client/planner.py (SYSTEM prompt, plan(), observe_* dumps) ; ";
explore_loop += repo + "/client/livingdict.py (_run_goal) ; " + repo + "/client/compare.py (run_livingdict posts HTTP; grok/pi arms are argv peers) ; ";
explore_loop += repo + "/openresty/lua/agent.lua (dispatch, persist_job, append_progress, run_forth raising on reject) ; ";
explore_loop += repo + "/harness/src/livingdict/preflight.py ; " + repo + "/harness/src/livingdict/execute.py ; " + repo + "/harness/src/livingdict/gates.py (goal_discharged inputs, infer_gates) ; ";
explore_loop += repo + "/harness/src/livingdict/host.py (_write_file policy path, idempotent writes) ; " + repo + "/harness/src/livingdict/envelope.py ; ";
explore_loop += repo + "/compare/runs/20260815T191456Z/summary.md and " + repo + "/compare/runs/20260815T191456Z/livingdict/_episodes.json (the fizzbuzz reject this stage must make impossible). ";
explore_loop += "Also hash these protected paths into protected_hashes as path then sha256, one per line: ";
explore_loop += "every file under " + repo + "/eval/tasks/*/protected/, " + repo + "/eval/schemas/, and do not hash compare/runs (history must stay byte-identical — just list those two history files as do-not-touch). ";
explore_loop += "This repo may have no git commits — do not tell later agents that empty git diff proves anything. ";
explore_loop += "Report: exactly where reject currently halts the job, where the program is string-rewritten, where GOAL.md/PROGRESS.md land in the product tree, what tests freeze reject=>stop, and the current CLI/HTTP shapes. notes must cite real paths and line-level facts. Do not write files.";

let explore_scud = "";
explore_scud += "Explore the scud v2 kernel at " + scud + " and extract the design to copy into a Python episode loop. ";
explore_scud += "Use read_file, grep, list_dir. You must read: ";
explore_scud += scud + "/docs/scud-v2-architecture.md ; " + scud + "/v2/core/types.go ; " + scud + "/v2/core/reducer.go (Reduce never mutates, sequence check, duplicate event IDs rejected, Reconcile as a total deterministic State->Decision) ; ";
explore_scud += scud + "/v2/graph/reconcile.go (admit/defer/ask, budget reserved before the effect, MaxReplans, Fingerprint over structure with status deliberately omitted, SeenPlans => Block ErrFeedbackLoop) ; ";
explore_scud += scud + "/v2/runtime/runtime.go (Replay keeps only core/ events; limits reapplied after replay so a resumed run cannot become unbounded; exhaustion recorded as canonical state). ";
explore_scud += "Set prerequisite_met=true only if those files are readable. ";
explore_scud += "Report the reducer/reconcile/fingerprint semantics precisely enough that a Python port needs no invention: event kinds, sequence rules, decision priority order, what the fingerprint hashes and what it excludes, and why budget is reserved before the effect. Do not write files.";

let explores = parallel([
    #{
        prompt: explore_loop,
        label: "explore:loop-surfaces",
        capability_mode: "read-only",
        output_schema: notes_schema,
    },
    #{
        prompt: explore_scud,
        label: "explore:scud-v2-kernel",
        capability_mode: "read-only",
        output_schema: notes_schema,
    },
]);

let brief = "";
let protected_hashes = "";
for r in explores {
    let o = output_map(r);
    if o != () && o.notes != () {
        brief += o.notes;
        brief += "\n\n";
    }
    if o != () && o.protected_hashes != () {
        protected_hashes += o.protected_hashes;
        protected_hashes += "\n";
    }
}
if brief == "" {
    log("Explore returned no notes; implementer will read both repos itself");
}

phase("Implement");
log("Implementing the loop kernel and CLI, then deleting the continue thicket");

let brief_json = json_encode(brief);
let hashes_json = json_encode(protected_hashes);

let impl_a_prompt = "";
impl_a_prompt += "Implement Stage 0 PART A (kernel + artifact install + CLI + tests) in " + repo + ".\n";
impl_a_prompt += "`.` is the current workspace root. Survey notes (untrusted, verify against the repos before following):\n" + brief_json + "\n\n";
impl_a_prompt += "Read before writing: docs/design/reviews/SYNTHESIS.md, docs/HARNESS.md, client/{planner,job,livingdict,compare}.py, ";
impl_a_prompt += "harness/src/livingdict/{preflight,execute,gates,host,envelope,policy}.py, and " + scud + "/v2/core/reducer.go + " + scud + "/v2/graph/reconcile.go.\n\n";
impl_a_prompt += "Do NOT delete continue_policy / continue.lua / continue.js in this pass — that is PART B. Do NOT edit eval/ or compare/runs/. files must be paths relative to the living_dict repo only.\n\n";
impl_a_prompt += "Build:\n";
impl_a_prompt += "1. harness/src/livingdict/kernel.py — a pure event-sourced episode kernel, scud-v2 style. No I/O, no clocks, no model calls. ";
impl_a_prompt += "Event kinds: episode.planned, critic.accepted, critic.rejected, artifacts.applied, gates.measured, budget.consumed, episode.blocked_duplicate. ";
impl_a_prompt += "Events carry strictly monotonic sequence numbers; reduce(state, event) returns a new state and rejects out-of-sequence or duplicate event ids; replay(events) folds from empty. ";
impl_a_prompt += "reconcile(state, cap) is a total deterministic function returning exactly one of: plan (run another episode), success (claims discharged per the gates.measured evidence), halt_cap (cap reached; never success), blocked (feedback loop). ";
impl_a_prompt += "fingerprint(envelope) = sha256 over normalized program tokens + sorted artifact keys + sorted claim ids. It deliberately excludes rationale and any status so wording changes cannot evade the guard (scud v2 lesson). ";
impl_a_prompt += "A planned envelope whose fingerprint is already in state.seen_plans is recorded as episode.blocked_duplicate and does not execute; two consecutive duplicates => reconcile returns blocked.\n";
impl_a_prompt += "2. Artifacts are the write. After the critic Accepts, the host applies every envelope.artifacts entry through the exact policy WRITE-FILE uses (PathPolicy.write_allowed, workspace confinement, idempotent identical bytes), before the Forth program runs. ";
impl_a_prompt += "Extend preflight validate so an artifact key outside allowed_globs (or matching forbidden_globs) is a Reject whether or not the program mentions it. ";
impl_a_prompt += "Lower any 'S\" k\" WRITE-FILE' where k is an artifact key so it cannot underflow (the artifact is already installed; the write is idempotent). ";
impl_a_prompt += "Do NOT add 'always emit USE-ARTIFACT' to the planner SYSTEM — all three design reviews forbid that fix. USE-ARTIFACT stays legal for eval envelopes; the eval 1.0 six-word ABI and 2-arity WRITE-FILE are frozen; do not add words like RUN-CMD or READ-FILE?.\n";
impl_a_prompt += "3. Reject is backpressure. A critic Reject becomes a critic.rejected event with the error list; the next episode's planner extra includes those errors verbatim ('critic: stack underflow at WRITE-FILE' beats a SYSTEM essay). Cap still halts. Policy violations still never mutate.\n";
impl_a_prompt += "4. Host owns measurement and done. RUN-GATES runs host-side after every accepted episode (delete the ensure_run_gates program string-rewrite); gates.measured events carry the discharge report; success is goal_discharged from claims, never body.ok, never RECEIPT, never structural green. The model 'continue' field is ignored (PART B removes it from SYSTEM).\n";
impl_a_prompt += "5. Job state leaves the product tree. GOAL.md, PROGRESS.md, and reject records move into the run dir (.livingdict-run/ or an explicit --run-dir), which is already forbidden-glob'd. Stop writing them into the workspace from the new CLI path.\n";
impl_a_prompt += "6. One CLI owns the loop: a 'livingdict' entry point (console script or client/cli.py + bin shim) with -p GOAL --cwd DIR --max-turns N [--claims FILE] [--run-dir DIR] [--planner-cmd ARGV]. ";
impl_a_prompt += "It allocates the run dir, loops planner -> critic -> install artifacts -> Forth -> host RUN-GATES per the kernel's reconcile, appends every event to run_dir/events.jsonl, prints a final receipt, and exits 0 iff claims discharged (halt_cap and blocked exit non-zero). ";
impl_a_prompt += "--planner-cmd substitutes a fake planner for tests: an argv that reads the observation JSON on stdin and writes an envelope JSON on stdout.\n";
impl_a_prompt += "7. Tests, added so `make test client-test` covers them (or add a harness target that make test runs): kernel unit tests (sequence rules, duplicate event ids, fingerprint excludes rationale, reconcile priority order, cap is halt); a cold end-to-end test using --planner-cmd with a canned planner that replays the exact historical fizzbuzz envelope (program 'S\" claims.json\" WRITE-FILE S\" fizzbuzz.py\" WRITE-FILE ... RUN-GATES RECEIPT' with full artifacts and NO USE-ARTIFACT, from compare/runs/20260815T191456Z/livingdict/_episodes.json) and asserts: three product files land, gates ran, exit code 0 against compare/fixtures/fizzbuzz/claims.json. That envelope is the regression this stage exists to make impossible.\n\n";
impl_a_prompt += "Invariants: do not edit eval/ oracles or protected tests; do not touch compare/runs/ history; the model stays out of the loop while words run; Shen/preflight stays always-on (no --always-approve mode); keep Python 3.11 stdlib only. ";
impl_a_prompt += "After writing, run make test (or the closest runnable subset) and the cold e2e. status is shipped or blocked. files is what you created/changed. how_to_run is exact commands for the cold e2e AND `make test client-test`.";

let impl_a = agent(impl_a_prompt, #{
    label: "implement:kernel-cli",
    capability_mode: "all",
    output_schema: impl_schema,
});

let impl_b_prompt = "";
impl_b_prompt += "Implement Stage 0 PART B (delete the continue thicket, HTTP/UI, compare argv) in " + repo + ".\n";
impl_b_prompt += "PART A summary (untrusted): " + json_encode(summary_of(impl_a)) + "\n";
impl_b_prompt += "PART A how_to_run (untrusted): " + json_encode(how_to_run_of(impl_a)) + "\n\n";
impl_b_prompt += "If kernel.py or the livingdict CLI from PART A is absent, return status blocked — do not reimplement PART A.\n";
impl_b_prompt += "Do not edit eval/ or compare/runs/. files are living_dict-relative only.\n\n";
impl_b_prompt += "Build:\n";
impl_b_prompt += "1. Delete client/continue_policy.py, openresty/lua/continue.lua, client/web/src/continue.js, and every import/use. ";
impl_b_prompt += "Also delete or rewrite client/web/test/continue.test.mjs so `make client-test` is not red.\n";
impl_b_prompt += "2. POST /think becomes a single-episode client of the same kernel semantics (a reject is a 200 with {critic:'reject', errors:[...]}, not a 400 job death); the browser UI shows envelope artifacts and critic errors even on reject.\n";
impl_b_prompt += "3. Flip or delete the tests that freeze reject=>stop (client/test_livingdict.py names them).\n";
impl_b_prompt += "4. Stop writing GOAL.md/PROGRESS.md into the workspace from client/job.py ensure_job_files and the Lua persist_job/append_progress paths; delete the 'do not READ-FILE GOAL.md/PROGRESS.md' prompt rules — the files are no longer reachable by READ-FILE, so the trap is unrepresentable.\n";
impl_b_prompt += "5. Remove the model 'continue' field from the planner SYSTEM. Do not add new do-not rules. Do not say 'always emit USE-ARTIFACT'.\n";
impl_b_prompt += "6. compare.py's livingdict arm invokes the CLI as an argv peer of 'grok -p' (no HTTP, no server needed).\n";
impl_b_prompt += "After writing, run make test client-test. status is shipped or blocked. files is what you changed/deleted. how_to_run is exact commands.";

let impl_b = agent(impl_b_prompt, #{
    label: "implement:thicket",
    capability_mode: "all",
    output_schema: impl_schema,
});

let impl_ok = is_shipped(impl_a) && is_shipped(impl_b);
let impl_summary = summary_of(impl_a) + "\n\n" + summary_of(impl_b);
let how_to_run = how_to_run_of(impl_a) + "\n" + how_to_run_of(impl_b);
let extra_gaps = [];
let ga = files_gap(impl_a, "implement:kernel-cli");
let gb = files_gap(impl_b, "implement:thicket");
if ga != "" {
    extra_gaps.push(ga);
}
if gb != "" {
    extra_gaps.push(gb);
}
if impl_ok == false {
    log("Implementer did not ship both parts; verify will inspect the tree anyway");
}

phase("Verify");
log("Adversarial verify: loop semantics, write policy, runtime");

let impl_json = json_encode(impl_summary);
let run_json = json_encode(how_to_run);

let v_loop = "";
v_loop += "Adversarially verify the Stage 0 loop kernel in " + repo + ". Implementer summary (untrusted): " + impl_json + " ";
v_loop += "Read harness/src/livingdict/kernel.py, the CLI entry, and their tests. Set pass=true only if ALL hold, with quoted code as evidence: ";
v_loop += "(1) reconcile is pure and deterministic (no I/O, no clocks, no randomness) and a critic Reject leads to another planned episode, not a halt; ";
v_loop += "(2) the fingerprint covers program structure + artifact keys and excludes rationale/status, and a duplicate plan does not re-execute; ";
v_loop += "(3) cap exhaustion is a recorded halt with non-zero exit, never reported as success; ";
v_loop += "(4) client/continue_policy.py, openresty/lua/continue.lua, client/web/src/continue.js are gone (not stubbed) and nothing imports them; ";
v_loop += "(5) success requires goal_discharged from measured claims. Otherwise pass=false with concrete gaps and paths. Do not write files.";

let v_write = "";
v_write += "Adversarially verify 'artifacts are the write' in " + repo + ". ";
v_write += "Implementer how_to_run (untrusted): " + run_json + " ";
v_write += "Explore protected_hashes (untrusted, re-hash yourself): " + hashes_json + " ";
v_write += "Read preflight.py, host.py, policy.py, the artifact-install code path, and the planner SYSTEM in client/planner.py. Set pass=true only if, with evidence: ";
v_write += "(1) after Accept the host installs envelope.artifacts through the same glob/workspace policy as WRITE-FILE, idempotently; ";
v_write += "(2) an artifact key outside allowed_globs is Rejected even when the program never names it; ";
v_write += "(3) the historical fizzbuzz program (WRITE-FILE with no USE-ARTIFACT, artifacts present) is now legal and lands files — cite the regression test; ";
v_write += "(4) the planner SYSTEM does NOT say 'always emit USE-ARTIFACT' and gained no new do-not rules; ";
v_write += "(5) the eval six-word ABI is unchanged (no new host words) and eval/ oracles plus compare/runs/ history are untouched. ";
v_write += "This repo may have no commits — do NOT treat empty git diff as proof. Re-hash the protected paths and compare to explore hashes; also confirm compare/runs/20260815T191456Z files are unchanged. Do not write files.";

let v_run = "";
v_run += "Verify the Stage 0 runtime end to end in " + repo + ". ";
v_run += "Implementer how_to_run (untrusted, use these commands if they exist): " + run_json + " ";
v_run += "Run `make test client-test` (client-test is NOT part of `make test` — you must run both). ";
v_run += "Then run the cold e2e exactly as how_to_run says (the canned-planner fizzbuzz path) in a scratch workspace under $TMPDIR/ld-verify-loop-e2e, and verify: three product files on disk, run_dir/events.jsonl exists with episode.planned/critic/gates events in sequence, exit code 0, and GOAL.md/PROGRESS.md are NOT in the product tree. ";
v_run += "Then run the CLI with --max-turns 1 and a canned planner that emits a program with a forbidden write (e.g. .git/config) against a different scratch dir $TMPDIR/ld-verify-loop-forbid and confirm non-zero exit and no mutation. ";
v_run += "If a command cannot run, pass=false with gap 'runtime not exercised' and what is missing — do not fake a pass. evidence must include command output. Do not edit product files.";

fn run_skeptics(p_loop, p_write, p_run, schema) {
    let ro = parallel([
        #{
            prompt: p_loop,
            label: "verify:loop-semantics",
            capability_mode: "read-only",
            output_schema: schema,
        },
    ]);
    let verdicts = [];
    for r in ro {
        verdicts.push(r);
    }
    let w = agent(p_write, #{
        label: "verify:write-policy",
        capability_mode: "execute",
        output_schema: schema,
    });
    verdicts.push(w);
    let rt = agent(p_run, #{
        label: "verify:runtime",
        capability_mode: "execute",
        output_schema: schema,
    });
    verdicts.push(rt);
    verdicts
}

let verdicts = run_skeptics(v_loop, v_write, v_run, verdict_schema);
let scored = score_verdicts(verdicts);
let gaps = scored.gaps;
for g in extra_gaps {
    gaps.push(g);
}
let verified = scored.verified;
log(verified.to_string() + "/" + scored.usable.to_string() + " skeptics passed with evidence");

let need_fix = verified < 3 || impl_ok == false;
if need_fix {
    phase("Fix");
    log("Fixing gaps from verification, then re-running skeptics");
    let gaps_json = json_encode(gaps);
    let fix_a = "";
    fix_a += "Resume Stage 0 PART A (kernel+CLI) in " + repo + ". Verification gaps (untrusted until you reproduce):\n";
    fix_a += gaps_json;
    fix_a += "\nReproduce each gap that is yours, fix it, and re-run make test plus the cold fizzbuzz e2e. ";
    fix_a += "Do not touch eval oracles or compare/runs. Do not do PART B's deletions unless they block PART A tests. ";
    fix_a += "status is shipped or blocked. files are what you changed. how_to_run is exact commands.";
    let fix_a_opts = #{
        label: "fix:kernel-cli",
        capability_mode: "all",
        output_schema: impl_schema,
    };
    if impl_a != () && impl_a.agent_id != () {
        fix_a_opts.resume_from = impl_a.agent_id;
    }
    let fixed_a = agent(fix_a, fix_a_opts);

    let fix_b = "";
    fix_b += "Resume Stage 0 PART B (thicket) in " + repo + ". Verification gaps (untrusted until you reproduce):\n";
    fix_b += gaps_json;
    fix_b += "\nReproduce each gap that is yours, fix it, and re-run make test client-test. ";
    fix_b += "Do not touch eval oracles. status is shipped or blocked. files are what you changed. how_to_run is exact commands.";
    let fix_b_opts = #{
        label: "fix:thicket",
        capability_mode: "all",
        output_schema: impl_schema,
    };
    if impl_b != () && impl_b.agent_id != () {
        fix_b_opts.resume_from = impl_b.agent_id;
    }
    let fixed_b = agent(fix_b, fix_b_opts);

    if is_shipped(fixed_a) {
        impl_a = fixed_a;
    }
    if is_shipped(fixed_b) {
        impl_b = fixed_b;
    }
    impl_ok = is_shipped(impl_a) && is_shipped(impl_b);
    impl_summary = summary_of(impl_a) + "\n\n" + summary_of(impl_b);
    how_to_run = how_to_run_of(impl_a) + "\n" + how_to_run_of(impl_b);
    impl_json = json_encode(impl_summary);
    run_json = json_encode(how_to_run);

    v_loop = "";
    v_loop += "Adversarially verify the Stage 0 loop kernel in " + repo + ". Implementer summary (untrusted): " + impl_json + " ";
    v_loop += "Read harness/src/livingdict/kernel.py, the CLI entry, and their tests. Set pass=true only if ALL hold, with quoted code as evidence: ";
    v_loop += "(1) reconcile is pure and deterministic (no I/O, no clocks, no randomness) and a critic Reject leads to another planned episode, not a halt; ";
    v_loop += "(2) the fingerprint covers program structure + artifact keys and excludes rationale/status, and a duplicate plan does not re-execute; ";
    v_loop += "(3) cap exhaustion is a recorded halt with non-zero exit, never reported as success; ";
    v_loop += "(4) client/continue_policy.py, openresty/lua/continue.lua, client/web/src/continue.js are gone (not stubbed) and nothing imports them; ";
    v_loop += "(5) success requires goal_discharged from measured claims. Otherwise pass=false with concrete gaps and paths. Do not write files.";

    v_write = "";
    v_write += "Adversarially verify 'artifacts are the write' in " + repo + ". ";
    v_write += "Implementer how_to_run (untrusted): " + run_json + " ";
    v_write += "Explore protected_hashes (untrusted, re-hash yourself): " + hashes_json + " ";
    v_write += "Read preflight.py, host.py, policy.py, the artifact-install code path, and the planner SYSTEM in client/planner.py. Set pass=true only if, with evidence: ";
    v_write += "(1) after Accept the host installs envelope.artifacts through the same glob/workspace policy as WRITE-FILE, idempotently; ";
    v_write += "(2) an artifact key outside allowed_globs is Rejected even when the program never names it; ";
    v_write += "(3) the historical fizzbuzz program (WRITE-FILE with no USE-ARTIFACT, artifacts present) is now legal and lands files — cite the regression test; ";
    v_write += "(4) the planner SYSTEM does NOT say 'always emit USE-ARTIFACT' and gained no new do-not rules; ";
    v_write += "(5) the eval six-word ABI is unchanged (no new host words) and eval/ oracles plus compare/runs/ history are untouched. ";
    v_write += "This repo may have no commits — do NOT treat empty git diff as proof. Re-hash the protected paths and compare to explore hashes; also confirm compare/runs/20260815T191456Z files are unchanged. Do not write files.";

    v_run = "";
    v_run += "Verify the Stage 0 runtime end to end in " + repo + ". ";
    v_run += "Implementer how_to_run (untrusted, use these commands if they exist): " + run_json + " ";
    v_run += "Run `make test client-test` (client-test is NOT part of `make test` — you must run both). ";
    v_run += "Then run the cold e2e exactly as how_to_run says (the canned-planner fizzbuzz path) in a scratch workspace under $TMPDIR/ld-verify-loop-e2e, and verify: three product files on disk, run_dir/events.jsonl exists with episode.planned/critic/gates events in sequence, exit code 0, and GOAL.md/PROGRESS.md are NOT in the product tree. ";
    v_run += "Then run the CLI with --max-turns 1 and a canned planner that emits a program with a forbidden write (e.g. .git/config) against a different scratch dir $TMPDIR/ld-verify-loop-forbid and confirm non-zero exit and no mutation. ";
    v_run += "If a command cannot run, pass=false with gap 'runtime not exercised' and what is missing — do not fake a pass. evidence must include command output. Do not edit product files.";

    phase("Verify");
    log("Re-running skeptics after fix");
    verdicts = run_skeptics(v_loop, v_write, v_run, verdict_schema);
    scored = score_verdicts(verdicts);
    gaps = scored.gaps;
    ga = files_gap(impl_a, "implement:kernel-cli");
    gb = files_gap(impl_b, "implement:thicket");
    if ga != "" {
        gaps.push(ga);
    }
    if gb != "" {
        gaps.push(gb);
    }
    verified = scored.verified;
    log(verified.to_string() + "/" + scored.usable.to_string() + " skeptics passed after fix");
}

let shipped = impl_ok && verified == 3;
let report = "";
if shipped {
    report += "# Stage 0: loop kernel\n\n";
} else {
    report += "# FAILED: Stage 0 loop kernel did not ship\n\n";
}
report += "Repo: " + repo + "\nScud reference: " + scud + "\n";
report += "shipped: " + shipped.to_string() + "\n\n";
report += "## Implementer\n\n" + impl_summary + "\n\n";
report += "## Verification\n\n";
report += verified.to_string() + " of 3 skeptics passed with evidence.\n\n";
if gaps.len() > 0 {
    report += "Gaps:\n";
    report += clip_gaps(gaps);
}
let report_path = write_scratch_file("loop-kernel.md", report);
complete(#{
    path: report_path,
    repo: repo,
    shipped: shipped,
    verified: verified,
    skeptics: 3,
    implement_ok: impl_ok,
    remaining_gaps: gaps.len(),
});
