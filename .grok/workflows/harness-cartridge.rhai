let meta = #{
    name: "harness-cartridge",
    description: "Build the BEAM+Shen harness cartridge from docs/design/HARNESS_CARTRIDGE.md. No Python overlay path. Flags stay off. Never edit eval/.",
    when_to_use: "After HARNESS_CARTRIDGE.md is the design of record. Implements PRs 1–7 in order. Optional args: {repo, stop_after} where stop_after is 1–7 (smoke: 1). Pauses after PR 4 for the Exp 0 human kill switch when continuing past 4.",
    phases: [
        #{ title: "Explore", detail: "design + four-body dictionary/critic substrate" },
        #{ title: "PR1 spec", detail: "primitives.v1.json + gen_primitives.py + fixtures" },
        #{ title: "PR2 promotion", detail: "BEAM persist identity, public topo_order" },
        #{ title: "PR3 identity-hash", detail: "hash(D) identity-only + freeze_of" },
        #{ title: "PR4 exp0", detail: "mixed-family grant+path retrieval" },
        #{ title: "PR5 shen", detail: "join shape, reserved, fuel, graph TODO" },
        #{ title: "PR6 cartridge", detail: "nested overlay + repair cap" },
        #{ title: "PR7 pareto", detail: "quarantine / discard / narrow" },
        #{ title: "Report", detail: "scratch report of what shipped" },
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
let stop_after = 7;
if args != () && args.repo != () {
    let given = trimmed(args.repo);
    if given != "" {
        repo = given;
    }
}
if args != () && args.stop_after != () {
    stop_after = args.stop_after;
}

let laws = "";
laws += "Laws from docs/design/HARNESS_CARTRIDGE.md (the design of record — read it). ";
laws += "Never edit eval/ or compare/runs/. Never add host Forth words. Eval 1.0 six-word ABI stays frozen. ";
laws += "Live body is BEAM (beam/) + Shen critic (shen/critic/). No Python overlay path: do not make bin/livingdict execute cartridges, do not add a Python shaken-validate ladder, do not use eval forth_shen as an Exp 1 arm. ";
laws += "Feature flags default off (LD_DICT_MODE=load-all, LD_CARTRIDGE=0). ";
laws += "Do not generate a planner, COMPLETE, DIRECTIVE, ReAct, or Layer C INSTALL. ";
laws += "Proof admits; receipts audit. Planner stays LdHost.Planner. ";
laws += "`.` is the workspace root. Use read_file, grep, list_dir, and run mix test in beam/. ";
laws += "status is shipped or blocked. files is what you created/changed (no eval/ paths). how_to_run is exact commands. ";

phase("Explore");
log("Reading the cartridge design and the four-body substrate");

let explore_design = "";
explore_design += "Read " + repo + "/docs/design/HARNESS_CARTRIDGE.md in full (Key Decisions, Proposed Design, PR Plan). ";
explore_design += "Also read docs/ARCHITECTURE.md, docs/HARNESS.md, docs/design/STORE.md, AGENTS.md. ";
explore_design += "Summarize the 7-PR order, the Exp 0 kill switch, fingerprint/cartridge rules, and hash(D) identity-only rule. ";
explore_design += "Do not write files. notes must cite section headings and file paths.";

let explore_code = "";
explore_code += "Explore the four-body dictionary/critic substrate in " + repo + ". Use read_file and grep. You must read: ";
explore_code += "harness/src/livingdict/{dictionary.py,promotion.py,preflight.py,kernel.py,execute.py,store.py}, ";
explore_code += "beam/lib/ld_host/{dictionary.ex,run.ex,ledger.ex,forth.ex,envelope.ex,critic.ex}, ";
explore_code += "shen/critic/validate.shen, openresty/lua/bridge.lua, browser/js/forth.js. ";
explore_code += "Quote: EVENT_KINDS, BEAM @event_kinds, Python load_prelude (alphabetical, no SAFE_NAME filter), ";
explore_code += "BEAM defp topo_order, execute._promote_colon vs Run.promote/5, preflight _skip_colon Contract(0,0,empty), ";
explore_code += "kernel.fingerprint fields. Do not write files. notes must cite real paths.";

let explores = parallel([
    #{
        prompt: explore_design,
        label: "explore:design",
        capability_mode: "read-only",
        output_schema: notes_schema,
    },
    #{
        prompt: explore_code,
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
    log("Explore returned no notes; implementers will read the design themselves");
}
let brief_json = json_encode(brief);
let laws_json = json_encode(laws);

let shipped_prs = [];
let blocked_at = "";
let all_gaps = [];

fn skeptics_for(repo, label, how_run, summary, verdict_schema) {
    let run_json = json_encode(how_run);
    let sum_json = json_encode(summary);
    let p_abi = "";
    p_abi += "Adversarially verify " + label + " in " + repo + " against the cartridge laws. ";
    p_abi += "Implementer how_to_run (untrusted): " + run_json + " ";
    p_abi += "summary (untrusted): " + sum_json + " ";
    p_abi += "Read the diff and listed files. pass=true only if ALL of: (1) no path under eval/ or compare/runs/ was edited; ";
    p_abi += "(2) no new host Forth word (READ-FILE LIST-DIR SEARCH WRITE-FILE RUN-TESTS RUN-GATES RECEIPT USE-ARTIFACT stay the ABI); ";
    p_abi += "(3) LD_CARTRIDGE default remains off / ignored at execute unless this label is PR6; no Python CLI overlay path; ";
    p_abi += "(4) you quote the evidence (paths, grep hits, or test names). Do not edit product files.";

    let p_run = "";
    p_run += "Re-run the implementer's how_to_run for " + label + " in " + repo + ". ";
    p_run += "how_to_run (untrusted): " + run_json + " ";
    p_run += "Execute those commands yourself. pass=true only with command output in evidence. ";
    p_run += "If you cannot run it, pass=false 'runtime not exercised'. Do not edit product files. Never touch eval/ oracles.";

    let a = agent(p_abi, #{
        label: "verify:" + label + ":abi",
        capability_mode: "execute",
        output_schema: verdict_schema,
    });
    let b = agent(p_run, #{
        label: "verify:" + label + ":tests",
        capability_mode: "execute",
        output_schema: verdict_schema,
    });
    [a, b]
}

