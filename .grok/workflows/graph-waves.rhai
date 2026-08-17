let meta = #{
    name: "graph-waves",
    description: "Stage 2: wave-parallel node execution — independent nodes with disjoint declared write sets run concurrently, gates at wave boundaries, conflicts unrepresentable, result byte-identical to serial",
    when_to_use: "After graph-critic ships. Adds Kahn-wave scheduling to the Python CLI body, per-node policy confinement, and the hypothesis-6 concurrency/conflict measurements. Optional args: {repo, scud}. Commit first so the stage diff is reviewable.",
    phases: [
        #{ title: "Explore", detail: "node execution path, per-node policy, scud wave-backpressure lesson" },
        #{ title: "Implement", detail: "wave scheduler, per-node VMs, wave-boundary gates, metrics" },
        #{ title: "Verify", detail: "equivalence, safety, and concurrency skeptics (sequential)" },
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
log("Surveying the node execution path and scud's wave scheduling");

let explore_body = "";
explore_body += "Explore the Stage 1 node execution path at " + repo + " so it can be made wave-parallel. Use read_file, grep, list_dir. ";
explore_body += "`.` is the current workspace root. You must read: the node execution code in harness/src/livingdict/ (execute.py / kernel.py / wherever graph-critic put topological node running), ";
explore_body += "harness/src/livingdict/host.py (CapabilityHost state: is it safe to share across threads? where are snapshots and receipts computed?), ";
explore_body += "harness/src/livingdict/forth.py (ForthVM per-node instantiation cost and shared state), ";
explore_body += "harness/src/livingdict/policy.py and preflight.py (the overlapping-write-set Reject from Stage 1 — quote it), ";
explore_body += "harness/src/livingdict/gates.py (RUN-GATES cost; where wave-boundary gating would hook), ";
explore_body += "harness/src/livingdict/trace.py (is trace emission append-safe under concurrency?), ";
explore_body += "and " + repo + "/eval/tasks/graph-01/repo/task_graph.json + eval/docs/EVALUATION.md (hypothesis 6, concurrency and conflict endpoints). ";
explore_body += "Set prerequisite_met=true only if Stage 1 has landed: envelope nodes field, overlapping-write-set Reject in preflight, and serial topological node execution. Set it false if any of those is missing — do not guess, do not implement Stage 1 here. ";
explore_body += "Hash into protected_hashes (path then sha256, one per line): eval/tasks/graph-01/repo/task_graph.json and eval/tasks/graph-01/protected/* . This repo may have no commits — empty git diff is not proof. ";
explore_body += "Report exactly what is and is not thread-safe today, and where the serial node loop lives. Do not write files. notes must cite real paths.";

let explore_scud = "";
explore_scud += "Explore scud's wave scheduling and its lessons at " + scud + ". Use read_file, grep, list_dir. You must read: ";
explore_scud += scud + "/pkg/wave/planner.go (Kahn waves; in-degree within the given set; CircularDeps) ; ";
explore_scud += scud + "/pkg/swarm/executor.go (wave 0 only, rounds with errgroup limit, re-reading state after runs) ; ";
explore_scud += scud + "/pkg/swarm/backpressure.go (validation runs AFTER the whole wave, a clear pass/fail gate between waves — the documented lesson is that this is simpler than per-call validation) ; ";
explore_scud += scud + "/v2/graph/graph.go (Waves(completed) is deterministic and returns NO partial plan on a cycle). ";
explore_scud += "Report the wave semantics worth copying and the failure modes to avoid (e.g. nondeterministic ordering, partial plans on cycles). Do not write files.";

let explores = parallel([
    #{
        prompt: explore_body,
        label: "explore:node-exec-path",
        capability_mode: "read-only",
        output_schema: notes_schema,
    },
    #{
        prompt: explore_scud,
        label: "explore:scud-waves",
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

if explicit_prereq_false(explores[0]) {
    let report = "# FAILED: Stage 2 blocked — Stage 1 graph-critic missing\n\nRepo: " + repo + "\n";
    let report_path = write_scratch_file("graph-waves.md", report);
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
log("Implementing wave-parallel node execution with wave-boundary gates");

let brief_json = json_encode(brief);
let hashes_json = json_encode(protected_hashes);

let impl_prompt = "";
impl_prompt += "Implement Stage 2 (graph-waves) of the Living Dictionary redesign in " + repo + ".\n";
impl_prompt += "`.` is the current workspace root. Survey notes (untrusted, verify before following):\n" + brief_json + "\n\n";
impl_prompt += "Prerequisite: Stage 1 (envelope nodes + graph-aware preflight + serial topological execution + graph.node.* events). If absent, return status blocked — do not build it here.\n\n";
impl_prompt += "Safety precondition you may rely on and must NOT weaken: the Stage 1 critic already rejects two nodes with overlapping write sets unless one transitively depends on the other. ";
impl_prompt += "Therefore nodes inside one wave have pairwise-disjoint declared writes BY CONSTRUCTION, and write conflicts are unrepresentable, not detected. If you find that Reject missing or bypassable, stop and return status blocked naming it.\n\n";
impl_prompt += "Build, in the Python CLI body only (OpenResty stays serial; document that in openresty/README.md):\n";
impl_prompt += "1. Wave planner: partition accepted nodes into Kahn levels (wave = all nodes whose deps are satisfied by prior waves), deterministic order inside a wave (lexicographic by node id). A cycle at this layer is an internal error (the critic already rejected it) — fail closed, never emit a partial plan (scud v2 Waves lesson).\n";
impl_prompt += "2. Wave executor: run each wave's nodes concurrently (concurrent.futures ThreadPoolExecutor; default max workers = min(wave width, 4), flag --wave-workers N; --serial forces width 1 and must remain available). ";
impl_prompt += "Each node gets its OWN ForthVM and its own PathPolicy narrowed to that node's writes, over the shared workspace. Reads are unrestricted. ";
impl_prompt += "If CapabilityHost carries per-run mutable state (snapshots, effect lists, trace handles), give each node an isolated host view and merge results deterministically afterward — by node id, never by completion time.\n";
impl_prompt += "3. Trace under concurrency: graph.node.start/finish keep wall-clock timestamps (they are the overlap evidence) but the events.jsonl / trace.jsonl APPEND ORDER must be deterministic: buffer per node, flush in wave order then node-id order after each wave. The scorer only counts, so buffering is safe.\n";
impl_prompt += "4. Wave-boundary gates (scud's documented lesson: validate AFTER the wave, not per call): after each wave completes, host runs RUN-GATES once; a wave whose gates regress records the failure and reconcile decides (this is an episode-level event, not a mid-wave abort). Final discharge after the last wave as today.\n";
impl_prompt += "5. A node whose program traps: complete the wave (other nodes are independent by construction), record execution.trap with the node id, do not start dependent later waves for that node's dependents; reconcile sees the failure as backpressure, exactly like a critic reject.\n";
impl_prompt += "6. Metrics for hypothesis 6, written into the receipt and the run summary: wave_count, max_wave_width, nodes_parallel (nodes that ran with at least one overlapping-timestamp sibling), conflicts (must be structurally 0), wall_ms_serial_estimate (sum of node durations) vs wall_ms_actual.\n";
impl_prompt += "7. Tests, added to make test: ";
impl_prompt += "(a) EQUIVALENCE: run the graph-01 canned envelope --serial and with --wave-workers 4; assert the final workspace trees are byte-identical (hash every file) and the discharge reports agree; ";
impl_prompt += "(b) CONCURRENCY: with 3 independent nodes each executing a program that takes measurable time (e.g. a RUN-GATES-free node set against a fixture whose node programs write then read), assert overlapping start/finish intervals when workers > 1 — if node programs are too fast to overlap reliably, inject latency via a test-only host hook, never a new Forth word; ";
impl_prompt += "(c) SAFETY: attempt to construct a mid-wave overlapping write by handing the executor a doctored post-critic plan and assert the per-node PathPolicy still refuses the out-of-set write at the host layer (defense in depth below the critic); ";
impl_prompt += "(d) TRAP ISOLATION: one node traps, siblings complete, dependents do not run, exit is the backpressure path not a crash. ";
impl_prompt += "Never edit eval oracles, protected tests, or task_graph.json. files must not include any eval/ path.\n\n";
impl_prompt += "After writing, run make test and both graph-01 runs (serial and waved), and paste the metrics line. status is shipped or blocked. files is what you created/changed. how_to_run is exact commands.";

let impl = agent(impl_prompt, #{
    label: "implement:graph-waves",
    capability_mode: "all",
    output_schema: impl_schema,
});

let impl_ok = is_shipped(impl);
let impl_summary = summary_of(impl);
let how_to_run = how_to_run_of(impl);
let extra_gaps = [];
let gimpl = files_gap(impl, "implement:graph-waves");
if gimpl != "" {
    extra_gaps.push(gimpl);
}
if impl_ok == false {
    log("Implementer did not ship; verify will inspect the tree anyway");
}

phase("Verify");
log("Adversarial verify sequentially: safety, then equivalence, then concurrency/make test");

let impl_json = json_encode(impl_summary);
let run_json = json_encode(how_to_run);

let p_safety = "";
p_safety += "Adversarially verify wave safety in " + repo + " by attacking it. ";
p_safety += "Implementer how_to_run (untrusted): " + run_json + " ";
p_safety += "Use a scratch dir $TMPDIR/ld-verify-wave-safety. Do not run make test (a later skeptic does). ";
p_safety += "(1) Confirm in preflight tests or by constructing the envelope that overlapping independent write sets are rejected BEFORE execution. ";
p_safety += "(2) Bypass the critic deliberately: feed the executor a post-critic plan (test hook or direct call) where two same-wave nodes write one path, and confirm the per-node PathPolicy refuses at the host layer with no partial mutation of that path. ";
p_safety += "(3) Confirm a trapping node cannot poison siblings: its trap is recorded, siblings' writes land, dependents are skipped. ";
p_safety += "(4) Read the wave planner and confirm a cycle fails closed with no partial plan. ";
p_safety += "pass=true only with all four evidenced by command output or quoted code. Do not edit product files.";

let p_equiv = "";
p_equiv += "Adversarially verify serial/parallel equivalence in " + repo + ". Implementer summary (untrusted): " + impl_json + " ";
p_equiv += "how_to_run (untrusted): " + run_json + " ";
p_equiv += "Run the graph-01 canned envelope twice yourself in isolated scratch trees: $TMPDIR/ld-verify-wave-serial (with --serial) and $TMPDIR/ld-verify-wave-waved (--wave-workers 4). ";
p_equiv += "Hash every file in both final workspaces and diff the discharge reports. Then read the trace-merge code and confirm event append order is deterministic (buffered by node, flushed in wave order), not completion-time order. ";
p_equiv += "Do not run make test. pass=true only with byte-identical trees, agreeing discharge, and the buffering code quoted. If you cannot run it, pass=false 'runtime not exercised'. Do not edit product files.";

let p_conc = "";
p_conc += "Verify real concurrency and the hypothesis-6 metrics in " + repo + ". ";
p_conc += "how_to_run (untrusted): " + run_json + " ";
p_conc += "Explore protected_hashes (untrusted, re-hash yourself): " + hashes_json + " ";
p_conc += "Run make test, then the concurrency test and the waved graph-01 run. Quote from the receipt/summary: wave_count, max_wave_width, nodes_parallel, conflicts (must be 0), and the serial-estimate vs actual wall numbers. ";
p_conc += "Confirm graph.node.start/finish timestamps for at least two nodes in one wave genuinely overlap in the waved run. ";
p_conc += "Confirm OpenResty was left serial and its README says so. ";
p_conc += "This repo may have no commits — do NOT treat empty git diff as proof. Re-hash graph-01 task_graph.json and protected files. ";
p_conc += "If anything cannot run, pass=false with what is missing — do not fake a pass. evidence must include command output. Do not edit product files.";

fn run_skeptics(ps, pe, pc, schema) {
    let verdicts = [];
    let a = agent(ps, #{
        label: "verify:safety-attacks",
        capability_mode: "execute",
        output_schema: schema,
    });
    verdicts.push(a);
    let b = agent(pe, #{
        label: "verify:equivalence",
        capability_mode: "execute",
        output_schema: schema,
    });
    verdicts.push(b);
    let c = agent(pc, #{
        label: "verify:concurrency-metrics",
        capability_mode: "execute",
        output_schema: schema,
    });
    verdicts.push(c);
    verdicts
}

