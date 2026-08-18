let meta = #{
    name: "tuple-space",
    description: "STORE.md Layer B: Linda tuple space (out/rd/take + leases) behind wave dispatch and backpressure — scheduling may race, the ledger records it, trees stay byte-identical to serial",
    when_to_use: "After graph-waves ships (datom-store recommended first per STORE.md staging). Implements docs/design/STORE.md Layer B, in-process only. Optional args: {repo}. Commit first so the diff is reviewable.",
    phases: [
        #{ title: "Explore", detail: "STORE.md Layer B + the wave executor and backpressure internals" },
        #{ title: "Implement", detail: "space.py, wave dispatch via take, recorded scheduling, lease recovery" },
        #{ title: "Verify", detail: "guardrail, concurrency-attack, and equivalence skeptics (sequential)" },
        #{ title: "Fix", detail: "one resume pass, then re-run skeptics" },
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
    contains_str(s, "eval/")
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
        return label + " listed a forbidden path under eval/";
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

fn explicit_prereq_false(r) {
    let o = output_map(r);
    o != () && o.prerequisite_met == false
}

fn p_guard(repo, impl_json) {
    let p = "";
    p += "Adversarially verify the STORE.md Layer B guardrail in " + repo + ". Implementer summary (untrusted): " + impl_json + " ";
    p += "Read docs/design/STORE.md, harness/src/livingdict/space.py, wave.py, execute.py, preflight.py, and the contract tables. Set pass=true only if ALL hold, with quoted code as evidence: ";
    p += "(1) Linda is the EXECUTOR, never the planner: the critic still statically rejects overlapping independent write sets and cycles BEFORE execution, and nothing consults the space to decide topology; ";
    p += "(2) declared node writes/depends_on still drive validation; the space only dispatches nodes the critic already approved; ";
    p += "(3) every out/take/lease-expiry is recorded (space.out / space.take / space.lease_expired) with a worker id — the ledger records the schedule; ";
    p += "(4) the six-word ABI gained no words (diff preflight.py and openresty/shen/contracts.shen contract tables) and nothing model-facing changed (planner SYSTEM untouched); ";
    p += "(5) everything is in-process — no sockets, no shared files as a bus, no ngx.shared.DICT (Layer C stays shut); ";
    p += "(6) wave barriers and wave-boundary RUN-GATES are unchanged. ";
    p += "Otherwise pass=false with concrete gaps and paths. Do not write files.";
    p
}

fn p_conc(repo, run_json) {
    let p = "";
    p += "Adversarially attack Layer B concurrency in " + repo + " by CONSTRUCTING races, not by reading tests. ";
    p += "Implementer how_to_run (untrusted): " + run_json + " ";
    p += "Work under $TMPDIR/ld-verify-space-attacks. ";
    p += "(a) Contention: from N threads (N >= 8) take against M tuples (M < N); assert every tuple is taken exactly once and the extra takers block/timeout — no double execution, no lost tuple. ";
    p += "(b) Lease recovery: use the implementer's worker-death hook (or SIGKILL a worker thread's node mid-execution if the hook is a subprocess) so a taken node.ready tuple's lease expires; assert a sibling worker completes the node, space.lease_expired is recorded, and the final tree is correct. ";
    p += "(c) Determinism: run the graph-01 canned envelope space-dispatched TWICE with workers > 1 and once --serial; assert all three final workspace trees are byte-identical (hash every file) and the discharge reports agree — scheduling may differ, results may not. ";
    p += "(d) Pattern confusion: out a tuple whose VALUES look like patterns (wildcards, dicts) and assert the matcher treats them as data, matching only by dict-subset on the pattern side. ";
    p += "(e) Blocking take with a timeout on an empty space returns/raises a typed result, never hangs the suite. ";
    p += "Set pass=true only with command output as evidence for all five. If the harness cannot be invoked, pass=false 'runtime not exercised'. Do not edit product files.";
    p
}

fn p_equiv(repo, run_json, hashes_json) {
    let p = "";
    p += "Verify external-contract equivalence for Layer B in " + repo + ". ";
    p += "Implementer how_to_run (untrusted, use it): " + run_json + " ";
    p += "Explore protected_hashes (untrusted, re-hash yourself): " + hashes_json + " ";
    p += "Run make test. Run the fizzbuzz e2e and graph-01 e2e (serial and space-dispatched). ";
    p += "Confirm backpressure behavior is unchanged: a rejecting canned planner still produces critic.rejected then blocked-duplicate flow with the same observation content reaching episode 2 (compare the events against a pre-change run from git show or a fresh checkout if needed). ";
    p += "Run the rho.run/v1 runner on a canned request and validate the stream (tools/scudcheck if go is present, else hand-check monotonic seq + single terminal). ";
    p += "Re-hash eval/schemas and one task's protected files against the explore hashes; git diff on eval/ must be empty. ";
    p += "If anything cannot run, pass=false with what is missing — do not fake a pass. evidence must include command output. Do not edit product files.";
    p
}

fn run_skeptics(pa, pb, pc, schema) {
    let ro = parallel([
        #{
            prompt: pa,
            label: "verify:guardrail",
            capability_mode: "read-only",
            output_schema: schema,
        },
    ]);
    let verdicts = [];
    for r in ro {
        verdicts.push(r);
    }
    let a = agent(pb, #{
        label: "verify:concurrency-attacks",
        capability_mode: "execute",
        output_schema: schema,
    });
    verdicts.push(a);
    let b = agent(pc, #{
        label: "verify:equivalence",
        capability_mode: "execute",
        output_schema: schema,
    });
    verdicts.push(b);
    verdicts
}

