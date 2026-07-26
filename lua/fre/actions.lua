local default_ui = require("fre.write_ui")

local M = {}
local ui_adapter = default_ui

local function fail(message, level)
  error("fre: " .. message, level or 3)
end

local function instance_from(ctx)
  if type(ctx) ~= "table" or type(ctx.instance) ~= "table" then
    fail("action context must contain an instance", 3)
  end
  if ctx.bufnr ~= nil and ctx.bufnr ~= ctx.instance.bufnr then
    fail("action context buffer does not match its instance", 3)
  end
  return ctx.instance
end

local function report_internal(instance, message)
  if instance and type(instance._report_async_error) == "function" then
    instance:_report_async_error(message)
  else
    pcall(vim.notify, "fre: " .. tostring(message), vim.log.levels.ERROR)
  end
end

local function safe_method(instance, object, method, ...)
  if object == nil or type(object[method]) ~= "function" then return true end
  local ok, err = pcall(object[method], object, ...)
  if not ok then report_internal(instance, "write UI " .. method .. " failed: " .. tostring(err)) end
  return ok
end

local function release(instance, token)
  local ok, err = pcall(instance._release_write_lock, instance, token)
  if not ok then report_internal(instance, "write unlock failed: " .. tostring(err)) end
end

local function validate_display(display)
  if type(display) ~= "table" then fail("confirmation display must be a string array", 4) end
  local count = 0
  for key, line in pairs(display) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or type(line) ~= "string" then
      fail("confirmation display must be a string array", 4)
    end
    count = count + 1
  end
  if count ~= #display then fail("confirmation display must not contain nil holes", 4) end
end

function M.confirm(ctx, display, on_decision)
  instance_from(ctx)
  validate_display(display)
  if type(on_decision) ~= "function" then fail("confirmation callback must be a function", 3) end
  return ui_adapter.confirm(ctx, display, on_decision)
end

local function report_outcome(ctx, outcome, reconciliation_error)
  local instance = ctx.instance
  if type(ui_adapter.report) ~= "function" then return end
  local ok, err = pcall(ui_adapter.report, ctx, outcome, reconciliation_error)
  if not ok then report_internal(instance, "write UI report failed: " .. tostring(err)) end
end

function M.write(ctx, _opts)
  local instance = instance_from(ctx)
  local token = instance:_acquire_write_lock()
  instance._last_write_result = nil
  token.phase = "preparing"
  token.ctx = ctx

  local function close_confirmation()
    local handle = token.confirmation_ui
    token.confirmation_ui = nil
    safe_method(instance, handle, "close", true)
  end

  local function close_progress()
    local handle = token.progress_ui
    token.progress_ui = nil
    safe_method(instance, handle, "close", true)
  end

  local function finish_before_execution()
    if token.phase == "finished" then return end
    token.phase = "finished"
    close_confirmation()
    close_progress()
    token.execution = nil
    release(instance, token)
    token.ctx = nil
  end

  local function finish_reconciliation(outcome, reconciliation_error)
    if token.phase == "finished" then return end
    token.phase = "finished"
    close_confirmation()
    close_progress()
    token.execution = nil
    if reconciliation_error ~= nil then instance.needs_refresh = true end
    instance._last_write_result = {
      execution = outcome == nil and nil or vim.deepcopy(outcome),
      reconciliation_error = reconciliation_error,
    }
    release(instance, token)
    report_outcome(ctx, outcome, reconciliation_error)
    token.ctx = nil
  end

  local function reconcile(outcome)
    token.phase = "reconciling"
    local ok, err = pcall(instance._reconcile_write, instance, token, function(reconciliation_error)
      finish_reconciliation(outcome, reconciliation_error)
    end)
    if not ok then finish_reconciliation(outcome, err) end
  end

  local function begin_execution(plan)
    close_confirmation()
    token.phase = "starting-execution"
    local execution
    local ok, execution_or_error = pcall(instance._execute_write, instance, token, plan, {
      on_progress = function(status)
        safe_method(instance, token.progress_ui, "update", status)
      end,
      on_complete = function(_execution_error, result)
        if token.phase == "finished" or token.phase == "reconciling" then return end
        close_progress()
        token.execution = nil
        reconcile(result)
      end,
    })
    if not ok then
      finish_before_execution()
      error(execution_or_error, 0)
    end
    execution = execution_or_error
    token.execution = execution
    token.phase = "executing"

    local progress_ok, progress_or_error = pcall(ui_adapter.progress, ctx,
      execution:get_status(), function()
        if token.phase ~= "executing" or token.execution ~= execution then return end
        local cancel_ok, cancel_error = pcall(execution.cancel, execution)
        if not cancel_ok then
          report_internal(instance, "write progress cancellation failed: " .. tostring(cancel_error))
        end
      end)
    if progress_ok then
      if token.phase == "executing" then
        token.progress_ui = progress_or_error
      else
        safe_method(instance, progress_or_error, "close", true)
      end
    else
      report_internal(instance, "write progress UI failed: " .. tostring(progress_or_error))
      local cancel_ok, cancel_error = pcall(execution.cancel, execution)
      if not cancel_ok then
        report_internal(instance, "write cancellation after UI failure failed: " .. tostring(cancel_error))
      end
    end
    return execution
  end

  local prepare_ok, plan_or_error = pcall(instance._prepare_write, instance, token)
  if not prepare_ok then
    finish_before_execution()
    error(plan_or_error, 0)
  end
  local plan = plan_or_error
  if #plan.operations == 0 then
    reconcile(nil)
    return nil
  end

  token.phase = "confirming"
  local function decide(accepted)
    if token.phase ~= "confirming" then return end
    if accepted ~= true then
      finish_before_execution()
      return
    end
    local ok, err = pcall(begin_execution, plan)
    if not ok then
      if token.execution ~= nil then
        local cancel_ok, cancel_error = pcall(token.execution.cancel, token.execution)
        if not cancel_ok then
          report_internal(instance, "write cancellation failed: " .. tostring(cancel_error))
        end
      else
        finish_before_execution()
      end
      report_internal(instance, err)
    end
  end
  local confirm_ok, confirmation_or_error = pcall(M.confirm, ctx, plan.display, decide)
  if not confirm_ok then
    finish_before_execution()
    error(confirmation_or_error, 0)
  end
  if token.phase == "confirming" then
    token.confirmation_ui = confirmation_or_error
  else
    safe_method(instance, confirmation_or_error, "close", true)
  end
  return nil
end

function M._set_ui_adapter(adapter)
  if type(adapter) ~= "table" or type(adapter.confirm) ~= "function"
      or type(adapter.progress) ~= "function" then
    fail("write UI adapter must provide confirm() and progress()", 2)
  end
  ui_adapter = adapter
end

function M._reset_ui_adapter()
  ui_adapter = default_ui
end

return M