let verdicts = run_skeptics(p_safety, p_equiv, p_conc, verdict_schema);
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
    fix_prompt += "Resume Stage 2 graph-waves work in " + repo + ". Verification gaps (untrusted until you reproduce):\n";
    fix_prompt += gaps_json;
    fix_prompt += "\nReproduce each gap, fix it, re-run make test plus the serial and waved graph-01 runs. ";
    fix_prompt += "Never edit eval oracles. Do not reimplement Stage 1. status is shipped or blocked. files are what you changed. how_to_run is exact commands.";
    let fix_opts = #{
        label: "fix:graph-waves",
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

    p_safety = "";
    p_safety += "Adversarially verify wave safety in " + repo + " by attacking it. ";
    p_safety += "Implementer how_to_run (untrusted): " + run_json + " ";
    p_safety += "Use a scratch dir $TMPDIR/ld-verify-wave-safety. Do not run make test (a later skeptic does). ";
    p_safety += "(1) Confirm in preflight tests or by constructing the envelope that overlapping independent write sets are rejected BEFORE execution. ";
    p_safety += "(2) Bypass the critic deliberately: feed the executor a post-critic plan (test hook or direct call) where two same-wave nodes write one path, and confirm the per-node PathPolicy refuses at the host layer with no partial mutation of that path. ";
    p_safety += "(3) Confirm a trapping node cannot poison siblings: its trap is recorded, siblings' writes land, dependents are skipped. ";
    p_safety += "(4) Read the wave planner and confirm a cycle fails closed with no partial plan. ";
    p_safety += "pass=true only with all four evidenced by command output or quoted code. Do not edit product files.";

    p_equiv = "";
    p_equiv += "Adversarially verify serial/parallel equivalence in " + repo + ". Implementer summary (untrusted): " + impl_json + " ";
    p_equiv += "how_to_run (untrusted): " + run_json + " ";
    p_equiv += "Run the graph-01 canned envelope twice yourself in isolated scratch trees: $TMPDIR/ld-verify-wave-serial (with --serial) and $TMPDIR/ld-verify-wave-waved (--wave-workers 4). ";
    p_equiv += "Hash every file in both final workspaces and diff the discharge reports. Then read the trace-merge code and confirm event append order is deterministic (buffered by node, flushed in wave order), not completion-time order. ";
    p_equiv += "Do not run make test. pass=true only with byte-identical trees, agreeing discharge, and the buffering code quoted. If you cannot run it, pass=false 'runtime not exercised'. Do not edit product files.";

    p_conc = "";
    p_conc += "Verify real concurrency and the hypothesis-6 metrics in " + repo + ". ";
    p_conc += "how_to_run (untrusted): " + run_json + " ";
    p_conc += "Explore protected_hashes (untrusted, re-hash yourself): " + hashes_json + " ";
    p_conc += "Run make test, then the concurrency test and the waved graph-01 run. Quote from the receipt/summary: wave_count, max_wave_width, nodes_parallel, conflicts (must be 0), and the serial-estimate vs actual wall numbers. ";
    p_conc += "Confirm graph.node.start/finish timestamps for at least two nodes in one wave genuinely overlap in the waved run. ";
    p_conc += "Confirm OpenResty was left serial and its README says so. ";
    p_conc += "This repo may have no commits — do NOT treat empty git diff as proof. Re-hash graph-01 task_graph.json and protected files. ";
    p_conc += "If anything cannot run, pass=false with what is missing — do not fake a pass. evidence must include command output. Do not edit product files.";

    phase("Verify");
    log("Re-running skeptics after fix");
    verdicts = run_skeptics(p_safety, p_equiv, p_conc, verdict_schema);
    scored = score_verdicts(verdicts);
    gaps = scored.gaps;
    gimpl = files_gap(impl, "implement:graph-waves");
    if gimpl != "" {
        gaps.push(gimpl);
    }
    verified = scored.verified;
    log(verified.to_string() + "/" + scored.usable.to_string() + " skeptics passed after fix");
}

let shipped = impl_ok && verified == 3;
let report = "";
if shipped {
    report += "# Stage 2: graph-waves\n\n";
} else {
    report += "# FAILED: Stage 2 graph-waves did not ship\n\n";
}
report += "Repo: " + repo + "\nScud reference: " + scud + "\nshipped: " + shipped.to_string() + "\n\n";
report += "## Implementer\n\n" + impl_summary + "\n\n";
report += "## Verification\n\n";
report += verified.to_string() + " of 3 skeptics passed with evidence.\n\n";
if gaps.len() > 0 {
    report += "Gaps:\n";
    report += clip_gaps(gaps);
}
let report_path = write_scratch_file("graph-waves.md", report);
complete(#{
    path: report_path,
    repo: repo,
    shipped: shipped,
    verified: verified,
    skeptics: 3,
    implement_ok: impl_ok,
    remaining_gaps: gaps.len(),
});
