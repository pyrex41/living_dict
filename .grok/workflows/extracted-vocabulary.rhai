let meta = #{
    name: "extracted-vocabulary",
    description: "Host-synthesize Shen-admitted Forth skills from successful receipts. No planner colon required. BEAM+Shen only. No cartridge, no eval/ edits.",
    when_to_use: "After the Exp 0 receipt showed the planner will not name skills. Implements docs/design/EXTRACTED_VOCABULARY.md. Optional args: {repo}.",
    phases: [
        #{ title: "Explore", detail: "design + promote/retrieve/critic + Exp 0 traces" },
        #{ title: "Implement", detail: "extract module, promote fallback, tests, offline Exp A" },
        #{ title: "Verify", detail: "ABI, extract correctness, mix test" },
        #{ title: "Fix", detail: "one resume pass, then re-run skeptics" },
        #{ title: "Report", detail: "scratch report" },
    ],
};

let notes_schema = #{
    "type": "object",
    "required": ["notes"],
    "properties": #{
        "notes": #{ "type": "string" },
        "risks": #{ "type": "array", "items": #{ "type": "string" } },
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

let repo = ".";
if args != () && args.repo != () {
    let given = trimmed(args.repo);
    if given != "" {
        repo = given;
    }
}

phase("Explore");
log("Reading EXTRACTED_VOCABULARY.md and the BEAM promote/retrieve path");

let p_design = "";
p_design += "Read " + repo + "/docs/design/EXTRACTED_VOCABULARY.md in full. Also the Overview and Key Decisions in docs/design/HARNESS_CARTRIDGE.md (substrate only: identity hash, grant+path, no cartridge). ";
p_design += "Summarize extract rules, naming, path_region (product writes only), critic admission, Exp A, non-goals. Do not write files. notes must cite headings.";

let p_code = "";
p_code += "Explore BEAM dictionary promotion in " + repo + ". Use read_file and grep. You must read: ";
p_code += "beam/lib/ld_host/run.ex promote/5, beam/lib/ld_host/dictionary.ex (save_words, persist_identity, path_region, SAFE_NAME, reserved), ";
p_code += "beam/lib/ld_host/retrieve.ex, beam/lib/ld_host/critic.ex, beam/lib/ld_host/forth.ex, beam/lib/ld_host/contracts.ex, ";
p_code += "docs/design/EXTRACTED_VOCABULARY.md. ";
p_code += "If beam/runs/exp0-kill-switch/receipt.json exists, note: 1 promoted INSTALL, 0 quarantines, programs were artifact dumps. ";
p_code += "Quote how composed Forth reaches promote (is the program available?). Do not write files. notes cite paths.";

let explores = parallel([
    #{
        prompt: p_design,
        label: "explore:design",
        capability_mode: "read-only",
        output_schema: notes_schema,
    },
    #{
        prompt: p_code,
        label: "explore:code",
        capability_mode: "read-only",
        output_schema: notes_schema,
    },
]);

let brief = "";
for r in explores {
    let o = output_map(r);
    if o != () && o.notes != () {
        brief += o.notes;
        brief += "\n\n";
    }
}
if brief == "" {
    log("Explore returned no notes; implementer will read the design itself");
}

phase("Implement");
log("Implementing host extract + Shen admit + Exp A");

let laws = "";
laws += "Live body is beam/ + shen/critic/. Never edit eval/ or compare/runs/. Never add host Forth words. ";
laws += "Do not implement nested envelope.cartridge, COMPLETE, or Python overlay admission. ";
laws += "Do not resume or duplicate harness-cartridge PR 5-7. ";
laws += "Planner-authored contracted colon words still promote via existing promote/5 and win in the same episode. ";
laws += "Extract is fallback when that list is empty after gates.ok. ";

