local mutation_execute = require("fre.mutation.execute")
local mutation_prepare = require("fre.mutation.prepare")
local default_ui = require("fre.write_ui")

local M = {}
local Work = {}
Work.__index = Work

local ui_adapter = default_ui

local function fail(message, level)
  error("fre: " .. message, level or 3)
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

local function is_simple_edit(operations)
  local creates, moves, copies = 0, 0, 0
  for _, operation in ipairs(operations) do
    if operation.type == "create_file" or operation.type == "create_directory" then
      creates = creates + 1
    elseif operation.type == "move" then
      moves = moves + 1
    elseif operation.type == "copy" then
      copies = copies + 1
    else
      return false
    end
  end
  return creates <= 5 and moves <= 1 and copies <= 1
end

function Work.new(options)
  return setmetatable({
    root = assert(options.root),
    bufnr = assert(options.bufnr),
    tree = assert(options.tree),
    buffer = assert(options.buffer),
    sync = assert(options.sync),
    skip_confirm_for_simple_edits = options.skip_confirm_for_simple_edits == true,
    get_mutation_adapter = assert(options.get_mutation_adapter),
    is_alive = assert(options.is_alive),
    is_ready = assert(options.is_ready),
    reconsider_gc = assert(options.reconsider_gc),
    report_error = assert(options.report_error),
    write_request = nil,
    execution = nil,
    last_result = nil,
  }, Work)
end

function Work:_preparation_input()
  return {
    root = self.root,
    bufnr = self.bufnr,
    tree = self.tree,
    buffer = self.buffer,
    ready = self.is_ready(),
  }
end

function Work:_prepare()
  return mutation_prepare.prepare(self:_preparation_input())
end

function Work:prepare()
  if not self.is_alive() then fail("instance is destroyed", 3) end
  if self.write_request then fail("instance is write-locked", 3) end
  return self:_prepare()
end

function Work:is_write_active()
  return self.write_request ~= nil
end

function Work:is_execution_active()
  return self.execution ~= nil and not mutation_execute.is_terminal(self.execution)
end

function Work:active_execution()
  return self.execution
end

function Work:last_write_result()
  return self.last_result == nil and nil or vim.deepcopy(self.last_result)
end

function Work:_start_execution(plan, handlers)
  if self:is_execution_active() then fail("an execution is already in progress", 3) end
  self.sync:cancel_active_watch_refresh()
  local execution
  execution = mutation_execute.start(
    plan, handlers, self.get_mutation_adapter(), function(completed)
      if self.execution == completed then self.execution = nil end
      if self.sync:is_dirty() then self.sync:schedule_followup() end
      if self.is_alive() then self.reconsider_gc(true) end
    end
  )
  self.execution = execution
  self.reconsider_gc(false)
  return execution
end

function Work:execute(plan, handlers)
  if not self.is_alive() then fail("instance is destroyed", 3) end
  if self.write_request then fail("instance is write-locked", 3) end
  return self:_start_execution(plan, handlers)
end

function Work:_report(message)
  self.report_error(message)
end

function Work:_safe_method(object, method, ...)
  if object == nil or type(object[method]) ~= "function" then return true end
  local ok, err = pcall(object[method], object, ...)
  if not ok then self:_report("write UI " .. method .. " failed: " .. tostring(err)) end
  return ok
end

function Work:_acquire_write()
  if not self.is_alive() then fail("instance is destroyed", 3) end
  if not self.is_ready() then fail("instance is not ready", 3) end
  if not vim.api.nvim_buf_is_valid(self.bufnr) then fail("instance buffer is not valid", 3) end
  if self.write_request then fail("instance is already write-locked", 3) end
  if self.sync:is_full_refresh_busy() then fail("refresh is already in progress", 3) end
  if self:is_execution_active() then fail("an execution is already in progress", 3) end
  if not vim.bo[self.bufnr].modifiable then fail("buffer is not modifiable", 3) end
  self.sync:cancel_active_watch_refresh()

  local request = {
    original_modifiable = vim.bo[self.bufnr].modifiable,
    phase = "preparing",
    released = false,
  }
  self.write_request = request
  self.last_result = nil
  local ok, err = pcall(function() vim.bo[self.bufnr].modifiable = false end)
  if not ok then
    self.write_request = nil
    request.released = true
    error(err, 0)
  end
  self.reconsider_gc(false)
  return request
end

function Work:_release_write(request)
  if type(request) ~= "table" or request.released or self.write_request ~= request then
    return false
  end
  request.released = true
  local ok, err = true, nil
  if vim.api.nvim_buf_is_valid(self.bufnr) then
    ok, err = pcall(function() vim.bo[self.bufnr].modifiable = request.original_modifiable end)
  end
  self.write_request = nil
  if not ok then self:_report("write unlock failed: " .. tostring(err)) end
  if self.is_alive() then self.reconsider_gc(true) end
  return true
end

function Work:_release_safely(request)
  local ok, err = pcall(self._release_write, self, request)
  if not ok then self:_report("write unlock failed: " .. tostring(err)) end
