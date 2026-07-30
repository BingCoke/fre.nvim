local copy = require("fre.config").copy
local kind_support = require("fre.mutation.kind")

local M = {}

local states = setmetatable({}, { __mode = "k" })
local methods = {}
local terminal_states = { succeeded = true, failed = true, canceled = true }

local function fail(message, level)
  error("fre: " .. message, level or 3)
end

local function notify_handler_error(err)
  pcall(vim.notify, "fre: execution handler failed: " .. tostring(err), vim.log.levels.ERROR)
end

local function protected_call(handler, ...)
  if handler == nil then return end
  local ok, err = pcall(handler, ...)
  if not ok then notify_handler_error(err) end
end

local function canceled_error(err)
  local text = tostring(err or ""):lower()
  return text:find("ecanceled", 1, true) ~= nil
    or text:find("ecancelled", 1, true) ~= nil
    or text:find("operation canceled", 1, true) ~= nil
    or text:find("operation cancelled", 1, true) ~= nil
end

local function snapshot(state)
  local result = {
    state = state.state,
    completed = state.completed,
    total = state.total,
  }
  if state.current ~= nil then result.current = copy(state.current) end
  if state.detail ~= nil then result.detail = copy(state.detail) end
  if state.error ~= nil then result.error = copy(state.error) end
  if terminal_states[state.state] then
    result.partial_current = copy(state.partial_current)
  end
  return result
end

local function validate_handlers(value)
  if value == nil then return {} end
  if type(value) == "function" then return { on_complete = value } end
  if type(value) ~= "table" then
    fail("execute handlers must be a function or table", 4)
  end
  for key in next, value do
    if key ~= "on_progress" and key ~= "on_complete" then
      fail("execute handlers contain unknown field " .. tostring(key), 4)
    end
  end
  if value.on_progress ~= nil and type(value.on_progress) ~= "function" then
    fail("execute handlers.on_progress must be a function", 4)
  end
  if value.on_complete ~= nil and type(value.on_complete) ~= "function" then
    fail("execute handlers.on_complete must be a function", 4)
  end
  return {
    on_progress = value.on_progress,
    on_complete = value.on_complete,
  }
end

local operation_fields = {
  create_file = { type = true, path = true },
  create_directory = { type = true, path = true },
  copy = { type = true, from = true, to = true, kind = true },
  move = { type = true, from = true, to = true, kind = true },
  delete = { type = true, path = true, kind = true },
}

local function validate_operation(operation, index)
  if type(operation) ~= "table" then
    return nil, "operation " .. index .. " must be a table"
  end
  if type(operation.type) ~= "string" or operation_fields[operation.type] == nil then
    return nil, "operation " .. index .. " has unknown type " .. tostring(operation.type)
  end
  local allowed = operation_fields[operation.type]
  for key in next, operation do
    if not allowed[key] then
      return nil, "operation " .. index .. " contains unknown field " .. tostring(key)
    end
  end
  if operation.type == "create_file" or operation.type == "create_directory" then
    if type(operation.path) ~= "string" then
      return nil, "operation " .. index .. ".path must be a string"
    end
  elseif operation.type == "delete" then
    if type(operation.path) ~= "string" then
      return nil, "operation " .. index .. ".path must be a string"
    end
    if not kind_support.supports("delete", operation.kind) then
      return nil, "operation " .. index .. ".kind " .. tostring(operation.kind)
        .. " does not support delete"
    end
  else
    if type(operation.from) ~= "string" then
      return nil, "operation " .. index .. ".from must be a string"
    end
    if type(operation.to) ~= "string" then
      return nil, "operation " .. index .. ".to must be a string"
    end
    if not kind_support.supports(operation.type, operation.kind) then
      return nil, "operation " .. index .. ".kind " .. tostring(operation.kind)
        .. " does not support " .. operation.type
    end
  end
  return operation
end

local function cancel_request(request)
  if request == nil then return false end
  if type(request) == "function" then
    local ok, accepted = pcall(request)
    return ok and accepted ~= false
  end
  if type(request) == "table" and type(request.cancel) == "function" then
    local ok, accepted = pcall(request.cancel, request)
    return ok and accepted ~= false
  end
  local ok, accepted = pcall(vim.uv.cancel, request)
  return ok and accepted ~= false
end

local function dispatch_adapter(adapter, operation, done, report)
  if operation.type == "create_file" then
    return adapter.create_file(operation.path, done, report)
  end
  if operation.type == "create_directory" then
    return adapter.create_directory(operation.path, done, report)
  end
  if operation.type == "copy" then
    return adapter.copy(operation.from, operation.to, operation.kind, done, report)
  end
  if operation.type == "move" then
    return adapter.move(operation.from, operation.to, done, report)
  end
  return adapter.delete(operation.path, operation.kind, done, report)
end

function methods:get_status()
  local state = states[self]
  if state == nil then fail("invalid Execution", 2) end
  return snapshot(state)
end

