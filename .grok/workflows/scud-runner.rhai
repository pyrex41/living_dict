let meta = #{
    name: "scud-runner",
    description: "Stage 3: livingdict becomes a bounded runner scud v2 can orchestrate — rho.run/v1 wire protocol with grant enforcement, plus the critic exposed as scud's Shen policy Evaluator seam",
    when_to_use: "After loop-kernel ships (graph stages help but are not required). Makes scud own the inter-goal DAG while livingdict owns bounded episode execution and Shen owns policy at both seams. Optional args: {repo, scud}. Commit first so the stage diff is reviewable.",
    phases: [
        #{ title: "Explore", detail: "scud's wire protocol + policy seam; livingdict's CLI and event surface" },
        #{ title: "Implement", detail: "runner stream first, then grant gate + policy evaluator" },
        #{ title: "Verify", detail: "stream-contract, grant, and integration skeptics (sequential)" },
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

fn path_forbidden(p, scud_root) {
    let s = trimmed(p);
    if s == "" {
        return false;
    }
    if contains_str(s, "eval/") {
        return true;
    }
    let root = trimmed(scud_root);
    if root != "" && contains_str(s, root) {
        return true;
    }
    if contains_str(s, "/scud/") {
        return true;
    }
    false
}

fn files_violate(files, scud_root) {
    if files == () || type_of(files) != "array" {
        return false;
    }
    for p in files {
        if path_forbidden(p, scud_root) {
            return true;
        }
    }
    false
}

fn is_shipped(r, scud_root) {
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
    if files_violate(o.files, scud_root) {
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

fn files_gap(r, label, scud_root) {
    let o = output_map(r);
    if o == () {
        return "";
    }
    if files_violate(o.files, scud_root) {
        return label + " listed a forbidden path under eval/ or the scud checkout";
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

fn scud_gate_prompt(scud_root) {
    let p = "";
    p += "Check that the scud checkout was not modified. Run exactly: git -C ";
    p += scud_root;
    p += " status --porcelain\n";
    p += "pass=true only if the command succeeds and stdout is empty. ";
    p += "evidence is the command plus its output (write 'clean' if empty). ";
    p += "Do not write any files. Do not run make test.";
    p
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
log("Surveying scud's wire protocol / policy seam and livingdict's CLI surface");

let explore_scud = "";
explore_scud += "Explore the exact WIRE contracts a bounded runner must satisfy for scud, at " + scud + ". Use read_file, grep, list_dir. You must read: ";
explore_scud += scud + "/pkg/executor/executor.go — note that Request {RunID, Prompt, SystemPrompt, Model, WorkingDir, AllowedTools, Limits, Context} is the IN-PROCESS harness type, NOT stdin JSON. ";
explore_scud += "WorkingDir is applied as cmd.Dir on the parent; it is not a JSON field. ";
explore_scud += "Then read " + scud + "/pkg/executor/rho_v1.go in full. The bytes RhoV1.Run writes to the child stdin are wireRequest: ";
explore_scud += "{protocol, run_id, model: {provider, id}, input: [{role, content: [{type, text}]}], system, limits, grant, context}. ";
explore_scud += "Prompt becomes input[0].content[0].text. SystemPrompt becomes system. Model is ModelRef {provider,id}, never an opaque string. ";
explore_scud += "canonicalJSON re-marshals through any => lexicographic keys, no whitespace. Authorize embeds witness + issuer pubkey; child env RHO_PROTOCOL_GRANT_MODE=require + RHO_PROTOCOL_GRANT_PUBKEY. ";
explore_scud += "ConsumeRhoV1 rules: protocol string, run-id match, STRICTLY monotonic seq, exactly one terminal (run.completed|run.failed|run.cancelled), no events after terminal, unknown event types passed through. ";
explore_scud += "reduceTerminal payloads (quote the Go): run.completed data MUST be {status: \"succeeded\", usage?}; run.failed data MUST be {code, message}; run.cancelled data MUST be {reason, usage?}. A receipt-shaped completed payload is invalid. ";
explore_scud += "Also read " + scud + "/v2/adapters/adapters.go, " + scud + "/v2/adapters/shen/shen.go (Evaluator: Evaluate(Input{RunID,Action,Resource,Attributes}) -> Output{Allowed,Reason,Constraints}), ";
explore_scud += scud + "/v2/adapters/rho/testdata/completed.jsonl (quote it verbatim — it starts with run.started seq 1, then message.delta, then run.completed {status:succeeded, usage}) and invalid_after_terminal.jsonl, and " + scud + "/docs/scud-v2-architecture.md. ";
explore_scud += "notes must be a spec another engineer can implement against without opening scud. Do not write files.";

let explore_ld = "";
explore_ld += "Explore the livingdict CLI and event surface at " + repo + " (post loop-kernel). `.` is the current workspace root. Use read_file, grep, list_dir. You must read: ";
explore_ld += "the livingdict CLI entry (client/ or harness bin — find it), harness/src/livingdict/kernel.py (event kinds, sequence numbering, reconcile decisions), ";
explore_ld += "harness/src/livingdict/trace.py (existing trace event shapes: preflight.rejected, mutation.applied, execution.trap, dictionary.*, gates), ";
explore_ld += "harness/src/livingdict/adapter.py and eval/docs/ADAPTER_PROTOCOL.md (the ldeval request/receipt contract that must keep working unchanged), ";
explore_ld += "and harness/src/livingdict/preflight.py (the validate signature the policy evaluator will wrap). ";
explore_ld += "Set prerequisite_met=true only if kernel.py AND a livingdict CLI entry exist. Set it false if either is absent — do not guess. ";
explore_ld += "Hash into protected_hashes (path then sha256, one per line) eval/schemas/*.json and eval/docs/ADAPTER_PROTOCOL.md. This repo may have no commits — empty git diff is not proof. ";
explore_ld += "Report: how a runner mode can map wireRequest.input text -> goal, where events already have sequence numbers, what the final receipt contains, and whether Stage 0 has landed (if not, say so loudly). Do not write files. notes must cite real paths.";

let explores = parallel([
    #{
        prompt: explore_scud,
        label: "explore:rho-v1-contract",
        capability_mode: "read-only",
        output_schema: notes_schema,
    },
    #{
        prompt: explore_ld,
        label: "explore:livingdict-cli",
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

if explicit_prereq_false(explores[1]) {
    let report = "# FAILED: Stage 3 blocked — Stage 0 kernel/CLI missing\n\nRepo: " + repo + "\n";
    let report_path = write_scratch_file("scud-runner.md", report);
    complete(#{
        path: report_path,
        repo: repo,
        scud: scud,
        shipped: false,
        blocked: "prerequisite",
        verified: 0,
        skeptics: 3,
        implement_ok: false,
        remaining_gaps: 1,
    });
}

phase("Implement");
log("Implementing the runner stream, then the grant gate and policy evaluator");

let brief_json = json_encode(brief);
let hashes_json = json_encode(protected_hashes);

let impl_a_prompt = "";
impl_a_prompt += "Implement Stage 3 PART A (rho.run/v1 runner + event stream + contract tests) in " + repo + ", against the scud contracts at " + scud + ".\n";
impl_a_prompt += "`.` is the living_dict workspace. Survey notes (untrusted, verify against scud's source before following):\n" + brief_json + "\n\n";
impl_a_prompt += "Prerequisite: the Stage 0 livingdict CLI and kernel. If absent, return status blocked.\n";
impl_a_prompt += "Hard rule: do NOT modify anything under " + scud + ". It is the reference and the test oracle. files must be living_dict-relative; never list a scud path.\n\n";
impl_a_prompt += "WIRE SHAPE — implement stdin/stdout against rho_v1.go wireRequest / Event / ConsumeRhoV1 / reduceTerminal, NOT executor.Request:\n";
impl_a_prompt += "- stdin: one JSON object {protocol, run_id, model:{provider,id}, input:[{role, content:[{type,text}]}], system?, limits, grant, context?}.\n";
impl_a_prompt += "- Mapping: input[0].content[0].text -> goal; cwd is the process cwd (scud sets cmd.Dir; you may also honor context.working_dir if present); limits.max_turns -> episode cap; limits deadline/cost honored as budget events; model.provider + model.id are structured fields (do not treat model as an opaque string); grant.write_roots/read_roots -> allowed/forbidden globs and workspace confinement.\n";
impl_a_prompt += "- Accept and record unknown fields; never crash on them. Do not expect working_dir, prompt, or system_prompt as top-level JSON keys.\n";
impl_a_prompt += "- stdout JSONL must satisfy ConsumeRhoV1: protocol rho.run/v1 on every event, run_id echoed, strictly monotonic seq starting at 1, flush per line.\n";
impl_a_prompt += "- First event should match fixtures: type run.started (not a hello/protocol event).\n";
impl_a_prompt += "- Kernel/trace events map to non-terminal typed events (episode.planned, preflight.*, mutation.applied, gates.measured, livingdict.receipt, ...). Unknown types pass through, so keep livingdict names on non-terminal events.\n";
impl_a_prompt += "- EXACTLY ONE terminal and nothing after it. reduceTerminal is strict:\n";
impl_a_prompt += "  run.completed data MUST include status=\"succeeded\" (usage optional). Put the livingdict receipt on a pre-terminal event such as livingdict.receipt — NOT as the completed payload.\n";
impl_a_prompt += "  run.failed data MUST be {code, message} (not {reason}). Use this for blocked/halt_cap/trap.\n";
impl_a_prompt += "  run.cancelled data MUST include reason.\n";
impl_a_prompt += "A Python checker copied from this prompt that omits those payload shapes will certify a stream scud rejects — include the payload rules in the checker.\n\n";
impl_a_prompt += "Contract tests, added to make test (runnable without scud's toolchain): a Python test module encoding ConsumeRhoV1's rules (monotonic seq, single terminal, nothing after terminal, run-id match, valid completed/failed payloads) and running the livingdict runner on a canned fizzbuzz wireRequest via --planner-cmd, asserting the stream passes; a test replaying " + scud + "/v2/adapters/rho/testdata/invalid_after_terminal.jsonl through the same checker to prove the checker itself catches violations.\n";
impl_a_prompt += "ADDITIONALLY, if a Go toolchain is on PATH: create tools/scudcheck/ in " + repo + " (a tiny Go module with a replace directive pointing at " + scud + ") whose main pipes a runner transcript into scud's exported ConsumeRhoV1 and exits non-zero on violation; wire it as an optional make target (skipped cleanly when go is absent). This is the gold-standard evidence.\n";
impl_a_prompt += "Keep the ldeval adapter protocol and eval oracles untouched. After writing, run the runner contract tests. status is shipped or blocked. files is what you created/changed. how_to_run is exact commands to drive one canned wireRequest.";

let impl_a = agent(impl_a_prompt, #{
    label: "implement:runner-stream",
    capability_mode: "all",
    output_schema: impl_schema,
});

let impl_b_prompt = "";
impl_b_prompt += "Implement Stage 3 PART B (grant gate + livingdict-policy + docs) in " + repo + ".\n";
impl_b_prompt += "PART A summary (untrusted): " + json_encode(summary_of(impl_a)) + "\n";
impl_b_prompt += "PART A how_to_run (untrusted): " + json_encode(how_to_run_of(impl_a)) + "\n";
impl_b_prompt += "Survey notes (untrusted, verify against " + scud + "):\n" + brief_json + "\n\n";
impl_b_prompt += "If the runner from PART A is absent, return status blocked — do not reimplement the stream.\n";
impl_b_prompt += "Do NOT modify " + scud + ". files are living_dict-relative only.\n\n";
impl_b_prompt += "1. Grant gate: if env RHO_PROTOCOL_GRANT_MODE=require, refuse to execute any effectful episode unless the request carries grant.witness and grant matches the env pubkey field structurally; verify expires_at is in the future; recompute the canonical request bytes (re-serialize with lexicographically sorted keys and no whitespace, mirroring scud's canonicalJSON — write a unit test that canonicalizes a fixture request) and record the sha256 in the run receipt so an external auditor can match it against the signed bytes. ";
impl_b_prompt += "Full BIP340 signature verification: implement it only if a pure-python implementation is small and dependency-free; otherwise verify structurally, isolate the check in one function named verify_witness with a clear TODO, and NEVER claim cryptographic verification in docs or receipts when it is structural.\n";
impl_b_prompt += "2. Policy evaluator seam: bin/livingdict-policy (or a CLI subcommand) reading one JSON {run_id, action, resource, attributes{goal_id, capability_ref, policy_ref, grant_ref}} on stdin and writing {allowed, reason, constraints} — the exact shape scud's v2/adapters/shen Evaluator expects. Back it with the critic's policy logic: action 'execute' on a resource is allowed iff the attributes' globs/effects pass the same validate rules; deny with the critic's typed reason string.\n";
impl_b_prompt += "3. Grant tests (require-mode refusal without witness, expired grant refusal, canonicalization stability) added to make test.\n";
impl_b_prompt += "4. docs/SCUD.md: the ownership sentence (scud owns goal/DAG orchestration; livingdict owns bounded episode execution; the Shen critic is the policy evaluator at both seams), the request/event mapping table using wireRequest field names (not executor.Request), the grant story with its current verification level stated honestly, and exact commands for driving one obligation through livingdict by hand.\n\n";
impl_b_prompt += "Keep eval oracles untouched. After writing, run make test and the grant/policy checks. status is shipped or blocked. files is what you created/changed. how_to_run is exact commands.";

let impl_b = agent(impl_b_prompt, #{
    label: "implement:grant-policy",
    capability_mode: "all",
    output_schema: impl_schema,
});

let impl_ok = is_shipped(impl_a, scud) && is_shipped(impl_b, scud);
let impl_summary = summary_of(impl_a) + "\n\n" + summary_of(impl_b);
let how_to_run = how_to_run_of(impl_a) + "\n" + how_to_run_of(impl_b);
let extra_gaps = [];
let ga = files_gap(impl_a, "implement:runner-stream", scud);
let gb = files_gap(impl_b, "implement:grant-policy", scud);
if ga != "" {
    extra_gaps.push(ga);
}
if gb != "" {
    extra_gaps.push(gb);
}

let gate = agent(scud_gate_prompt(scud), #{
    label: "gate:scud-clean",
    capability_mode: "execute",
    output_schema: verdict_schema,
});
let gate_out = output_map(gate);
if gate_out == () || gate_out.pass != true || gate_out.evidence == () || gate_out.evidence == "" {
    impl_ok = false;
    extra_gaps.push("scud working tree is dirty or the git-status gate failed");
}

if impl_ok == false {
    log("Implementer did not ship both parts or scud was touched; verify will inspect anyway");
}

phase("Verify");
log("Adversarial verify sequentially: stream, grant, then integration/make test");

let impl_json = json_encode(impl_summary);
let run_json = json_encode(how_to_run);

let p_stream = "";
p_stream += "Adversarially verify the runner event stream in " + repo + " against scud's real ConsumeRhoV1 rules. Implementer summary (untrusted): " + impl_json + " ";
p_stream += "how_to_run (untrusted): " + run_json + " ";
p_stream += "First read " + scud + "/pkg/executor/rho_v1.go wireRequest, ConsumeRhoV1, and reduceTerminal yourself and list the rules from the source. ";
p_stream += "Then run the livingdict runner on a canned wireRequest (per how_to_run) in $TMPDIR/ld-verify-scud-stream and check the transcript BY HAND: protocol/run_id echo, strictly monotonic seq from 1, first event run.started, exactly one terminal, nothing after it, valid JSON per line, and terminal payload matches reduceTerminal (completed => status=succeeded; failed => code+message). ";
p_stream += "If tools/scudcheck exists and go is on PATH, build and run it on the transcript and treat its exit code as primary evidence. ";
p_stream += "Do not run make test (a later skeptic does). pass=true only with transcript excerpts (first 3 events, the terminal, the seq sequence) as evidence. Do not write files outside scratch.";

let p_grant = "";
p_grant += "Adversarially verify the grant gate in " + repo + ". ";
p_grant += "how_to_run (untrusted): " + run_json + " ";
p_grant += "Use scratch $TMPDIR/ld-verify-scud-grant. Do not run make test. ";
p_grant += "Run the runner with RHO_PROTOCOL_GRANT_MODE=require and: (a) no witness — must refuse before ANY effect (confirm the scratch workspace untouched); (b) an expired grant — refuse; (c) a valid-shaped grant — proceed, and the receipt must record the canonical request sha256. ";
p_grant += "Read verify_witness and the docs: pass=false if docs or receipts claim cryptographic verification while the code is structural. ";
p_grant += "Also verify canonicalization: two requests with reordered keys must produce the same recorded sha256 (run it). ";
p_grant += "evidence must include command output. Do not edit product files.";

let p_integ = "";
p_integ += "Verify the Stage 3 integration surface in " + repo + ". ";
p_integ += "how_to_run (untrusted): " + run_json + " ";
p_integ += "Explore protected_hashes (untrusted, re-hash yourself): " + hashes_json + " ";
p_integ += "Run make test. Run bin/livingdict-policy with: an allowed execute input (globs inside policy), a denied one (write root outside globs), and malformed JSON — expect allowed:true, allowed:false with a typed reason, and a clean error (non-zero exit, no traceback spew) respectively. ";
p_integ += "Confirm the output shape matches the Evaluator contract in " + scud + "/v2/adapters/shen/shen.go by reading that file. ";
p_integ += "Confirm docs/SCUD.md exists, states the ownership split, uses wireRequest field names (not executor.Request.Prompt / WorkingDir as JSON), and its commands actually run (execute at least one). ";
p_integ += "Confirm the ldeval adapter path still works: run the canned config-01 adapter check if the Makefile has it. ";
p_integ += "This repo may have no commits — do NOT treat empty git diff as proof. Re-hash eval/schemas and ADAPTER_PROTOCOL.md. ";
p_integ += "If anything cannot run, pass=false with what is missing — do not fake a pass. evidence must include command output. Do not edit product files.";

fn run_skeptics(ps, pg, pi, schema) {
    let verdicts = [];
    let a = agent(ps, #{
        label: "verify:stream-contract",
        capability_mode: "execute",
        output_schema: schema,
    });
    verdicts.push(a);
    let b = agent(pg, #{
        label: "verify:grant-gate",
        capability_mode: "execute",
        output_schema: schema,
    });
    verdicts.push(b);
    let c = agent(pi, #{
        label: "verify:integration",
        capability_mode: "execute",
        output_schema: schema,
    });
    verdicts.push(c);
    verdicts
}