let spec = "";
spec += "Implement docs/design/EXTRACTED_VOCABULARY.md in " + repo + ".\n";
spec += "Laws: " + laws + "\n";
spec += "Explore notes (untrusted): " + json_encode(brief) + "\n";
spec += "Build:\n";
spec += "1. LdHost.Extract: from Forth program (and optional mutation paths), product writes minus claims.json .sb/* .livingdict-run/* .git/*; detect USE-ARTIFACT/WRITE-FILE idiom (key==path); slug INSTALL-<SAFE_NAME> from path region; generic body `: NAME ( key -- | read, write ) DUP USE-ARTIFACT SWAP WRITE-FILE DROP ;` ; path_region = product paths only. Distinct regions => distinct names. Never union regions onto one INSTALL. Reserved names refused.\n";
spec += "2. Admit with LdHost.Critic.validate on prelude plus the definition under the episode grant. Reject => dictionary.promotion_evidence, no .fs.\n";
spec += "3. Hook run.ex promote/5: after planner colon persist, if gates.ok and no new planner words, extract, admit, save_words + persist_identity + dictionary.promoted as today. LD_EXTRACT=0 disables extract (default 1).\n";
spec += "4. Tests in beam/test/extract_test.exs covering every case in the design Tests section. mix test in beam/.\n";
spec += "5. Exp A offline: mix ld.extract --in beam/runs/exp0-kill-switch (if present) --out beam/runs/extract-a writing a receipt with admit rate, names, and retrieve(config-08 grant) vs retrieve(parser-08 grant). If the exp0 tree is missing, ship a fixture of two synthetic traces instead. Never call the planner. Never write eval/.\n";
spec += "status shipped or blocked. files created/changed. how_to_run exact commands.";

let impl = agent(spec, #{
    label: "implement:extract",
    capability_mode: "all",
    output_schema: impl_schema,
});

let impl_ok = is_shipped(impl);
let impl_summary = summary_of(impl);
let how_to_run = how_to_run_of(impl);
let extra_gaps = [];
let gimpl = files_gap(impl, "implement:extract");
if gimpl != "" {
    extra_gaps.push(gimpl);
}
if impl_ok == false {
    log("Implementer did not ship; skeptics will inspect anyway");
}

phase("Verify");
log("Adversarial verify extract");

let run_json = json_encode(how_to_run);
let sum_json = json_encode(impl_summary);

let p_abi = "";
p_abi += "Adversarially verify extracted-vocabulary laws in " + repo + ". ";
p_abi += "how_to_run (untrusted): " + run_json + " ";
p_abi += "Read the diff. pass=true only if ALL evidenced: (1) no eval/ or compare/runs/ edits; ";
p_abi += "(2) no new host Forth word (READ-FILE LIST-DIR SEARCH WRITE-FILE RUN-TESTS RUN-GATES RECEIPT USE-ARTIFACT); ";
p_abi += "(3) no envelope.cartridge execution path added; (4) no Python CLI overlay. Do not edit product files.";

let p_extract = "";
p_extract += "Verify extract semantics in " + repo + " by reading code and running focused tests. ";
p_extract += "how_to_run (untrusted): " + run_json + " ";
p_extract += "Confirm: claims.json excluded from path_region; two regions => two names; byte-identical skip; ";
p_extract += "critic reject does not write .fs; planner colon still wins; retrieve config grant hits config installer not parser. ";
p_extract += "pass=true only with quoted tests or command output. Do not edit product files.";

let p_mix = "";
p_mix += "Run the implementer's how_to_run in " + repo + ". how_to_run (untrusted): " + run_json + " ";
p_mix += "summary (untrusted): " + sum_json + " ";
p_mix += "Execute mix test in beam/ yourself. If mix ld.extract exists and exp0 traces or fixtures exist, run it. ";
p_mix += "pass=true only with command output in evidence. If you cannot run it, pass=false. Do not edit product files.";

