let meta = #{
    name: "shenscript-browser",
    description: "Browser Living Dictionary: vanilla JS Forth/host + Ratatoskr-shaken ShenScript critic; also shake lua",
    when_to_use: "Build the ShenScript browser host or shake the portable critic for js --web and lua. Optional args: {repo}.",
    phases: [
        #{ title: "Explore", detail: "ShenScript, Ratatoskr --web, Bifrost --shake, local ABI" },
        #{ title: "Implement", detail: "portable critic, browser/, lua shake, bifrost suite" },
        #{ title: "Verify", detail: "ABI, shake/eval-free, node selftest skeptics" },
        #{ title: "Fix", detail: "one resume pass, then re-run skeptics" },
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
log("Surveying ShenScript, Ratatoskr --web, Bifrost --shake, and the local ABI");

let explore_shake = "";
explore_shake += "Research the REAL CLIs. Do not invent flags. Use web_fetch and read local checkouts if present: ";
explore_shake += "../ratatoskr/README.md, ../bifrost/README.md, ../ShenScript/README.md (siblings of the workspace). ";
explore_shake += "Also https://github.com/pyrex41/ratatoskr and pyrex41/bifrost. ";
explore_shake += "Document exact commands: (1) ratatoskr build PROG OUT --target js --web ; ";
explore_shake += "(2) ratatoskr build PROG OUT --target lua ; (3) bifrost --shake --suite FILE --impls shen-lua,ShenScript ; ";
explore_shake += "(4) bifrost build FILE OUT --target T — note whether --web is forwarded (as of now it is NOT; use ratatoskr for --web). ";
explore_shake += "Explain needs-eval=false for --web; why (tc +), eval, load, lua.call disqualify --web; ";
explore_shake += "how to call a named function on a --web ES module (import $ from './app.js', $.caller). ";
explore_shake += "Confirm ratatoskr and bifrost on PATH if you can run --help. notes must cite real flags. Do not write repo files.";

let explore_abi = "";
explore_abi += "Read the Living Dictionary repo at " + repo + " so the browser port matches the ABI. `.` is the current workspace root. ";
explore_abi += "You must read with tools: " + repo + "/docs/BROWSER.md ; " + repo + "/docs/ARCHITECTURE.md ; ";
explore_abi += repo + "/README.md ; " + repo + "/openresty/lua/host.lua ; " + repo + "/openresty/lua/forth.lua ; ";
explore_abi += repo + "/openresty/lua/bridge.lua ; " + repo + "/openresty/lua/agent.lua ; ";
explore_abi += repo + "/openresty/shen/preflight.shen ; " + repo + "/openresty/shen/contracts.shen ; ";
explore_abi += repo + "/harness/src/livingdict/forth.py ; " + repo + "/harness/src/livingdict/preflight.py ; ";
explore_abi += repo + "/openresty/selftest.lua . ";
explore_abi += "Report: six words, envelope, critic Accept/Reject, what in preflight.shen is lua.call and must become portable, ";
explore_abi += "and that RUN-TESTS cannot spawn Python in a browser. Do not write files. notes cite paths.";

let explores = parallel([
    #{
        prompt: explore_shake,
        label: "explore:bifrost-ratatoskr",
        capability_mode: "read-only",
        output_schema: notes_schema,
    },
    #{
        prompt: explore_abi,
        label: "explore:abi",
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
    log("Explore returned no notes; implementer will read BROWSER.md and upstream CLIs itself");
}

phase("Implement");
log("Implementing portable critic, browser/, and lua/js shakes");

let brief_json = json_encode(brief);

let impl_prompt = "";
impl_prompt += "Implement the Living Dictionary browser host and shake the critic. Repo: " + repo + "\n";
impl_prompt += "`.` is the current workspace root. Follow " + repo + "/docs/BROWSER.md exactly. Survey notes (untrusted, verify against docs and --help):\n";
impl_prompt += brief_json;
impl_prompt += "\n\nRead BROWSER.md, ARCHITECTURE.md, openresty/shen/*.shen, openresty/lua/{host,forth,bridge,agent}.lua, harness forth/preflight before writing.\n";
impl_prompt += "Confirm CLIs with `ratatoskr --help` and `bifrost --help`. Do not invent flags.\n\n";
impl_prompt += "Decisions already made (do not reopen):\n";
impl_prompt += "- Vanilla JS only. No React, Vue, Svelte, Elm, or a bundler for the UI.\n";
impl_prompt += "- Shen is critic only. Forth + host + UI are JS.\n";
impl_prompt += "- Use pyrex41/ratatoskr for artifacts: --target js --web AND --target lua.\n";
impl_prompt += "- Use pyrex41/bifrost --shake (suite) for deploy-path parity of the critic.\n";
impl_prompt += "- bifrost build does not forward --web; call ratatoskr for the browser module.\n";
impl_prompt += "- Critic must be eval-free portable Shen: no lua.call, no js.call, no (tc +) at runtime, no eval/load.\n";
impl_prompt += "- Tokenise Forth in portable Shen or pass tokens from the host into validate-tokens.\n";
impl_prompt += "- Also shake lua and wire OpenResty to prefer the shaken lua artifact when present.\n";
impl_prompt += "- Do not edit eval oracles or rewrite the Python lab. files must not include eval/ paths.\n";
impl_prompt += "- No XAI_API_KEY in the page. No planner. No WAForth unless optional and labeled.\n\n";
impl_prompt += "Create:\n";
impl_prompt += "  shen/critic/           portable sources (contracts, validate, tokenise if needed)\n";
impl_prompt += "  bifrost.suite.json     critic fixture; marker + agreement; script-mode entrypoint\n";
impl_prompt += "  browser/               index.html, css, js/{host,forth,bridge,agent,ui}.js, README, node selftest\n";
impl_prompt += "  Makefile targets: browser-test, browser-shake, browser-serve\n";
impl_prompt += "  openresty: load shaken lua critic when dist exists; keep selftest proving forbidden write never mutates\n\n";
impl_prompt += "If ratatoskr/bifrost/shen-cl host cannot shake in this environment, still land portable .shen + JS host + documented exact shake commands; status=blocked with the missing tool named. ";
impl_prompt += "If shake succeeds, commit or gitignore dist/ per BROWSER.md (gitignore generated bits; document how to rebuild).\n";
impl_prompt += "Run node selftest if node exists. status is shipped or blocked. files is what you created. how_to_run is exact commands.";

let impl = agent(impl_prompt, #{
    label: "implement:browser",
    capability_mode: "all",
    output_schema: impl_schema,
});