let verdicts = run_skeptics(p_stream, p_grant, p_integ, verdict_schema);
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
    fix_a += "Resume Stage 3 PART A (runner stream) in " + repo + ". Verification gaps (untrusted until you reproduce):\n";
    fix_a += gaps_json;
    fix_a += "\nReproduce each gap that is yours, fix it, re-run the runner contract tests. ";
    fix_a += "Do not modify " + scud + ". Match wireRequest / reduceTerminal exactly. ";
    fix_a += "status is shipped or blocked. files are what you changed. how_to_run is exact commands.";
    let fix_a_opts = #{
        label: "fix:runner-stream",
        capability_mode: "all",
        output_schema: impl_schema,
    };
    if impl_a != () && impl_a.agent_id != () {
        fix_a_opts.resume_from = impl_a.agent_id;
    }
    let fixed_a = agent(fix_a, fix_a_opts);

    let fix_b = "";
    fix_b += "Resume Stage 3 PART B (grant/policy) in " + repo + ". Verification gaps (untrusted until you reproduce):\n";
    fix_b += gaps_json;
    fix_b += "\nReproduce each gap that is yours, fix it, re-run make test and the grant/policy checks. ";
    fix_b += "Do not modify " + scud + ". status is shipped or blocked. files are what you changed. how_to_run is exact commands.";
    let fix_b_opts = #{
        label: "fix:grant-policy",
        capability_mode: "all",
        output_schema: impl_schema,
    };
    if impl_b != () && impl_b.agent_id != () {
        fix_b_opts.resume_from = impl_b.agent_id;
    }
    let fixed_b = agent(fix_b, fix_b_opts);

    if is_shipped(fixed_a, scud) {
        impl_a = fixed_a;
    }
    if is_shipped(fixed_b, scud) {
        impl_b = fixed_b;
    }
    impl_ok = is_shipped(impl_a, scud) && is_shipped(impl_b, scud);
    impl_summary = summary_of(impl_a) + "\n\n" + summary_of(impl_b);
    how_to_run = how_to_run_of(impl_a) + "\n" + how_to_run_of(impl_b);
    impl_json = json_encode(impl_summary);
    run_json = json_encode(how_to_run);

    gate = agent(scud_gate_prompt(scud), #{
        label: "gate:scud-clean-after-fix",
        capability_mode: "execute",
        output_schema: verdict_schema,
    });
    gate_out = output_map(gate);
    if gate_out == () || gate_out.pass != true || gate_out.evidence == () || gate_out.evidence == "" {
        impl_ok = false;
    }

    p_stream = "";
    p_stream += "Adversarially verify the runner event stream in " + repo + " against scud's real ConsumeRhoV1 rules. Implementer summary (untrusted): " + impl_json + " ";
    p_stream += "how_to_run (untrusted): " + run_json + " ";
    p_stream += "First read " + scud + "/pkg/executor/rho_v1.go wireRequest, ConsumeRhoV1, and reduceTerminal yourself and list the rules from the source. ";
    p_stream += "Then run the livingdict runner on a canned wireRequest (per how_to_run) in $TMPDIR/ld-verify-scud-stream and check the transcript BY HAND: protocol/run_id echo, strictly monotonic seq from 1, first event run.started, exactly one terminal, nothing after it, valid JSON per line, and terminal payload matches reduceTerminal (completed => status=succeeded; failed => code+message). ";
    p_stream += "If tools/scudcheck exists and go is on PATH, build and run it on the transcript and treat its exit code as primary evidence. ";
    p_stream += "Do not run make test (a later skeptic does). pass=true only with transcript excerpts (first 3 events, the terminal, the seq sequence) as evidence. Do not write files outside scratch.";

    p_grant = "";
    p_grant += "Adversarially verify the grant gate in " + repo + ". ";
    p_grant += "how_to_run (untrusted): " + run_json + " ";
    p_grant += "Use scratch $TMPDIR/ld-verify-scud-grant. Do not run make test. ";
    p_grant += "Run the runner with RHO_PROTOCOL_GRANT_MODE=require and: (a) no witness — must refuse before ANY effect (confirm the scratch workspace untouched); (b) an expired grant — refuse; (c) a valid-shaped grant — proceed, and the receipt must record the canonical request sha256. ";
    p_grant += "Read verify_witness and the docs: pass=false if docs or receipts claim cryptographic verification while the code is structural. ";
    p_grant += "Also verify canonicalization: two requests with reordered keys must produce the same recorded sha256 (run it). ";
    p_grant += "evidence must include command output. Do not edit product files.";

    p_integ = "";
    p_integ += "Verify the Stage 3 integration surface in " + repo + ". ";
    p_integ += "how_to_run (untrusted): " + run_json + " ";
    p_integ += "Explore protected_hashes (untrusted, re-hash yourself): " + hashes_json + " ";
    p_integ += "Run make test. Run bin/livingdict-policy with: an allowed execute input (globs inside policy), a denied one (write root outside globs), and malformed JSON — expect allowed:true, allowed:false with a typed reason, and a clean error (non-zero exit, no traceback spew) respectively. ";
    p_integ += "Confirm the output shape matches the Evaluator contract in " + scud + "/v2/adapters/shen/shen.go by reading that file. ";
    p_integ += "Confirm docs/SCUD.md exists, states the ownership split, uses wireRequest field names (not executor.Request.Prompt / WorkingDir as JSON), and its commands actually run (execute at least one). ";
    p_integ += "Confirm the ldeval adapter path still works: run the canned config-01 adapter check if the Makefile has it. ";
    p_integ += "This repo may have no commits — do NOT treat empty git diff as proof. Re-hash eval/schemas and ADAPTER_PROTOCOL.md. ";
    p_integ += "If anything cannot run, pass=false with what is missing — do not fake a pass. evidence must include command output. Do not edit product files.";

    phase("Verify");
    log("Re-running skeptics after fix");
    verdicts = run_skeptics(p_stream, p_grant, p_integ, verdict_schema);
    scored = score_verdicts(verdicts);
    gaps = scored.gaps;
    ga = files_gap(impl_a, "implement:runner-stream", scud);
    gb = files_gap(impl_b, "implement:grant-policy", scud);
    if ga != "" {
        gaps.push(ga);
    }
    if gb != "" {
        gaps.push(gb);
    }
    if gate_out == () || gate_out.pass != true {
        gaps.push("scud working tree is dirty or the git-status gate failed");
    }
    verified = scored.verified;
    log(verified.to_string() + "/" + scored.usable.to_string() + " skeptics passed after fix");
}

let shipped = impl_ok && verified == 3;
let report = "";
if shipped {
    report += "# Stage 3: scud-runner\n\n";
} else {
    report += "# FAILED: Stage 3 scud-runner did not ship\n\n";
}
report += "Repo: " + repo + "\nScud reference (read-only): " + scud + "\nshipped: " + shipped.to_string() + "\n\n";
report += "## Implementer\n\n" + impl_summary + "\n\n";
report += "## Verification\n\n";
report += verified.to_string() + " of 3 skeptics passed with evidence.\n\n";
if gaps.len() > 0 {
    report += "Gaps:\n";
    report += clip_gaps(gaps);
}
let report_path = write_scratch_file("scud-runner.md", report);
complete(#{
    path: report_path,
    repo: repo,
    scud: scud,
    shipped: shipped,
    verified: verified,
    skeptics: 3,
    implement_ok: impl_ok,
    remaining_gaps: gaps.len(),
});
