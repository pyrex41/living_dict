-- Pure event-sourced episode kernel. Transcription of kernel.py reduce
-- / reconcile. No I/O, no clocks, no model.

local M = {}

local KINDS = {
  ["episode.planned"] = true,
  ["critic.accepted"] = true,
  ["critic.rejected"] = true,
  ["artifacts.applied"] = true,
  ["gates.measured"] = true,
  ["budget.consumed"] = true,
  ["episode.blocked_duplicate"] = true,
  ["dictionary.promoted"] = true,
  ["dictionary.promotion_evidence"] = true,
  ["contract.approved"] = true,
}

local function copy(v)
  if type(v) ~= "table" then
    return v
  end
  local o = {}
  for k, x in pairs(v) do
    o[k] = copy(x)
  end
  return o
end

function M.empty()
  return {
    revision = 0,
    events = {},
    seen_plans = {},
    consecutive_duplicates = 0,
    last_fingerprint = "",
    last_errors = {},
    last_gates = nil,
    used = 0,
    last_critic = "",
    pending_execute = false,
    last_artifact_keys = {},
  }
end

function M.reduce(state, event)
  if not KINDS[event.kind] then
    error("invalid event kind " .. tostring(event.kind))
  end
  local new = copy(state)
  local payload = event.payload or {}
  if event.kind == "episode.planned" then
    local fp = tostring(payload.fingerprint or "")
    local dedupe = tostring(payload.dedupe_key or fp)
    new.last_fingerprint = fp
    if dedupe ~= "" and new.seen_plans[dedupe] then
      new.pending_execute = false
    else
      if dedupe ~= "" then
        new.seen_plans[dedupe] = true
      end
      new.consecutive_duplicates = 0
      new.pending_execute = true
    end
  elseif event.kind == "episode.blocked_duplicate" then
    new.pending_execute = false
    new.consecutive_duplicates = new.consecutive_duplicates + 1
  elseif event.kind == "critic.accepted" then
    new.last_critic = "accepted"
    new.last_errors = {}
  elseif event.kind == "critic.rejected" then
    new.last_critic = "rejected"
    new.last_errors = copy(payload.errors or {})
    new.pending_execute = false
  elseif event.kind == "artifacts.applied" then
    new.last_artifact_keys = copy(payload.keys or {})
  elseif event.kind == "gates.measured" then
    new.last_gates = copy(payload.report)
  elseif event.kind == "budget.consumed" then
    local steps = tonumber(payload.steps or 1) or 1
    if steps <= 0 then
      error("budget delta is empty")
    end
    new.used = new.used + steps
  end
  local stored = {
    kind = event.kind,
    sequence = new.revision + 1,
    id = event.id or "",
    payload = copy(payload),
  }
  new.revision = new.revision + 1
  new.events[#new.events + 1] = stored
  return new
end

function M.replay(events)
  local state = M.empty()
  for i, event in ipairs(events) do
    if not event.sequence or event.sequence == 0 then
      event = {
        kind = event.kind,
        sequence = i,
        id = event.id or "",
        payload = event.payload,
      }
    end
    state = M.reduce(state, event)
  end
  return state
end

function M.claims_discharged(report)
  if type(report) ~= "table" then
    return false
  end
  local gates = report.gates
  if type(gates) ~= "table" or #gates == 0 then
    return false
  end
  local saw = false
  for _, gate in ipairs(gates) do
    if gate.name == "claims" then
      saw = true
      if not gate.passed then
        return false
      end
    end
  end
  if not saw then
    return false
  end
  for _, gate in ipairs(gates) do
    local n = gate.name
    if (n == "look" or n == "progress" or n == "contract") and not gate.skipped and not gate.passed then
      return false
    end
  end
  return true
end

function M.reconcile(state, cap)
  if M.claims_discharged(state.last_gates) then
    return { kind = "success", reason = "claims discharged" }
  end
  if state.consecutive_duplicates >= 2 then
    return { kind = "blocked", reason = "feedback loop" }
  end
  cap = tonumber(cap) or 0
  if cap > 0 and state.used >= cap then
    return { kind = "halt_cap", reason = "cap reached" }
  end
  return { kind = "plan", reason = "run another episode" }
end

return M