let repo = ".";
if args != () && args.repo != () {
    let given = trimmed(args.repo);
    if given != "" {
        repo = given;
    }
}

phase("Explore");
log("Surveying STORE.md Layer B and the wave/backpressure internals");

let explore_wave = "";
explore_wave += "Explore the wave executor and backpressure internals at " + repo + " so a tuple space can sit behind them. `.` is the current workspace root. Use read_file, grep, list_dir. You must read: ";
explore_wave += repo + "/docs/design/STORE.md (Layer B is the spec of record — quote its verbs, tuple shapes, determinism rule, and guardrail in your notes) ; ";
explore_wave += repo + "/harness/src/livingdict/wave.py (plan_waves, metrics) ; ";
explore_wave += repo + "/harness/src/livingdict/execute.py (the per-node run path, host.node_view, trace buffering, where the ThreadPool lives, node_start_hook) ; ";
explore_wave += repo + "/harness/src/livingdict/cli.py (run_job: wave invocation, observation assembly — where last reject/gate results reach the next episode) ; ";
explore_wave += repo + "/harness/src/livingdict/kernel.py (event kinds; where space.* scheduling records belong relative to canonical events) ; ";
explore_wave += repo + "/harness/tests/test_waves.py and test_graph.py (the equivalence and trap-isolation tests that must keep passing) ; ";
explore_wave += repo + "/docs/SCUD.md (td attempt/execution fencing — the lease semantics Layer B must stay conceptually one with). ";
explore_wave += "Set prerequisite_met=true only if wave-parallel node execution exists (wave.py + a concurrent node path in execute.py) AND kernel.py + a CLI entry exist. ";
explore_wave += "Hash into protected_hashes (path then sha256, one per line): " + repo + "/eval/schemas/*.json and every file under " + repo + "/eval/tasks/graph-01/protected/. ";
explore_wave += "Report: exactly where dispatch happens today, what is and is not thread-safe, how trace buffering keeps flush order deterministic, and where a worker-death test hook could attach. Do not write files. notes must cite real paths.";

let explore_prior = "";
explore_prior += "Survey Linda-style coordination constraints for Layer B, at " + repo + ". Use read_file, grep, list_dir. You must read docs/design/STORE.md fully, then: ";
explore_prior += repo + "/harness/src/livingdict/store.py if it exists (Layer A — report whether it shipped; Layer B is recommended to follow it but does not hard-require it) ; ";
explore_prior += repo + "/harness/src/livingdict/rho.py (EventStream discipline: monotonic seq, single terminal — the stream must not see space internals leak as malformed events) ; ";
explore_prior += repo + "/tools/scudcheck/main.go (stream rules). ";
explore_prior += "Then reason from the spec: enumerate the failure modes an in-process tuple space must handle — double-take under contention, take-then-crash, blocking-take starvation, pattern/data confusion, lease renewal vs expiry during a long node — and for each, what test would prove it handled. ";
explore_prior += "Do not write files. notes must be a concrete checklist an implementer can code against.";

