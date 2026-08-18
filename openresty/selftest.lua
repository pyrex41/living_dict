-- luajit openresty/selftest.lua
-- Forth 5 SQUARE, artifact write, Shen-gated forbidden write never mutates.
-- No nginx. shen-lua is required: the mutation proof boots the kernel first.

local function dirname(path)
  return path:match("^(.*)/[^/]+$") or "."
end

local here = debug.getinfo(1, "S").source:match("^@(.*)$") or arg[0]
local root = dirname(here)
package.path = root .. "/lua/?.lua;" .. root .. "/?.lua;" .. package.path

local hostmod = require("host")
local forth = require("forth")
local bridge = require("bridge")
local agent = require("agent")

bridge.setup_package_path(root)

local fail = 0
local function check(label, cond, detail)
  if cond then
    print("  ok  " .. label)
  else
    fail = fail + 1
    print("  FAIL " .. label .. (detail and (" — " .. tostring(detail)) or ""))
  end
end

local function tmpdir()
  local base = os.tmpname()
  os.remove(base)
  hostmod.mkdir_p(base)
  return base
end

local function write(path, text)
  local parent = path:match("^(.*)/[^/]+$")
  if parent then
    hostmod.mkdir_p(parent)
  end
  hostmod.write_bytes(path, text)
end

local function read(path)
  return hostmod.read_bytes(path)
end

