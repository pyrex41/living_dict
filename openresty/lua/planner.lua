-- Call client/planner.py (Grok 4.6 via OAuth or XAI_API_KEY).
-- Used by /think when the body has a `goal` instead of a Forth envelope.

local hostmod = require("host")

local M = {}

local function planner_path()
  local prefix = (ngx and ngx.config and ngx.config.prefix()) or ""
  if prefix ~= "" then
    return prefix .. "../client/planner.py"
  end
  local src = debug.getinfo(1, "S").source
  local here = src:match("^@(.*)[/\\][^/\\]+$") or "."
  return here .. "/../../client/planner.py"
end

function M.plan(goal, workspace, extra, dictionary, episode)
  local py = os.getenv("PYTHON") or "python3"
  local script = planner_path()
  local payload = hostmod.encode_json({
    dictionary = dictionary or "",
    episode = tonumber(episode) or 1,
    extra = extra or "",
    goal = goal,
    workspace = workspace,
  })
  local raw = ""
  local err_out = ""
  if ngx and ngx.pipe then
    local proc, err = ngx.pipe.spawn({ py, script, "--stdin" })
    if not proc then
      return nil, "cannot spawn planner: " .. tostring(err)
    end
    proc:set_timeouts(10000, 10000, 180000)
    proc:write(payload)
    proc:shutdown("stdin")
    raw = proc:stdout_read_all() or ""
    local ok_err, captured = pcall(function()
      return proc:stderr_read_all()
    end)
    if ok_err then
      err_out = captured or ""
    end
    proc:wait()
  else
    local tmp = os.tmpname()
    local f = io.open(tmp, "w")
    if f then
      f:write(payload)
      f:close()
    end
    local cmd = string.format("%s %q --stdin < %q", py, script, tmp)
    local p = io.popen(cmd)
    raw = p and p:read("*a") or ""
    if p then
      p:close()
    end
    os.remove(tmp)
  end
  local ok, env = pcall(hostmod.decode_json, raw)
  if not ok or type(env) ~= "table" or type(env.program) ~= "string" then
    local msg = err_out
    if msg == "" then
      local failed = pcall(hostmod.decode_json, err_out)
      msg = raw
      if failed then
        -- keep raw
      end
    end
    if err_out ~= "" then
      local eok, ej = pcall(hostmod.decode_json, err_out)
      if eok and type(ej) == "table" and ej.error then
        msg = ej.error
      else
        msg = err_out
      end
    end
    return nil, tostring(msg ~= "" and msg or "planner returned no envelope")
  end
  return env, nil
end

return M
