let meta = #{
    name: "evidence-capability-pipeline",
    description: "Post-harvest empirical landing: instrument honest dictionary reuse, freeze it, run paired parser/graph families, classify failures adversarially, and report only measured effects",
    when_to_use: "Use after the 31 August dictionary correctness harvest (A-D/F/H/I). This workflow deliberately does not build objects, waves, retrieval, or new extraction organs. Optional args: {repo, run_dir}.",
    phases: [
        #{ title: "Explore", detail: "Audit live telemetry, historical rows, campaign commands, and protected benchmark paths" },
        #{ title: "Implement", detail: "Add only missing observational fields; preserve behavior and frozen ABI" },
        #{ title: "Freeze", detail: "Adversarially verify scope, ABI, and additive telemetry before any campaign run" },
        #{ title: "Campaign", detail: "Three paired parser replicates, graph confirmation, optional Rust only after observed reuse; preserve every raw run" },
        #{ title: "Verify", detail: "Adversarially classify infrastructure failure, negative transfer, no-use, and measured reuse" },
    ],
};

let notes_schema = #{
    "type": "object",
    required: ["notes"],
    properties: #{
        notes: #{ "type": "string" },
        risks: #{ "type": "array", items: #{ "type": "string" } },
        prerequisite_met: #{ "type": "boolean" },
        protected_hashes: #{ "type": "string" },
    },
};

let impl_schema = #{
    "type": "object",
    required: ["status", "summary", "files", "how_to_run"],
    properties: #{
        status: #{ "type": "string", enum: ["shipped", "blocked"] },
        summary: #{ "type": "string" },
        files: #{ "type": "array", items: #{ "type": "string" } },
        how_to_run: #{ "type": "string" },
    },
};

let campaign_schema = #{
    "type": "object",
    required: ["status", "summary", "run_dir", "raw_preserved"],
    properties: #{
        status: #{ "type": "string", enum: ["complete", "blocked"] },
        summary: #{ "type": "string" },
        run_dir: #{ "type": "string" },
        raw_preserved: #{ "type": "boolean" },
        parser_replicates: #{ "type": "string" },
        graph_confirmation: #{ "type": "string" },
        rust_ran: #{ "type": "boolean" },
        commands: #{ "type": "string" },
    },
};

let verdict_schema = #{
    "type": "object",
    required: ["pass", "summary", "gaps"],
    properties: #{
        pass: #{ "type": "boolean" },
        summary: #{ "type": "string" },
        gaps: #{ "type": "array", items: #{ "type": "string" } },
        evidence: #{ "type": "string" },
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
    if n == 0 { return true; }
    if n > h { return false; }
    let i = 0;
    while i + n <= h {
        if hay.sub_string(i, n) == needle { return true; }
        i += 1;
    }
    false
}

fn output_map(r) {
    if r == () || r.success != true || r.output == () { return (); }
    if type_of(r.output) == "map" { return r.output; }
    ()
}

fn path_forbidden(p) {
    let s = trimmed(p);
    if s == "" { return false; }
    contains_str(s, "eval/") || contains_str(s, "compare/runs/")
}

fn files_violate(files) {
    if files == () || type_of(files) != "array" { return false; }
    for p in files {
        if path_forbidden(p) { return true; }
    }
    false
}

fn is_shipped(r) {
    let o = output_map(r);
    if o == () || o.status != "shipped" { return false; }
    if trimmed(o.how_to_run) == "" || files_violate(o.files) { return false; }
    true
}

fn summary_of(r) {
    let o = output_map(r);
    if o == () || o.summary == () { return ""; }
    trimmed(o.summary)
}

fn how_to_run_of(r) {
    let o = output_map(r);
    if o == () || o.how_to_run == () { return ""; }
    trimmed(o.how_to_run)
}

fn campaign_summary_of(r) {
    let o = output_map(r);
    if o == () || o.summary == () { return ""; }
    trimmed(o.summary)
}

