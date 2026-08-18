-- Warm dictionary: colon words persist in dictionary_dir/words/*.fs.
-- Matches harness/src/livingdict/dictionary.py.

local hostmod = require("host")

local M = {}

local RESERVED = {
  ["READ-FILE"] = true,
  ["LIST-DIR"] = true,
  SEARCH = true,
  ["WRITE-FILE"] = true,
  ["RUN-TESTS"] = true,
  ["RUN-GATES"] = true,
  RECEIPT = true,
  ["USE-ARTIFACT"] = true,
  DUP = true,
  DROP = true,
  SWAP = true,
  OVER = true,
  ["+"] = true,
  ["-"] = true,
  ["*"] = true,
  IF = true,
  ELSE = true,
  THEN = true,
  [":"] = true,
  [";"] = true,
}

function M.safe_name(name)
  return type(name) == "string" and name:match("^[A-Z][A-Z0-9-]*$") ~= nil and #name <= 63
end

function M.words_dir(dictionary_dir)
  if not dictionary_dir or dictionary_dir == "" then
    return nil
  end
  return dictionary_dir .. "/words"
end

function M.load_prelude(dictionary_dir)
  local dir = M.words_dir(dictionary_dir)
  if not dir or not hostmod.is_dir(dir) then
    return ""
  end
  local chunks = {}
  for _, item in ipairs(hostmod.walk_files(dir, {})) do
    if item.rel:match("%.fs$") then
      local text = hostmod.read_bytes(item.full)
      if text then
        text = text:gsub("^%s+", ""):gsub("%s+$", "")
        if text ~= "" then
          chunks[#chunks + 1] = { rel = item.rel, text = text }
        end
      end
    end
  end
  table.sort(chunks, function(a, b)
    return a.rel < b.rel
  end)
  local out = {}
  for i = 1, #chunks do
    out[i] = chunks[i].text
  end
  return table.concat(out, "\n")
end

function M.compose(prelude, program)
  prelude = (prelude or ""):gsub("^%s+", ""):gsub("%s+$", "")
  program = (program or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if prelude == "" then
    return program
  end
  if program == "" then
    return prelude
  end
  return prelude .. "\n" .. program
end

function M.loaded_names(dictionary_dir)
  local dir = M.words_dir(dictionary_dir)
  if not dir or not hostmod.is_dir(dir) then
    return {}
  end
  local names = {}
  for _, item in ipairs(hostmod.walk_files(dir, {})) do
    local stem = item.rel:match("([^/]+)%.fs$")
    if stem then
      stem = string.upper(stem)
      if M.safe_name(stem) then
        names[#names + 1] = stem
      end
    end
  end
  table.sort(names)
  return names
end

function M.tokens_to_source(tokens)
  local parts = {}
  for i = 1, #tokens do
    local token = tokens[i]
    if token.kind == "string" then
      parts[#parts + 1] = 'S" ' .. tostring(token.value) .. '"'
    elseif token.kind == "number" then
      parts[#parts + 1] = tostring(token.value)
    else
      parts[#parts + 1] = tostring(token.value)
    end
  end
  return table.concat(parts, " ")
end

function M.used_names(program, loaded)
  local wanted = {}
  for i = 1, #(loaded or {}) do
    wanted[string.upper(tostring(loaded[i]))] = true
  end
  if next(wanted) == nil then
    return {}
  end
  local forth = require("forth")
  local ok, tokens = pcall(forth.tokenize, program)
  if not ok then
    return {}
  end
  local used, seen = {}, {}
  for i = 1, #tokens do
    local token = tokens[i]
    if token.kind == "word" then
      local name = string.upper(tostring(token.value))
      if wanted[name] and not seen[name] then
        seen[name] = true
        used[#used + 1] = name
      end
    end
  end
  table.sort(used)
  return used
end

function M.save_colon(dictionary_dir, vm, objects_root)
  local dir = M.words_dir(dictionary_dir)
  if not dir or type(vm) ~= "table" or type(vm.colon) ~= "table" then
    return {}
  end
  hostmod.mkdir_p(dir)
  local written = {}
  for name, body in pairs(vm.colon) do
    local key = string.upper(tostring(name))
    if M.safe_name(key) and not RESERVED[key] then
      local src
      if body and #body > 0 then
        src = ": " .. key .. " " .. M.tokens_to_source(body) .. " ;\n"
      else
        src = ": " .. key .. " ;\n"
      end
      if objects_root and objects_root ~= "" then
        hostmod.intern(objects_root, src)
      end
      local path = dir .. "/" .. key .. ".fs"
      local existing = hostmod.read_bytes(path)
      if existing ~= src then
        hostmod.write_bytes(path, src)
        written[#written + 1] = key
      end
    end
  end
  table.sort(written)
  return written
end

return M