let impl_ok = is_shipped(impl);
let impl_summary = summary_of(impl);
let how_to_run = how_to_run_of(impl);
let extra_gaps = [];
let gimpl = files_gap(impl, "implement:browser");
if gimpl != "" {
    extra_gaps.push(gimpl);
}
if impl_ok == false {
    log("Implementer did not ship; verify will inspect the tree anyway");
}

phase("Verify");
log("Adversarial verify of the browser port and shakes");

let impl_json = json_encode(impl_summary);
let run_json = json_encode(how_to_run);

let p_abi = "";
p_abi += "Adversarially verify ABI parity of " + repo + "/browser against Python and OpenResty. ";
p_abi += "Implementer summary (untrusted): " + impl_json + " ";
p_abi += "Read browser/js/*.js if present, harness forth/host/preflight, openresty/lua/host.lua and forth.lua, docs/BROWSER.md. ";
p_abi += "Set pass=true only if six words, envelope, and reject-before-mutate match and you quoted files. ";
p_abi += "pass=false if Elm/React or Forth written only in Shen. Do not write files.";

let p_shake = "";
p_shake += "Adversarially verify the critic is shakeable and actually shaken for js --web and lua in " + repo + ". ";
p_shake += "how_to_run (untrusted): " + run_json + " ";
p_shake += "Read shen/critic/*.shen, bifrost.suite.json, Makefile, browser/js/bridge.js, openresty/lua/bridge.lua. ";
p_shake += "Set pass=true only if: no lua.call/js.call/(tc +)/eval in the portable critic; ";
p_shake += "shake commands are exact ratatoskr/bifrost flags; --web is used for JS; lua target is also built; ";
p_shake += "needs-eval=false is required. If dist/ is missing, pass=false unless README names the missing toolchain. ";
p_shake += "If ratatoskr is on PATH, run the documented shake or `ratatoskr --help` and cite output. Do not write product files. Do not run the node selftest (a later skeptic does).";

let p_run = "";
p_run += "Verify the browser runtime in " + repo + "/browser. ";
p_run += "how_to_run (untrusted, use it): " + run_json + " ";
p_run += "Read index.html, test/*, README. ";
p_run += "If node is on PATH, run the documented node selftest and treat exit code as evidence. ";
p_run += "Selftest must prove: Forth 5 SQUARE, artifact write, forbidden WRITE-FILE never mutates, critic ran (not a JS-only skip). ";
p_run += "Missing node or missing shaken module => pass=false with the gap named. Do not fake a pass. Do not edit product files.";