fn campaign_dir_of(r) {
    let o = output_map(r);
    if o == () || o.run_dir == () { return ""; }
    trimmed(o.run_dir)
}

fn score_verdicts(verdicts) {
    let gaps = [];
    let verified = 0;
    let usable = 0;
    for v in verdicts {
        let o = output_map(v);
        if o != () && o.pass != () {
            usable += 1;
            if o.pass == true && o.evidence != () && trimmed(o.evidence) != "" {
                verified += 1;
            } else {
                if o.gaps != () {
                    for g in o.gaps { gaps.push(g); }
                }
                if o.summary != () { gaps.push(o.summary); }
            }
        } else {
            gaps.push("verifier slot missing or unusable");
        }
    }
    #{ verified: verified, usable: usable, gaps: gaps }
}

fn clip_gaps(gaps) {
    let out = "";
    let i = 0;
    for g in gaps {
        if i < 16 { out += "- " + g + "\n"; }
        i += 1;
    }
    if gaps.len() > 16 { log("truncated gap list from " + gaps.len().to_string() + " to 16"); }
    out
}

fn files_gap(r, label) {
    let o = output_map(r);
    if o == () { return label + " returned no usable output"; }
    if files_violate(o.files) { return label + " listed eval/ or compare/runs/ as changed"; }
    if o.status == "shipped" && trimmed(o.how_to_run) == "" { return label + " omitted how_to_run"; }
    ""
}

