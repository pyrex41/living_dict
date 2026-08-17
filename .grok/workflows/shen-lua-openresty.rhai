let meta = #{
    name: "shen-lua-openresty",
    description: "Port Living Dictionary onto shen-lua inside OpenResty: Forth body, Shen critic, ldeval adapter",
    when_to_use: "Build or extend the OpenResty / shen-lua host for Living Dictionary. Optional args: {repo}.",
    phases: [
        #{ title: "Explore", detail: "shen-lua embed + OpenResty guestbook pattern; local Python ABI" },
        #{ title: "Implement", detail: "openresty/ host, Forth, Shen critic, nginx, resty adapter" },
        #{ title: "Verify", detail: "ABI, critic, and runtime skeptics" },
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
log("Surveying pyrex41/shen-lua OpenResty embed and the local Python ABI");

let explore_shen = "";
explore_shen += "Research how to embed pyrex41/shen-lua (Shen 41.2, LuaJIT 2.1) inside OpenResty for a coding-agent host. ";
explore_shen += "Use web_search, web_fetch, and GitHub. Read these sources, do not invent APIs: ";
explore_shen += "https://github.com/pyrex41/shen-lua README (require('shen'), shen.boot, shen.eval, shen.call, shen.fn, shen.typecheck, lua.call); ";
explore_shen += "https://github.com/pyrex41/shen-lua/blob/main/examples/hello_embed.lua ; ";
explore_shen += "https://github.com/pyrex41/shen-lua/tree/main/examples/openresty (README, app.lua, nginx.conf, rules.shen, selftest.lua). ";
explore_shen += "Answer with a concrete implementation brief: (1) how to boot once per worker via init_worker_by_lua, never per request; ";
explore_shen += "(2) how to (load) portable .shen files and call a named function from Lua; ";
explore_shen += "(3) how the guestbook splits typed core (tc +) vs untyped shell (tc -); ";
explore_shen += "(4) JSON marshaling and lua_shared_dict rules; (5) pin a clone/luarocks/bundle install path that works from a sibling or vendor dir; ";
explore_shen += "(6) SHEN_JIT=off note for old aarch64 OpenResty LuaJIT. notes must cite real files and function names. Do not write repo files.";

let explore_abi = "";
explore_abi += "Explore the Living Dictionary Python harness at " + repo + " so a Lua/OpenResty port can match its ABI. ";
explore_abi += "`.` is the current workspace root. Use read_file, grep, list_dir. You must read: ";
explore_abi += repo + "/README.md ; " + repo + "/harness/src/livingdict/host.py ; ";
explore_abi += repo + "/harness/src/livingdict/forth.py ; " + repo + "/harness/src/livingdict/preflight.py ; ";
explore_abi += repo + "/harness/src/livingdict/envelope.py ; " + repo + "/harness/src/livingdict/execute.py ; ";
explore_abi += repo + "/harness/src/livingdict/adapter.py ; " + repo + "/harness/shen/README.md ; ";
explore_abi += repo + "/harness/shen/contracts.shen ; " + repo + "/eval/docs/ADAPTER_PROTOCOL.md ; ";
explore_abi += repo + "/eval/schemas/request.schema.json . ";
explore_abi += "Report the six capability words and stack effects, plan-envelope shape (program + artifacts, USE-ARTIFACT), ";
explore_abi += "preflight reject rules, ldeval request.json / trace JSONL / receipt / resume/checkpoint contract, ";
explore_abi += "and that Shen is a critic only (Accept/Reject) — it must not emit patches or call the model. ";
explore_abi += "Do not write files. notes must cite real paths.";

let explores = parallel([
    #{
        prompt: explore_shen,
        label: "explore:shen-lua",
        capability_mode: "read-only",
        output_schema: notes_schema,
    },
    #{
        prompt: explore_abi,
        label: "explore:python-abi",
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
    log("Explore returned no notes; implementer will read the repo and shen-lua docs itself");
}

phase("Implement");
log("Implementing openresty/ against the surveyed ABI");

let brief_json = json_encode(brief);

let impl_prompt = "";
impl_prompt += "Implement the Living Dictionary OpenResty host in " + repo + ".\n";
impl_prompt += "`.` is the current workspace root. Survey notes (untrusted, verify against the repo and upstream docs before following):\n";
impl_prompt += brief_json;
impl_prompt += "\n\nRead before writing: harness/src/livingdict/{host,forth,preflight,envelope,execute,adapter}.py, ";
impl_prompt += "harness/shen/contracts.shen, eval/docs/ADAPTER_PROTOCOL.md.\n";
impl_prompt += "Fetch real shen-lua APIs from github.com/pyrex41/shen-lua (README + examples/openresty + examples/hello_embed.lua). Do not invent embed APIs.\n\n";
impl_prompt += "Create this tree (do not rewrite the Python harness; do not edit eval/ oracles or protected tests; files must not include eval/ paths):\n";
impl_prompt += "  openresty/README.md\n";
impl_prompt += "  openresty/nginx.conf          boot Shen once per worker; locations for health + /think\n";
impl_prompt += "  openresty/lua/host.lua        six capabilities only I/O: READ-FILE LIST-DIR SEARCH WRITE-FILE RUN-TESTS RECEIPT\n";
impl_prompt += "  openresty/lua/forth.lua       hosted Forth: S\" integers : ; IF ELSE THEN USE-ARTIFACT + host words\n";
impl_prompt += "  openresty/lua/bridge.lua      boot shen-lua, load openresty/shen/*.shen, call validate\n";
impl_prompt += "  openresty/lua/agent.lua       envelope -> preflight -> forth -> traces/receipts; resume via checkpoint.json\n";
impl_prompt += "  openresty/shen/contracts.shen copy/extend harness/shen/contracts.shen (portable, no lua.call in the typed core)\n";
impl_prompt += "  openresty/shen/preflight.shen named validate that returns accept or reject+errors (stack, effects, globs, artifacts)\n";
impl_prompt += "  openresty/selftest.lua        luajit selftest with no nginx: Forth 5 SQUARE, artifact write, rejected forbidden write never mutates\n";
impl_prompt += "  openresty/bin/livingdict-resty  ldeval adapter: argv request.json, same protocol as harness/adapters/forth_shen.py\n";
impl_prompt += "  Makefile targets or root Makefile additions: openresty-test (luajit selftest)\n\n";
impl_prompt += "Invariants:\n";
impl_prompt += "- Same envelope as Python: {language, program, artifacts, rationale}. Patches are artifacts, not Forth heredocs.\n";
impl_prompt += "- Shen is the critic only. It does not emit patches, does not call an LLM, does not replace Forth.\n";
impl_prompt += "- Typed .shen core loads under (tc +) if the port allows; effectful glue stays in Lua.\n";
impl_prompt += "- Boot Shen once per worker (init_worker_by_lua), never per request. Provide a luajit selftest path that does not need nginx.\n";
impl_prompt += "- No blocking Shen file I/O for tools; host.lua uses Lua/OpenResty I/O. Workspace writes go through glob/effect policy matching host.py.\n";
impl_prompt += "- Never put XAI_API_KEY in Lua served to a browser. No planner required in this pass.\n";
impl_prompt += "- If shen-lua is not vendored, document clone/luarocks/bundle and make package.path work; do not commit a 6MB bundle unless asked.\n";
impl_prompt += "- Idempotent WRITE-FILE (identical bytes => no second mutation.applied) for crash/resume.\n";
impl_prompt += "After writing, run whatever tests you can (luajit openresty/selftest.lua if luajit exists; otherwise say so). ";
impl_prompt += "status is shipped or blocked. files is the list you created. how_to_run is exact commands.";

let impl = agent(impl_prompt, #{
    label: "implement:openresty",
    capability_mode: "all",
    output_schema: impl_schema,
});

