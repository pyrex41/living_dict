-- Organs as transducers. Critic is forth.validate (Lua body of the Shen
-- contracts). Store is content-addressed intern. No clocks, no RNG.

local forth = require("forth")
local host = require("host")

local M = {}

local function msg(src, dst, kind, body)
  return { src = src, dst = dst, kind = kind, body = body or {} }
end

function M.critic_step(message)
  if message.kind ~= "plan" then
    error("critic got " .. tostring(message.kind))
  end
  local envelope = message.body.envelope or {}
  local artifacts = envelope.artifacts or {}
  local result = forth.validate(
    envelope.program or "",
    message.body.allowed_effects or { "read", "write", "exec" },
    message.body.allowed_globs or { "**" },
    message.body.forbidden_globs or {},
    artifacts
  )
  local errors = {}
  for i, e in ipairs(result.errors or {}) do
    errors[i] = tostring(e)
  end
  return {
    msg("critic", "seq", "verdict", {
      accepted = result.valid and true or false,
      errors = errors,
      envelope = envelope,
    }),
  }
end

function M.host_step(message)
  if message.kind ~= "execute" then
    error("host got " .. tostring(message.kind))
  end
  local artifacts = (message.body.envelope or {}).artifacts or {}
  local keys = {}
  for path in pairs(artifacts) do
    keys[#keys + 1] = path
  end
  table.sort(keys)
  local outbound = {}
  local files = {}
  for _, path in ipairs(keys) do
    files[path] = tostring(artifacts[path])
    outbound[#outbound + 1] = msg("host", "store", "intern", {
      path = path,
      bytes = files[path],
    })
  end
  outbound[#outbound + 1] = msg("host", "seq", "applied", {
    keys = keys,
    files = files,
  })
  return outbound
end

function M.new_store()
  return { objects = {} }
end

function M.store_step(store, message)
  if message.kind ~= "intern" then
    error("store got " .. tostring(message.kind))
  end
  local blob = tostring(message.body.bytes or "")
  local digest = host.intern(nil, blob)
  store.objects[digest] = blob
  return {
    msg("store", "host", "interned", {
      path = tostring(message.body.path or ""),
      digest = digest,
    }),
  }
end

function M.gates_step(message)
  if message.kind ~= "measure" then
    error("gates got " .. tostring(message.kind))
  end
  local files = message.body.files or {}
  local digests = {}
  for path, body in pairs(files) do
    digests[path] = host.sha256(tostring(body))
  end
  local tree = host.intern(nil, host.encode_json(digests))
  local expect = message.body.expect_tree
  local passed = (expect == nil) or (expect == tree)
  local report = {
    passed = passed,
    gates = {
      {
        name = "claims",
        passed = passed,
        claims = { { id = "tree", kind = "hash", passed = passed } },
      },
    },
    tree = tree,
  }
  return { msg("gates", "seq", "report", { report = report }) }
end

return M