function methods:cancel()
  local state = states[self]
  if state == nil then fail("invalid Execution", 2) end
  if state.state ~= "running" then return false end
  state.state = "canceling"
  protected_call(state.handlers.on_progress, snapshot(state))
  if not state.inflight then
    vim.schedule(function()
      if state.state == "canceling" then state.finalize("canceled", nil, false) end
    end)
  else
    cancel_request(state.current_request)
  end
  return true
end

local execution_mt = {
  __index = function(_, key)
    return methods[key]
  end,
  __metatable = false,
}

function M.start(instance, plan, handlers_value, adapter, on_terminal)
  if type(plan) ~= "table" then fail("execute plan must be a table", 3) end
  if type(plan.operations) ~= "table" then
    fail("execute plan.operations must be a table", 3)
  end
  local handlers = validate_handlers(handlers_value)
  local total = #plan.operations
  local operations = {}
  for index = 1, total do
    operations[index] = copy(rawget(plan.operations, index))
  end

  local execution = setmetatable({}, execution_mt)
  local state = {
    state = "running",
    completed = 0,
    total = total,
    current = nil,
    detail = nil,
    error = nil,
    partial_current = nil,
    current_request = nil,
    inflight = false,
    handlers = handlers,
    operations = operations,
    callback_token = 0,
    completion_called = false,
  }
  states[execution] = state

  local function emit_progress()
    protected_call(state.handlers.on_progress, snapshot(state))
  end

  local function finalize(terminal, err, partial_current)
    if terminal_states[state.state] then return end
    state.state = terminal
    state.error = err == nil and nil or copy(err)
    state.partial_current = partial_current == nil and "unknown" or copy(partial_current)
    state.current_request = nil
    state.inflight = false
    state.callback_token = state.callback_token + 1
    if terminal == "succeeded" then
      state.current = nil
      state.detail = nil
      state.partial_current = false
    end
    if on_terminal then protected_call(on_terminal, execution) end
    emit_progress()
    if state.completion_called then return end
    state.completion_called = true
    local result = snapshot(state)
    result.status = result.state
    local completion_err = terminal == "failed" and copy(state.error) or nil
    protected_call(state.handlers.on_complete, completion_err, result)
  end
  state.finalize = finalize

  local dispatch_next
  dispatch_next = function()
    if state.state == "canceling" then
      finalize("canceled", nil, false)
      return
    end
    if state.state ~= "running" then return end
    if state.completed >= state.total then
      finalize("succeeded", nil, false)
      return
    end

    local index = state.completed + 1
    local operation = state.operations[index]
    state.current = copy(operation)
    state.detail = nil
    local valid, validation_err = validate_operation(operation, index)
    if valid == nil then
      finalize("failed", validation_err, false)
      return
    end
    emit_progress()
    if state.state ~= "running" then
      finalize("canceled", nil, false)
      return
    end

    state.inflight = true
    state.callback_token = state.callback_token + 1
    local token = state.callback_token
    local callback_received = false
    local function done(err, detail, partial_current, canceled)
      if callback_received or token ~= state.callback_token or terminal_states[state.state] then return end
      callback_received = true
      local callback_err = err == nil and nil or copy(err)
      local callback_detail = detail == nil and nil or copy(detail)
      local callback_partial = partial_current == nil and nil or copy(partial_current)
      local callback_canceled = canceled == true
      vim.schedule(function()
        if token ~= state.callback_token or terminal_states[state.state] then return end
        state.current_request = nil
        state.inflight = false
        if callback_detail ~= nil then state.detail = callback_detail end
        if state.state == "canceling" then
          if callback_err ~= nil and not callback_canceled and not canceled_error(callback_err) then
            finalize("failed", callback_err, callback_partial)
            return
          end
          if callback_err == nil and not callback_canceled then
            state.completed = state.completed + 1
            local completed_partial = callback_partial
            if completed_partial == nil then completed_partial = false end
            finalize("canceled", nil, completed_partial)
          else
            local canceled_partial = callback_partial
            if canceled_partial == nil then canceled_partial = "unknown" end
            finalize("canceled", nil, canceled_partial)
          end
          return
        end
        if callback_err ~= nil then
          finalize("failed", callback_err, callback_partial)
          return
        end
        if callback_canceled then
          state.state = "canceling"
          finalize("canceled", nil, callback_partial)
          return
        end
        state.completed = state.completed + 1
        state.current = nil
        state.detail = nil
        emit_progress()
        if state.state == "running" then dispatch_next() end
      end)
    end
    local function report(detail)
      if callback_received or token ~= state.callback_token or terminal_states[state.state] then return end
      state.detail = copy(detail)
      emit_progress()
    end

    local ok, request_or_err = pcall(dispatch_adapter, adapter, valid, done, report)
    if not ok then
      callback_received = true
      local dispatch_err = copy(request_or_err)
      vim.schedule(function()
        if token == state.callback_token and not terminal_states[state.state] then
          state.inflight = false
          finalize("failed", dispatch_err, "unknown")
        end
      end)
      return
    end
    state.current_request = request_or_err
    if state.state == "canceling" then cancel_request(state.current_request) end
  end

  vim.schedule(dispatch_next)
  return execution
end

function M.is_terminal(execution)
  local state = states[execution]
  return state == nil or terminal_states[state.state] == true
end

return M