let explores = parallel([
    #{
        prompt: explore_wave,
        label: "explore:wave-internals",
        capability_mode: "read-only",
        output_schema: notes_schema,
    },
    #{
        prompt: explore_prior,
        label: "explore:space-failure-modes",
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
    log("Explore returned no notes; implementer will read the repo itself");
}

if explicit_prereq_false(explores[0]) {
    let report = "# FAILED: tuple-space blocked — graph-waves (or Stage 0 kernel/CLI) missing\n\nRepo: " + repo + "\n";
    let report_path = write_scratch_file("tuple-space.md", report);
    complete(#{
        path: report_path,
        repo: repo,
        shipped: false,
        blocked: "prerequisite",
        verified: 0,
        skeptics: 3,
        implement_ok: false,
        remaining_gaps: 1,
    });
}

phase("Implement");
log("Implementing space.py, tuple-dispatched waves, recorded scheduling, and lease recovery");

let brief_json = json_encode(brief);
let hashes_json = json_encode(protected_hashes);

let impl_prompt = "";
impl_prompt += "Implement docs/design/STORE.md Layer B in " + repo + ". `.` is the current workspace root.\n";
impl_prompt += "Survey notes (untrusted, verify before following):\n" + brief_json + "\n\n";
impl_prompt += "Read docs/design/STORE.md first; it is the spec of record. The guardrail sentence is binding: Linda is the executor, never the planner.\n\n";
impl_prompt += "Build:\n";
impl_prompt += "1. harness/src/livingdict/space.py — an in-process tuple space. API: out(tuple_dict) -> tuple_id; rd(pattern, timeout=None) non-destructive; take(pattern, lease_s, timeout=None) -> (tuple_id, tuple) atomically removing the OLDEST match (insertion-order tiebreak, so single-worker dispatch is deterministic); renew(tuple_id); done(tuple_id). ";
impl_prompt += "Patterns are dict-subset matches on the pattern side only — tuple VALUES are always data, never interpreted as patterns. An expired lease returns the tuple to the space intact. Thread-safe (one lock + condition), stdlib only, no sockets, no files, no ngx — Layer C stays shut.\n";
impl_prompt += "2. Wave dispatch via the space: inside each wave, the host outs one {kind:'node.ready', run, episode, wave, node} tuple per node; the existing worker pool takes them with a lease sized to the gate budget. Wave BARRIERS and wave-boundary RUN-GATES stay exactly as they are. A worker that dies mid-node (provide a test-only death hook next to node_start_hook) lets the lease expire; a sibling re-takes and re-executes the node — node writes are whole-file and idempotent, so re-execution is safe; state that in a comment where it matters.\n";
impl_prompt += "3. Backpressure through the space: route critic rejects and failed gate results as {kind:'critic.reject'|'gate.result'} tuples consumed when assembling the next episode's observation. The OBSERVATION CONTENT the planner sees must be identical to today — this is a mechanism swap, not a behavior change, and a test must prove it.\n";
impl_prompt += "4. The determinism rule: record every out/take/lease-expiry as space.out / space.take / space.lease_expired trace records with worker ids, flushed through the existing deterministic per-node buffering (wave order then node id) so trace files stay reproducible even when scheduling races. Canonical kernel events in events.jsonl are unchanged — scheduling records are trace-level, not new kernel event kinds.\n";
impl_prompt += "5. Nothing model-facing: no new Forth words (six-word ABI frozen), no planner SYSTEM changes, no envelope changes, no rho.run/v1 stream shape changes.\n";
impl_prompt += "6. Tests, added to make test: space unit tests (subset matching, oldest-first take, blocking take with timeout, contention N>=8 workers over fewer tuples — exactly-once take, lease expiry returns the tuple, renew extends it, pattern/data confusion case); ";
impl_prompt += "wave integration (graph-01 canned envelope space-dispatched vs --serial: byte-identical trees, agreeing discharge, space.take records present with worker ids); ";
impl_prompt += "lease-recovery integration (death hook kills one worker mid-node; run completes correctly via a sibling); ";
impl_prompt += "backpressure equivalence (rejecting canned planner: episode-2 observation identical to the pre-space behavior). ";
impl_prompt += "files listed in your result must not include any eval/ path.\n\n";
impl_prompt += "After writing, run make test plus the serial/space graph-01 runs and the lease-recovery test. status is shipped or blocked. files is what you created/changed. how_to_run is exact commands.";