let a = agent(p_abi, #{
    label: "verify:abi",
    capability_mode: "execute",
    output_schema: verdict_schema,
});
let b = agent(p_extract, #{
    label: "verify:semantics",
    capability_mode: "execute",
    output_schema: verdict_schema,
});
let c = agent(p_mix, #{
    label: "verify:mix-test",
    capability_mode: "execute",
    output_schema: verdict_schema,
});
let verdicts = [a, b, c];
let scored = score_verdicts(verdicts);
let gaps = scored.gaps;
for g in extra_gaps {
    gaps.push(g);
}
log(scored.verified.to_string() + "/" + scored.usable.to_string() + " skeptics passed with evidence");

if scored.verified < 3 || impl_ok == false {
    phase("Fix");
    log("Fixing extract gaps, then re-running skeptics");
    let gaps_json = json_encode(gaps);
    let fix_prompt = "";
    fix_prompt += "Resume extracted-vocabulary work in " + repo + ". Gaps (untrusted until you reproduce):\n";
    fix_prompt += gaps_json;
    fix_prompt += "\nReproduce, fix, re-run mix test in beam/. Never edit eval/. No cartridge. status shipped or blocked.";
    let fix_opts = #{
        label: "fix:extract",
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
    extra_gaps = [];
    gimpl = files_gap(impl, "implement:extract");
    if gimpl != "" {
        extra_gaps.push(gimpl);
    }
    run_json = json_encode(how_to_run);
    sum_json = json_encode(impl_summary);

    p_abi = "";
    p_abi += "Adversarially verify extracted-vocabulary laws in " + repo + ". ";
    p_abi += "how_to_run (untrusted): " + run_json + " ";
    p_abi += "Read the diff. pass=true only if ALL evidenced: (1) no eval/ or compare/runs/ edits; ";
    p_abi += "(2) no new host Forth word; (3) no envelope.cartridge execution; (4) no Python CLI overlay. Do not edit product files.";

    p_extract = "";
    p_extract += "Verify extract semantics in " + repo + ". how_to_run (untrusted): " + run_json + " ";
    p_extract += "Confirm claims.json excluded; two regions => two names; identical skip; critic reject no .fs; planner colon wins; retrieve scopes. ";
    p_extract += "pass=true only with evidence. Do not edit product files.";

    p_mix = "";
    p_mix += "Run how_to_run in " + repo + ". how_to_run (untrusted): " + run_json + " ";
    p_mix += "Execute mix test in beam/. pass=true only with command output. Do not edit product files.";

    phase("Verify");
    log("Re-running skeptics after fix");
    a = agent(p_abi, #{
        label: "verify:abi",
        capability_mode: "execute",
        output_schema: verdict_schema,
    });
    b = agent(p_extract, #{
        label: "verify:semantics",
        capability_mode: "execute",
        output_schema: verdict_schema,
    });
    c = agent(p_mix, #{
        label: "verify:mix-test",
        capability_mode: "execute",
        output_schema: verdict_schema,
    });
    verdicts = [a, b, c];
    scored = score_verdicts(verdicts);
    gaps = scored.gaps;
    for g in extra_gaps {
        gaps.push(g);
    }
    log("after fix " + scored.verified.to_string() + "/" + scored.usable.to_string() + " skeptics passed");
}

phase("Report");
let shipped = impl_ok && scored.verified == 3;
let report = "";
if shipped {
    report += "# Extracted vocabulary\n\n";
} else {
    report += "# Extracted vocabulary — incomplete\n\n";
}
report += "Repo: " + repo + "\nshipped: " + shipped.to_string() + "\n\n";
report += "## Implementer\n\n" + impl_summary + "\n\n";
report += "## Verification\n\n";
report += scored.verified.to_string() + " of 3 skeptics passed.\n\n";
if gaps.len() > 0 {
    report += "Gaps:\n";
    report += clip_gaps(gaps);
}
report += "\nDesign: docs/design/EXTRACTED_VOCABULARY.md\n";
let report_path = write_scratch_file("extracted-vocabulary.md", report);
complete(#{
    path: report_path,
    repo: repo,
    shipped: shipped,
    verified: scored.verified,
    skeptics: 3,
    implement_ok: impl_ok,
    remaining_gaps: gaps.len(),
});
