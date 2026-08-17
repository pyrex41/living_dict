-- Tiny hosted Forth. Control flow and tool order, not a payload language.
-- Matches harness/src/livingdict/forth.py and livingdict/preflight.py.

local hostmod = require("host")

local M = {}

local function forth_error(code, message)
  error({ class = "forth", code = code, message = message }, 0)
end

function M.is_forth_error(err)
  return type(err) == "table" and (err.class == "forth" or err.class == "capability")
end

function M.err_code(err)
  if type(err) == "table" then
    return err.code or "error", err.message or tostring(err)
  end
  return "error", tostring(err)
end

local function isspace(c)
  return hostmod.isspace(c)
end

local function is_number(raw)
  if raw == "+" or raw == "-" then
    return false
  end
  if raw:sub(1, 1) == "-" then
    return raw:sub(2):match("^[0-9]+$") ~= nil
  end
  return raw:match("^[0-9]+$") ~= nil
end

function M.tokenize(source)
  local tokens = {}
  local i, n = 1, #source
  while i <= n do
    local ch = source:sub(i, i)
    if isspace(ch) then
      i = i + 1
    elseif ch == "\\" and (i == 1 or isspace(source:sub(i - 1, i - 1))) then
      while i <= n and source:sub(i, i) ~= "\n" do
        i = i + 1
      end
    elseif ch == "(" and (i == n or isspace(source:sub(i + 1, i + 1))) then
      i = i + 1
      while i <= n and source:sub(i, i) ~= ")" do
        i = i + 1
      end
      if i <= n then
        i = i + 1
      end
    elseif source:sub(i, i + 1) == 'S"' or source:sub(i, i + 1) == 's"' then
      i = i + 2
      if i <= n and source:sub(i, i) == " " then
        i = i + 1
      end
      local start = i
      while i <= n and source:sub(i, i) ~= '"' do
        i = i + 1
      end
      if i > n then
        forth_error("syntax", 'unterminated S" string')
      end
      tokens[#tokens + 1] = { kind = "string", value = source:sub(start, i - 1), index = #tokens }
      i = i + 1
    else
      local start = i
      while i <= n and not isspace(source:sub(i, i)) do
        i = i + 1
      end
      local raw = source:sub(start, i - 1)
      if is_number(raw) then
        tokens[#tokens + 1] = { kind = "number", value = tonumber(raw, 10), index = #tokens }
      else
        tokens[#tokens + 1] = { kind = "word", value = raw, index = #tokens }
      end
    end
  end
  return tokens
end

-- Encode tokens as dense arrays for lua_interop / Shen lists: [kind value index].
function M.tokens_as_lists(tokens)
  local out = {}
  for i, tok in ipairs(tokens) do
    out[i] = { tok.kind, tok.value, tok.index }
  end
  return out
end

local HOST_DICTIONARY = {
  ["READ-FILE"] = { inputs = 1, outputs = 1, effects = { "read" } },
  ["LIST-DIR"] = { inputs = 1, outputs = 1, effects = { "read" } },
  ["SEARCH"] = { inputs = 1, outputs = 1, effects = { "read" } },
  ["WRITE-FILE"] = { inputs = 2, outputs = 1, effects = { "write" } },
  ["RUN-TESTS"] = { inputs = 0, outputs = 1, effects = { "exec" } },
  ["RUN-GATES"] = { inputs = 0, outputs = 1, effects = { "exec" } },
  ["RECEIPT"] = { inputs = 0, outputs = 1, effects = {} },
  ["USE-ARTIFACT"] = { inputs = 1, outputs = 1, effects = { "read" } },
  ["DUP"] = { inputs = 1, outputs = 2, effects = {} },
  ["DROP"] = { inputs = 1, outputs = 0, effects = {} },
  ["SWAP"] = { inputs = 2, outputs = 2, effects = {} },
  ["OVER"] = { inputs = 2, outputs = 3, effects = {} },
  ["+"] = { inputs = 2, outputs = 1, effects = {} },
  ["-"] = { inputs = 2, outputs = 1, effects = {} },
  ["*"] = { inputs = 2, outputs = 1, effects = {} },
  ["IF"] = { inputs = 1, outputs = 0, effects = {} },
  ["ELSE"] = { inputs = 0, outputs = 0, effects = {} },
  ["THEN"] = { inputs = 0, outputs = 0, effects = {} },
}

M.HOST_DICTIONARY = HOST_DICTIONARY

local function literal_before(tokens, word_index)
  -- word_index is 1-based Lua; Python uses 0-based token.index for messages
  -- but _literal_before uses the loop index i into the tokens list (0-based).
  if word_index <= 1 then
    return nil
  end
  local prev = tokens[word_index - 1]
  if prev.kind == "string" then
    return tostring(prev.value)
  end
  return nil
end

local function skip_colon(tokens, i, errors)
  if i + 1 > #tokens or tokens[i + 1].kind ~= "word" then
    errors[#errors + 1] = string.format("token %s: expected name after :", tokens[i].index)
    return i + 1, nil
  end
  local defined = string.upper(tostring(tokens[i + 1].value))
  local j = i + 2
  while j <= #tokens do
    local token = tokens[j]
    if token.kind == "word" and string.upper(tostring(token.value)) == ";" then
      return j + 1, defined
    end
    if token.kind == "word" and string.upper(tostring(token.value)) == ":" then
      errors[#errors + 1] = string.format("token %s: nested colon definitions are not supported", token.index)
      return j + 1, nil
    end
    j = j + 1
  end
  errors[#errors + 1] = "unterminated colon definition"
  return #tokens + 1, nil
end

local DUMMY_ROOT = "/workspace"

function M.validate(program, allowed_effects, allowed_globs, forbidden_globs, artifacts)
  local errors = {}
  local ok, tokens = pcall(M.tokenize, program)
  if not ok then
    local msg = tokens
    if type(msg) == "table" and msg.message then
      msg = msg.message
    end
    return {
      valid = false,
      errors = hostmod.json_array({ tostring(msg) }),
      final_depth = 0,
      effects = hostmod.json_array({}),
    }
  end
  artifacts = artifacts or {}
  allowed_globs = allowed_globs or { "**" }
  forbidden_globs = forbidden_globs or {}
  local allowed_set = {}
  if type(allowed_effects) == "table" then
    for _, e in ipairs(allowed_effects) do
      allowed_set[e] = true
    end
    -- also accept a set-like table
    for k, v in pairs(allowed_effects) do
      if type(k) == "string" and v == true then
        allowed_set[k] = true
      end
    end
  end
  local words = {}
  for name, c in pairs(HOST_DICTIONARY) do
    words[name] = c
  end
  local effects = {}
  local depth = 0
  local i = 1
  while i <= #tokens do
    local token = tokens[i]
    if token.kind == "string" or token.kind == "number" then
      depth = depth + 1
      i = i + 1
    else
      local name = string.upper(tostring(token.value))
      if name == ":" then
        local defined
        i, defined = skip_colon(tokens, i, errors)
        if defined then
          words[defined] = { inputs = 0, outputs = 0, effects = {} }
        end
      else
        local contract = words[name]
        if contract == nil then
          errors[#errors + 1] = string.format("token %s: unknown word %s", token.index, token.value)
          i = i + 1
        else
          if depth < contract.inputs then
            errors[#errors + 1] = string.format("token %s: stack underflow at %s", token.index, name)
            depth = 0
          else
            depth = depth - contract.inputs
          end
          depth = depth + contract.outputs
          for _, e in ipairs(contract.effects) do
            effects[e] = true
          end
          if name == "WRITE-FILE" then
            local path = literal_before(tokens, i)
            if path ~= nil then
              local rok, rel = pcall(hostmod.relative_to, DUMMY_ROOT, path)
              if not rok then
                errors[#errors + 1] = string.format("token %s: %s", token.index, rel)
              else
                local reason = hostmod.write_allowed(rel, allowed_globs, forbidden_globs)
                if reason then
                  errors[#errors + 1] = string.format("token %s: %s", token.index, reason)
                end
              end
            end
          end
          if name == "USE-ARTIFACT" then
            local path = literal_before(tokens, i)
            if path ~= nil and artifacts[path] == nil then
              errors[#errors + 1] = string.format("token %s: no artifact: %s", token.index, path)
            end
          end
          i = i + 1
        end
      end
    end
  end
  local excess = {}
  for e in pairs(effects) do
    if not allowed_set[e] then
      excess[#excess + 1] = e
    end
  end
  table.sort(excess)
  if #excess > 0 then
    errors[#errors + 1] = "effects not allowed: " .. table.concat(excess, ", ")
  end
  local used = {}
  for e in pairs(effects) do
    used[#used + 1] = e
  end
  table.sort(used)
  return {
    valid = #errors == 0,
    errors = hostmod.json_array(errors),
    final_depth = depth,
    effects = hostmod.json_array(used),
  }
end

-- ---- VM --------------------------------------------------------------------

local function match_if(tokens, start)
  local depth = 0
  local else_at = nil
  for i = start, #tokens do
    local token = tokens[i]
    if token.kind == "word" then
      local word = string.upper(tostring(token.value))
      if word == "IF" then
        depth = depth + 1
      elseif word == "ELSE" and depth == 1 then
        else_at = i
      elseif word == "THEN" then
        if depth == 1 then
          return else_at, i
        end
        depth = depth - 1
      end
    end
  end
  forth_error("syntax", "IF without THEN")
end

local VM = {}
VM.__index = VM

function M.new(host, artifacts)
  local self = setmetatable({
    host = host,
    artifacts = artifacts or {},
    stack = {},
    colon = {},
  }, VM)
  self.words = {
    DUP = function()
      self:_dup()
    end,
    DROP = function()
      self:_drop()
    end,
    SWAP = function()
      self:_swap()
    end,
    OVER = function()
      self:_over()
    end,
    ["+"] = function()
      self:_add()
    end,
    ["-"] = function()
      self:_sub()
    end,
    ["*"] = function()
      self:_mul()
    end,
    ["READ-FILE"] = function()
      self:_read_file()
    end,
    ["LIST-DIR"] = function()
      self:_list_dir()
    end,
    SEARCH = function()
      self:_search()
    end,
    ["WRITE-FILE"] = function()
      self:_write_file()
    end,
    ["RUN-TESTS"] = function()
      self:_run_tests()
    end,
    ["RUN-GATES"] = function()
      self:_run_gates()
    end,
    RECEIPT = function()
      self:_receipt()
    end,
    ["USE-ARTIFACT"] = function()
      self:_use_artifact()
    end,
  }
  return self
end

function VM:interpret(source)
  self:run_tokens(M.tokenize(source))
end

function VM:run_tokens(tokens)
  local i = 1
  while i <= #tokens do
    local token = tokens[i]
    if token.kind == "string" then
      self.stack[#self.stack + 1] = tostring(token.value)
      i = i + 1
    elseif token.kind == "number" then
      self.stack[#self.stack + 1] = tonumber(token.value)
      i = i + 1
    else
      local name = tostring(token.value)
      local key = string.upper(name)
      if key == ":" then
        i = self:_compile_colon(tokens, i)
      elseif key == "IF" then
        i = self:_run_if(tokens, i)
      elseif key == "ELSE" or key == "THEN" or key == ";" then
        forth_error("syntax", key .. " without matching opener")
      else
        self:_exec_word(key, name)
        i = i + 1
      end
    end
  end
end

function VM:_exec_word(key, original)
  local body = self.colon[key]
  if body then
    self:run_tokens(body)
    return
  end
  local action = self.words[key]
  if action == nil then
    forth_error("unknown", "unknown word " .. original)
  end
  local ok, err = pcall(action)
  if not ok then
    if hostmod.is_capability_error(err) then
      forth_error(err.code, err.message)
    elseif M.is_forth_error(err) then
      error(err, 0)
    end
    error(err, 0)
  end
end

function VM:_compile_colon(tokens, i)
  if i + 1 > #tokens or tokens[i + 1].kind ~= "word" then
    forth_error("syntax", "expected name after :")
  end
  local name = string.upper(tostring(tokens[i + 1].value))
  local body = {}
  local j = i + 2
  while j <= #tokens do
    local token = tokens[j]
    if token.kind == "word" and string.upper(tostring(token.value)) == ";" then
      self.colon[name] = body
      return j + 1
    end
    if token.kind == "word" and string.upper(tostring(token.value)) == ":" then
      forth_error("syntax", "nested colon definitions are not supported")
    end
    body[#body + 1] = token
    j = j + 1
  end
  forth_error("syntax", "unterminated definition of " .. name)
end

function VM:_run_if(tokens, i)
  local flag = self:_truthy(self:_pop("IF"))
  local else_at, then_at = match_if(tokens, i)
  if flag then
    local finish = else_at or then_at
    local slice = {}
    for k = i + 1, finish - 1 do
      slice[#slice + 1] = tokens[k]
    end
    self:run_tokens(slice)
  elseif else_at ~= nil then
    local slice = {}
    for k = else_at + 1, then_at - 1 do
      slice[#slice + 1] = tokens[k]
    end
    self:run_tokens(slice)
  end
  return then_at + 1
end

function VM:_dup()
  local value = self:_peek("DUP")
  self.stack[#self.stack + 1] = value
end

function VM:_drop()
  self:_pop("DROP")
end

function VM:_swap()
  local b = self:_pop("SWAP")
  local a = self:_pop("SWAP")
  self.stack[#self.stack + 1] = b
  self.stack[#self.stack + 1] = a
end

function VM:_over()
  if #self.stack < 2 then
    forth_error("underflow", "stack underflow at OVER")
  end
  self.stack[#self.stack + 1] = self.stack[#self.stack - 1]
end

function VM:_add()
  local b = self:_pop_int("+")
  local a = self:_pop_int("+")
  self.stack[#self.stack + 1] = a + b
end

function VM:_sub()
  local b = self:_pop_int("-")
  local a = self:_pop_int("-")
  self.stack[#self.stack + 1] = a - b
end

function VM:_mul()
  local b = self:_pop_int("*")
  local a = self:_pop_int("*")
  self.stack[#self.stack + 1] = a * b
end

function VM:_read_file()
  local path = self:_pop_str("READ-FILE")
  self.stack[#self.stack + 1] = self.host:read_file(path)
end

function VM:_list_dir()
  local path = self:_pop_str("LIST-DIR")
  self.stack[#self.stack + 1] = self.host:list_dir(path)
end

function VM:_search()
  local query = self:_pop_str("SEARCH")
  self.stack[#self.stack + 1] = self.host:search(query)
end

function VM:_write_file()
  local path = self:_pop_str("WRITE-FILE")
  local content = self:_pop_str("WRITE-FILE")
  self.stack[#self.stack + 1] = self.host:write_file(content, path)
end

function VM:_run_tests()
  self.stack[#self.stack + 1] = self.host:run_tests()
end

function VM:_run_gates()
  self.stack[#self.stack + 1] = self.host:run_gates()
end

function VM:_receipt()
  self.stack[#self.stack + 1] = self.host:receipt()
end

function VM:_use_artifact()
  local path = self:_pop_str("USE-ARTIFACT")
  if self.artifacts[path] == nil then
    forth_error("missing_artifact", "no artifact: " .. path)
  end
  self.stack[#self.stack + 1] = self.artifacts[path]
end

function VM:_pop(word)
  if #self.stack == 0 then
    forth_error("underflow", "stack underflow at " .. word)
  end
  local v = self.stack[#self.stack]
  self.stack[#self.stack] = nil
  return v
end

function VM:_peek(word)
  if #self.stack == 0 then
    forth_error("underflow", "stack underflow at " .. word)
  end
  return self.stack[#self.stack]
end

function VM:_pop_str(word)
  local value = self:_pop(word)
  if type(value) ~= "string" then
    forth_error("type", word .. " expected string, got " .. type(value))
  end
  return value
end

function VM:_pop_int(word)
  local value = self:_pop(word)
  if type(value) ~= "number" or value ~= math.floor(value) then
    forth_error("type", word .. " expected integer, got " .. type(value))
  end
  return value
end

function VM:_truthy(value)
  if value == nil or value == false then
    return false
  end
  if value == 0 then
    return false
  end
  return true
end

function VM:defined_names()
  local names = {}
  for k in pairs(self.colon) do
    names[#names + 1] = k
  end
  table.sort(names)
  return names
end

M.VM = VM
M.error = forth_error

-- _G hook the untyped Shen shell uses to tokenise with the same rules as the VM.
livingdict = livingdict or {}
function livingdict.tokenise(program)
  local tokens = M.tokenize(program)
  return M.tokens_as_lists(tokens)
end

return M
