-- Logical-time multiplexer. Fabric drops illegal hops. kernel.reduce
-- is the only state machine.

local kernel = require("kernel")
local organs = require("organs")
local host = require("host")

local M = {}

local function fingerprint(envelope)
  return host.sha256(host.encode_json(envelope))
end

function M.new(fabric, cap)
  return {
    fabric = fabric,
    cap = cap or 8,
    state = kernel.empty(),
    files = {},
    digests = {},
    store = organs.new_store(),
    dropped = {},
    trace = {},
  }
end

local function send(seq, message)
  local delivered = seq.fabric:deliver(message)
  seq.trace[#seq.trace + 1] = {
    src = message.src,
    dst = message.dst,
    kind = message.kind,
    delivered = delivered ~= nil,
  }
  if not delivered then
    seq.dropped[#seq.dropped + 1] = message
    error("fabric dropped " .. message.src .. " -[" .. message.kind .. "]-> " .. message.dst)
  end
  return delivered
end

function M.inject_illegal(seq, message)
  local delivered = seq.fabric:deliver(message)
  seq.trace[#seq.trace + 1] = {
    src = message.src,
    dst = message.dst,
    kind = message.kind,
    delivered = delivered ~= nil,
  }
  if not delivered then
    seq.dropped[#seq.dropped + 1] = message
  end
end

function M.run_episode(seq, envelope)
  local fp = fingerprint(envelope)
  seq.state = kernel.reduce(seq.state, {
    kind = "episode.planned",
    payload = { fingerprint = fp, dedupe_key = fp },
  })
  send(seq, { src = "planner", dst = "seq", kind = "plan", body = { envelope = envelope } })
  local verdict = organs.critic_step(send(seq, {
    src = "seq",
    dst = "critic",
    kind = "plan",
    body = {
      envelope = envelope,
      allowed_effects = { "read", "write", "exec" },
      allowed_globs = { "**" },
    },
  }))[1]
  verdict = send(seq, verdict)
  if verdict.body.accepted then
    seq.state = kernel.reduce(seq.state, { kind = "critic.accepted", payload = {} })
  else
    seq.state = kernel.reduce(seq.state, {
      kind = "critic.rejected",
      payload = { errors = verdict.body.errors },
    })
    seq.state = kernel.reduce(seq.state, { kind = "budget.consumed", payload = { steps = 1 } })
    return seq.state
  end

  local host_out = organs.host_step(send(seq, {
    src = "seq",
    dst = "host",
    kind = "execute",
    body = { envelope = envelope },
  }))
  local keys, files = {}, {}
  for _, m in ipairs(host_out) do
    local delivered = send(seq, m)
    if delivered.kind == "intern" then
      local interned = organs.store_step(seq.store, delivered)
      local ack = send(seq, interned[1])
      seq.digests[ack.body.path] = ack.body.digest
    elseif delivered.kind == "applied" then
      keys = delivered.body.keys or {}
      files = delivered.body.files or {}
      for path, body in pairs(files) do
        seq.files[path] = body
      end
    end
  end
  seq.state = kernel.reduce(seq.state, {
    kind = "artifacts.applied",
    payload = { keys = keys },
  })
  local report = organs.gates_step(send(seq, {
    src = "seq",
    dst = "gates",
    kind = "measure",
    body = { files = files },
  }))[1]
  report = send(seq, report)
  seq.state = kernel.reduce(seq.state, {
    kind = "gates.measured",
    payload = { report = report.body.report },
  })
  seq.state = kernel.reduce(seq.state, { kind = "budget.consumed", payload = { steps = 1 } })
  return seq.state
end

function M.decision(seq)
  return kernel.reconcile(seq.state, seq.cap)
end

function M.ledger(seq)
  return seq.state.events
end

return M
