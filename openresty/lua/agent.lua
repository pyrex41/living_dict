-- Envelope -> preflight -> Forth -> traces/receipts. Same protocol as
-- harness/src/livingdict/adapter.py + execute.py + envelope.py.

local hostmod = require("host")
local forth = require("forth")
local bridge = require("bridge")

local M = {}

local function exec_error(code, message, details)
  return { class = "execution", code = code, message = message, details = details or {} }
end

local function raise(code, message, details)
  error(exec_error(code, message, details), 0)
end

local function string_list(value, label)
  if value == nil then
    return {}
  end
  if type(value) ~= "table" then
    raise("envelope", label .. " must be an array")
  end
  for k, v in pairs(value) do
    if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
      raise("envelope", label .. " must be an array")
    end
    if type(v) ~= "string" then
      raise("envelope", label .. " entries must be strings")
    end
  end
  local out = {}
  for i, v in ipairs(value) do
    out[i] = v
  end
  return out
end

local function parse_nodes(raw)
  if raw == nil then
    return nil
  end
  if type(raw) ~= "table" then
    raise("envelope", "envelope.nodes must be an array")
  end
  local nodes = {}
  for i, item in ipairs(raw) do
    if type(item) ~= "table" then
      raise("envelope", "envelope.nodes[" .. i .. "] must be an object")
    end
    local ident = item.id
    if type(ident) ~= "string" or ident:match("^%s*$") then
      raise("envelope", "envelope.nodes[" .. i .. "].id must be a string")
    end
    local program = item.program
    if program == nil then
      program = ""
    end
    if type(program) ~= "string" then
      raise("envelope", "envelope.nodes[" .. i .. "].program must be a string")
    end
    local node = {
      id = ident,
      writes = string_list(item.writes, "envelope.nodes[" .. i .. "].writes"),
      depends_on = string_list(item.depends_on, "envelope.nodes[" .. i .. "].depends_on"),
      program = program,
    }
    if item.allowed_globs ~= nil then
      node.allowed_globs = string_list(
        item.allowed_globs,
        "envelope.nodes[" .. i .. "].allowed_globs"
      )
    end
    nodes[#nodes + 1] = node
  end
  if #nodes == 0 then
    return nil
  end
  return nodes
end

function M.parse_envelope(value)
  if type(value) ~= "table" then
    raise("envelope", "envelope must be an object")
  end
  local language = value.language
  local program = value.program
  local nodes = parse_nodes(value.nodes)
  if type(language) ~= "string" or language:match("^%s*$") then
    raise("envelope", "envelope.language must be a string")
  end
  if type(program) ~= "string" then
    if nodes then
      program = ""
    else
      raise("envelope", "envelope.program must be a string")
    end
  end
  local artifacts = value.artifacts or {}
  if type(artifacts) ~= "table" then
    raise("envelope", "envelope.artifacts must be an object")
  end
  local cleaned = {}
  for key, text in pairs(artifacts) do
    if type(key) ~= "string" or type(text) ~= "string" then
      raise("envelope", "artifact keys and values must be strings")
    end
    cleaned[key] = text
  end
  local rationale = value.rationale or ""
  if type(rationale) ~= "string" then
    raise("envelope", "envelope.rationale must be a string")
  end
  return {
    language = language:match("^%s*(.-)%s*$"):lower(),
    program = program,
    artifacts = cleaned,
    rationale = rationale,
    nodes = nodes,
  }
end

function M.envelope_to_dict(envelope)
  local payload = {
    artifacts = envelope.artifacts,
    language = envelope.language,
    program = envelope.program,
    rationale = envelope.rationale or "",
  }
  if envelope.nodes then
    payload.nodes = envelope.nodes
  end
  return payload
end

function M.load_envelope(path)
  local data, err = hostmod.read_bytes(path)
  if not data then
    raise("envelope", "cannot read envelope: " .. tostring(err))
  end
  local ok, payload = pcall(hostmod.decode_json, data)
  if not ok then
    raise("envelope", "invalid envelope JSON: " .. tostring(payload))
  end
  return M.parse_envelope(payload)
end

function M.checkpoint_path(request)
  local receipt = request.receipt_path
  local parent = receipt:match("^(.*)/[^/]+$")
  if parent then
    return parent .. "/checkpoint.json"
  end
  return "checkpoint.json"
end

function M.save_checkpoint(request, envelope)
  local path = M.checkpoint_path(request)
  local parent = path:match("^(.*)/[^/]+$")
  if parent then
    hostmod.mkdir_p(parent)
  end
  local body = {
    envelope = M.envelope_to_dict(envelope),
    workspace = request.workspace,
  }
  hostmod.write_bytes(path, hostmod.encode_json(body, 2) .. "\n")
end

function M.load_checkpoint(request)
  local path = M.checkpoint_path(request)
  local data = hostmod.read_bytes(path)
  if not data then
    return nil
  end
  local ok, payload = pcall(hostmod.decode_json, data)
  if not ok or type(payload) ~= "table" or type(payload.envelope) ~= "table" then
    return nil
  end
  return M.parse_envelope(payload.envelope)
end

function M.resolve_envelope(request)
  if request.resume then
    local saved = M.load_checkpoint(request)
    if saved == nil then
      raise("resume", "resume requested but checkpoint.json is missing")
    end
    return saved
  end
  local override = os.getenv("LIVINGDICT_ENVELOPE")
  if override and override ~= "" then
    return M.load_envelope(override)
  end
  local candidate = (request.dictionary_dir or ".") .. "/envelope.json"
  if hostmod.is_file(candidate) then
    return M.load_envelope(candidate)
  end
  raise("envelope", "no plan envelope (set LIVINGDICT_ENVELOPE or write dictionary_dir/envelope.json)")
end

local function lower_artifact_writes(program, artifacts)
  if type(program) ~= "string" or type(artifacts) ~= "table" then
    return program
  end
  local ok, tokens = pcall(forth.tokenize, program)
  if not ok then
    return program
  end
  local kept = {}
  local i = 1
  while i <= #tokens do
    local token = tokens[i]
    local nxt = tokens[i + 1]
    if token.kind == "string" and artifacts[token.value] and nxt and nxt.kind == "word" and string.upper(tostring(nxt.value)) == "WRITE-FILE" then
      i = i + 2
    else
      kept[#kept + 1] = token
      i = i + 1
    end
  end
  return require("dictionary").tokens_to_source(kept)
end

local function artifact_policy_errors(artifacts, allowed_globs, forbidden_globs)
  local errors = {}
  if type(artifacts) ~= "table" then
    return errors
  end
  local keys = {}
  for path in pairs(artifacts) do
    if type(path) == "string" then
      keys[#keys + 1] = path
    end
  end
  table.sort(keys)
  for i = 1, #keys do
    local reason = hostmod.write_allowed(keys[i], allowed_globs, forbidden_globs)
    if reason then
      errors[#errors + 1] = "artifact " .. keys[i] .. ": " .. reason
    end
  end
  return errors
end

local function write_globs(node)
  if node.writes and #node.writes > 0 then
    return node.writes
  end
  return node.allowed_globs or {}
end

local function node_covers(node, path)
  local globs = write_globs(node)
  if #globs == 0 then
    return false
  end
  return hostmod.write_allowed(path, globs, {}) == nil
end

local function kahn_order(nodes)
  local by_id = {}
  local indeg = {}
  local children = {}
  for i = 1, #nodes do
    local node = nodes[i]
    by_id[node.id] = node
    indeg[node.id] = 0
    children[node.id] = children[node.id] or {}
  end
  for i = 1, #nodes do
    local node = nodes[i]
    for j = 1, #(node.depends_on or {}) do
      local dep = node.depends_on[j]
      if by_id[dep] then
        indeg[node.id] = indeg[node.id] + 1
        children[dep] = children[dep] or {}
        children[dep][#children[dep] + 1] = node.id
      end
    end
  end
  local ready = {}
  for id, degree in pairs(indeg) do
    if degree == 0 then
      ready[#ready + 1] = id
    end
  end
  table.sort(ready)
  local ordered = {}
  while #ready > 0 do
    local id = table.remove(ready, 1)
    ordered[#ordered + 1] = by_id[id]
    local kids = children[id] or {}
    table.sort(kids)
    for i = 1, #kids do
      local child = kids[i]
      indeg[child] = indeg[child] - 1
      if indeg[child] == 0 then
        ready[#ready + 1] = child
        table.sort(ready)
      end
    end
  end
  local leftover = {}
  for id, degree in pairs(indeg) do
    if degree > 0 then
      leftover[#leftover + 1] = by_id[id]
    end
  end
  return ordered, leftover
end

local function effective_program(envelope)
  if not envelope.nodes then
    return envelope.program
  end
  local ordered, leftover = kahn_order(envelope.nodes)
  local parts = {}
  for i = 1, #ordered do
    local text = ordered[i].program
    if type(text) == "string" and text:match("%S") then
      parts[#parts + 1] = text
    end
  end
  for i = 1, #leftover do
    local text = leftover[i].program
    if type(text) == "string" and text:match("%S") then
      parts[#parts + 1] = text
    end
  end
  return table.concat(parts, "\n")
end

local function install_artifacts(h, artifacts, nodes)
  if type(artifacts) ~= "table" then
    return
  end
  if nodes then
    local ordered, leftover = kahn_order(nodes)
    if #leftover > 0 then
      raise("graph", "dependency cycle")
    end
    for i = 1, #ordered do
      local node = ordered[i]
      hostmod.emit(h.trace_path, "graph.node.start", { node = node.id, worker = "host" })
      local keys = {}
      for path, content in pairs(artifacts) do
        if type(path) == "string" and type(content) == "string" and node_covers(node, path) then
          keys[#keys + 1] = path
        end
      end
      table.sort(keys)
      local ok, err = pcall(function()
        for j = 1, #keys do
          h:write_file(artifacts[keys[j]], keys[j])
        end
      end)
      if not ok then
        hostmod.emit(h.trace_path, "graph.node.finish", {
          detail = tostring(err),
          node = node.id,
          status = "fail",
          worker = "host",
        })
        error(err)
      end
      hostmod.emit(h.trace_path, "graph.node.finish", {
        node = node.id,
        status = "ok",
        worker = "host",
      })
    end
    return
  end
  local keys = {}
  for path in pairs(artifacts) do
    if type(path) == "string" and type(artifacts[path]) == "string" then
      keys[#keys + 1] = path
    end
  end
  table.sort(keys)
  for i = 1, #keys do
    local path = keys[i]
    hostmod.emit(h.trace_path, "graph.node.start", { node = path, worker = "host" })
    local ok, err = pcall(function()
      h:write_file(artifacts[path], path)
    end)
    if not ok then
      hostmod.emit(h.trace_path, "graph.node.finish", {
        detail = tostring(err),
        node = path,
        status = "fail",
        worker = "host",
      })
      error(err)
    end
    hostmod.emit(h.trace_path, "graph.node.finish", { node = path, status = "ok", worker = "host" })
  end
end

function M.run_forth(h, envelope, opts)
  opts = opts or {}
  local preflight = opts.preflight
  local request = opts.request
  local resume = opts.resume
  if envelope.language ~= "forth" and envelope.language ~= "forth-shen" then
    raise("language", "unsupported envelope language: " .. envelope.language)
  end
  local dictionary = require("dictionary")
  local dict_dir = request and request.dictionary_dir or nil
  local prelude = dictionary.load_prelude(dict_dir)
  local program = dictionary.compose(
    prelude,
    lower_artifact_writes(effective_program(envelope), envelope.artifacts)
  )
  if preflight then
    if not bridge.ensure() then
      raise("preflight", "shen-lua critic is not available: " .. tostring(bridge.error))
    end
    local result = bridge.validate(
      program,
      h.allowed_effects,
      h.allowed_globs,
      h.forbidden_globs,
      envelope.artifacts
    )
    local art_errs = artifact_policy_errors(envelope.artifacts, h.allowed_globs, h.forbidden_globs)
    if #art_errs > 0 then
      result.valid = false
      result.errors = result.errors or {}
      for i = 1, #art_errs do
        result.errors[#result.errors + 1] = art_errs[i]
      end
    end
    if not result.valid then
      if request ~= nil then
        hostmod.emit(h.trace_path, "preflight.rejected", {
          effects = result.effects,
          engine = result.engine or bridge.engine,
          errors = result.errors,
        })
      end
      raise("preflight", "preflight rejected program", result.errors)
    end
  end
  if request ~= nil and not resume then
    M.save_checkpoint(request, envelope)
  end
  if h._objects_root and envelope.artifacts then
    for path, body in pairs(envelope.artifacts) do
      if type(body) == "string" then
        hostmod.intern(h._objects_root, body)
      end
    end
  end
  if request ~= nil and prelude ~= "" then
    local known = dictionary.loaded_names(dict_dir)
    hostmod.emit(h.trace_path, "dictionary.retrieve", { candidates = known, query = "*" })
    local reused = dictionary.used_names(effective_program(envelope), known)
    for i = 1, #reused do
      hostmod.emit(h.trace_path, "dictionary.reuse", { version = 1, word = reused[i] })
    end
  end
  local vm = forth.new(h, envelope.artifacts)
  local ok, err = pcall(function()
    install_artifacts(h, envelope.artifacts, envelope.nodes)
    vm:interpret(program)
  end)
  if not ok then
    local code, message = forth.err_code(err)
    if request ~= nil then
      hostmod.emit(h.trace_path, "execution.trap", { detail = message, reason = code })
    end
    raise(code, message)
  end
  if dict_dir and dict_dir ~= "" then
    local written = dictionary.save_colon(dict_dir, vm, h._objects_root)
    for i = 1, #written do
      hostmod.emit(h.trace_path, "dictionary.promote", {
        evidence = "colon",
        version = 1,
        word = written[i],
      })
    end
  end
  return {
    defined = hostmod.json_array(vm:defined_names()),
    program_hash = hostmod.sha256(envelope.program),
    stack_depth = #vm.stack,
  }
end

function M.run_request(request, opts)
  opts = opts or {}
  local preflight = opts.preflight
  if preflight == nil then
    preflight = true
  end
  if preflight then
    bridge.ensure()
  end
  local h = hostmod.from_request(request)
  local ok, result = pcall(function()
    local envelope = request._envelope or M.resolve_envelope(request)
    local extra = M.run_forth(h, envelope, {
      preflight = preflight,
      request = request,
      resume = request.resume,
    })
    if not string.upper(envelope.program):find("RECEIPT", 1, true) then
      h:receipt({ program_hash = extra.program_hash })
    end
    return extra
  end)
  if not ok then
    local code = "error"
    local message = tostring(result)
    local details = {}
    if type(result) == "table" then
      code = result.code or code
      message = result.message or message
      details = result.details or {}
    end
    hostmod.emit(h.trace_path, "execution.trap", {
      detail = message,
      errors = details,
      reason = code,
    })
    return 2, {
      code = code,
      critic = bridge.engine,
      details = details,
      error = message,
      ok = false,
    }
  end
  local payload = {
    ok = true,
    critic = bridge.engine,
    result = result,
    workspace = request.workspace,
    dictionary = request.dictionary_dir,
  }
  if h.receipt_path and hostmod.is_file(h.receipt_path) then
    local raw = hostmod.read_bytes(h.receipt_path)
    if raw then
      local rok, rec = pcall(hostmod.decode_json, raw)
      if rok then
        payload.receipt = rec
      end
    end
  end
  M.attach_work(payload, request.workspace)
  return 0, payload
end

function M.attach_work(payload, workspace)
  if type(payload) ~= "table" or not workspace then
    return
  end
  if hostmod.is_file(workspace .. "/dist/index.html") then
    payload.product_url = "/product/"
  end
  local rec = payload.receipt
  if type(rec) ~= "table" or type(rec.changed_files) ~= "table" then
    return
  end
  local previews = {}
  for i = 1, #rec.changed_files do
    if #previews >= 6 then
      break
    end
    local rel = rec.changed_files[i]
    if type(rel) == "string" then
      local data = hostmod.read_bytes(workspace .. "/" .. rel)
      if data and not data:find("\0", 1, true) then
        if #data > 2500 then
          data = data:sub(1, 2500) .. "\n…"
        end
        previews[#previews + 1] = { path = rel, text = data }
      end
    end
  end
  payload.previews = previews
end

function M.load_request(path)
  local data, err = hostmod.read_bytes(path)
  if not data then
    error("cannot read request: " .. tostring(err), 0)
  end
  return hostmod.decode_json(data)
end

function M.main(argv)
  argv = argv or arg
  local path = argv and argv[#argv]
  if not path or path == "" or path:sub(1, 1) == "-" then
    io.stderr:write("usage: livingdict-resty REQUEST.json\n")
    return 2
  end
  bridge.boot()
  local ok, request = pcall(M.load_request, path)
  if not ok then
    io.stderr:write("invalid request.json: " .. tostring(request) .. "\n")
    return 2
  end
  local code = M.run_request(request, { preflight = true })
  return code
end

local function request_from_env(envelope, workspace)
  workspace = workspace
    or os.getenv("LDEVAL_WORKSPACE")
    or os.getenv("LIVINGDICT_WORKSPACE")
    or (ngx and ngx.var and ngx.var.livingdict_workspace)
    or "."
  local run = os.getenv("LIVINGDICT_RUN_DIR")
  if (not run or run == "") and ngx and ngx.config then
    run = ngx.config.prefix() .. "var/run/think"
  end
  if not run or run == "" then
    run = workspace .. "/../.livingdict-run"
  end
  hostmod.mkdir_p(run .. "/dictionary")
  if envelope then
    hostmod.write_bytes(run .. "/dictionary/envelope.json", hostmod.encode_json(M.envelope_to_dict(envelope), 2) .. "\n")
  end
  return {
    protocol_version = "1.0",
    run_id = os.getenv("LDEVAL_RUN_ID") or "think",
    arm = "forth-shen",
    memory_mode = "cold",
    resume = false,
    task = {
      id = os.getenv("LIVINGDICT_TASK_ID") or "think",
      family = "think",
      sequence = 1,
      allowed_effects = { "read", "write", "exec" },
      allowed_globs = { "**" },
      forbidden_globs = {},
    },
    workspace = workspace,
    prompt_path = workspace .. "/TASK.md",
    trace_path = os.getenv("LDEVAL_TRACE") or (run .. "/trace.jsonl"),
    receipt_path = run .. "/receipt.json",
    dictionary_dir = run .. "/dictionary",
    test_timeout_seconds = 180,
  }
end

function M.plan_view(envelope, extra)
  extra = extra or {}
  envelope = envelope or {}
  return {
    artifacts = envelope.artifacts or {},
    auth = extra.auth,
    model = extra.model,
    program = envelope.program or "",
    rationale = envelope.rationale or "",
  }
end

function M.reject_body(envelope, errors)
  local errs = errors or {}
  return {
    critic = "reject",
    details = errs,
    error = "preflight rejected program",
    errors = errs,
    ok = false,
    plan = M.plan_view(envelope),
  }
end

function M.as_think(code, result, envelope)
  if type(result) ~= "table" then
    result = { error = tostring(result), ok = false }
  end
  if code ~= 0 and result.code == "preflight" then
    return 0, M.reject_body(envelope, result.details or result.errors or {})
  end
  if result.plan == nil then
    result.plan = M.plan_view(envelope)
  end
  return code, result
end

function M.http_status(code, result)
  if type(result) == "table" and result.critic == "reject" then
    return 200
  end
  if code == 0 then
    return 200
  end
  return 400
end

function M.dispatch(payload)
  if type(payload) ~= "table" then
    return 2, { error = "body must be a JSON object", ok = false }
  end
  if payload.request then
    local request = payload.request
    local envelope
    if payload.envelope then
      envelope = M.parse_envelope(payload.envelope)
      request._envelope = envelope
    end
    local code, result = M.run_request(request, { preflight = payload.preflight ~= false })
    if type(result) == "table" and envelope then
      result.plan = M.plan_view(envelope)
    end
    return code, result
  end
  if payload.protocol_version and payload.workspace and payload.task then
    return M.run_request(payload, { preflight = payload.preflight ~= false })
  end
  if payload.language and payload.program then
    local envelope = M.parse_envelope(payload)
    local request = request_from_env(envelope, payload.workspace)
    request._envelope = envelope
    local code, result = M.run_request(request, { preflight = true })
    if type(result) == "table" then
      result.plan = M.plan_view(envelope)
    end
    return code, result
  end
  if type(payload.goal) == "string" and payload.goal:match("%S") then
    local planner = require("planner")
    local workspace = payload.workspace
      or (ngx and ngx.var and ngx.var.livingdict_workspace)
      or os.getenv("LIVINGDICT_WORKSPACE")
      or "."
    hostmod.mkdir_p(workspace)
    local scratch = request_from_env(nil, workspace)
    local dictionary = payload.dictionary or scratch.dictionary_dir
    local envelope, err = planner.plan(payload.goal, workspace, payload.extra or "", dictionary, payload.episode or 1)
    if not envelope then
      return 2, { critic = require("bridge").engine, error = tostring(err), ok = false, phase = "plan" }
    end
    local telemetry = envelope._telemetry
    envelope._telemetry = nil
    local request = payload.request
    if request then
      request._envelope = M.parse_envelope(envelope)
    else
      request = request_from_env(envelope, workspace)
      request.workspace = workspace
      request.prompt_path = workspace .. "/TASK.md"
      request.dictionary_dir = dictionary
      request._envelope = M.parse_envelope(envelope)
    end
    if payload.run_dir and payload.run_dir ~= "" then
      hostmod.mkdir_p(payload.run_dir)
      request.trace_path = payload.run_dir .. "/trace.jsonl"
      request.receipt_path = payload.run_dir .. "/receipt.json"
    end
    hostmod.mkdir_p((request.dictionary_dir or dictionary) .. "/words")
    local code, result = M.run_request(request, { preflight = payload.preflight ~= false })
    if type(result) == "table" then
      result.plan = M.plan_view(envelope, {
        auth = telemetry and telemetry.auth,
        model = telemetry and telemetry.model,
      })
      result.workspace = request.workspace
      result.dictionary = request.dictionary_dir
    end
    return code, result
  end
  return 2, { error = "expected goal, request.json, envelope, or {request, envelope}", ok = false }
end

function M.handle()
  ngx.req.read_body()
  local raw = ngx.req.get_body_data() or ""
  local ok, payload = pcall(hostmod.decode_json, raw)
  if not ok then
    ngx.status = 400
    ngx.header.content_type = "application/json"
    ngx.say(hostmod.encode_json({ error = "invalid JSON", ok = false }))
    return
  end
  local code, result = M.dispatch(payload)
  local envelope = {}
  if type(payload) == "table" then
    if type(payload.envelope) == "table" then
      envelope = payload.envelope
    elseif type(payload.program) == "string" then
      envelope = payload
    end
  end
  if type(result) == "table" and type(result.plan) == "table" then
    envelope = {
      artifacts = result.plan.artifacts or envelope.artifacts,
      program = result.plan.program or envelope.program,
      rationale = result.plan.rationale or envelope.rationale,
    }
  end
  code, result = M.as_think(code, result, envelope)
  ngx.status = M.http_status(code, result)
  ngx.header.content_type = "application/json"
  ngx.say(hostmod.encode_json(result))
end

return M