print("== sha256 ==")
check("empty", hostmod.sha256("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
check("abc", hostmod.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
do
  local root = tmpdir() .. "/objects"
  local a = hostmod.intern(root, "abc")
  local b = hostmod.intern(root, "abc")
  check("intern idempotent", a == b)
  check("intern digest", a == hostmod.sha256("abc"))
  local tree = hostmod.intern_tree(root, { x = a })
  check("intern tree compact", tree == hostmod.sha256('{"x":"' .. a .. '"}'))
end
do
  local arrow = hostmod.decode_json('"\\u2192"')
  check("json \\u2192 is utf-8 arrow", arrow == "\226\134\146", arrow and string.byte(arrow, 1, #arrow))
  local round = hostmod.decode_json(hostmod.encode_json({ goal = "15 \226\134\146 FizzBuzz" }))
  check("json utf-8 goal roundtrip", type(round) == "table" and round.goal == "15 \226\134\146 FizzBuzz", round and round.goal)
end

print("== Forth 5 SQUARE ==")
do
  local ws = tmpdir()
  local h = hostmod.new({
    workspace = ws,
    allowed_effects = { "read", "write", "exec" },
    allowed_globs = { "app/*.py" },
    forbidden_globs = { "tests/**" },
  })
  local vm = forth.new(h)
  vm:interpret("3 4 +")
  check("3 4 +", vm.stack[1] == 7, vm.stack[1])
  vm.stack = {}
  vm:interpret(": SQUARE DUP * ; 5 SQUARE")
  check("5 SQUARE", vm.stack[1] == 25, vm.stack[1])
  vm.stack = {}
  vm:interpret("0 IF 99 ELSE 42 THEN")
  check("IF ELSE THEN", vm.stack[1] == 42, vm.stack[1])
  vm.stack = {}
  vm:interpret('S" hello world" \\ ignored\n( also ignored )')
  check('S" string + comments', vm.stack[1] == "hello world", vm.stack[1])
end

print("== artifact write ==")
do
  local ws = tmpdir()
  write(ws .. "/app/config.py", "OLD\n")
  local h = hostmod.new({
    workspace = ws,
    allowed_effects = { "read", "write", "exec" },
    allowed_globs = { "app/*.py", "src/*.py" },
    forbidden_globs = { "tests/**" },
  })
  local vm = forth.new(h, { ["app/config.py"] = "NEW\n" })
  vm:interpret('S" app/config.py" USE-ARTIFACT S" app/config.py" WRITE-FILE')
  check("wrote NEW", read(ws .. "/app/config.py") == "NEW\n")
  check("receipt path", type(vm.stack[1]) == "table" and vm.stack[1].path == "app/config.py")
  local again = h:write_file("NEW\n", "app/config.py")
  check("idempotent sha", again.sha256 == hostmod.sha256("NEW\n"))
end

print("== Lua critic mirror (not the live host path) ==")
do
  local program = 'S" tests/test_public.py" USE-ARTIFACT S" tests/test_public.py" WRITE-FILE'
  local lua_result = forth.validate(
    program,
    { "read", "write", "exec" },
    { "app/config.py" },
    { "tests/**" },
    { ["tests/test_public.py"] = "PWNED\n" }
  )
  check("lua critic rejects", lua_result.valid == false)
  local joined = table.concat(lua_result.errors, " ")
  check("lua critic says forbidden", joined:find("forbidden", 1, true) ~= nil, joined)
end

print("== boot Shen critic (required) ==")
if not bridge.boot() then
  io.stderr:write(
    "selftest requires shen-lua so the forbidden WRITE-FILE is gated by named validate.\n"
      .. "  git clone --branch v0.10.1 https://github.com/pyrex41/shen-lua.git ../shen-lua\n"
      .. "  or: export SHEN_LUA_DIR=/path/to/shen-lua\n"
      .. "boot error: "
      .. tostring(bridge.error)
      .. "\n"
  )
  os.exit(1)
end
local engine_ok = bridge.engine == "shen" or bridge.engine == "shaken"
check("bridge.engine", engine_ok, bridge.engine)
if bridge.engine == "shen" then
  check("contracts.shen loaded under (tc +)", bridge.contracts_typed == true)
end

print("== contracts via validate ==")
do
  if bridge.IO then
    local IO = bridge.IO
    local cin = IO.fn("contract-inputs")
    local cout = IO.fn("contract-outputs")
    local ceff = IO.fn("contract-effect")
    local wok = IO.fn("write-ok?")
    check("contract-inputs WRITE-FILE", cin("WRITE-FILE") == 2)
    check("contract-outputs WRITE-FILE", cout("WRITE-FILE") == 1)
    local eff = ceff("WRITE-FILE")
    check("contract-effect WRITE-FILE", type(eff) == "table" and eff[1] == "write", eff and eff[1])
    check(
      "write-ok? forbids tests/**",
      wok("tests/test_public.py", { "app/config.py" }, { "tests/**" }) == false
    )
    check(
      "write-ok? allows app/config.py",
      wok("app/config.py", { "app/config.py" }, { "tests/**" }) == true
    )
  else
    check("shaken path has no lua_interop (ok)", bridge.engine == "shaken")
  end
end

print("== Shen validate (stack / effects / globs / artifacts) ==")
do
  local accepted = bridge.validate(
    'S" src/records.py" USE-ARTIFACT S" src/records.py" WRITE-FILE RUN-TESTS RECEIPT',
    { "read", "write", "exec" },
    { "src/records.py" },
    {},
    { ["src/records.py"] = "ok\n" }
  )
  check("shen engine tag", accepted.engine == "shen" or accepted.engine == "shaken", accepted.engine)
  check("shen accepts straight-line", accepted.valid == true, table.concat(accepted.errors or {}, "; "))
  local rejected = bridge.validate(
    'DROP MYSTERY S" tests/test_public.py" WRITE-FILE',
    { "read", "write", "exec" },
    { "app/config.py" },
    { "tests/**" },
    {}
  )
  check("shen rejects", rejected.valid == false)
  local joined = table.concat(rejected.errors or {}, " ")
  check("shen underflow", joined:find("underflow", 1, true) ~= nil, joined)
  check("shen unknown", joined:find("unknown word", 1, true) ~= nil, joined)
  check("shen forbidden", joined:find("forbidden", 1, true) ~= nil, joined)
  local missing = bridge.validate(
    'S" app/config.py" USE-ARTIFACT',
    { "read", "write", "exec" },
    { "**" },
    {},
    {}
  )
  check("shen missing artifact", missing.valid == false)
  local mjoin = table.concat(missing.errors or {}, " ")
  check("shen no artifact text", mjoin:find("no artifact", 1, true) ~= nil, mjoin)
end

-- Agent path after boot: Shen validate rejects, interpret never runs, so
-- Host:write_file (which would also deny the glob) is never called.
print("== Shen-gated forbidden write never mutates ==")
do
  check("critic still live before agent", (bridge.engine == "shen" or bridge.engine == "shaken") and bridge.available, bridge.engine)
  local ws = tmpdir()
  write(ws .. "/tests/test_public.py", "SAFE\n")
  local run = tmpdir()
  local request = {
    protocol_version = "1.0",
    run_id = "selftest",
    arm = "forth-shen",
    memory_mode = "cold",
    resume = false,
    task = {
      id = "selftest",
      family = "selftest",
      sequence = 1,
      allowed_effects = { "read", "write", "exec" },
      allowed_globs = { "app/config.py" },
      forbidden_globs = { "tests/**" },
    },
    workspace = ws,
    prompt_path = ws .. "/TASK.md",
    trace_path = run .. "/trace.jsonl",
    receipt_path = run .. "/receipt.json",
    dictionary_dir = run .. "/dictionary",
  }
  hostmod.mkdir_p(run .. "/dictionary")
  write(run .. "/dictionary/envelope.json", hostmod.encode_json({
    artifacts = { ["tests/test_public.py"] = "PWNED\n" },
    language = "forth",
    program = 'S" tests/test_public.py" USE-ARTIFACT S" tests/test_public.py" WRITE-FILE',
    rationale = "",
  }, 2) .. "\n")

  local code = agent.run_request(request, { preflight = true })
  check("adapter exit 2", code == 2)
  check("file unchanged", read(ws .. "/tests/test_public.py") == "SAFE\n")
  local trace = read(run .. "/trace.jsonl") or ""
  check("preflight.rejected in trace", trace:find("preflight.rejected", 1, true) ~= nil, trace)
  check(
    "trace engine is shen or shaken",
    trace:find('"engine":"shen"', 1, true) ~= nil or trace:find('"engine":"shaken"', 1, true) ~= nil,
    trace
  )
  check("no tool.call (host I/O never ran)", not trace:find("tool.call", 1, true), trace)
  check("no WRITE-FILE tool", not trace:find("WRITE-FILE", 1, true), trace)
  check("no mutation.applied", not trace:find("mutation.applied", 1, true), trace)
end

print("== RUN-GATES word ==")
do
  local accepted = forth.validate("RUN-GATES RECEIPT", { "read", "write", "exec" }, { "**" }, {}, {})
  check("lua critic knows RUN-GATES", accepted.valid == true, table.concat(accepted.errors or {}, "; "))
end

print("== single-episode reject is not job death ==")
do
  local ws = tmpdir()
  write(ws .. "/tests/test_public.py", "SAFE\n")
  local run = tmpdir()
  local envelope = {
    artifacts = { ["tests/test_public.py"] = "PWNED\n" },
    language = "forth",
    program = 'S" tests/test_public.py" WRITE-FILE',
    rationale = "should reject",
  }
  local request = {
    protocol_version = "1.0",
    run_id = "selftest-reject",
    arm = "forth-shen",
    memory_mode = "cold",
    resume = false,
    task = {
      id = "selftest",
      family = "selftest",
      sequence = 1,
      allowed_effects = { "read", "write", "exec" },
      allowed_globs = { "app/config.py" },
      forbidden_globs = { "tests/**" },
    },
    workspace = ws,
    prompt_path = ws .. "/TASK.md",
    trace_path = run .. "/trace.jsonl",
    receipt_path = run .. "/receipt.json",
    dictionary_dir = run .. "/dictionary",
  }
  hostmod.mkdir_p(run .. "/dictionary")
  request._envelope = agent.parse_envelope(envelope)
  local code, result = agent.run_request(request, { preflight = true })
  check("adapter still exit 2", code == 2)
  local body
  code, body = agent.as_think(code, result, envelope)
  check("as_think maps reject to code 0", code == 0)
  check("critic is reject", body.critic == "reject")
  check("errors present", type(body.errors) == "table" and #body.errors > 0, body.errors and table.concat(body.errors, "; "))
  check("artifacts visible on reject", body.plan and body.plan.artifacts and body.plan.artifacts["tests/test_public.py"] == "PWNED\n")
  check("http 200", agent.http_status(code, body) == 200)
  check("file unchanged", read(ws .. "/tests/test_public.py") == "SAFE\n")
end

print("== host installs artifacts after accept (no USE-ARTIFACT) ==")
do
  local ws = tmpdir()
  local run = tmpdir()
  local envelope = {
    artifacts = { ["hello.txt"] = "hi\n" },
    language = "forth",
    program = 'S" hello.txt" WRITE-FILE RECEIPT',
    rationale = "write hello",
  }
  local request = {
    protocol_version = "1.0",
    run_id = "selftest-install",
    arm = "forth-shen",
    memory_mode = "cold",
    resume = false,
    task = {
      id = "selftest",
      family = "selftest",
      sequence = 1,
      allowed_effects = { "read", "write", "exec" },
      allowed_globs = { "**" },
      forbidden_globs = {},
    },
    workspace = ws,
    prompt_path = ws .. "/TASK.md",
    trace_path = run .. "/trace.jsonl",
    receipt_path = run .. "/receipt.json",
    dictionary_dir = run .. "/dictionary",
  }
  hostmod.mkdir_p(run .. "/dictionary")
  request._envelope = agent.parse_envelope(envelope)
  local code = agent.run_request(request, { preflight = true })
  check("accept exit 0", code == 0)
  check("installed hello.txt", read(ws .. "/hello.txt") == "hi\n")
  check("no GOAL.md in workspace", not hostmod.is_file(ws .. "/GOAL.md"))
  check("no PROGRESS.md in workspace", not hostmod.is_file(ws .. "/PROGRESS.md"))
end

print("== dictionary persist / reuse ==")
do
  local dictionary = require("dictionary")
  local ws = tmpdir()
  local dict = tmpdir()
  write(ws .. "/hello.txt", "OLD\n")
  local h = hostmod.new({
    workspace = ws,
    allowed_effects = { "read", "write", "exec" },
    allowed_globs = { "**" },
    forbidden_globs = {},
  })
  local vm = forth.new(h, { ["hello.txt"] = "NEW\n" })
  vm:interpret(': INSTALL DUP USE-ARTIFACT SWAP WRITE-FILE DROP ; S" hello.txt" INSTALL')
  local written = dictionary.save_colon(dict, vm)
  check("saved INSTALL", written[1] == "INSTALL", written[1])
  check("prelude has INSTALL", dictionary.load_prelude(dict):find("INSTALL", 1, true) ~= nil)
  local h2 = hostmod.new({
    workspace = ws,
    allowed_effects = { "read", "write", "exec" },
    allowed_globs = { "**" },
    forbidden_globs = {},
  })
  local program = dictionary.compose(dictionary.load_prelude(dict), 'S" hello.txt" INSTALL')
  local vm2 = forth.new(h2, { ["hello.txt"] = "LATER\n" })
  vm2:interpret(program)
  check("reused INSTALL writes", read(ws .. "/hello.txt") == "LATER\n")
end

if fail == 0 then
  print("\nOK — openresty selftest passed")
  os.exit(0)
else
  print(string.format("\n%d check(s) FAILED", fail))
  os.exit(1)
end