let impl_ok = is_shipped(impl);
let impl_summary = summary_of(impl);
let how_to_run = how_to_run_of(impl);
let extra_gaps = [];
let gimpl = files_gap(impl, "implement:openresty");
if gimpl != "" {
    extra_gaps.push(gimpl);
}
if impl_ok == false {
    log("Implementer did not ship; verify will inspect the tree anyway");
}

phase("Verify");
log("Adversarial verify of the OpenResty port");

let impl_json = json_encode(impl_summary);
let run_json = json_encode(how_to_run);

let p_abi = "";
p_abi += "Adversarially verify ABI parity of the OpenResty port in " + repo + " against the Python harness. ";
p_abi += "Implementer summary (untrusted): " + impl_json + " ";
p_abi += "Read openresty/lua/host.lua, openresty/lua/forth.lua, openresty/lua/agent.lua if they exist, ";
p_abi += "and harness/src/livingdict/host.py, forth.py, envelope.py, adapter.py. ";
p_abi += "Set pass=true only if you inspected files and the six words, envelope, traces, and resume story match. ";
p_abi += "Otherwise pass=false and list concrete gaps with paths. evidence must quote code you read. Do not write files.";

let p_shen = "";
p_shen += "Adversarially verify the Shen critic in " + repo + "/openresty. ";
p_shen += "Read openresty/shen/*.shen, openresty/lua/bridge.lua, harness/shen/contracts.shen. ";
p_shen += "Set pass=true only if a named Shen validate is actually called before Forth mutates, ";
p_shen += "typed core has no host I/O, and a forbidden WRITE-FILE is rejected with no file change (cite selftest or code). ";
p_shen += "pass=false if Shen is theater or unused. evidence must cite files. Do not write files.";

