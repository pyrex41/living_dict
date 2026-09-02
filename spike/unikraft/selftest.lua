-- luajit spike/unikraft/selftest.lua
-- No Python. Organs are Lua transducers on a NetKAT fabric.

local function dirname(path)
  return path:match("^(.*)/[^/]+$") or "."
end

local here = debug.getinfo(1, "S").source:match("^@(.*)$") or arg[0]
local root = dirname(here)
local repo = root .. "/../.."
package.path = root
  .. "/lua/?.lua;"
  .. repo
  .. "/openresty/lua/?.lua;"
  .. package.path

local netkat = require("netkat")
local fabricmod = require("fabric")
local kernel = require("kernel")
local seqmod = require("seq")

local fail = 0
local function check(label, cond, detail)
  if cond then
    print("  ok  " .. label)
  else
    fail = fail + 1
    print("  FAIL " .. label .. (detail and (" — " .. tostring(detail)) or ""))
  end
end

print("== NetKAT ==")
do
  local hop = netkat.seq(netkat.filt("sw", "a"), netkat.assign("sw", "b"))
  local out = hop.apply({ sw = "a", kind = "plan" })
  check("filter+assign", #out == 1 and out[1].sw == "b")
  check("filter miss", #hop.apply({ sw = "b" }) == 0)
  check("drop", #netkat.drop().apply({ sw = "a" }) == 0)
  local env = netkat.parse("p := sw = a ; sw <- b\nforward := p\n")
  check("parse named", env.forward.apply({ sw = "a" })[1].sw == "b")
end

print("== fabric isolation ==")
local fabric = fabricmod.from_file(root .. "/model/fabric.netkat")
do
  local failed = fabricmod.isolation_holds(fabric)
  check("isolation queries", #failed == 0, failed[1])
end

print("== episode ==")
local HELLO = {
  language = "forth",
  program = 'S" hello.txt" USE-ARTIFACT S" hello.txt" WRITE-FILE RECEIPT',
  artifacts = { ["hello.txt"] = "hello from unikraft spike\n" },
}
local BAD = {
  language = "forth",
  program = "NOT-A-WORD",
  artifacts = { ["hello.txt"] = "nope\n" },
}

do
  local seq = seqmod.new(fabric, 8)
  seqmod.run_episode(seq, HELLO)
  check("accept critic", seq.state.last_critic == "accepted")
  check("workspace write", seq.files["hello.txt"] == "hello from unikraft spike\n")
  local nobj = 0
  for _ in pairs(seq.store.objects) do
    nobj = nobj + 1
  end
  check("store interned", nobj > 0)
  check("decision success", seqmod.decision(seq).kind == "success")
  local kinds = {}
  for i, ev in ipairs(seq.state.events) do
    kinds[i] = ev.kind
  end
  check(
    "ledger kinds",
    table.concat(kinds, ",")
      == "episode.planned,critic.accepted,artifacts.applied,gates.measured,budget.consumed"
  )

  local replayed = kernel.replay(seqmod.ledger(seq))
  check("replay critic", replayed.last_critic == seq.state.last_critic)
  check("replay used", replayed.used == seq.state.used)
  local again = seqmod.new(fabric, 8)
  seqmod.run_episode(again, HELLO)
  check("deterministic ledger len", #again.state.events == #seq.state.events)
  check("deterministic tree", again.state.last_gates.tree == seq.state.last_gates.tree)
end

do
  local seq = seqmod.new(fabric, 8)
  seqmod.run_episode(seq, BAD)
  check("reject critic", seq.state.last_critic == "rejected")
  check("reject no files", seq.files["hello.txt"] == nil)
  local nobj = 0
  for _ in pairs(seq.store.objects) do
    nobj = nobj + 1
  end
  check("reject no store", nobj == 0)
  local saw_apply = false
  for _, ev in ipairs(seq.state.events) do
    if ev.kind == "artifacts.applied" then
      saw_apply = true
    end
  end
  check("reject no apply", not saw_apply)
  check("reject next is plan", seqmod.decision(seq).kind == "plan")
end

do
  local seq = seqmod.new(fabric, 8)
  seqmod.inject_illegal(seq, {
    src = "planner",
    dst = "store",
    kind = "intern",
    body = { path = "x", bytes = "y" },
  })
  check("drop planner intern", #seq.dropped == 1)
  check("drop did not intern", seq.store.objects["x"] == nil)
end

if fail > 0 then
  print("FAILED " .. fail)
  os.exit(1)
end
print("all ok")
