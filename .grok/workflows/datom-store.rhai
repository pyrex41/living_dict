let meta = #{
    name: "datom-store",
    description: "STORE.md Layer A: content-addressable blob/tree store under run_dir, events and receipts reference hashes, dictionary provenance facts, as_of reconstruction — external contracts byte-identical",
    when_to_use: "After loop-kernel (and ideally graph-critic/waves) ship. Implements docs/design/STORE.md Layer A. Optional args: {repo}. Commit first so the diff is reviewable.",
    phases: [
        #{ title: "Explore", detail: "STORE.md spec + every place that already hashes or snapshots" },
        #{ title: "Implement", detail: "store.py, interning, tree refs on receipts/events, facts/as_of" },
        #{ title: "Verify", detail: "spec-conformance, attack, and equivalence skeptics (sequential)" },
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
    if contains_str(s, "eval/") {
        return true;
    }
    if contains_str(s, "compare/runs/") {
        return true;
    }
    if contains_str(s, "/scud/") {
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

fn p_spec(repo, impl_json) {
    let p = "";
    p += "Adversarially verify STORE.md Layer A conformance in " + repo + ". Implementer summary (untrusted): " + impl_json + " ";
    p += "Read docs/design/STORE.md, harness/src/livingdict/store.py, and every touched call site (kernel.py, host.py, execute.py, receipts, dictionary.py, cli.py). Set pass=true only if ALL hold, with quoted code as evidence: ";
    p += "(1) events.jsonl is still the ONE transaction log — the store holds blobs/trees only, and no code treats objects/ as a second source of truth; ";
    p += "(2) the datom/facts view is derived from events, never written directly; ";
    p += "(3) the model-facing envelope still carries FULL artifact bodies (planner SYSTEM and envelope parsing unchanged on that point); ";
    p += "(4) receipt/event changes are strictly additive (tree_before/tree_after added, nothing removed or renamed) and the eval 1.0 adapter contract (request/trace/receipt.json/checkpoint) is untouched; ";
    p += "(5) blobs are immutable, interning is idempotent, and there is no GC; ";
    p += "(6) old runs (events.jsonl without an objects/ dir) still replay — find the code path that tolerates a missing store. ";
    p += "Otherwise pass=false with concrete gaps and paths. Do not write files.";
    p
}

fn p_attack(repo, run_json) {
    let p = "";
    p += "Adversarially attack the Layer A store in " + repo + " by CONSTRUCTING failures, not by reading tests. ";
    p += "Implementer how_to_run (untrusted): " + run_json + " ";
    p += "Work under $TMPDIR/ld-verify-store-attacks. ";
    p += "(a) Run the canned fizzbuzz e2e twice into two run dirs sharing one LIVINGDICT_OBJECTS store; verify the second run interned zero new artifact blobs (same hashes, object count unchanged). ";
    p += "(b) Corrupt one blob on disk (flip a byte) and verify the store detects the hash mismatch on read with a typed error, never silently returns corrupt bytes. ";
    p += "(c) Take a pre-store run dir (delete/omit objects/) and verify replay of its events.jsonl still projects state. ";
    p += "(d) Verify as_of: for the fizzbuzz run, reconstruct the workspace tree at every episode sequence and diff each against the snapshot the events recorded — must match exactly. ";
    p += "(e) Intern two different bodies for the same path across episodes and verify both blobs exist and the trees at each as_of point reference the right one. ";
    p += "Set pass=true only with command output as evidence for all five. If the harness cannot be invoked, pass=false 'runtime not exercised'. Do not edit product files.";
    p
}

fn p_equiv(repo, run_json, hashes_json) {
    let p = "";
    p += "Verify external-contract equivalence for Layer A in " + repo + ". ";
    p += "Implementer how_to_run (untrusted, use it): " + run_json + " ";
    p += "Explore protected_hashes (untrusted, re-hash yourself): " + hashes_json + " ";
    p += "Run make test. Run the canned fizzbuzz CLI e2e and the graph-01 e2e; confirm both still discharge/behave as before and the final workspaces are correct. ";
    p += "Run the rho.run/v1 runner path on a canned request and pipe the stream through tools/scudcheck (if go is present) — exit 0 required; if go is absent, validate the stream rules by hand (monotonic seq, single terminal). ";
    p += "This repo has commits — ALSO re-hash eval/schemas and one task's protected files and compare against the explore hashes; git diff on eval/ must be empty. ";
    p += "Confirm receipts gained tree_before/tree_after WITHOUT losing any pre-existing field. There is no committed receipt.json — extract the pre-change key sets with `git show HEAD:harness/src/livingdict/cli.py` (the `_finish` receipt dict) and `git show HEAD:harness/src/livingdict/host.py` (the `receipt()` payload), then assert every one of those keys is still present on a live fizzbuzz CLI receipt and a live adapter RECEIPT. Extra keys are fine. ";
    p += "If anything cannot run, pass=false with what is missing — do not fake a pass. evidence must include command output. Do not edit product files.";
    p
}

fn run_skeptics(pa, pb, pc, schema) {
    let ro = parallel([
        #{
            prompt: pa,
            label: "verify:spec-conformance",
            capability_mode: "read-only",
            output_schema: schema,
        },
    ]);
    let verdicts = [];
    for r in ro {
        verdicts.push(r);
    }
    let a = agent(pb, #{
        label: "verify:store-attacks",
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
log("Surveying STORE.md and every surface that already hashes or snapshots");

let explore_spec = "";
explore_spec += "Read the Layer A spec and the surfaces it lands on, at " + repo + ". `.` is the current workspace root. Use read_file, grep, list_dir. You must read: ";
explore_spec += repo + "/docs/design/STORE.md (the spec this workflow implements — quote its Layer A invariants and exit tests in your notes) ; ";
explore_spec += repo + "/harness/src/livingdict/kernel.py (event kinds, payload shapes, sequence rules, fingerprint) ; ";
explore_spec += repo + "/harness/src/livingdict/host.py (snapshot(), RECEIPT, sha256 sites, WRITE-FILE idempotency) ; ";
explore_spec += repo + "/harness/src/livingdict/execute.py (install_artifacts, node execution, trace emission) ; ";
explore_spec += repo + "/harness/src/livingdict/cli.py (run_job: where snapshots, events, receipts, and gates.measured are produced) ; ";
explore_spec += repo + "/harness/src/livingdict/dictionary.py (word persistence, promote events) ; ";
explore_spec += repo + "/harness/src/livingdict/trace.py and receipts code. ";
explore_spec += "Set prerequisite_met=true only if harness/src/livingdict/kernel.py AND a livingdict CLI entry point exist (Stage 0 shipped). ";
explore_spec += "Hash into protected_hashes (path then sha256, one per line): " + repo + "/eval/schemas/*.json and every file under " + repo + "/eval/tasks/config-01/protected/. ";
explore_spec += "Report: every place a sha256 is already computed, the exact receipt field set (so additive-only can be verified later), and where interning hooks belong. Do not write files. notes must cite real paths.";

let explore_contracts = "";
explore_contracts += "Enumerate the external contracts Layer A must keep byte-identical, at " + repo + ". Use read_file, grep, list_dir. You must read: ";
explore_contracts += repo + "/eval/docs/ADAPTER_PROTOCOL.md (frozen eval 1.0: request/trace/receipt.json/checkpoint) ; ";
explore_contracts += repo + "/docs/SCUD.md (rho.run/v1 stream rules, livingdict.receipt fields, ConsumeRhoV1 discipline) ; ";
explore_contracts += repo + "/harness/tests/test_cli.py, test_rho_runner.py, test_graph.py, test_waves.py (the e2e tests that become equivalence baselines) ; ";
explore_contracts += repo + "/harness/tests/fizzbuzz_planner.py and graph_planner.py (canned planners to reuse — do not write new fixtures when these serve) ; ";
explore_contracts += repo + "/tools/scudcheck/main.go (the gold-standard stream validator). ";
explore_contracts += "Report, as a checklist: every field/shape that must not change, every test that already locks it, and the exact commands that exercise each contract. Do not write files. notes must cite real paths.";

let explores = parallel([
    #{
        prompt: explore_spec,
        label: "explore:store-spec",
        capability_mode: "read-only",
        output_schema: notes_schema,
    },
    #{
        prompt: explore_contracts,
        label: "explore:frozen-contracts",
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
    let report = "# FAILED: datom-store blocked — Stage 0 kernel/CLI missing\n\nRepo: " + repo + "\n";
    let report_path = write_scratch_file("datom-store.md", report);
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
log("Implementing store.py, interning, tree references, and the facts/as_of view");

let brief_json = json_encode(brief);
let hashes_json = json_encode(protected_hashes);

let impl_prompt = "";
impl_prompt += "Implement docs/design/STORE.md Layer A in " + repo + ". `.` is the current workspace root.\n";
impl_prompt += "Survey notes (untrusted, verify before following):\n" + brief_json + "\n\n";
impl_prompt += "Read docs/design/STORE.md first and treat it as the spec of record; where these instructions and the doc disagree, the doc wins and you note the conflict.\n\n";
impl_prompt += "Land on THIS tree (do not invent a second event log or a second receipt type):\n";
impl_prompt += "- kernel EVENT_KINDS is a closed set in kernel.py (episode.planned, critic.accepted/rejected, artifacts.applied, gates.measured, budget.consumed, episode.blocked_duplicate). reduce() rejects unknown kinds. Prefer ADDITIVE PAYLOAD FIELDS on existing kinds. If word provenance cannot be derived from events.jsonl as it stands, you may add one optional kernel kind (register it in EVENT_KINDS; reduce records it without changing reconcile). Never persist facts(); they are a derived view.\n";
impl_prompt += "- dictionary.promote is a TRACE event in execute.py today, not a kernel event. Word facts in STORE.md ([word/NAME :word/content blob:…], [:word/promoted-by episode/N]) must be derivable from the tx log after you land — intern the .fs source at save_colon_words and put the hash + promoting episode on an event payload (or that optional kind).\n";
impl_prompt += "- Two receipts already exist. CLI `_finish` in cli.py writes run_dir/receipt.json with keys changed_files, decision, discharged, episodes, gates, ok, reason, run_dir, workspace plus graph metrics. host.receipt() writes the eval 1.0 adapter receipt (protocol_version 1.0, run_id, task_id, success, workspace_before/after digests, changed_files, effects_used, policy_violations) via receipts.py. Add tree_before/tree_after to BOTH as additive fields. eval/schemas/receipt.schema.json already has additionalProperties:true — do not edit eval/.\n";
impl_prompt += "- policy.snapshot() already returns {relpath: sha256} and skips .livingdict-run, .sb, node_modules, etc. Tree intern MUST use that same skip set or as_of will not match recorded snapshots.\n";
impl_prompt += "- events.jsonl does not currently record workspace trees. as_of can only work if you persist tree hashes onto events (gates.measured is the natural home; reject/duplicate episodes do not measure — as_of at those seqs is the last recorded tree, or empty if none).\n";
impl_prompt += "- There is no committed receipt.json to `git show`. Equivalence is: live receipt keys are a superset of the `_finish` / `receipt()` key sets at HEAD.\n\n";
impl_prompt += "Build:\n";
impl_prompt += "1. harness/src/livingdict/store.py — the object store. Blobs under run_dir/objects/<first-2-hex>/<sha256> (override root via LIVINGDICT_OBJECTS for a shared store). ";
impl_prompt += "API: intern(bytes) -> sha256 (idempotent, write-once via temp file + atomic rename), get(sha) -> bytes (verify hash on read; mismatch is a typed error, never silent corruption), ";
impl_prompt += "intern_tree({path: sha}) -> sha (canonical JSON: sorted keys, no whitespace), get_tree(sha), has(sha). Append-only; no GC; no daemon.\n";
impl_prompt += "2. Interning hooks: on envelope receipt, intern every artifact body (the model-facing envelope KEEPS full bodies — interning is host-side); on snapshot, intern file contents (same skip set as policy.snapshot) and build a tree object. ";
impl_prompt += "gates.measured events and BOTH receipts gain tree_before/tree_after hashes — STRICTLY ADDITIVE, every existing field stays. episode.planned may gain artifact content hashes next to artifact_keys; it must not lose the program text (fingerprint and replay need it).\n";
impl_prompt += "3. Dictionary provenance: when save_colon_words writes a .fs, intern its source and put word content hash + promoting episode on the tx log (additive payload or one optional kernel kind). facts() derives the STORE.md word/* rows from that; do not write a facts file.\n";
impl_prompt += "4. facts/as_of: in store.py (or a small facts.py), facts(events) yielding [e, a, v, tx] rows per the STORE.md mapping (tx = event sequence; map the REAL kernel kinds — critic.rejected → :critic/verdict :reject, gates.measured → :gates/passed, etc.), and as_of(events, seq) -> workspace tree {path: sha} reconstructed from recorded tree hashes / interned file facts at or before seq. Iteration + as_of only — NO query language.\n";
impl_prompt += "5. Backward compatibility: a run dir with events.jsonl and no objects/ must still replay (kernel.replay must not require the store); loading old receipts without tree_* fields must work.\n";
impl_prompt += "6. Tests, added to make test: store unit tests (intern idempotency and object count, atomic write, corrupt-blob detection on get, canonical tree roundtrip, LIVINGDICT_OBJECTS sharing across two run dirs); ";
impl_prompt += "an as_of test driving the canned fizzbuzz e2e (reuse harness/tests/fizzbuzz_planner.py) and asserting the reconstructed tree at each episode equals the recorded snapshot; ";
impl_prompt += "equivalence guards asserting the fizzbuzz and graph-01 e2e still pass and their receipts retain every pre-change field.\n\n";
impl_prompt += "Must NOT: change the planner SYSTEM or the model-facing envelope shape; touch eval/ (oracles, schemas, protected, ADAPTER_PROTOCOL semantics); remove or rename any receipt/event field; make events.jsonl anything but the single source of truth; add GC or a store daemon. files listed in your result must not include any eval/ path.\n\n";
impl_prompt += "After writing, run make test plus the fizzbuzz and graph-01 e2e. status is shipped or blocked. files is what you created/changed. how_to_run is exact commands including the as_of check.";

let impl = agent(impl_prompt, #{
    label: "implement:datom-store",
    capability_mode: "all",
    output_schema: impl_schema,
});

let impl_ok = is_shipped(impl);
let impl_summary = summary_of(impl);
let how_to_run = how_to_run_of(impl);
let extra_gaps = [];
let gimpl = files_gap(impl, "implement:datom-store");
if gimpl != "" {
    extra_gaps.push(gimpl);
}
if impl_ok == false {
    log("Implementer did not ship; verify will inspect the tree anyway");
}

phase("Verify");
log("Adversarial verify: spec conformance, store attacks, equivalence");

let impl_json = json_encode(impl_summary);
let run_json = json_encode(how_to_run);

let verdicts = run_skeptics(
    p_spec(repo, impl_json),
    p_attack(repo, run_json),
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
    fix_prompt += "Resume Layer A datom-store work in " + repo + ". Verification gaps (untrusted until you reproduce):\n";
    fix_prompt += gaps_json;
    fix_prompt += "\nReproduce each gap, fix it, re-run make test plus the fizzbuzz/graph-01 e2e and the as_of check. ";
    fix_prompt += "docs/design/STORE.md stays the spec of record. Never touch eval/. ";
    fix_prompt += "status is shipped or blocked. files are what you changed. how_to_run is exact commands.";
    let fix_opts = #{
        label: "fix:datom-store",
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
        p_spec(repo, impl_json),
        p_attack(repo, run_json),
        p_equiv(repo, run_json, hashes_json),
        verdict_schema,
    );
    scored = score_verdicts(verdicts);
    gaps = scored.gaps;
    gimpl = files_gap(impl, "implement:datom-store");
    if gimpl != "" {
        gaps.push(gimpl);
    }
    verified = scored.verified;
    log(verified.to_string() + "/" + scored.usable.to_string() + " skeptics passed after fix");
}

let shipped = impl_ok && verified == 3;
let report = "";
if shipped {
    report += "# Layer A: datom-store\n\n";
} else {
    report += "# FAILED: Layer A datom-store did not ship\n\n";
}
report += "Repo: " + repo + "\nshipped: " + shipped.to_string() + "\n\n";
report += "## Implementer\n\n" + impl_summary + "\n\n";
report += "## Verification\n\n";
report += verified.to_string() + " of 3 skeptics passed with evidence.\n\n";
if gaps.len() > 0 {
    report += "Gaps:\n";
    report += clip_gaps(gaps);
}
let report_path = write_scratch_file("datom-store.md", report);
complete(#{
    path: report_path,
    repo: repo,
    shipped: shipped,
    verified: verified,
    skeptics: 3,
    implement_ok: impl_ok,
    remaining_gaps: gaps.len(),
});