fn run_skeptics(pa, ps, pr, schema) {
    let ro = parallel([
        #{
            prompt: pa,
            label: "verify:abi",
            capability_mode: "read-only",
            output_schema: schema,
        },
    ]);
    let verdicts = [];
    for r in ro {
        verdicts.push(r);
    }
    let a = agent(ps, #{
        label: "verify:shake",
        capability_mode: "execute",
        output_schema: schema,
    });
    verdicts.push(a);
    let b = agent(pr, #{
        label: "verify:selftest",
        capability_mode: "execute",
        output_schema: schema,
    });
    verdicts.push(b);
    verdicts
}

let verdicts = run_skeptics(p_abi, p_shake, p_run, verdict_schema);
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
    fix_prompt += "Resume browser / shake work in " + repo + ". Gaps (untrusted until you reproduce):\n";
    fix_prompt += gaps_json;
    fix_prompt += "\nRe-read docs/BROWSER.md. Keep vanilla JS. Keep critic eval-free. Use ratatoskr --target js --web and --target lua. ";
    fix_prompt += "Use bifrost --shake for the suite. Re-run node selftest if possible. Do not touch eval oracles. ";
    fix_prompt += "status is shipped or blocked. files are what you changed. how_to_run is exact commands.";
    let fix_opts = #{
        label: "fix:browser",
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

    p_abi = "";
    p_abi += "Adversarially verify ABI parity of " + repo + "/browser against Python and OpenResty. ";
    p_abi += "Implementer summary (untrusted): " + impl_json + " ";
    p_abi += "Read browser/js/*.js if present, harness forth/host/preflight, openresty/lua/host.lua and forth.lua, docs/BROWSER.md. ";
    p_abi += "Set pass=true only if six words, envelope, and reject-before-mutate match and you quoted files. ";
    p_abi += "pass=false if Elm/React or Forth written only in Shen. Do not write files.";

    p_shake = "";
    p_shake += "Adversarially verify the critic is shakeable and actually shaken for js --web and lua in " + repo + ". ";
    p_shake += "how_to_run (untrusted): " + run_json + " ";
    p_shake += "Read shen/critic/*.shen, bifrost.suite.json, Makefile, browser/js/bridge.js, openresty/lua/bridge.lua. ";
    p_shake += "Set pass=true only if: no lua.call/js.call/(tc +)/eval in the portable critic; ";
    p_shake += "shake commands are exact ratatoskr/bifrost flags; --web is used for JS; lua target is also built; ";
    p_shake += "needs-eval=false is required. If dist/ is missing, pass=false unless README names the missing toolchain. ";
    p_shake += "If ratatoskr is on PATH, run the documented shake or `ratatoskr --help` and cite output. Do not write product files. Do not run the node selftest (a later skeptic does).";

    p_run = "";
    p_run += "Verify the browser runtime in " + repo + "/browser. ";
    p_run += "how_to_run (untrusted, use it): " + run_json + " ";
    p_run += "Read index.html, test/*, README. ";
    p_run += "If node is on PATH, run the documented node selftest and treat exit code as evidence. ";
    p_run += "Selftest must prove: Forth 5 SQUARE, artifact write, forbidden WRITE-FILE never mutates, critic ran (not a JS-only skip). ";
    p_run += "Missing node or missing shaken module => pass=false with the gap named. Do not fake a pass. Do not edit product files.";

    phase("Verify");
    log("Re-running skeptics after fix");
    verdicts = run_skeptics(p_abi, p_shake, p_run, verdict_schema);
    scored = score_verdicts(verdicts);
    gaps = scored.gaps;
    gimpl = files_gap(impl, "implement:browser");
    if gimpl != "" {
        gaps.push(gimpl);
    }
    verified = scored.verified;
    log(verified.to_string() + "/" + scored.usable.to_string() + " skeptics passed after fix");
}

let shipped = impl_ok && verified == 3;
let report = "";
if shipped {
    report += "# ShenScript browser + shaken critic\n\n";
} else {
    report += "# FAILED: browser port did not ship\n\n";
}
report += "Repo: " + repo + "\nshipped: " + shipped.to_string() + "\n\n";
report += "## Implementer\n\n" + impl_summary + "\n\n";
report += "## Verification\n\n";
report += verified.to_string() + " of 3 skeptics passed with evidence.\n\n";
if gaps.len() > 0 {
    report += "Gaps:\n";
    report += clip_gaps(gaps);
}
let report_path = write_scratch_file("browser-port.md", report);
complete(#{
    path: report_path,
    repo: repo,
    shipped: shipped,
    verified: verified,
    skeptics: 3,
    implement_ok: impl_ok,
    remaining_gaps: gaps.len(),
});