let impl = agent(impl_prompt, #{
    label: "implement:tuple-space",
    capability_mode: "all",
    output_schema: impl_schema,
});

let impl_ok = is_shipped(impl);
let impl_summary = summary_of(impl);
let how_to_run = how_to_run_of(impl);
let extra_gaps = [];
let gimpl = files_gap(impl, "implement:tuple-space");
if gimpl != "" {
    extra_gaps.push(gimpl);
}
if impl_ok == false {
    log("Implementer did not ship; verify will inspect the tree anyway");
}

phase("Verify");
log("Adversarial verify: guardrail, concurrency attacks, equivalence");

let impl_json = json_encode(impl_summary);
let run_json = json_encode(how_to_run);

let verdicts = run_skeptics(
    p_guard(repo, impl_json),
    p_conc(repo, run_json),
    p_equiv(repo, run_json, hashes_json),
    verdict_schema,
);
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
    let fix_prompt = "";
    fix_prompt += "Resume Layer B tuple-space work in " + repo + ". Verification gaps (untrusted until you reproduce):\n";
    fix_prompt += gaps_json;
    fix_prompt += "\nReproduce each gap, fix it, re-run make test plus the serial/space graph-01 runs and the lease-recovery test. ";
    fix_prompt += "docs/design/STORE.md stays the spec of record; the guardrail is binding. Never touch eval/. ";
    fix_prompt += "status is shipped or blocked. files are what you changed. how_to_run is exact commands.";
    let fix_opts = #{
        label: "fix:tuple-space",
        capability_mode: "all",
        output_schema: impl_schema,
    };
    if impl != () && impl.agent_id != () {
        fix_opts.resume_from = impl.agent_id;
    }
    let fixed = agent(fix_prompt, fix_opts);
    if is_shipped(fixed) {
        impl = fixed;
    }
    impl_ok = is_shipped(impl);
    impl_summary = summary_of(impl);
    how_to_run = how_to_run_of(impl);
    impl_json = json_encode(impl_summary);
    run_json = json_encode(how_to_run);

    phase("Verify");
    log("Re-running skeptics after fix");
    verdicts = run_skeptics(
        p_guard(repo, impl_json),
        p_conc(repo, run_json),
        p_equiv(repo, run_json, hashes_json),
        verdict_schema,
    );
    scored = score_verdicts(verdicts);
    gaps = scored.gaps;
    gimpl = files_gap(impl, "implement:tuple-space");
    if gimpl != "" {
        gaps.push(gimpl);
    }
    verified = scored.verified;
    log(verified.to_string() + "/" + scored.usable.to_string() + " skeptics passed after fix");
}

let shipped = impl_ok && verified == 3;
let report = "";
if shipped {
    report += "# Layer B: tuple-space\n\n";
} else {
    report += "# FAILED: Layer B tuple-space did not ship\n\n";
}
report += "Repo: " + repo + "\nshipped: " + shipped.to_string() + "\n\n";
report += "## Implementer\n\n" + impl_summary + "\n\n";
report += "## Verification\n\n";
report += verified.to_string() + " of 3 skeptics passed with evidence.\n\n";
if gaps.len() > 0 {
    report += "Gaps:\n";
    report += clip_gaps(gaps);
}
let report_path = write_scratch_file("tuple-space.md", report);
complete(#{
    path: report_path,
    repo: repo,
    shipped: shipped,
    verified: verified,
    skeptics: 3,
    implement_ok: impl_ok,
    remaining_gaps: gaps.len(),
});