fn ship_pr(repo, n, title, spec, laws_json, brief_json, impl_schema, verdict_schema) {
    let label = "pr" + n.to_string();
    let impl_prompt = "";
    impl_prompt += "Implement PR " + n.to_string() + " (" + title + ") of the Living Dictionary harness cartridge in " + repo + ".\n";
    impl_prompt += "Read docs/design/HARNESS_CARTRIDGE.md PR Plan for this PR before writing code.\n";
    impl_prompt += "Laws (untrusted until you verify): " + laws_json + "\n";
    impl_prompt += "Explore notes (untrusted): " + brief_json + "\n";
    impl_prompt += "Spec:\n" + spec + "\n";
    impl_prompt += "If a prerequisite PR is missing in the tree, status=blocked naming it. Do not implement other PRs here.\n";
    impl_prompt += "After writing, run the tests named in the spec (at least the focused tests; make test if the spec says so). ";
    impl_prompt += "Never edit eval/. status shipped or blocked. files created/changed. how_to_run exact commands.";

    let impl = agent(impl_prompt, #{
        label: "implement:" + label,
        capability_mode: "all",
        output_schema: impl_schema,
    });

    let impl_ok = is_shipped(impl);
    let impl_summary = summary_of(impl);
    let how_to_run = how_to_run_of(impl);
    let extra = [];
    let gimpl = files_gap(impl, "implement:" + label);
    if gimpl != "" {
        extra.push(gimpl);
    }
    if impl_ok == false {
        log(label + " implementer did not ship; skeptics will inspect anyway");
    }

    let verdicts = skeptics_for(repo, label, how_to_run, impl_summary, verdict_schema);
    let scored = score_verdicts(verdicts);
    let gaps = scored.gaps;
    for g in extra {
        gaps.push(g);
    }
    log(label + " " + scored.verified.to_string() + "/" + scored.usable.to_string() + " skeptics passed with evidence");

    if scored.verified < 2 || impl_ok == false {
        phase("Fix");
        log("Fixing " + label + " gaps, then re-running skeptics");
        let gaps_json = json_encode(gaps);
        let fix_prompt = "";
        fix_prompt += "Resume PR " + n.to_string() + " (" + title + ") in " + repo + ". Verification gaps (untrusted until you reproduce):\n";
        fix_prompt += gaps_json;
        fix_prompt += "\nReproduce each gap, fix it, re-run the PR tests. Never edit eval/. ";
        fix_prompt += "Do not implement other PRs. status shipped or blocked. files changed. how_to_run exact commands.";
        let fix_opts = #{
            label: "fix:" + label,
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
        extra = [];
        gimpl = files_gap(impl, "implement:" + label);
        if gimpl != "" {
            extra.push(gimpl);
        }
        verdicts = skeptics_for(repo, label, how_to_run, impl_summary, verdict_schema);
        scored = score_verdicts(verdicts);
        gaps = scored.gaps;
        for g in extra {
            gaps.push(g);
        }
        log(label + " after fix " + scored.verified.to_string() + "/" + scored.usable.to_string() + " skeptics passed");
    }

    #{
        n: n,
        title: title,
        shipped: impl_ok && scored.verified == 2,
        summary: impl_summary,
        how_to_run: how_to_run,
        verified: scored.verified,
        gaps: gaps,
    }
}

