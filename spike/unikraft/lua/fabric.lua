local netkat = require("netkat")

local M = {}

function M.load(source)
  local env = netkat.parse(source)
  if not env.forward then
    error("fabric.netkat must define forward")
  end
  return {
    forward = env.forward,
    env = env,
    deliver = function(self, msg)
      local packet = {
        src = msg.src,
        dst = msg.dst,
        kind = msg.kind,
        sw = msg.src,
        pt = msg.pt or "0",
      }
      for _, hop in ipairs(netkat.star(self.forward, 6).apply(packet)) do
        if hop.sw == msg.dst then
          local out = {}
          for k, v in pairs(msg) do
            out[k] = v
          end
          out.sw = msg.dst
          return out
        end
      end
      return nil
    end,
    can_reach = function(self, src, dst, kind)
      return netkat.reachable(self.forward, {
        src = src,
        dst = dst,
        kind = kind,
        sw = src,
        pt = "0",
      }, dst)
    end,
  }
end

function M.from_file(path)
  local f, err = io.open(path, "r")
  if not f then
    error(err)
  end
  local src = f:read("*a")
  f:close()
  return M.load(src)
end

function M.isolation_holds(fabric)
  local banned = {
    { "planner", "store", "intern" },
    { "planner", "host", "execute" },
    { "planner", "store", "plan" },
    { "critic", "store", "intern" },
    { "critic", "host", "execute" },
    { "critic", "host", "intern" },
  }
  local required = {
    { "planner", "seq", "plan" },
    { "seq", "critic", "plan" },
    { "critic", "seq", "verdict" },
    { "seq", "host", "execute" },
    { "host", "store", "intern" },
    { "seq", "gates", "measure" },
    { "gates", "seq", "report" },
  }
  local failed = {}
  for _, row in ipairs(banned) do
    if fabric:can_reach(row[1], row[2], row[3]) then
      failed[#failed + 1] = row[1] .. " -[" .. row[3] .. "]-> " .. row[2] .. " should be drop"
    end
  end
  for _, row in ipairs(required) do
    if not fabric:can_reach(row[1], row[2], row[3]) then
      failed[#failed + 1] = row[1] .. " -[" .. row[3] .. "]-> " .. row[2] .. " should be reachable"
    end
  end
  return failed
end

return M
