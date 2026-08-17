let meta = #{
    name: "graph-critic",
    description: "Stage 1: the graph enters the envelope, the critic, and the trace — node write-sets and dependency order statically checked before any I/O; graph.node.* events the eval already counts",
    when_to_use: "After loop-kernel ships. Adds envelope nodes {id, writes, depends_on, program}, graph-aware preflight rejection, and graph.node.start/finish trace events; proves it on eval graph-01. Optional args: {repo}. Commit first so the stage diff is reviewable.",
    phases: [
        #{ title: "Explore", detail: "eval graph hooks + current envelope/critic/trace surfaces" },
        #{ title: "Implement", detail: "envelope nodes, topological execution, graph checks in preflight, node events" },
        #{ title: "Verify", detail: "graph-semantics, critic-rejection, and eval-run skeptics" },
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
if args != () && args.repo != () {
    let given = trimmed(args.repo);
    if given != "" {
        repo = given;
    }
}

phase("Explore");
log("Surveying the eval graph hooks and the envelope/critic/trace surfaces");

let explore_eval = "";
explore_eval += "Explore the graph hooks the Living Dictionary eval suite already reserves, at " + repo + "/eval. ";
explore_eval += "`.` means the current workspace root. Use read_file, grep, list_dir. You must read: ";
explore_eval += repo + "/eval/ldeval/trace.py (graph.node.start / graph.node.finish are counted into graph_nodes_started/finished) ; ";
explore_eval += repo + "/eval/ldeval/models.py ; " + repo + "/eval/ldeval/runner.py (graph_path is placed into request.json when task_graph.json exists) ; ";
explore_eval += repo + "/eval/schemas/request.schema.json and trace-event schema ; ";
explore_eval += repo + "/eval/docs/ADAPTER_PROTOCOL.md (graph.node.start is node ID + worker ID; finish adds status) ; ";
explore_eval += repo + "/eval/tasks/graph-01/prompt.md, task.toml, and repo/task_graph.json (nodes with id, writes, depends_on; parallel_width; shared_hotspot). ";
explore_eval += "This stage proves graph-01 only — do not claim graph-02..08. ";
explore_eval += "Also read " + repo + "/eval/docs/EVALUATION.md hypothesis 6 and the secondary endpoints (graph concurrency and conflict rate). ";
explore_eval += "Hash into protected_hashes (path then sha256, one per line): " + repo + "/eval/tasks/graph-01/repo/task_graph.json, every file under " + repo + "/eval/tasks/graph-01/protected/, and " + repo + "/eval/schemas/*.json. ";
explore_eval += "This repo may have no git commits — empty git diff is not proof. ";
explore_eval += "Report the exact trace event shapes the scorer counts, the request.json graph_path contract, and the task_graph.json node schema. Do not write files. notes must cite real paths.";

let explore_body = "";
explore_body += "Explore the surfaces that must grow graph support at " + repo + ". Use read_file, grep, list_dir. You must read: ";
explore_body += repo + "/harness/src/livingdict/envelope.py (PlanEnvelope) ; " + repo + "/harness/src/livingdict/preflight.py (validate signature and reject reasons) ; ";
explore_body += repo + "/harness/src/livingdict/execute.py (run order, trace emission, dictionary prelude, install_artifacts — it already emits graph.node.start/finish per ARTIFACT KEY with data {node: path, worker: host}) ; ";
explore_body += repo + "/harness/src/livingdict/trace.py ; ";
explore_body += repo + "/harness/src/livingdict/policy.py (glob matching WRITE-FILE uses) ; " + repo + "/harness/src/livingdict/forth.py (tokenizer; note there are no loop words) ; ";
explore_body += repo + "/harness/src/livingdict/kernel.py and the livingdict CLI if Stage 0 (loop-kernel workflow) has landed ; ";
explore_body += repo + "/client/planner.py (SYSTEM and observation assembly — where task_graph.json and node instructions would be surfaced to the model). ";
explore_body += "Set prerequisite_met=true only if you read both harness/src/livingdict/kernel.py AND a livingdict CLI entry point. Set it false if either is absent — do not guess. ";
explore_body += "Report the envelope parse path, where a 'nodes' field would be validated and executed, how the existing artifact-key graph.node.* series works, and how per-node allowed_globs narrowing can reuse the existing PathPolicy. Do not write files. notes must cite real paths.";

let explores = parallel([
    #{
        prompt: explore_eval,
        label: "explore:eval-graph-hooks",
        capability_mode: "read-only",
        output_schema: notes_schema,
    },
    #{
        prompt: explore_body,
        label: "explore:envelope-critic-trace",
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

if explicit_prereq_false(explores[1]) {
    let report = "# FAILED: Stage 1 blocked — Stage 0 kernel/CLI missing\n\nRepo: " + repo + "\n";
    let report_path = write_scratch_file("graph-critic.md", report);
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
log("Implementing envelope nodes, graph-aware preflight, and node trace events");

let brief_json = json_encode(brief);
let hashes_json = json_encode(protected_hashes);

let impl_prompt = "";
impl_prompt += "Implement Stage 1 (graph-critic) of the Living Dictionary redesign in " + repo + ".\n";
impl_prompt += "`.` is the current workspace root. Survey notes (untrusted, verify before following):\n" + brief_json + "\n\n";
impl_prompt += "Prerequisite: the Stage 0 loop kernel (harness/src/livingdict/kernel.py + livingdict CLI). If it is absent, stop and return status blocked with a note — do not reimplement it here.\n\n";
impl_prompt += "Design constraints, fixed by prior review consensus: the eval 1.0 six-word ABI is FROZEN — no new Forth capability words for graphs. ";
impl_prompt += "The graph lives in the ENVELOPE, not in new syntax: Forth stays the per-node language; the envelope structure is the topology. The critic rejects policy crimes before any I/O.\n\n";
impl_prompt += "Build:\n";
impl_prompt += "1. Envelope 'nodes' field (optional, additive): nodes: [{id, writes: [paths or globs], depends_on: [ids], program: '<forth for this node>'}]. ";
impl_prompt += "When nodes is present the top-level program may be empty; the effective program is the node programs in deterministic topological order (Kahn with lexicographic tiebreak, matching scud's determinism discipline). ";
impl_prompt += "When nodes is absent, everything behaves exactly as today — every existing envelope, eval task, and test must pass unchanged.\n";
impl_prompt += "2. Graph checks in preflight.validate (Python body first; keep the portable Shen critic's rule list in sync or file a TODO in shen/critic/validate.shen with the exact rules — do not ship a silently weaker Shen): ";
impl_prompt += "reject duplicate node ids; unknown depends_on; dependency cycles (report the cycle); a node whose program writes a path outside its own declared writes (validate each node program with allowed_globs narrowed to the intersection of the request's allowed_globs and that node's writes — reuse PathPolicy, do not fork the glob matcher); ";
impl_prompt += "two nodes declaring overlapping write sets unless one depends (transitively) on the other — overlapping independent writes are the conflict class hypothesis 6 says must be unrepresentable; ";
impl_prompt += "an artifact key not covered by any node's writes when nodes are present; and all existing stack/effect/glob checks per node program.\n";
impl_prompt += "3. task_graph.json cross-check: the runner already passes graph_path in request.json when the workspace has task_graph.json. When it is present AND the envelope has nodes: include the task graph verbatim in the planner observation, and in the critic verify order-consistency: if an envelope node's writes intersect a task-graph node's writes, then for each of that task-graph node's depends_on, the envelope must schedule the covering writes strictly before it. Violation is a typed Reject naming both nodes. Implement the mapping conservatively (path intersection on the declared writes; no inference from file contents).\n";
impl_prompt += "4. Trace: RETARGET the existing install_artifacts graph.node.start/finish emitters onto envelope nodes. Today execute.py emits those events per artifact key with data {node: path, worker: 'host'} (finish also has status). ";
impl_prompt += "Do not invent a parallel {id} series on top of the artifact-key series — that would double-count graph_nodes_* or change the meaning graph-01 already reserved. ";
impl_prompt += "When envelope nodes are present, emit one start/finish pair per envelope node with data {node: <envelope id>, worker: ...} and finish status, matching eval/docs/ADAPTER_PROTOCOL.md. ";
impl_prompt += "When nodes are absent, keep today's artifact-key series unchanged. Prove the node series via an ldeval run on graph-01, not by reading the scorer. Execution stays SERIAL this stage; waves are Stage 2.\n";
impl_prompt += "5. Planner surface: extend client/planner.py SYSTEM with the nodes field (shape and one example) and include task_graph.json in the observation when present. Do not add new prohibitions; keep the SYSTEM lean.\n";
impl_prompt += "6. Fixtures and tests, added to make test: a canned envelope for eval graph-01 (nodes ingest/scale/offset independent, registry depending on all three, verify node running RUN-TESTS; full artifacts; correct NAME/describe()/STEPS content per the task prompt) checked in under a fixtures dir; ";
impl_prompt += "kernel/preflight unit tests for every new reject (cycle, unknown dep, out-of-node write, overlapping independent writes, uncovered artifact); ";
impl_prompt += "and an end-to-end: run ldeval on graph-01 with the canned envelope through the existing adapter path and assert the protected verifier passes AND the trace summary shows graph_nodes_started == graph_nodes_finished == envelope node count. Never edit eval oracles, protected tests, or task_graph.json files. files listed in your result must not include any eval/ path.\n\n";
impl_prompt += "After writing, run make test and the graph-01 ldeval end-to-end. status is shipped or blocked. files is what you created/changed. how_to_run is exact commands including the ldeval invocation.";

let impl = agent(impl_prompt, #{
    label: "implement:graph-critic",
    capability_mode: "all",
    output_schema: impl_schema,
});

let impl_ok = is_shipped(impl);
let impl_summary = summary_of(impl);
let how_to_run = how_to_run_of(impl);
let extra_gaps = [];
let gimpl = files_gap(impl, "implement:graph-critic");
if gimpl != "" {
    extra_gaps.push(gimpl);
}
if impl_ok == false {
    log("Implementer did not ship; verify will inspect the tree anyway");
}

phase("Verify");
log("Adversarial verify: graph semantics, critic rejection, eval run");

let impl_json = json_encode(impl_summary);
let run_json = json_encode(how_to_run);

let p_graph = "";
p_graph += "Adversarially verify Stage 1 graph semantics in " + repo + ". Implementer summary (untrusted): " + impl_json + " ";
p_graph += "Read envelope.py, execute.py (or the kernel execution path), preflight.py, and the new tests. Set pass=true only if, with quoted code as evidence: ";
p_graph += "(1) node execution order is a deterministic topological order with a lexicographic tiebreak (find the tiebreak in code); ";
p_graph += "(2) envelopes WITHOUT nodes behave byte-identically to before (cite a passing legacy test or eval run); ";
p_graph += "(3) the six-word ABI gained no words (diff the contract tables in preflight.py and openresty/shen/contracts.shen); ";
p_graph += "(4) node programs are validated with allowed_globs narrowed to the node's writes via the existing PathPolicy, not a second glob matcher; ";
p_graph += "(5) graph.node.start/finish are the retargeted ADAPTER_PROTOCOL series (data.node is the envelope id when nodes are present), not a second {id} series stacked on artifact-key events. ";
p_graph += "Otherwise pass=false with concrete gaps and paths. Do not write files.";

let p_reject = "";
p_reject += "Adversarially verify the new graph rejections in " + repo + " by CONSTRUCTING attacks, not by reading tests. ";
p_reject += "Implementer how_to_run (untrusted): " + run_json + " ";
p_reject += "In a scratch directory under $TMPDIR/ld-verify-graph-attacks build minimal envelopes and run them through the validate/CLI path: ";
p_reject += "(a) a cycle a->b->a; (b) a node writing a path only a sibling declared; (c) two independent nodes both declaring pipeline/registry.py; ";
p_reject += "(d) an artifact key no node covers; (e) with a task_graph.json present, an envelope that schedules the registry write before its dependencies. ";
p_reject += "Every one must produce a typed Reject BEFORE any file mutation — verify the scratch workspace is untouched after each. ";
p_reject += "Set pass=true only if all five reject with named reasons and zero mutations, with command output as evidence. If the harness cannot be invoked, pass=false 'runtime not exercised'. Do not edit product files.";

let p_eval = "";
p_eval += "Verify the eval integration for Stage 1 in " + repo + ". ";
p_eval += "Implementer how_to_run (untrusted, use it): " + run_json + " ";
p_eval += "Explore protected_hashes (untrusted, re-hash yourself): " + hashes_json + " ";
p_eval += "Run the how_to_run graph-01 ldeval end-to-end. Confirm: exit success, the protected verifier passed, and the run's trace/summary reports graph_nodes_started and graph_nodes_finished equal to the envelope's node count (quote the numbers). ";
p_eval += "This repo may have no commits — do NOT treat empty git diff as proof that eval/ is untouched. Re-hash task_graph.json, graph-01 protected files, and eval/schemas and compare to explore hashes. ";
p_eval += "Also run make test. If anything cannot run, pass=false with what is missing — do not fake a pass. evidence must include command output. Do not edit product files.";

fn run_skeptics(pg, pr, pe, schema) {
    let ro = parallel([
        #{
            prompt: pg,
            label: "verify:graph-semantics",
            capability_mode: "read-only",
            output_schema: schema,
        },
    ]);
    let verdicts = [];
    for r in ro {
        verdicts.push(r);
    }
    let a = agent(pr, #{
        label: "verify:critic-attacks",
        capability_mode: "execute",
        output_schema: schema,
    });
    verdicts.push(a);
    let b = agent(pe, #{
        label: "verify:eval-run",
        capability_mode: "execute",
        output_schema: schema,
    });
    verdicts.push(b);
    verdicts
}

