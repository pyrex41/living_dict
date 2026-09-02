let meta = #{
    name: "unikraft-harness",
    description: "Land Unikraft-shaped organs as Lua transducers on a NetKAT fabric with a Shen critic and TLA+ kernel; no Python on this path",
    when_to_use: "Build or extend the Unikraft/Lua organ fabric (spike/unikraft). Optional args: {repo}.",
    phases: [
        #{ title: "Explore", detail: "Unikraft micro-libs vs ledger determinism; Lua/Shen/TLA/NetKAT split" },
        #{ title: "Implement", detail: "Lua organs + NetKAT fabric + luajit selftest; Kraftfiles stay packaging" },
        #{ title: "Verify", detail: "isolation, no-Python, selftest skeptics" },
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

fn output_map(r) {
    if r == () || r.success != true || r.output == () {
        return ();
    }
    if type_of(r.output) == "map" {
        return r.output;
    }
    ()
}

let repo = "/Users/reuben/projects/living_dict-unikraft-spike";
if args != () && args.repo != () {
    repo = args.repo;
}

phase("Explore");
let explore_prompt = "";
explore_prompt += "Read " + repo + "/docs/design/UNIKRAFT.md and " + repo + "/spike/unikraft/README.md. ";
explore_prompt += "Also read spike/unikraft/lua/*.lua and model/fabric.netkat. ";
explore_prompt += "Use read_file and grep. Do not edit. ";
explore_prompt += "Explain in notes: Unikraft is confinement not the source of determinism; ";
explore_prompt += "NetKAT owns isolation; TLA+/kernel.lua owns the episode loop; Shen/forth.validate owns the critic. ";
explore_prompt += "List risks if someone reintroduces Python or lwip/ukrandom.";
let expl = agent(explore_prompt, #{
    label: "explore",
    capability_mode: "read-only",
    output_schema: notes_schema,
});
let expl_out = output_map(expl);
if expl_out == () {
    pause("verification", "explore agent failed");
}

phase("Implement");
let impl_prompt = "";
impl_prompt += "Work in " + repo + " on branch spike/unikraft-harness. ";
impl_prompt += "The Lua landing already exists under spike/unikraft/. ";
impl_prompt += "NEVER use Python: no .py files under spike/unikraft, no pytest, no livingdict Python imports. ";
impl_prompt += "NEVER edit eval/. NEVER add Forth words to the eval ABI. ";
impl_prompt += "If make -C spike/unikraft test (luajit selftest.lua) is already green and there are no .py files under spike/unikraft, ";
impl_prompt += "status=shipped, list the files, how_to_run=make -C spike/unikraft test, and do not rewrite. ";
impl_prompt += "If it is not green, fix in Lua/Shen/TLA/NetKAT/Kraftfiles only, then re-run that make target. ";
impl_prompt += "Use run_terminal_command, read_file, grep. Kraft images are optional; do not require docker.";
let impl = agent(impl_prompt, #{
    label: "implement",
    capability_mode: "all",
    output_schema: impl_schema,
});
let impl_out = output_map(impl);
if impl_out == () {
    pause("verification", "implement agent failed");
}
log("implement status=" + trimmed(impl_out.status) + " " + trimmed(impl_out.summary));

phase("Verify");
let v1 = "";
v1 += "In " + repo + " verify NetKAT isolation is enforced by code, not comments. ";
v1 += "Read spike/unikraft/model/fabric.netkat, lua/fabric.lua, lua/seq.lua, selftest.lua. ";
v1 += "Run make -C spike/unikraft test and cite the isolation / drop planner intern checks. ";
v1 += "pass=true only with that evidence. Gaps if planner can intern or critic can execute.";
let v2 = "";
v2 += "In " + repo + " verify spike/unikraft contains no Python. ";
v2 += "Use grep and run_terminal_command find. ";
v2 += "pass=true only if there are zero .py files under spike/unikraft and selftest is luajit. ";
v2 += "A leftover ld_uk/*.py is a fail.";
let v3 = "";
v3 += "In " + repo + " verify reject does not mutate store or workspace. ";
v3 += "Read lua/seq.lua and selftest.lua reject cases. Run make -C spike/unikraft test. ";
v3 += "pass=true only if the reject checks ran ok. ";
v3 += "Also confirm kernel.lua has no os.time / math.random / socket.";
let verdicts = parallel([
    #{ prompt: v1, label: "verify:isolation", capability_mode: "execute", output_schema: verdict_schema },
    #{ prompt: v2, label: "verify:no-python", capability_mode: "execute", output_schema: verdict_schema },
    #{ prompt: v3, label: "verify:reject", capability_mode: "execute", output_schema: verdict_schema },
]);

let gaps = [];
let i = 0;
for v in verdicts {
    let out = output_map(v);
    if out == () || out.pass != true {
        gaps.push("skeptic " + i.to_string() + " failed or unverified");
    }
    i += 1;
}

if gaps.len() > 0 {
    phase("Fix");
    let fix_prompt = "";
    fix_prompt += "Resume the implementer in " + repo + ". Skeptics reported: ";
    for g in gaps {
        fix_prompt += g + "; ";
    }
    fix_prompt += "Fix in Lua/Shen/NetKAT only. No Python. Re-run make -C spike/unikraft test.";
    let fix = agent(fix_prompt, #{
        label: "fix",
        capability_mode: "all",
        output_schema: impl_schema,
        resume_from: impl.agent_id,
    });
    let fix_out = output_map(fix);
    if fix_out == () {
        pause("verification", "fix agent failed");
    }
    log("fix status=" + trimmed(fix_out.status) + " " + trimmed(fix_out.summary));
    let again = parallel([
        #{ prompt: v1, label: "reverify:isolation", capability_mode: "execute", output_schema: verdict_schema },
        #{ prompt: v2, label: "reverify:no-python", capability_mode: "execute", output_schema: verdict_schema },
        #{ prompt: v3, label: "reverify:reject", capability_mode: "execute", output_schema: verdict_schema },
    ]);
    gaps = [];
    i = 0;
    for v in again {
        let out = output_map(v);
        if out == () || out.pass != true {
            gaps.push("reverify " + i.to_string() + " failed");
        }
        i += 1;
    }
    if gaps.len() > 0 {
        pause("verification", "skeptics still failing");
    }
}

let files = [];
if impl_out.files != () {
    files = impl_out.files;
}
complete(#{
    summary: "Unikraft/Lua organs; isolation and no-Python skeptics passed",
    how_to_run: "make -C spike/unikraft test",
    files: files,
});