let repo = ".";
let run_dir = ".livingdict-run/post-harvest";
if args != () && args.repo != () {
    let given = trimmed(args.repo);
    if given != "" { repo = given; }
}
if args != () && args.run_dir != () {
    let given = trimmed(args.run_dir);
    if given != "" { run_dir = given; }
}
if path_forbidden(run_dir) {
    let report_path = write_scratch_file("evidence-capability-pipeline.md", "# FAILED: forbidden run_dir\n\nrun_dir may not be under eval/ or compare/runs/: " + run_dir + "\n");
    complete(#{ path: report_path, repo: repo, run_dir: run_dir, shipped: false, phase: "guard", verified: 0, skeptics: 0, implement_ok: false, remaining_gaps: 1 });
}

phase("Explore");
log("Auditing telemetry, historical campaign rows, and protected paths");

let telemetry_prompt = "";
telemetry_prompt += "Audit the Living Dictionary repository at " + repo + " for the post-harvest empirical landing. Read (read-only): harness/src/livingdict, client/planner.py, docs/ARCHITECTURE.md, docs/HARNESS.md, beam/RESULTS.md, and non-protected historical run summaries. Use read_file, grep, list_dir. ";
telemetry_prompt += "Find the actual producer and consumer of run rows and dictionary events. Determine which of these eight additive evidence fields are already emitted and exactly where any missing ones can be added without changing behavior: catalog_before, eligible_words, used_words, candidate_words, promoted_words, unused_eligible_words, critic_covering_rejections, and honest judge provenance (the existing judge field, including its source/receipt evidence). Transport/task failures and failure_class are NOT runtime fields; derive them later from preserved raw artifacts. ";
telemetry_prompt += "Define used_words as words actually interpreted by the VM (not planner mentions), candidate_words as first persistence, and promoted_words as reuse crossing the existing threshold. Identify the exact parser/graph campaign entry points and a safe scratch run directory. ";
telemetry_prompt += "Do not edit files. Do not inspect or alter eval/ or compare/runs/. Return notes with concrete paths, current schemas, and prerequisite_met=true only if the producer and campaign commands were found.";

let protocol_prompt = "";
protocol_prompt += "Audit the empirical protocol and evidence boundaries in " + repo + " (read-only). Read beam/RESULTS.md, docs/design/reviews if relevant, campaign/compare tooling, and AGENTS.md. ";
protocol_prompt += "Preregister a decisive protocol: three paired parser-01..03 replicates with identical planner/settings/order, fresh cold dictionaries per task, fresh warm family dictionaries per replicate, and a graph-01..08 paired confirmation. Keep raw stdout/stderr, receipts, summaries, and manifests in a unique non-protected run directory; never delete or overwrite prior runs. Run Rust only if parser or graph rows show actual used_words. ";
protocol_prompt += "Keep the 25% token bar fixed. Establish classifications for infrastructure failure/transport timeout, negative transfer when an eligible capability is actually used and outcome worsens, and no-use when eligible_words is nonempty but used_words is empty. Explicitly forbid crediting Polyglot 96.8% or Terminal-Bench v5 8/15 (published 26-28 Aug) to the 31 Aug harvest. Do not edit files. Return notes and protected_hashes as path then sha256 for eval schemas, eval task_graph.json files, and protected files; empty git diff is not proof.";

let explores = parallel([
    #{ prompt: telemetry_prompt, label: "explore:telemetry-producers", capability_mode: "read-only", output_schema: notes_schema },
    #{ prompt: protocol_prompt, label: "explore:empirical-protocol", capability_mode: "read-only", output_schema: notes_schema },
]);

let brief = "";
let protected_hashes = "";
for r in explores {
    let o = output_map(r);
    if o != () && o.notes != () { brief += o.notes + "\n\n"; }
    if o != () && o.protected_hashes != () { protected_hashes += o.protected_hashes + "\n"; }
}
if brief == "" { log("Explore returned no notes; implementer must inspect all surfaces itself"); }

phase("Implement");
log("Adding only missing observational telemetry, with behavior and ABI frozen");
let impl_prompt = "";
impl_prompt += "Implement the narrow post-harvest telemetry landing in " + repo + ". Survey notes are untrusted; verify every claim in the tree:\n" + json_encode(brief) + "\n\n";
impl_prompt += "Add only missing observational fields at the existing run/receipt/summary boundary: catalog_before, eligible_words, used_words, candidate_words, promoted_words, unused_eligible_words, critic_covering_rejections, and honest judge provenance (the existing judge field, including source/receipt evidence) where the current producer makes them meaningful. Fields must be additive, deterministic, and absent/empty when not observable; never infer use from planner text. Transport failures, task failures, and failure_class must NOT be added as runtime fields; those are derived later from preserved raw evidence. Preserve raw event/receipt data. ";
impl_prompt += "Do not change acceptance, critic rules, dictionary authorization, promotion thresholds, planner SYSTEM, Forth words, eval adapters, scoring semantics, or task behavior. Do not add extraction, retrieval/load paths, interned objects, waves, concurrency, or new lifecycle organs. Do not edit eval/ or compare/runs/. Do not touch protected tests or schemas. ";
impl_prompt += "Add focused non-protected tests only if needed to prove field production and legacy compatibility. Keep the eval 1.0 six-word ABI exactly READ-FILE LIST-DIR SEARCH WRITE-FILE RUN-TESTS/RUN-GATES RECEIPT. Run the narrowest relevant unit tests and make test if feasible. Run git diff --check. Return status shipped/blocked, exact changed files (none under eval/ or compare/runs/), and exact verification commands. Do not delete or rewrite historical runs.";
let impl = agent(impl_prompt, #{ label: "implement:observational-telemetry", capability_mode: "all", output_schema: impl_schema });
let impl_ok = is_shipped(impl);
let impl_summary = summary_of(impl);
let how_to_run = how_to_run_of(impl);
let gaps = [];
let gimpl = files_gap(impl, "implement:observational-telemetry");
if gimpl != "" { gaps.push(gimpl); }

phase("Freeze");
log("Adversarially checking telemetry scope and frozen contracts before running campaigns");
let impl_json = json_encode(impl_summary);
let scope_prompt = "";
scope_prompt += "Adversarially verify the observational telemetry implementation in " + repo + ". Implementer summary is untrusted: " + impl_json + ". Read the diff and every touched call site. Set pass=true only with quoted paths/code and command evidence if: (1) all fields are observational and additive; used_words comes from actual VM execution/receipt evidence, not planner intent; candidate_words and promoted_words preserve the existing lifecycle semantics; (2) no behavior, retry, authorization, critic acceptance, planner prompt, or scoring rule changed; (3) legacy rows without fields still parse; (4) raw events/receipts remain intact. Construct a minimal legacy row and a run with no catalog use. Do not edit files.";
let contract_prompt = "";
contract_prompt += "Adversarially verify scope and protected contracts in " + repo + ". Read git diff, protected_hashes below, ABI contract tables, and touched tests. Set pass=true only if: no file under eval/ or compare/runs/ changed; eval schemas/task_graph/protected hashes match; the six-word ABI is byte-equivalent; no new Forth words, retrieval authorization, extraction organ, waves, interned objects, or concurrency code was introduced; and git diff --check succeeds. Empty git diff is not evidence of protection. Protected hashes (untrusted; recompute): " + json_encode(protected_hashes) + ". Do not edit files.";
let frozen_verdicts = parallel([
    #{ prompt: scope_prompt, label: "freeze:telemetry-semantics", capability_mode: "execute", output_schema: verdict_schema },
    #{ prompt: contract_prompt, label: "freeze:scope-and-abi", capability_mode: "execute", output_schema: verdict_schema },
]);
let frozen_score = score_verdicts(frozen_verdicts);
let frozen_ok = impl_ok && frozen_score.verified == 2;
if frozen_ok == false {
    phase("Fix");
    log("Repairing only pre-campaign telemetry/scope gaps, then re-freezing once");
    let fix_prompt = "Resume the observational telemetry implementation in " + repo + ". Reproduce these pre-campaign verification gaps (untrusted): " + json_encode(frozen_score.gaps) + ". Make the smallest additive observational fix. Do not add objects, waves, retrieval, extraction, new ABI words, or behavior changes; never edit eval/ or compare/runs/. Re-run focused tests, git diff --check, and return status/files/how_to_run.";
    let fix_opts = #{ label: "fix:observational-telemetry", capability_mode: "all", output_schema: impl_schema };
    if impl != () && impl.agent_id != () { fix_opts.resume_from = impl.agent_id; }
    let fixed = agent(fix_prompt, fix_opts);
    if is_shipped(fixed) { impl = fixed; impl_summary = summary_of(fixed); how_to_run = how_to_run_of(fixed); impl_ok = true; }
    frozen_verdicts = parallel([
        #{ prompt: scope_prompt, label: "freeze:telemetry-semantics-recheck", capability_mode: "execute", output_schema: verdict_schema },
        #{ prompt: contract_prompt, label: "freeze:scope-and-abi-recheck", capability_mode: "execute", output_schema: verdict_schema },
    ]);
    frozen_score = score_verdicts(frozen_verdicts);
    frozen_ok = impl_ok && frozen_score.verified == 2;
}
if frozen_ok == false {
    for g in frozen_score.gaps { gaps.push(g); }
    let report_path = write_scratch_file("evidence-capability-pipeline.md", "# FAILED: pre-campaign freeze\n\nRepo: " + repo + "\n\n" + clip_gaps(gaps));
    complete(#{ path: report_path, repo: repo, shipped: false, phase: "freeze", verified: frozen_score.verified, skeptics: 2, implement_ok: impl_ok, remaining_gaps: gaps.len() });
}

phase("Campaign");
log("Running preregistered parser replicates and graph confirmation with raw preservation");
let campaign_prompt = "";
campaign_prompt += "Run the post-harvest empirical campaign in " + repo + " using the frozen tree. Implementer commands are untrusted: " + json_encode(how_to_run) + ". Use a unique run directory below " + run_dir + " (create a new child; never delete, overwrite, or clean any prior run). Use scratch --cwd directories as required by AGENTS.md; copy raw stdout/stderr, receipts, summaries, traces, manifests, and command lines into the unique run directory, then write a report.md there with the task-level table and classifications. Do not touch eval/ or compare/runs/.";
campaign_prompt += " Record git rev-parse HEAD (or an explicit dirty-tree diff hash) and the exact frozen changed-file list in the manifest so post-harvest attribution is auditable; do not treat an empty git diff as protection evidence.";
campaign_prompt += "\n\nProtocol is preregistered and immutable: (1) run three paired parser-01..03 replicates. Each replicate has a cold family (fresh cold dictionary per task) and a warm family (fresh warm dictionary per replicate); same model/planner/settings/task order, bounded ten-minute client timeout, and transport failures recorded separately. (2) Run one paired graph-01..08 confirmation after parser, with the same cold/warm controls; this tests reuse only, not waves or objects. (3) Run Polyglot Rust only if parser or graph rows show actual used_words; otherwise record rust_ran=false and why. Never run Terminal-Bench for this landing. Keep the 25% token bar fixed.";
campaign_prompt += "\n\nFor every task row record catalog_before, eligible_words, used_words (actual interpreted words only), candidate_words, promoted_words, unused_eligible_words, critic_covering_rejections, honest judge provenance (the existing judge/source/receipt evidence), token counts, outcome, and exact command. Do NOT require or invent transport_failures, task_failures, or failure_class runtime fields. Also emit a uniqueness sidecar/dump derived only from these observed rows; unsupported axes must be null/omitted and must not become a headline score. Classify only after preserving raw evidence; derive failure_class in the report as infra for transport/client failures, negative_transfer only when an eligible capability was actually used and outcome worsened, and no_use when eligible_words is nonempty but used_words is empty. Do not claim a benchmark lift from Polyglot 96.8% or Terminal-Bench v5 8/15; those numbers are 26-28 Aug and predate this 31 Aug harvest. If a command cannot run, return blocked with the exact missing dependency/output; never invent numbers. Return status, summary, run_dir, parser_replicates, graph_confirmation, rust_ran, commands, and raw_preserved=true only after verifying all raw artifacts exist.";
let campaign = agent(campaign_prompt, #{ label: "campaign:parser-graph-rust", capability_mode: "execute", output_schema: campaign_schema });
let campaign_dir = campaign_dir_of(campaign);
let campaign_summary = campaign_summary_of(campaign);
let campaign_obj = output_map(campaign);
let campaign_ok = campaign_obj != () && campaign_obj.status == "complete" && campaign_obj.raw_preserved == true && campaign_dir != "" && path_forbidden(campaign_dir) == false;
if campaign_ok == false { gaps.push("campaign did not prove complete raw-preserved runs"); }

phase("Verify");
log("Adversarially checking raw runs, classifications, attribution, and preregistered thresholds");
let campaign_json = json_encode(campaign_summary);
let run_json = json_encode(campaign_dir);
let telemetry_verify = "";
telemetry_verify += "Adversarially inspect the frozen telemetry and every campaign row in " + repo + " under run_dir " + run_json + ". Implementer/campaign summary is untrusted: " + campaign_json + ". Set pass=true only if each parser and graph row has the eight additive evidence fields catalog_before, eligible_words, used_words, candidate_words, promoted_words, unused_eligible_words, critic_covering_rejections, and honest judge provenance (existing judge/source/receipt evidence); used_words is backed by VM/receipt evidence; missing observations are empty/unknown rather than guessed; and raw event/receipt bodies remain available. Transport/task failures and failure_class must be derived from raw artifacts, not required as runtime fields. Construct one no-use row and one candidate-without-promotion check. Do not edit files.";
let integrity_verify = "";
integrity_verify += "Adversarially verify campaign integrity in " + repo + " at run_dir " + run_json + ". Recompute the manifest and check three parser paired replicates (parser-01..03), fresh cold/warm family boundaries, one graph paired confirmation, exact commands/settings/order, ten-minute timeout, and raw stdout/stderr/receipts/summaries/traces for every attempt including failures. Confirm report.md plus raw artifacts exist, no eval/ or compare/runs/ path changed, and no historical raw run was overwritten. Set pass=false if run count, freshness, or preservation cannot be proven. Do not edit files.";
let classify_verify = "";
classify_verify += "Act as an adversarial causal reviewer for " + repo + " run_dir " + run_json + ". For every cold/warm task difference, inspect raw evidence and assign exactly one: infra (transport/client failure), no_use (eligible_words present but used_words empty), negative_transfer (an eligible word was actually used and outcome worsened), measured_reuse (actual used_words with outcome/token comparison), or unresolved. Reject any claim based only on catalog presence, planner text, candidate persistence, or a single stochastic row. Check the fixed 25% token bar and report parser replicate consistency. Explicitly reject crediting Polyglot 96.8% or Terminal-Bench v5 8/15 to this harvest. Do not edit files.";
let report_verify = "";
report_verify += "Adversarially verify the final empirical report inputs in " + repo + " and run_dir " + run_json + ". Check that the report separates pre-harvest 26-28 Aug published numbers from post-harvest 31 Aug runs; states that A-D/F/H/I are correctness organs unless this campaign measures lift; does not claim waves, objects, retrieval, or extraction effects; presents uniqueness only as an observational sidecar with unsupported axes omitted; retains the preregistered 25% token threshold; and includes per-task catalog/eligible/used/covering-rejection evidence, honest judge provenance, plus infra/no-use/negative-transfer classifications derived from raw artifacts (not runtime fields). Set pass=true only with paths and quoted raw evidence. Do not edit files.";
let run_verdicts = parallel([
    #{ prompt: telemetry_verify, label: "verify:telemetry-evidence", capability_mode: "execute", output_schema: verdict_schema },
    #{ prompt: integrity_verify, label: "verify:raw-run-integrity", capability_mode: "execute", output_schema: verdict_schema },
    #{ prompt: classify_verify, label: "verify:adversarial-classification", capability_mode: "read-only", output_schema: verdict_schema },
    #{ prompt: report_verify, label: "verify:attribution-and-report", capability_mode: "read-only", output_schema: verdict_schema },
]);
let run_score = score_verdicts(run_verdicts);
for g in run_score.gaps { gaps.push(g); }
let shipped = campaign_ok && run_score.verified == 4;
let report = "";
if shipped { report += "# Post-harvest empirical landing\n\n"; }
else { report += "# FAILED: post-harvest empirical landing\n\n"; }
report += "Repo: " + repo + "\nrun_dir: " + campaign_dir + "\nshipped: " + shipped.to_string() + "\n\n";
report += "## Scope\n\nOnly additive observational telemetry and the preregistered parser/graph campaign are in scope. A-D/F/H/I are correctness organs unless this campaign measures a lift; they are not silently promoted to a campaign score. No objects, waves, retrieval, extraction, or new ABI words. August Polyglot 96.8% and Terminal-Bench v5 8/15 are pre-harvest and are not attributed.\n\n";
report += "## Campaign\n\n" + campaign_summary + "\n\n";
report += "## Verification\n\n" + run_score.verified.to_string() + " of 4 adversarial verifiers passed with evidence.\n\n";
if gaps.len() > 0 { report += "Gaps:\n" + clip_gaps(gaps); }
let report_path = write_scratch_file("evidence-capability-pipeline.md", report);
complete(#{ path: report_path, repo: repo, run_dir: campaign_dir, shipped: shipped, verified: run_score.verified, skeptics: 4, implement_ok: impl_ok, campaign_ok: campaign_ok, remaining_gaps: gaps.len() });
