-- Living Dictionary capability host. The only I/O a plan may perform.
-- Matches harness/src/livingdict/host.py + policy.py + receipts.py + trace.py.

local bit = require("bit")

local M = {}

local SKIP_SNAPSHOT = {
  [".git"] = true,
  ["__pycache__"] = true,
  [".mypy_cache"] = true,
  [".pytest_cache"] = true,
  [".ruff_cache"] = true,
  node_modules = true,
  dist = true,
  build = true,
  [".vite"] = true,
  [".livingdict-run"] = true,
  [".sb"] = true,
}

local SKIP_SEARCH = { [".git"] = true, ["__pycache__"] = true }

-- ---- errors ----------------------------------------------------------------

local function fail(code, message)
  error({ class = "capability", code = code, message = message }, 0)
end

function M.is_capability_error(err)
  return type(err) == "table" and err.class == "capability"
end

-- ---- strings / paths -------------------------------------------------------

local function isspace(c)
  return c == " " or c == "\t" or c == "\n" or c == "\r" or c == "\f" or c == "\v"
end

function M.isspace(c)
  return isspace(c)
end

local function is_abs(path)
  return type(path) == "string" and path:sub(1, 1) == "/"
end

local function split_parts(path)
  local parts = {}
  for part in string.gmatch(path, "[^/]+") do
    parts[#parts + 1] = part
  end
  return parts
end

function M.normalize(path)
  local abs = is_abs(path)
  local acc = {}
  for _, part in ipairs(split_parts(path)) do
    if part == "." then
      -- skip
    elseif part == ".." then
      if #acc > 0 then
        acc[#acc] = nil
      elseif not abs then
        acc[#acc + 1] = ".."
      end
    else
      acc[#acc + 1] = part
    end
  end
  if abs then
    if #acc == 0 then
      return "/"
    end
    return "/" .. table.concat(acc, "/")
  end
  return table.concat(acc, "/")
end

function M.join_path(base, path)
  if is_abs(path) then
    return M.normalize(path)
  end
  return M.normalize((base or "") .. "/" .. path)
end

local function sh_quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function realpath_of(path)
  local ok, ffi = pcall(require, "ffi")
  if not ok then
    return nil
  end
  pcall(ffi.cdef, "char *realpath(const char *path, char *resolved_path); void free(void *ptr);")
  local ok2, resolved = pcall(function()
    local r = ffi.C.realpath(path, nil)
    if r == nil then
      return nil
    end
    local s = ffi.string(r)
    ffi.C.free(r)
    return s
  end)
  if ok2 then
    return resolved
  end
  return nil
end

local function resolve_existing_prefix(path)
  local real = realpath_of(path)
  if real then
    return real
  end
  local parts = split_parts(M.normalize(path))
  local abs = is_abs(path)
  local built = abs and "/" or ""
  local last_real = nil
  if abs then
    last_real = realpath_of("/") or "/"
    built = last_real
  end
  local leftover = {}
  local seen_missing = false
  for i = 1, #parts do
    if not seen_missing then
      local candidate = (built == "/" or built == "") and (built .. parts[i]) or (built .. "/" .. parts[i])
      local r = realpath_of(candidate)
      if r then
        last_real = r
        built = r
      else
        seen_missing = true
        leftover[#leftover + 1] = parts[i]
      end
    else
      leftover[#leftover + 1] = parts[i]
    end
  end
  if last_real and #leftover > 0 then
    return M.normalize(last_real .. "/" .. table.concat(leftover, "/"))
  end
  if last_real then
    return last_real
  end
  return M.normalize(path)
end

function M.relative_to(workspace, path)
  local ws = realpath_of(workspace) or M.normalize(workspace)
  local resolved
  if is_abs(path) then
    resolved = resolve_existing_prefix(path)
  else
    resolved = resolve_existing_prefix(ws .. "/" .. path)
  end
  if resolved == ws then
    return ""
  end
  local prefix = ws .. "/"
  if resolved:sub(1, #prefix) == prefix then
    return resolved:sub(#prefix + 1)
  end
  error("path escapes workspace: " .. path, 0)
end

-- POSIX fnmatch, same contract as Python fnmatch.fnmatch (no special **).
function M.fnmatch(name, pattern)
  local function match(s, p)
    local si, pi, sn, pn = 1, 1, #s, #p
    local star_p, star_s = nil, nil
    while si <= sn do
      local pc = p:sub(pi, pi)
      if pc == "*" then
        star_p = pi
        star_s = si
        pi = pi + 1
      elseif pc == "?" or pc == s:sub(si, si) then
        si = si + 1
        pi = pi + 1
      elseif pc == "[" then
        local close = p:find("]", pi + 1, true)
        if not close then
          if pc == s:sub(si, si) then
            si = si + 1
            pi = pi + 1
          elseif star_p then
            star_s = star_s + 1
            si = star_s
            pi = star_p + 1
          else
            return false
          end
        else
          local cls = p:sub(pi + 1, close - 1)
          local negate = cls:sub(1, 1) == "!"
          if negate then
            cls = cls:sub(2)
          end
          local ch = s:sub(si, si)
          local found = false
          local ci = 1
          while ci <= #cls do
            if ci + 2 <= #cls and cls:sub(ci + 1, ci + 1) == "-" then
              if ch >= cls:sub(ci, ci) and ch <= cls:sub(ci + 2, ci + 2) then
                found = true
                break
              end
              ci = ci + 3
            else
              if ch == cls:sub(ci, ci) then
                found = true
                break
              end
              ci = ci + 1
            end
          end
          if negate then
            found = not found
          end
          if found then
            si = si + 1
            pi = close + 1
          elseif star_p then
            star_s = star_s + 1
            si = star_s
            pi = star_p + 1
          else
            return false
          end
        end
      elseif star_p then
        star_s = star_s + 1
        si = star_s
        pi = star_p + 1
      else
        return false
      end
    end
    while p:sub(pi, pi) == "*" do
      pi = pi + 1
    end
    return pi > pn
  end
  return match(name, pattern)
end

function M.matches_any(path, patterns)
  if not patterns then
    return false
  end
  for i = 1, #patterns do
    if M.fnmatch(path, patterns[i]) then
      return true
    end
  end
  return false
end

function M.write_allowed(rel, allowed_globs, forbidden_globs)
  if M.matches_any(rel, forbidden_globs) then
    return "forbidden path: " .. rel
  end
  if not M.matches_any(rel, allowed_globs) then
    return "path outside allowed change set: " .. rel
  end
  return nil
end

-- ---- SHA-256 ---------------------------------------------------------------

local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rshift, lshift = bit.rshift, bit.lshift

local function ror(x, n)
  return bor(rshift(x, n), lshift(x, 32 - n))
end

local K256 = {
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function add32(...)
  local s = 0
  for i = 1, select("#", ...) do
    s = s + band(select(i, ...), 0xffffffff)
  end
  return band(s, 0xffffffff)
end

function M.sha256(data)
  data = data or ""
  local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
  local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  local len = #data
  local bitlen = len * 8
  local pad = 64 - ((len + 9) % 64)
  if pad == 64 then
    pad = 0
  end
  local msg = data .. "\128" .. string.rep("\0", pad)
  local hi = math.floor(bitlen / 4294967296)
  local lo = bitlen % 4294967296
  msg = msg
    .. string.char(
      band(rshift(hi, 24), 255),
      band(rshift(hi, 16), 255),
      band(rshift(hi, 8), 255),
      band(hi, 255),
      band(rshift(lo, 24), 255),
      band(rshift(lo, 16), 255),
      band(rshift(lo, 8), 255),
      band(lo, 255)
    )
  local w = {}
  for i = 1, #msg, 64 do
    for t = 0, 15 do
      local j = i + t * 4
      local a, b, c, d = msg:byte(j, j + 3)
      w[t] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
    end
    for t = 16, 63 do
      local v15, v2 = w[t - 15], w[t - 2]
      local s0 = bxor(ror(v15, 7), ror(v15, 18), rshift(v15, 3))
      local s1 = bxor(ror(v2, 17), ror(v2, 19), rshift(v2, 10))
      w[t] = add32(w[t - 16], s0, w[t - 7], s1)
    end
    local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
    for t = 0, 63 do
      local S1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
      local ch = bxor(band(e, f), band(bnot(e), g))
      local temp1 = add32(h, S1, ch, K256[t + 1], w[t])
      local S0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
      local maj = bxor(band(a, b), band(a, c), band(b, c))
      local temp2 = add32(S0, maj)
      h, g, f, e, d, c, b, a = g, f, e, add32(d, temp1), c, b, a, add32(temp1, temp2)
    end
    h0, h1, h2, h3 = add32(h0, a), add32(h1, b), add32(h2, c), add32(h3, d)
    h4, h5, h6, h7 = add32(h4, e), add32(h5, f), add32(h6, g), add32(h7, h)
  end
  local function hex32(n)
    return string.format("%04x%04x", band(rshift(n, 16), 0xffff), band(n, 0xffff))
  end
  return hex32(h0) .. hex32(h1) .. hex32(h2) .. hex32(h3) .. hex32(h4) .. hex32(h5) .. hex32(h6) .. hex32(h7)
end

-- ---- JSON ------------------------------------------------------------------

local ArrayMT = { __jsontype = "array" }

function M.json_array(t)
  return setmetatable(t or {}, ArrayMT)
end

local function is_array_table(t)
  if getmetatable(t) == ArrayMT then
    return true
  end
  local n = 0
  local max = 0
  for k, _ in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
      return false
    end
    n = n + 1
    if k > max then
      max = k
    end
  end
  return n > 0 and n == max
end

local escapes = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function enc_str(s)
  return '"'
    .. s:gsub('[%z\1-\31"\\]', function(c)
      return escapes[c] or string.format("\\u%04x", c:byte())
    end)
    .. '"'
end

local encode_json

local function enc_array(t, out, indent, level)
  local n = #t
  if n == 0 then
    out[#out + 1] = "[]"
    return
  end
  if indent then
    out[#out + 1] = "[\n"
    for i = 1, n do
      out[#out + 1] = string.rep(" ", indent * (level + 1))
      encode_json(t[i], out, indent, level + 1)
      if i < n then
        out[#out + 1] = ",\n"
      else
        out[#out + 1] = "\n"
      end
    end
    out[#out + 1] = string.rep(" ", indent * level) .. "]"
  else
    out[#out + 1] = "["
    for i = 1, n do
      if i > 1 then
        out[#out + 1] = ","
      end
      encode_json(t[i], out, indent, level + 1)
    end
    out[#out + 1] = "]"
  end
end

local function enc_object(t, out, indent, level)
  local keys = {}
  for k in pairs(t) do
    if type(k) == "string" then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  if #keys == 0 then
    out[#out + 1] = "{}"
    return
  end
  if indent then
    out[#out + 1] = "{\n"
    for i, k in ipairs(keys) do
      out[#out + 1] = string.rep(" ", indent * (level + 1)) .. enc_str(k) .. ": "
      encode_json(t[k], out, indent, level + 1)
      if i < #keys then
        out[#out + 1] = ",\n"
      else
        out[#out + 1] = "\n"
      end
    end
    out[#out + 1] = string.rep(" ", indent * level) .. "}"
  else
    out[#out + 1] = "{"
    for i, k in ipairs(keys) do
      if i > 1 then
        out[#out + 1] = ","
      end
      out[#out + 1] = enc_str(k) .. ":"
      encode_json(t[k], out, indent, level + 1)
    end
    out[#out + 1] = "}"
  end
end

encode_json = function(v, out, indent, level)
  local t = type(v)
  if v == nil then
    out[#out + 1] = "null"
  elseif t == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      out[#out + 1] = "null"
    elseif v == math.floor(v) and math.abs(v) < 1e15 then
      out[#out + 1] = string.format("%.0f", v)
    else
      out[#out + 1] = tostring(v)
    end
  elseif t == "string" then
    out[#out + 1] = enc_str(v)
  elseif t == "table" then
    if is_array_table(v) then
      enc_array(v, out, indent, level)
    else
      enc_object(v, out, indent, level)
    end
  else
    out[#out + 1] = enc_str(tostring(v))
  end
end

function M.encode_json(value, indent)
  local out = {}
  encode_json(value, out, indent, 0)
  return table.concat(out)
end

local function decode_error(src, i, msg)
  error(string.format("json: %s at %d", msg, i), 0)
end

local function skip_ws(src, i)
  local n = #src
  while i <= n and isspace(src:sub(i, i)) do
    i = i + 1
  end
  return i
end

local parse_value

local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
  elseif cp < 0x10000 then
    return string.char(
      0xE0 + math.floor(cp / 0x1000),
      0x80 + (math.floor(cp / 0x40) % 0x40),
      0x80 + (cp % 0x40)
    )
  end
  return string.char(
    0xF0 + math.floor(cp / 0x40000),
    0x80 + (math.floor(cp / 0x1000) % 0x40),
    0x80 + (math.floor(cp / 0x40) % 0x40),
    0x80 + (cp % 0x40)
  )
end

local function parse_hex4(src, i)
  local hex = src:sub(i, i + 3)
  if not hex:match("^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$") then
    return nil
  end
  return tonumber(hex, 16)
end

local function parse_string(src, i)
  i = i + 1
  local out, n = {}, #src
  while i <= n do
    local c = src:sub(i, i)
    if c == '"' then
      return table.concat(out), i + 1
    elseif c == "\\" then
      local e = src:sub(i + 1, i + 1)
      local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
      if e == "u" then
        local cp = parse_hex4(src, i + 2)
        if not cp then
          decode_error(src, i, "bad unicode escape")
        end
        i = i + 6
        if cp >= 0xD800 and cp <= 0xDBFF and src:sub(i, i + 1) == "\\u" then
          local low = parse_hex4(src, i + 2)
          if low and low >= 0xDC00 and low <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (low - 0xDC00)
            i = i + 6
          end
        end
        out[#out + 1] = utf8_char(cp)
      elseif map[e] then
        out[#out + 1] = map[e]
        i = i + 2
      else
        decode_error(src, i, "bad escape")
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  decode_error(src, i, "unterminated string")
end

local function parse_number(src, i)
  local s, e = src:match("^([%-]?%d+%.?%d*[eE]?[%+%-]?%d*)", i)
  if not s then
    decode_error(src, i, "bad number")
  end
  return tonumber(s), i + #s
end

local function parse_array(src, i)
  i = skip_ws(src, i + 1)
  local arr = M.json_array({})
  if src:sub(i, i) == "]" then
    return arr, i + 1
  end
  while true do
    local v
    v, i = parse_value(src, i)
    arr[#arr + 1] = v
    i = skip_ws(src, i)
    local c = src:sub(i, i)
    if c == "]" then
      return arr, i + 1
    elseif c == "," then
      i = skip_ws(src, i + 1)
    else
      decode_error(src, i, "expected , or ]")
    end
  end
end

local function parse_object(src, i)
  i = skip_ws(src, i + 1)
  local obj = {}
  if src:sub(i, i) == "}" then
    return obj, i + 1
  end
  while true do
    i = skip_ws(src, i)
    if src:sub(i, i) ~= '"' then
      decode_error(src, i, "expected string key")
    end
    local key
    key, i = parse_string(src, i)
    i = skip_ws(src, i)
    if src:sub(i, i) ~= ":" then
      decode_error(src, i, "expected :")
    end
    local val
    val, i = parse_value(src, skip_ws(src, i + 1))
    obj[key] = val
    i = skip_ws(src, i)
    local c = src:sub(i, i)
    if c == "}" then
      return obj, i + 1
    elseif c == "," then
      i = i + 1
    else
      decode_error(src, i, "expected , or }")
    end
  end
end

parse_value = function(src, i)
  i = skip_ws(src, i)
  local c = src:sub(i, i)
  if c == '"' then
    return parse_string(src, i)
  elseif c == "{" then
    return parse_object(src, i)
  elseif c == "[" then
    return parse_array(src, i)
  elseif c == "t" and src:sub(i, i + 3) == "true" then
    return true, i + 4
  elseif c == "f" and src:sub(i, i + 4) == "false" then
    return false, i + 5
  elseif c == "n" and src:sub(i, i + 3) == "null" then
    return nil, i + 4
  elseif c == "-" or c:match("%d") then
    return parse_number(src, i)
  end
  decode_error(src, i, "unexpected token")
end

function M.decode_json(src)
  if type(src) ~= "string" then
    error("json: expected string", 0)
  end
  local value, i = parse_value(src, 1)
  i = skip_ws(src, i)
  if i <= #src then
    decode_error(src, i, "trailing data")
  end
  return value
end

-- ---- filesystem ------------------------------------------------------------

function M.read_bytes(path)
  local f, err = io.open(path, "rb")
  if not f then
    return nil, err
  end
  local data = f:read("*a")
  f:close()
  return data
end

function M.write_bytes(path, data)
  local f, err = io.open(path, "wb")
  if not f then
    return nil, err
  end
  f:write(data)
  f:close()
  return true
end

function M.is_dir(path)
  local d = io.open(path .. "/.", "r")
  if d then
    d:close()
    return true
  end
  return false
end

function M.is_file(path)
  if M.is_dir(path) then
    return false
  end
  local f = io.open(path, "rb")
  if f then
    f:close()
    return true
  end
  return false
end

function M.mkdir_p(path)
  if path == "" or path == "." or path == "/" then
    return true
  end
  os.execute("mkdir -p " .. sh_quote(path))
  return M.is_dir(path)
end

local function popen_lines(cmd)
  local p, err = io.popen(cmd)
  if not p then
    return nil, err
  end
  local lines = {}
  for line in p:lines() do
    lines[#lines + 1] = line
  end
  p:close()
  return lines
end

local function path_parts(rel)
  local parts = {}
  for part in string.gmatch(rel, "[^/]+") do
    parts[#parts + 1] = part
  end
  return parts
end

local function has_skip(rel, skip)
  for _, part in ipairs(path_parts(rel)) do
    if skip[part] then
      return true
    end
  end
  return false
end

function M.list_children(dir)
  local lines = popen_lines("find " .. sh_quote(dir) .. " -mindepth 1 -maxdepth 1 -print 2>/dev/null") or {}
  table.sort(lines, function(a, b)
    local na = a:match("([^/]+)$") or a
    local nb = b:match("([^/]+)$") or b
    return na < nb
  end)
  return lines
end

function M.walk_files(root, skip)
  skip = skip or SKIP_SNAPSHOT
  local lines = popen_lines("find " .. sh_quote(root) .. " -type f -print 2>/dev/null") or {}
  local out = {}
  local prefix = root
  if prefix:sub(-1) ~= "/" then
    prefix = prefix .. "/"
  end
  for _, full in ipairs(lines) do
    local rel
    if full:sub(1, #prefix) == prefix then
      rel = full:sub(#prefix + 1)
    else
      rel = full
    end
    if not has_skip(rel, skip) then
      out[#out + 1] = { full = full, rel = rel }
    end
  end
  table.sort(out, function(a, b)
    return a.rel < b.rel
  end)
  return out
end

function M.snapshot(root)
  local values = {}
  for _, item in ipairs(M.walk_files(root, SKIP_SNAPSHOT)) do
    if not item.rel:match("%.py[co]$") then
      local data = M.read_bytes(item.full)
      if data then
        values[item.rel] = M.sha256(data)
      end
    end
  end
  return values
end

function M.changed_files(before, after)
  local keys, seen = {}, {}
  for k in pairs(before) do
    if not seen[k] then
      seen[k] = true
      keys[#keys + 1] = k
    end
  end
  for k in pairs(after) do
    if not seen[k] then
      seen[k] = true
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  local changed = M.json_array({})
  for _, k in ipairs(keys) do
    if before[k] ~= after[k] then
      changed[#changed + 1] = k
    end
  end
  return changed
end

function M.workspace_digest(files)
  local hasher_input = {}
  local keys = {}
  for k in pairs(files) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  -- Match Python: sha256 over rel + \0 + digest + \n for each file.
  local chunks = {}
  for _, rel in ipairs(keys) do
    chunks[#chunks + 1] = rel .. "\0" .. files[rel] .. "\n"
  end
  return M.sha256(table.concat(chunks))
end

function M.iso_now()
  return os.date("!%Y-%m-%dT%H:%M:%S+00:00")
end

function M.emit(trace_path, event_type, data)
  if not trace_path or trace_path == "" then
    return
  end
  local event = {
    data = data or {},
    timestamp = M.iso_now(),
    type = event_type,
  }
  local parent = trace_path:match("^(.*)/[^/]+$")
  if parent then
    M.mkdir_p(parent)
  end
  local f, err = io.open(trace_path, "ab")
  if not f then
    error("cannot write trace: " .. tostring(err), 0)
  end
  f:write(M.encode_json(event) .. "\n")
  f:close()
end

-- ---- host object -----------------------------------------------------------

local Host = {}
Host.__index = Host

local function as_list(v)
  if v == nil then
    return {}
  end
  if type(v) ~= "table" then
    return { v }
  end
  local out = {}
  for i = 1, #v do
    out[i] = v[i]
  end
  return out
end

function M.new(opts)
  opts = opts or {}
  local workspace = opts.workspace
  if not workspace or workspace == "" then
    fail("workspace", "workspace is not a directory: " .. tostring(workspace))
  end
  workspace = realpath_of(workspace) or M.normalize(workspace)
  if not M.is_dir(workspace) then
    fail("workspace", "workspace is not a directory: " .. workspace)
  end
  local self = setmetatable({
    workspace = workspace,
    allowed_effects = as_list(opts.allowed_effects),
    allowed_globs = as_list(opts.allowed_globs),
    forbidden_globs = as_list(opts.forbidden_globs),
    trace_path = opts.trace_path,
    receipt_path = opts.receipt_path,
    run_id = tostring(opts.run_id or ""),
    task_id = tostring(opts.task_id or ""),
    test_timeout_seconds = opts.test_timeout_seconds or 60,
    _before = M.snapshot(workspace),
    _effects_used = {},
    _last_check = nil,
  }, Host)
  local allowed = {}
  for _, e in ipairs(self.allowed_effects) do
    allowed[e] = true
  end
  self._allowed_set = allowed
  return self
end

function M.from_request(request)
  local task = request.task or {}
  return M.new({
    workspace = request.workspace,
    allowed_effects = task.allowed_effects or { "read", "write", "exec" },
    allowed_globs = task.allowed_globs,
    forbidden_globs = task.forbidden_globs or {},
    trace_path = request.trace_path,
    receipt_path = request.receipt_path,
    run_id = request.run_id or "",
    task_id = task.id or "",
    test_timeout_seconds = request.test_timeout_seconds or task.test_timeout_seconds or 60,
  })
end

function Host:_tool(name, data)
  local payload = { tool = name }
  for k, v in pairs(data or {}) do
    payload[k] = v
  end
  M.emit(self.trace_path, "tool.call", payload)
end

function Host:_require_effect(effect)
  if not self._allowed_set[effect] then
    M.emit(self.trace_path, "execution.trap", { effect = effect, reason = "effect" })
    fail("effect", "effect not allowed: " .. effect)
  end
  self._effects_used[effect] = true
end

function Host:_rel(path)
  local ok, rel = pcall(M.relative_to, self.workspace, path)
  if not ok then
    local msg = type(rel) == "string" and rel or "path escapes workspace: " .. tostring(path)
    M.emit(self.trace_path, "execution.trap", { detail = msg, reason = "path" })
    fail("path", msg)
  end
  return rel
end

function Host:_existing_file(path)
  local rel = self:_rel(path)
  local target = rel == "" and self.workspace or (self.workspace .. "/" .. rel)
  if not M.is_file(target) then
    M.emit(self.trace_path, "execution.trap", { path = rel ~= "" and rel or ".", reason = "missing_file" })
    fail("missing_file", "missing file: " .. (rel ~= "" and rel or "."))
  end
  return target, rel
end

function Host:_existing_dir(path)
  if path == "" or path == "." then
    return self.workspace, "."
  end
  local rel = self:_rel(path)
  local target = rel == "" and self.workspace or (self.workspace .. "/" .. rel)
  if not M.is_dir(target) then
    M.emit(self.trace_path, "execution.trap", { path = rel ~= "" and rel or ".", reason = "missing_file" })
    fail("missing_file", "missing directory: " .. (rel ~= "" and rel or "."))
  end
  return target, rel
end

function Host:read_file(path)
  self:_require_effect("read")
  local target, rel = self:_existing_file(path)
  self:_tool("READ-FILE", { path = rel })
  local data, err = M.read_bytes(target)
  if not data then
    fail("decode", "cannot read: " .. rel .. " (" .. tostring(err) .. ")")
  end
  if data:find("\0", 1, true) then
    -- UTF-8 text check: reject NULs; remaining decode errors match Python.
  end
  -- Reject invalid UTF-8 the same way Python's read_text does.
  local i, n = 1, #data
  while i <= n do
    local b = data:byte(i)
    local need
    if b < 128 then
      need = 1
    elseif b >= 194 and b <= 223 then
      need = 2
    elseif b >= 224 and b <= 239 then
      need = 3
    elseif b >= 240 and b <= 244 then
      need = 4
    else
      fail("decode", "not utf-8 text: " .. rel)
    end
    if i + need - 1 > n then
      fail("decode", "not utf-8 text: " .. rel)
    end
    for j = 1, need - 1 do
      local c = data:byte(i + j)
      if c < 128 or c > 191 then
        fail("decode", "not utf-8 text: " .. rel)
      end
    end
    i = i + need
  end
  return data
end

function Host:list_dir(path)
  path = path or "."
  self:_require_effect("read")
  local target, rel = self:_existing_dir(path)
  self:_tool("LIST-DIR", { path = (rel ~= "" and rel) or "." })
  local names = M.json_array({})
  for _, full in ipairs(M.list_children(target)) do
    local child_rel
    local prefix = self.workspace .. "/"
    if full:sub(1, #prefix) == prefix then
      child_rel = full:sub(#prefix + 1)
    else
      child_rel = full:match("([^/]+)$") or full
    end
    if M.is_dir(full) then
      names[#names + 1] = child_rel .. "/"
    else
      names[#names + 1] = child_rel
    end
  end
  return names
end

function Host:search(query)
  self:_require_effect("read")
  self:_tool("SEARCH", { query = query })
  local hits = M.json_array({})
  if query == "" then
    return hits
  end
  for _, item in ipairs(M.walk_files(self.workspace, SKIP_SEARCH)) do
    local text = M.read_bytes(item.full)
    if text and not text:find("\0", 1, true) then
      local n = 0
      if text:sub(-1) == "\n" or #text == 0 then
        -- splitlines keeps no trailing empty from a final newline, like Python.
      end
      local start = 1
      while true do
        local nl = text:find("\n", start, true)
        local line
        if nl then
          line = text:sub(start, nl - 1)
          if line:sub(-1) == "\r" then
            line = line:sub(1, -2)
          end
          start = nl + 1
        else
          line = text:sub(start)
          if line == "" and start > 1 then
            break
          end
        end
        n = n + 1
        if query ~= "" and line:find(query, 1, true) then
          hits[#hits + 1] = { line = n, path = item.rel, text = line }
        end
        if not nl then
          break
        end
      end
    end
  end
  return hits
end

function Host:write_file(content, path)
  -- Defense in depth. The forth-shen critic (named validate) must reject a
  -- literal forbidden WRITE-FILE before interpret; this gate still runs if
  -- a path is only known at runtime.
  self:_require_effect("write")
  local rel = self:_rel(path)
  local reason = M.write_allowed(rel, self.allowed_globs, self.forbidden_globs)
  if reason then
    self:_tool("WRITE-FILE", { denied = true, path = rel })
    M.emit(self.trace_path, "execution.trap", { detail = reason, path = rel, reason = "policy" })
    fail("policy", reason)
  end
  local target = rel == "" and self.workspace or (self.workspace .. "/" .. rel)
  local data = content
  if type(data) ~= "string" then
    fail("type", "WRITE-FILE expected string content")
  end
  local digest = M.sha256(data)
  local receipt = { bytes = #data, path = rel, sha256 = digest }
  if M.is_file(target) then
    local existing = M.read_bytes(target)
    if existing == data then
      self:_tool("WRITE-FILE", { bytes = #data, idempotent = true, path = rel })
      return receipt
    end
  end
  local parent = target:match("^(.*)/[^/]+$")
  if parent then
    M.mkdir_p(parent)
  end
  local ok, err = M.write_bytes(target, data)
  if not ok then
    fail("write", "cannot write " .. rel .. ": " .. tostring(err))
  end
  self:_tool("WRITE-FILE", { bytes = #data, path = rel })
  M.emit(self.trace_path, "mutation.applied", { path = rel, sha256 = digest })
  return receipt
end

local function harness_script(name)
  if ngx and ngx.config and ngx.config.prefix then
    return ngx.config.prefix() .. "../harness/src/livingdict/" .. name
  end
  local src = debug.getinfo(1, "S").source
  local here = src:match("^@(.*)[/\\][^/\\]+$") or "."
  return here .. "/../../harness/src/livingdict/" .. name
end

function Host:run_gates()
  return self:_run_workspace_script("RUN-GATES", harness_script("gates.py"))
end

function Host:run_tests()
  return self:_run_workspace_script("RUN-TESTS", harness_script("check.py"))
end

function Host:_run_workspace_script(word, script)
  self:_require_effect("exec")
  self:_tool(word, { command = word })
  local py = os.getenv("PYTHON") or "python3"
  local timeout = self.test_timeout_seconds or 60
  local raw = ""
  local receipt
  if ngx and ngx.pipe then
    local proc, err = ngx.pipe.spawn({ py, script, self.workspace, tostring(timeout) })
    if proc then
      proc:set_timeouts(10000, 10000, (timeout + 5) * 1000)
      raw = proc:stdout_read_all() or ""
      proc:wait()
    else
      receipt = {
        passed = false,
        returncode = nil,
        stderr = tostring(err),
        stdout = "",
        timed_out = false,
      }
    end
  else
    local cmd = string.format("%s %s %s %s", sh_quote(py), sh_quote(script), sh_quote(self.workspace), tostring(timeout))
    local p = io.popen(cmd)
    raw = p and p:read("*a") or ""
    if p then
      p:close()
    end
  end
  if receipt == nil then
    local ok, decoded = pcall(M.decode_json, raw)
    if ok and type(decoded) == "table" then
      receipt = decoded
    else
      receipt = {
        passed = false,
        returncode = nil,
        stderr = raw,
        stdout = "",
        timed_out = false,
      }
    end
  end
  if receipt.timed_out then
    M.emit(self.trace_path, "execution.trap", { reason = "test_timeout" })
  end
  self._last_check = receipt
  return receipt
end

function Host:receipt(extra)
  local after = M.snapshot(self.workspace)
  local changed = M.changed_files(self._before, after)
  local violations = M.json_array({})
  local messages = M.json_array({})
  for i = 1, #changed do
    local item = changed[i]
    if M.write_allowed(item, self.allowed_globs, self.forbidden_globs) then
      violations[#violations + 1] = item
      messages[#messages + 1] = "path outside policy after the fact: " .. item
    end
  end
  local used = M.json_array({})
  for name in pairs(self._effects_used) do
    used[#used + 1] = name
  end
  table.sort(used)
  local payload = {
    changed_files = changed,
    effects_used = used,
    policy_violations = messages,
    run_id = self.run_id,
    success = #violations == 0,
    task_id = self.task_id,
    workspace_after = M.workspace_digest(after),
    workspace_before = M.workspace_digest(self._before),
    check = self._last_check,
  }
  if extra then
    for k, v in pairs(extra) do
      payload[k] = v
    end
  end
  local target = self.receipt_path
  if not target or target == "" then
    target = self.workspace .. "/receipt.json"
  end
  local body = { protocol_version = "1.0" }
  for k, v in pairs(payload) do
    body[k] = v
  end
  local parent = target:match("^(.*)/[^/]+$")
  if parent then
    M.mkdir_p(parent)
  end
  M.write_bytes(target, M.encode_json(body, 2) .. "\n")
  self:_tool("RECEIPT", { changed_files = changed, path = target })
  return body
end

M.Host = Host
M.fail = fail

return M