end

function Work:write(ctx)
  local request = self:_acquire_write()
  request.ctx = ctx
  local sync_execute, sync_finish

  local function close_confirmation()
    local handle = request.confirmation_ui
    request.confirmation_ui = nil
    self:_safe_method(handle, "close", true)
  end

  local function close_progress()
    local handle = request.progress_ui
    request.progress_ui = nil
    self:_safe_method(handle, "close", true)
  end

  local function finish_before_execution()
    if request.phase == "finished" then return end
    request.phase = "finished"
    close_confirmation()
    close_progress()
    request.execution = nil
    self:_release_safely(request)
    request.ctx = nil
  end

  local function finish_reconciliation(outcome, reconciliation_error)
    if request.phase == "finished" then return end
    request.phase = "finished"
    close_confirmation()
    close_progress()
    request.execution = nil
    local execution
    if outcome ~= nil then execution = vim.deepcopy(outcome) end
    self.last_result = {
      execution = execution,
      reconciliation_error = reconciliation_error,
    }
    self:_release_safely(request)
    if type(ui_adapter.report) == "function" then
      local ok, err = pcall(ui_adapter.report, ctx, outcome, reconciliation_error)
      if not ok then self:_report("write UI report failed: " .. tostring(err)) end
    end
    request.ctx = nil
  end

  local function reconcile(outcome)
    request.phase = "reconciling"
    sync_finish(outcome, true)
  end

  local function begin_execution(plan)
    close_confirmation()
    request.phase = "starting-execution"
    local ok, execution_or_error = pcall(sync_execute, function(complete)
      return self:_start_execution(plan, {
        on_progress = function(status)
          self:_safe_method(request.progress_ui, "update", status)
        end,
        on_complete = function(_execution_error, result)
          if request.phase == "finished" or request.phase == "reconciling" then return end
          close_progress()
          request.execution = nil
          complete(result, true)
        end,
      })
    end)
    if not ok then error(execution_or_error, 0) end
    local execution = execution_or_error
    request.execution = execution
    request.phase = "executing"

    local progress_ok, progress_or_error = pcall(ui_adapter.progress, ctx,
      execution:get_status(), function()
        if request.phase ~= "executing" or request.execution ~= execution then return end
        local cancel_ok, cancel_error = pcall(execution.cancel, execution)
        if not cancel_ok then
          self:_report("write progress cancellation failed: " .. tostring(cancel_error))
        end
      end)
    if progress_ok then
      if request.phase == "executing" then
        request.progress_ui = progress_or_error
      else
        self:_safe_method(progress_or_error, "close", true)
      end
    else
      self:_report("write progress UI failed: " .. tostring(progress_or_error))
      local cancel_ok, cancel_error = pcall(execution.cancel, execution)
      if not cancel_ok then
        self:_report("write cancellation after UI failure failed: " .. tostring(cancel_error))
      end
    end
    return execution
  end

  local function start_execution(plan)
    local ok, err = pcall(begin_execution, plan)
    if ok then return end
    if request.execution ~= nil then
      local cancel_ok, cancel_error = pcall(request.execution.cancel, request.execution)
      if not cancel_ok then self:_report("write cancellation failed: " .. tostring(cancel_error)) end
    else
      finish_before_execution()
    end
    self:_report(err)
  end

  return self.sync:write_reconcile(function(execute, finish)
    sync_execute = execute
    sync_finish = finish
    local prepare_ok, plan_or_error = pcall(self._prepare, self)
    if not prepare_ok then
      sync_finish(nil, false)
      error(plan_or_error, 0)
    end
    local plan = plan_or_error
    if #plan.operations == 0 then
      reconcile(nil)
      return nil
    end
    if self.skip_confirm_for_simple_edits and is_simple_edit(plan.operations) then
      start_execution(plan)
      return nil
    end

    request.phase = "confirming"
    local function decide(accepted)
      if request.phase ~= "confirming" then return end
      if accepted ~= true then
        sync_finish(nil, false)
        return
      end
      start_execution(plan)
    end
    validate_display(plan.display)
    local confirm_ok, confirmation_or_error = pcall(ui_adapter.confirm, ctx, plan.display, decide)
    if not confirm_ok then
      sync_finish(nil, false)
      error(confirmation_or_error, 0)
    end
    if request.phase == "confirming" then
      request.confirmation_ui = confirmation_or_error
    else
      self:_safe_method(confirmation_or_error, "close", true)
    end
    return nil
  end, function(outcome, reconciliation_error, reconciled)
    if reconciled then
      finish_reconciliation(outcome, reconciliation_error)
    else
      finish_before_execution()
    end
  end)
end

function Work:destroy()
  self.write_request = nil
  self.execution = nil
end

M.new = Work.new

function M.confirm(ctx, display, on_decision)
  validate_display(display)
  if type(on_decision) ~= "function" then fail("confirmation callback must be a function", 3) end
  return ui_adapter.confirm(ctx, display, on_decision)
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
