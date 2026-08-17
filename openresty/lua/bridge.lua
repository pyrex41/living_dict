-- Boot the critic once. Never do this per request.
--
-- Prefer openresty/dist/critic/app.lua (ratatoskr --target lua) when present.
-- Else boot the full kernel and load portable shen/critic/validate.shen
-- (eval-free, no lua.call). Last resort: openresty/shen/contracts+preflight.
-- forth.validate remains a Lua mirror for unit tests only.

local hostmod = require("host")

local M = {
  booted = false,
  available = false,
  contracts_typed = false,
  error = nil,
  engine = "lua",
}

local function this_dir()
  local src = debug.getinfo(1, "S").source
  return src:match("^@(.*)[/\\][^/\\]+$") or "."
end

local function openresty_root()
  return this_dir() .. "/.."
end

local function path_exists(path)
  local f = io.open(path, "r")
  if f then
    f:close()
    return true
  end
  return false
end

local function prepend_path(dir)
  if dir and dir ~= "" and path_exists(dir .. "/shen.lua") then
    package.path = dir .. "/?.lua;" .. package.path
    return dir
  end
  return nil
end

function M.setup_package_path(root)
  root = root or openresty_root()
  package.path = root .. "/lua/?.lua;" .. root .. "/?.lua;" .. package.path
  local candidates = {}
  local function add(dir)
    if dir and dir ~= "" then
      candidates[#candidates + 1] = dir
    end
  end
  add(os.getenv("SHEN_LUA_DIR"))
  add(root .. "/vendor/shen-lua")
  add(root .. "/../vendor/shen-lua")
  add(root .. "/../shen-lua")
  add(root .. "/../../shen-lua")
  for i = 1, #candidates do
    if prepend_path(candidates[i]) then
      M.shen_dir = candidates[i]
      return candidates[i]
    end
  end
  -- already on package.path (luarocks / sibling require)
  local ok = pcall(require, "shen")
  if ok then
    return true
  end
  return nil
end

local function boot_opts()
  local opts = { quiet = true, hush_load = true }
  local env = os.getenv("SHEN_JIT")
  if env == "off" or env == "0" then
    opts.jit = false
  end
  local jok, jit = pcall(require, "jit")
  if jok and jit and jit.arch == "arm64" then
    local ver = tostring(jit.version or "")
    if ver:find("beta3", 1, true) then
      opts.jit = false
    end
  end
  return opts
end

local function shen_err(P, err)
  if P and P.F and P.F["error-to-string"] then
    local ok, msg = pcall(P.F["error-to-string"], err)
    if ok and type(msg) == "string" then
      return msg
    end
  end
  if type(err) == "table" and err.msg then
    return tostring(err.msg)
  end
  return tostring(err)
end

local function load_file(P, shen, path, typed)
  if typed then
    shen.eval("(tc +)")
  else
    shen.eval("(tc -)")
  end
  local ok, err = pcall(P.F["load"], path)
  shen.eval("(tc -)")
  if not ok then
    return false, shen_err(P, err)
  end
  return true
end

local function setenv_if_empty(name, value)
  local cur = os.getenv(name)
  if cur and cur ~= "" then
    return
  end
  local ok, ffi = pcall(require, "ffi")
  if not ok then
    return
  end
  pcall(function()
    ffi.cdef[[int setenv(const char *name, const char *value, int overwrite);]]
    ffi.C.setenv(name, value, 0)
  end)
end

function M.pin_sidecar_paths(root)
  root = root or openresty_root()
  local hostmod = require("host")
  hostmod.mkdir_p(root .. "/var")
  hostmod.mkdir_p(root .. "/var/fasl")
  -- Kernel/fasl caches must not land in the ldeval workspace (cwd).
  setenv_if_empty("SHEN_KERNEL_CACHE", root .. "/var/shen-kernel-cache.bin")
  setenv_if_empty("SHEN_FASL_DIR", root .. "/var/fasl")
  setenv_if_empty("PYTHONDONTWRITEBYTECODE", "1")
end

local function portable_critic_path(root)
  local cands = {
    root .. "/../shen/critic/validate.shen",
    root .. "/shen/critic/validate.shen",
  }
  for i = 1, #cands do
    if path_exists(cands[i]) then
      return cands[i]
    end
  end
  return nil
end

local function shaken_critic_path(root)
  local p = root .. "/dist/critic/app.lua"
  if path_exists(p) then
    return p
  end
  return nil
end

local function array_from_list(R, lst)
  local out = {}
  while R.is_cons(lst) do
    local h = lst[1]
    if R.is_cons(h) then
      out[#out + 1] = array_from_list(R, h)
    elseif R.is_symbol(h) then
      out[#out + 1] = h.name
    elseif h == R.NIL then
      out[#out + 1] = {}
    else
      out[#out + 1] = h
    end
    lst = lst[2]
  end
  return out
end

local function shen_list(R, arr)
  if R.from_table then
    return R.from_table(arr)
  end
  local acc = R.NIL
  for i = #arr, 1, -1 do
    acc = R.cons(arr[i], acc)
  end
  return acc
end

local function bind_shaken_fns()
  local P = require("prims")
  local R = require("runtime")
  if not P.F or not P.F["validate"] then
    return false, "shaken artifact has no validate"
  end
  M._R = R
  M._P = P
  M._validate = P.F["validate"]
  M._validate_tokens = P.F["validate-tokens"]
  return true
end

local function boot_shaken(root)
  local path = shaken_critic_path(root)
  if not path then
    return false
  end
  local ok, err = pcall(dofile, path)
  if not ok then
    M.error = "shaken critic: " .. tostring(err)
    return false
  end
  local bound, berr = bind_shaken_fns()
  if not bound then
    M.error = tostring(berr)
    return false
  end
  M.available = true
  M.engine = "shaken"
  M.contracts_typed = false
  return true
end

local function boot_full_kernel(root)
  M.setup_package_path()
  M.pin_sidecar_paths()
  local ok_require, shen = pcall(require, "shen")
  if not ok_require then
    M.error = tostring(shen)
    return false
  end
  local opts = boot_opts()
  local ok_boot, err = pcall(function()
    shen.boot(opts)
  end)
  if not ok_boot then
    opts.jit = nil
    ok_boot, err = pcall(function()
      shen.boot(opts)
    end)
  end
  if not ok_boot then
    M.error = tostring(err)
    return false
  end
  local P = shen.prims
  local portable = portable_critic_path(root)
  if portable then
    local okp, errp = load_file(P, shen, portable, false)
    if not okp then
      M.error = "shen/critic/validate.shen: " .. tostring(errp)
      return false
    end
    M.contracts_typed = false
  else
    local contracts = root .. "/shen/contracts.shen"
    local preflight = root .. "/shen/preflight.shen"
    local okc, errc = load_file(P, shen, contracts, true)
    M.contracts_typed = okc and true or false
    if not okc then
      okc, errc = load_file(P, shen, contracts, false)
    end
    if not okc then
      M.error = "contracts.shen: " .. tostring(errc)
      return false
    end
    local okpf, errpf = load_file(P, shen, preflight, false)
    if not okpf then
      M.error = "preflight.shen: " .. tostring(errpf)
      return false
    end
  end
  local IO = require("lua_interop")
  M._validate = IO.fn("validate")
  M._validate_tokens = IO.fn("validate-tokens")
  M.shen = shen
  M.IO = IO
  M.available = true
  M.engine = "shen"
  return true
end

function M.boot()
  if M.booted then
    return M.available
  end
  M.booted = true
  local root = openresty_root()
  -- Prefer the Ratatoskr-shaken lua artifact (no full kernel, no lua.call).
  if boot_shaken(root) then
    return true
  end
  if boot_full_kernel(root) then
    return true
  end
  M.available = false
  if M.engine ~= "shaken" then
    M.engine = "lua"
  end
  return false
end

function M.ready()
  return M.available
end

local function keys_of(artifacts)
  local keys = {}
  if type(artifacts) ~= "table" then
    return keys
  end
  for k in pairs(artifacts) do
    if type(k) == "string" then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  return keys
end

local function as_string_list(v)
  if v == nil then
    return {}
  end
  if type(v) ~= "table" then
    return { tostring(v) }
  end
  local out = {}
  for i = 1, #v do
    out[#out + 1] = v[i]
  end
  return out
end

local function decode_shen_result(result)
  if type(result) ~= "table" then
    return {
      valid = false,
      errors = hostmod.json_array({ tostring(result) }),
      final_depth = 0,
      effects = hostmod.json_array({}),
    }
  end
  local tag = result[1]
  if tag == "accept" then
    return {
      valid = true,
      errors = hostmod.json_array({}),
      final_depth = tonumber(result[2]) or 0,
      effects = hostmod.json_array(as_string_list(result[3])),
    }
  end
  if tag == "reject" then
    return {
      valid = false,
      errors = hostmod.json_array(as_string_list(result[2])),
      final_depth = tonumber(result[3]) or 0,
      effects = hostmod.json_array(as_string_list(result[4])),
    }
  end
  return {
    valid = false,
    errors = hostmod.json_array({ "unexpected validate result" }),
    final_depth = 0,
    effects = hostmod.json_array({}),
  }
end

function M.ensure()
  if not M.booted then
    M.boot()
  end
  return M.available
end

function M.validate(program, allowed_effects, allowed_globs, forbidden_globs, artifacts)
  if not M.ensure() then
    error("shen-lua critic is not available: " .. tostring(M.error), 0)
  end
  local effects = as_string_list(allowed_effects)
  local allowed = as_string_list(allowed_globs)
  if #allowed == 0 then
    allowed = { "**" }
  end
  local forbidden = as_string_list(forbidden_globs)
  local keys = keys_of(artifacts)
  local args_program, args_effects, args_allowed, args_forbidden, args_keys =
    program, effects, allowed, forbidden, keys
  if M.engine == "shaken" and M._R then
    args_effects = shen_list(M._R, effects)
    args_allowed = shen_list(M._R, allowed)
    args_forbidden = shen_list(M._R, forbidden)
    args_keys = shen_list(M._R, keys)
  end
  local sok, result = pcall(M._validate, args_program, args_effects, args_allowed, args_forbidden, args_keys)
  if not sok then
    return {
      engine = M.engine,
      valid = false,
      errors = hostmod.json_array({ tostring(result) }),
      final_depth = 0,
      effects = hostmod.json_array({}),
    }
  end
  if M.engine == "shaken" and M._R and type(result) == "table" and M._R.is_cons(result) then
    result = array_from_list(M._R, result)
    if type(result[1]) == "string" then
      -- tag already a name
    end
  end
  local decoded = decode_shen_result(result)
  decoded.engine = M.engine
  return decoded
end

return M
