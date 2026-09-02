-- Tiny NetKAT: filter, assign, union, sequence, bounded star.
-- Isolation is reachability against drop. No clocks.

local M = {}

local function copy(p)
  local o = {}
  for k, v in pairs(p) do
    o[k] = v
  end
  return o
end

local function key_of(p)
  local ks = {}
  for k in pairs(p) do
    ks[#ks + 1] = k
  end
  table.sort(ks)
  local parts = {}
  for _, k in ipairs(ks) do
    parts[#parts + 1] = k .. "=" .. tostring(p[k])
  end
  return table.concat(parts, "\0")
end

local function uniq_push(seen, acc, packet)
  local k = key_of(packet)
  if not seen[k] then
    seen[k] = true
    acc[#acc + 1] = packet
  end
end

local function policy(name, apply)
  return { name = name, apply = apply }
end

function M.drop()
  return policy("drop", function()
    return {}
  end)
end

function M.ident()
  return policy("id", function(p)
    return { copy(p) }
  end)
end

function M.filt(field, value)
  return policy(field .. "=" .. value, function(p)
    if p[field] == value then
      return { copy(p) }
    end
    return {}
  end)
end

function M.assign(field, value)
  return policy(field .. "<-" .. value, function(p)
    local o = copy(p)
    o[field] = value
    return { o }
  end)
end

function M.union(...)
  local ps = { ... }
  local names = {}
  for i, p in ipairs(ps) do
    names[i] = p.name
  end
  return policy(table.concat(names, " + "), function(packet)
    local seen, acc = {}, {}
    for _, pol in ipairs(ps) do
      for _, out in ipairs(pol.apply(packet)) do
        uniq_push(seen, acc, out)
      end
    end
    return acc
  end)
end

function M.seq(...)
  local ps = { ... }
  local names = {}
  for i, p in ipairs(ps) do
    names[i] = p.name
  end
  return policy(table.concat(names, " ; "), function(packet)
    local frontier = { copy(packet) }
    for _, pol in ipairs(ps) do
      local seen, nxt = {}, {}
      for _, item in ipairs(frontier) do
        for _, out in ipairs(pol.apply(item)) do
          uniq_push(seen, nxt, out)
        end
      end
      frontier = nxt
      if #frontier == 0 then
        break
      end
    end
    return frontier
  end)
end

function M.star(pol, fuel)
  fuel = fuel or 8
  return policy("(" .. pol.name .. ")*", function(packet)
    local seen, acc = {}, {}
    uniq_push(seen, acc, copy(packet))
    local frontier = { copy(packet) }
    for _ = 1, fuel do
      local nxt, nseen = {}, {}
      for _, item in ipairs(frontier) do
        for _, out in ipairs(pol.apply(item)) do
          local k = key_of(out)
          if not seen[k] then
            seen[k] = true
            acc[#acc + 1] = out
            nseen[k] = true
            nxt[#nxt + 1] = out
          end
        end
      end
      if #nxt == 0 then
        break
      end
      frontier = nxt
    end
    return acc
  end)
end

local function tokenize(text)
  local tokens = {}
  local i, n = 1, #text
  while i <= n do
    local ch = text:sub(i, i)
    if ch:match("%s") then
      i = i + 1
    elseif ch == "(" or ch == ")" or ch == ";" or ch == "+" or ch == "*" or ch == "=" then
      tokens[#tokens + 1] = ch
      i = i + 1
    elseif text:sub(i, i + 1) == "<-" then
      tokens[#tokens + 1] = "<-"
      i = i + 2
    else
      local j = i
      while j <= n and text:sub(j, j):match("[%w_.%-]") do
        j = j + 1
      end
      if j == i then
        error("bad NetKAT token at " .. text:sub(i))
      end
      tokens[#tokens + 1] = text:sub(i, j - 1)
      i = j
    end
  end
  return tokens
end

local function split_top(tokens, sep)
  local parts, cur, depth = {}, {}, 0
  for _, tok in ipairs(tokens) do
    if tok == "(" then
      depth = depth + 1
    elseif tok == ")" then
      depth = depth - 1
    end
    if tok == sep and depth == 0 then
      parts[#parts + 1] = cur
      cur = {}
    else
      cur[#cur + 1] = tok
    end
  end
  parts[#parts + 1] = cur
  return parts
end

local function balanced(tokens)
  local depth = 0
  for i, tok in ipairs(tokens) do
    if tok == "(" then
      depth = depth + 1
    elseif tok == ")" then
      depth = depth - 1
      if depth == 0 and i ~= #tokens then
        return false
      end
      if depth < 0 then
        return false
      end
    end
  end
  return depth == 0
end

local parse_union

local function parse_atom(tokens, lookup)
  if #tokens == 0 then
    return M.ident()
  end
  if tokens[1] == "(" and tokens[#tokens] == ")" and balanced(tokens) then
    local inner = {}
    for i = 2, #tokens - 1 do
      inner[#inner + 1] = tokens[i]
    end
    return parse_union(inner, lookup)
  end
  if #tokens == 3 and tokens[2] == "=" then
    return M.filt(tokens[1], tokens[3])
  end
  if #tokens == 3 and tokens[2] == "<-" then
    return M.assign(tokens[1], tokens[3])
  end
  if #tokens == 1 then
    local name = tokens[1]
    if name == "drop" then
      return M.drop()
    end
    if name == "id" or name == "pass" then
      return M.ident()
    end
    return lookup(name)
  end
  error("cannot parse NetKAT atom")
end

local function parse_star(tokens, lookup)
  if #tokens > 0 and tokens[#tokens] == "*" then
    local inner = {}
    for i = 1, #tokens - 1 do
      inner[#inner + 1] = tokens[i]
    end
    return M.star(parse_atom(inner, lookup))
  end
  return parse_atom(tokens, lookup)
end

local function parse_seq(tokens, lookup)
  local parts = split_top(tokens, ";")
  local ps = {}
  for i, part in ipairs(parts) do
    ps[i] = parse_star(part, lookup)
  end
  return M.seq(unpack(ps))
end

parse_union = function(tokens, lookup)
  local parts = split_top(tokens, "+")
  local ps = {}
  for i, part in ipairs(parts) do
    ps[i] = parse_seq(part, lookup)
  end
  return M.union(unpack(ps))
end

function M.parse(source)
  local raw = {}
  local order = {}
  for line in string.gmatch(source .. "\n", "([^\n]*)\n") do
    local stripped = line:gsub("#.*", ""):match("^%s*(.-)%s*$")
    if stripped ~= "" then
      local name, expr = stripped:match("^([%w_.%-]+)%s*:=%s*(.+)$")
      if not name then
        error("expected 'name := expr', got " .. stripped)
      end
      raw[name] = expr
      order[#order + 1] = name
    end
  end
  local env = {}
  local function resolve(name, stack)
    if env[name] then
      return env[name]
    end
    if not raw[name] then
      error("unknown NetKAT name " .. name)
    end
    if stack[name] then
      error("cyclic NetKAT definition " .. name)
    end
    stack[name] = true
    local function lookup(ident)
      if ident == "drop" then
        return M.drop()
      end
      if ident == "id" or ident == "pass" then
        return M.ident()
      end
      if raw[ident] then
        return resolve(ident, stack)
      end
      error("unknown atom " .. ident .. " in " .. name)
    end
    local pol = parse_union(tokenize(raw[name]), lookup)
    stack[name] = nil
    env[name] = pol
    return pol
  end
  for _, name in ipairs(order) do
    resolve(name, {})
  end
  return env
end

function M.reachable(pol, start, at)
  for _, packet in ipairs(M.star(pol).apply(start)) do
    if packet.sw == at then
      return true
    end
  end
  return false
end

return M