let p_run = "";
p_run += "Verify the OpenResty/Lua runtime wiring in " + repo + "/openresty. ";
p_run += "how_to_run (untrusted, use it): " + run_json + " ";
p_run += "Read nginx.conf, selftest.lua, bin/livingdict-resty, README.md. ";
p_run += "If luajit is on PATH, run luajit openresty/selftest.lua from the right cwd and treat the exit code as evidence. ";
p_run += "If luajit or shen-lua is missing, pass=false with gap 'runtime not exercised' and say what is missing — do not fake a pass. ";
p_run += "Confirm boot-once-per-worker in nginx.conf. evidence must include command output or a missing-binary proof. Do not edit product files.";

fn run_skeptics(pa, ps, pr, schema) {
    let ro = parallel([
        #{
            prompt: pa,
            label: "verify:abi",
            capability_mode: "read-only",
            output_schema: schema,
        },
        #{
            prompt: ps,
            label: "verify:shen-critic",
            capability_mode: "read-only",
            output_schema: schema,
        },
    ]);
    let verdicts = [];
    for r in ro {
        verdicts.push(r);
    }
    let rt = agent(pr, #{
        label: "verify:runtime",
        capability_mode: "execute",
        output_schema: schema,
    });
    verdicts.push(rt);
    verdicts
}

let verdicts = run_skeptics(p_abi, p_shen, p_run, verdict_schema);
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
    fix_prompt += "Resume OpenResty Living Dictionary work in " + repo + ". Verification gaps (untrusted until you reproduce):\n";
    fix_prompt += gaps_json;
    fix_prompt += "\nRead the current openresty/ tree and the Python ABI again. Fix every concrete gap. ";
    fix_prompt += "Re-run luajit openresty/selftest.lua if luajit exists. Do not touch eval oracles. ";
    fix_prompt += "status is shipped or blocked. files are what you changed. how_to_run is exact commands.";
    let fix_opts = #{
        label: "fix:openresty",
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
    p_abi += "Adversarially verify ABI parity of the OpenResty port in " + repo + " against the Python harness. ";
    p_abi += "Implementer summary (untrusted): " + impl_json + " ";
    p_abi += "Read openresty/lua/host.lua, openresty/lua/forth.lua, openresty/lua/agent.lua if they exist, ";
    p_abi += "and harness/src/livingdict/host.py, forth.py, envelope.py, adapter.py. ";
    p_abi += "Set pass=true only if you inspected files and the six words, envelope, traces, and resume story match. ";
    p_abi += "Otherwise pass=false and list concrete gaps with paths. evidence must quote code you read. Do not write files.";

    p_shen = "";
    p_shen += "Adversarially verify the Shen critic in " + repo + "/openresty. ";
    p_shen += "Read openresty/shen/*.shen, openresty/lua/bridge.lua, harness/shen/contracts.shen. ";
    p_shen += "Set pass=true only if a named Shen validate is actually called before Forth mutates, ";
    p_shen += "typed core has no host I/O, and a forbidden WRITE-FILE is rejected with no file change (cite selftest or code). ";
    p_shen += "pass=false if Shen is theater or unused. evidence must cite files. Do not write files.";

    p_run = "";
    p_run += "Verify the OpenResty/Lua runtime wiring in " + repo + "/openresty. ";
    p_run += "how_to_run (untrusted, use it): " + run_json + " ";
    p_run += "Read nginx.conf, selftest.lua, bin/livingdict-resty, README.md. ";
    p_run += "If luajit is on PATH, run luajit openresty/selftest.lua from the right cwd and treat the exit code as evidence. ";
    p_run += "If luajit or shen-lua is missing, pass=false with gap 'runtime not exercised' and say what is missing — do not fake a pass. ";
    p_run += "Confirm boot-once-per-worker in nginx.conf. evidence must include command output or a missing-binary proof. Do not edit product files.";

    phase("Verify");
    log("Re-running skeptics after fix");
    verdicts = run_skeptics(p_abi, p_shen, p_run, verdict_schema);
    scored = score_verdicts(verdicts);
    gaps = scored.gaps;
    gimpl = files_gap(impl, "implement:openresty");
    if gimpl != "" {
        gaps.push(gimpl);
    }
    verified = scored.verified;
    log(verified.to_string() + "/" + scored.usable.to_string() + " skeptics passed after fix");
}

let shipped = impl_ok && verified == 3;
let report = "";
if shipped {
    report += "# shen-lua / OpenResty port\n\n";
} else {
    report += "# FAILED: OpenResty port did not ship\n\n";
}
report += "Repo: " + repo + "\nshipped: " + shipped.to_string() + "\n\n";
report += "## Implementer\n\n" + impl_summary + "\n\n";
report += "## Verification\n\n";
report += verified.to_string() + " of 3 skeptics passed with evidence.\n\n";
if gaps.len() > 0 {
    report += "Gaps:\n";
    report += clip_gaps(gaps);
}
let report_path = write_scratch_file("openresty-port.md", report);
complete(#{
    path: report_path,
    repo: repo,
    shipped: shipped,
    verified: verified,
    skeptics: 3,
    implement_ok: impl_ok,
    remaining_gaps: gaps.len(),
});