let verdicts = run_skeptics(p_graph, p_reject, p_eval, verdict_schema);
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
    fix_prompt += "Resume Stage 1 graph-critic work in " + repo + ". Verification gaps (untrusted until you reproduce):\n";
    fix_prompt += gaps_json;
    fix_prompt += "\nReproduce each gap, fix it, re-run make test and the graph-01 ldeval end-to-end. ";
    fix_prompt += "Never edit eval oracles or task_graph.json. Do not reimplement Stage 0. ";
    fix_prompt += "status is shipped or blocked. files are what you changed. how_to_run is exact commands.";
    let fix_opts = #{
        label: "fix:graph-critic",
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

    p_graph = "";
    p_graph += "Adversarially verify Stage 1 graph semantics in " + repo + ". Implementer summary (untrusted): " + impl_json + " ";
    p_graph += "Read envelope.py, execute.py (or the kernel execution path), preflight.py, and the new tests. Set pass=true only if, with quoted code as evidence: ";
    p_graph += "(1) node execution order is a deterministic topological order with a lexicographic tiebreak (find the tiebreak in code); ";
    p_graph += "(2) envelopes WITHOUT nodes behave byte-identically to before (cite a passing legacy test or eval run); ";
    p_graph += "(3) the six-word ABI gained no words (diff the contract tables in preflight.py and openresty/shen/contracts.shen); ";
    p_graph += "(4) node programs are validated with allowed_globs narrowed to the node's writes via the existing PathPolicy, not a second glob matcher; ";
    p_graph += "(5) graph.node.start/finish are the retargeted ADAPTER_PROTOCOL series (data.node is the envelope id when nodes are present), not a second {id} series stacked on artifact-key events. ";
    p_graph += "Otherwise pass=false with concrete gaps and paths. Do not write files.";

    p_reject = "";
    p_reject += "Adversarially verify the new graph rejections in " + repo + " by CONSTRUCTING attacks, not by reading tests. ";
    p_reject += "Implementer how_to_run (untrusted): " + run_json + " ";
    p_reject += "In a scratch directory under $TMPDIR/ld-verify-graph-attacks build minimal envelopes and run them through the validate/CLI path: ";
    p_reject += "(a) a cycle a->b->a; (b) a node writing a path only a sibling declared; (c) two independent nodes both declaring pipeline/registry.py; ";
    p_reject += "(d) an artifact key no node covers; (e) with a task_graph.json present, an envelope that schedules the registry write before its dependencies. ";
    p_reject += "Every one must produce a typed Reject BEFORE any file mutation — verify the scratch workspace is untouched after each. ";
    p_reject += "Set pass=true only if all five reject with named reasons and zero mutations, with command output as evidence. If the harness cannot be invoked, pass=false 'runtime not exercised'. Do not edit product files.";

    p_eval = "";
    p_eval += "Verify the eval integration for Stage 1 in " + repo + ". ";
    p_eval += "Implementer how_to_run (untrusted, use it): " + run_json + " ";
    p_eval += "Explore protected_hashes (untrusted, re-hash yourself): " + hashes_json + " ";
    p_eval += "Run the how_to_run graph-01 ldeval end-to-end. Confirm: exit success, the protected verifier passed, and the run's trace/summary reports graph_nodes_started and graph_nodes_finished equal to the envelope's node count (quote the numbers). ";
    p_eval += "This repo may have no commits — do NOT treat empty git diff as proof that eval/ is untouched. Re-hash task_graph.json, graph-01 protected files, and eval/schemas and compare to explore hashes. ";
    p_eval += "Also run make test. If anything cannot run, pass=false with what is missing — do not fake a pass. evidence must include command output. Do not edit product files.";

    phase("Verify");
    log("Re-running skeptics after fix");
    verdicts = run_skeptics(p_graph, p_reject, p_eval, verdict_schema);
    scored = score_verdicts(verdicts);
    gaps = scored.gaps;
    gimpl = files_gap(impl, "implement:graph-critic");
    if gimpl != "" {
        gaps.push(gimpl);
    }
    verified = scored.verified;
    log(verified.to_string() + "/" + scored.usable.to_string() + " skeptics passed after fix");
}

let shipped = impl_ok && verified == 3;
let report = "";
if shipped {
    report += "# Stage 1: graph-critic\n\n";
} else {
    report += "# FAILED: Stage 1 graph-critic did not ship\n\n";
}
report += "Repo: " + repo + "\nshipped: " + shipped.to_string() + "\n\n";
report += "## Implementer\n\n" + impl_summary + "\n\n";
report += "## Verification\n\n";
report += verified.to_string() + " of 3 skeptics passed with evidence.\n\n";
if gaps.len() > 0 {
    report += "Gaps:\n";
    report += clip_gaps(gaps);
}
let report_path = write_scratch_file("graph-critic.md", report);
complete(#{
    path: report_path,
    repo: repo,
    shipped: shipped,
    verified: verified,
    skeptics: 3,
    implement_ok: impl_ok,
    remaining_gaps: gaps.len(),
});