// ---- PR 1 ----
phase("PR1 spec");
log("PR 1: primitive spec + generated tables + fixtures");
let spec1 = "";
spec1 += "Create spec/primitives.v1.json and a generator (tools/gen_primitives.py is a one-shot table emitter, not a runtime). Command: python3 tools/gen_primitives.py spec/primitives.v1.json. ";
spec1 += "Write contract tables behind markers in shen/critic/validate.shen (yggdrasil-checkable) and beam/lib/ld_host/forth.ex ONLY. Do not generate preflight.py / Lua / JS tables this PR (documented drift). ";
spec1 += "Method bodies stay handwritten. Semantic equality tests against shaken Shen + LdHost.Critic. ";
spec1 += "Do not codegen docs/ARCHITECTURE.md. No overlay execution. Tests: mix test in beam/ plus shen/critic/suite-tests.shen.";
let r1 = ship_pr(repo, 1, "primitive spec", spec1, laws_json, brief_json, impl_schema, verdict_schema);
if r1.shipped {
    shipped_prs.push("PR1");
} else {
    blocked_at = "PR1";
    for g in r1.gaps { all_gaps.push(g); }
}
if 1 >= stop_after || blocked_at != "" {
    log("Stopping after PR1 (stop_after or blocked)");
} else {

// ---- PR 2 ----
phase("PR2 promotion");
log("PR 2: BEAM persist identity (effects, path_region, public topo)");
let spec2 = "";
spec2 += "BEAM is already evidence-gated. This PR records identity fields retrieval needs. ";
spec2 += "Export topo_order (today defp). Persist effects from the in-band contract and path_region = glob-union of literal WRITE-FILE paths, else episode allowed_globs. ";
spec2 += "Empty family scope on live jobs. Load-all remains default. No cartridge execution. Do NOT port this into harness/src/livingdict. ";
spec2 += "Tests in beam/test/. mix test in beam/.";
let r2 = ship_pr(repo, 2, "BEAM persist identity", spec2, laws_json, brief_json, impl_schema, verdict_schema);
if r2.shipped {
    shipped_prs.push("PR2");
} else {
    blocked_at = "PR2";
    for g in r2.gaps { all_gaps.push(g); }
}
if 2 >= stop_after || blocked_at != "" {
    log("Stopping after PR2 (stop_after or blocked)");
} else {

// ---- PR 3 ----
phase("PR3 identity-hash");
log("PR 3: identity-only hash(D) and freeze_of");
let spec3 = "";
spec3 += "hash(D) = sha256 of canonical JSON: parent + primitive_contract + name -> {source, contract, effects, callees, path_region, primitive_contract}. ";
spec3 += "Canonical JSON: UTF-8, sort_keys=True, separators=(',', ':'), interned bodies as 64-hex without sha256: prefix. Evidence stays on events/facts, not in the hash. ";
spec3 += "Add five kinds to LdHost.Ledger @event_kinds: dictionary.overlay.proposed, dictionary.overlay.admitted, dictionary.overlay.rejected, dictionary.narrowed, dictionary.discarded. ";
spec3 += "overlay.rejected coincides with critic.rejected (one pending_execute=false). Host freeze_of fold in run.ex restores hashes on resume. ";
spec3 += "LdHost.Envelope may parse cartridge structurally but LD_CARTRIDGE=0 ignores it at execute. ";
spec3 += "Fingerprint tests with a stub cartridge object (do not execute overlays). Tests in beam/test/. mix test. Do not implement this on the Python kernel.";
let r3 = ship_pr(repo, 3, "identity-only Dn hash", spec3, laws_json, brief_json, impl_schema, verdict_schema);
if r3.shipped {
    shipped_prs.push("PR3");
} else {
    blocked_at = "PR3";
    for g in r3.gaps { all_gaps.push(g); }
}
if 3 >= stop_after || blocked_at != "" {
    log("Stopping after PR3 (stop_after or blocked)");
} else {

// ---- PR 4 ----
phase("PR4 exp0");
log("PR 4: Exp 0 mixed-family grant+path retrieval");
let spec4 = "";
spec4 += "Retrieve index from BEAM ledger facts + identity blob (:word/effects, :word/region — NOT family). Subset prelude in LdHost.Dictionary.load_prelude / observe. Flag LD_DICT_MODE=load-all|retrieved. ";
spec4 += "Experiment runner under beam/bench/ that READS eval tasks (never edits eval/). Warm the union of sequences 1–7 across families. ";
spec4 += "Host query: effects subset of grant and path_region intersects grant, not forbidden. Live jobs have empty family scope. Metrics: prelude size, unused loaded words, tokens; seq-8 non-inferiority vs load-all. ";
spec4 += "Do not implement narrowing or cartridges. Tests in beam/test/ and mix test.";
let r4 = ship_pr(repo, 4, "Exp 0 grant+path retrieval", spec4, laws_json, brief_json, impl_schema, verdict_schema);
if r4.shipped {
    shipped_prs.push("PR4");
} else {
    blocked_at = "PR4";
    for g in r4.gaps { all_gaps.push(g); }
}

if 4 < stop_after && blocked_at == "" {
    await_user("verification", "Exp 0 kill switch. Review the compare receipt: retrieved must be non-inferior to load-all on sequence-8 AND shrink prelude size or unused-word load. Resume to continue PR 5–6 only on go. On stop, leave LD_DICT_MODE=load-all; do not land overlay/Shen-judgment PRs; do not revert PR 1.");
}

if 4 >= stop_after || blocked_at != "" {
    log("Stopping after PR4 (stop_after or blocked)");
} else {

// ---- PR 5 ----
phase("PR5 shen");
log("PR 5: Shen overlay judgments");
let spec5 = "";
spec5 += "shen/critic/validate.shen + suite-tests.shen: IF/ELSE join shape (v1 depth), reserved-name reject at critic time, abstract fuel, graph TODO parity so Shen is not a weaker Accept than today's Python _graph_errors (read those rules; do not edit preflight.py). ";
spec5 += "Shaken artifact consumed by LdHost.Critic. Recursion remains rejected. ";
spec5 += "Do NOT add a sequent that every path mentions RUN-GATES. Do not enable LD_CARTRIDGE. Tests: suite-tests.shen + mix test in beam/.";
let r5 = ship_pr(repo, 5, "Shen overlay judgments", spec5, laws_json, brief_json, impl_schema, verdict_schema);
if r5.shipped {
    shipped_prs.push("PR5");
} else {
    blocked_at = "PR5";
    for g in r5.gaps { all_gaps.push(g); }
}
if 5 >= stop_after || blocked_at != "" {
    log("Stopping after PR5 (stop_after or blocked)");
} else {

// ---- PR 6 ----
phase("PR6 cartridge");
log("PR 6: nested cartridge + repair cap");
let spec6 = "";
spec6 += "Nested envelope.cartridge on LdHost.Envelope. Fingerprint includes canonical overlay JSON. ";
spec6 += "cartridge.definitions is authoritative; extract from program only for names absent from that map; same-name body mismatch is a parse error. ";
spec6 += "After overlay.admitted, colon table immutable; : is a runtime syntax error; VM interprets entrypoint only; install words from D*. Forth tests on the BEAM VM. ";
spec6 += "LD_CARTRIDGE=1 to execute; default 0. Repair: two subsequent episodes after first overlay reject; third stops overlay generation. LdHost.Planner repairs; host validates exactly one of {replace one definition, narrow grant/budget/region, change entrypoint}. ";
spec6 += "Named test: reject overlay A, resubmit A' with one definition replaced and identical program/artifacts/tree -> pending_execute=true; byte-identical resubmit still blocks. ";
spec6 += "No Python CLI, no forth_shen. mix test in beam/.";
let r6 = ship_pr(repo, 6, "nested cartridge + repair cap", spec6, laws_json, brief_json, impl_schema, verdict_schema);
if r6.shipped {
    shipped_prs.push("PR6");
} else {
    blocked_at = "PR6";
    for g in r6.gaps { all_gaps.push(g); }
}
if 6 >= stop_after || blocked_at != "" {
    log("Stopping after PR6 (stop_after or blocked)");
} else {

// ---- PR 7 ----
phase("PR7 pareto");
log("PR 7: discard overlay, narrow, Pareto among eligible");
let spec7 = "";
spec7 += "Three distinct transitions: quarantine (BEAM already; keep it), discard overlay (admitted deltaD not committed: effect-drift or failed gates), narrow (post-hoc region/counterexample shrink; live family stays empty). ";
spec7 += "Use dictionary.narrowed and dictionary.discarded in anger. Predicted vs observed effect audit (observed writes/exec must not exceed predicted). ";
spec7 += "Rank only among eligible words. LdHost.Verdict.warm_run_allowed remains the compare gate, not persist. ";
spec7 += "Do not retrofit narrow into Exp 0. Do not implement this in Python. Tests in beam/test/; mix test.";
let r7 = ship_pr(repo, 7, "narrow/discard/Pareto", spec7, laws_json, brief_json, impl_schema, verdict_schema);
if r7.shipped {
    shipped_prs.push("PR7");
} else {
    blocked_at = "PR7";
    for g in r7.gaps { all_gaps.push(g); }
}

} // pr6 else
} // pr5 else
} // pr4 else
} // pr3 else
} // pr2 else
} // pr1 else

phase("Report");
let shipped_n = shipped_prs.len();
let ok = blocked_at == "" && shipped_n > 0;
if stop_after < 7 && blocked_at == "" {
    ok = shipped_n >= stop_after;
}

let report = "";
if ok {
    report += "# Harness cartridge workflow\n\n";
} else {
    report += "# Harness cartridge workflow — incomplete\n\n";
}
report += "Repo: " + repo + "\n";
report += "stop_after: " + stop_after.to_string() + "\n";
report += "shipped: " + shipped_n.to_string() + " PRs\n";
if blocked_at != "" {
    report += "blocked_at: " + blocked_at + "\n";
}
report += "\nShipped: ";
for s in shipped_prs {
    report += s + " ";
}
report += "\n\nGaps:\n";
report += clip_gaps(all_gaps);
report += "\nDesign: docs/design/HARNESS_CARTRIDGE.md\n";
report += "Flags stay off unless a shipped PR documents how to opt in.\n";

let report_path = write_scratch_file("harness-cartridge.md", report);
complete(#{
    path: report_path,
    repo: repo,
    shipped_prs: shipped_prs,
    blocked_at: blocked_at,
    stop_after: stop_after,
    ok: ok,
    remaining_gaps: all_gaps.len(),
});
