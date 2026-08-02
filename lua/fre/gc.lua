local M = {}

local function fail(message, level)
  error("fre.gc: " .. message, level or 3)
end

local function validate_adapter(adapter)
  if type(adapter) ~= "table" then fail("adapter must be a table", 4) end
  for _, method in ipairs({
    "now", "new_timer", "timer_start", "timer_stop", "close", "schedule",
  }) do
    if type(adapter[method]) ~= "function" then
      fail("adapter must provide " .. method .. "()", 4)
    end
  end
  return adapter
end

local function default_close(handle)
  if handle == nil then return end
  if type(handle.is_closing) == "function" then
    local ok, closing = pcall(handle.is_closing, handle)
    if ok and closing then return end
  end
  if type(handle.close) == "function" then pcall(handle.close, handle) end
end

M.default = {
  now = function() return vim.uv.hrtime() / 1000000 end,
  new_timer = function()
    local timer = vim.uv.new_timer()
    if timer and type(timer.unref) == "function" then pcall(timer.unref, timer) end
    return timer
  end,
  timer_start = function(timer, timeout, callback)
    return timer:start(math.max(0, math.ceil(timeout)), 0, callback)
  end,
  timer_stop = function(timer) return timer:stop() end,
  close = default_close,
  schedule = vim.schedule,
}

local Controller = {}
Controller.__index = Controller

function Controller:_registered(instance)
  if type(instance) ~= "table" or instance:is_destroyed() or instance:is_destroying() then return false end
  if self.manager.instances_by_id[instance.id] ~= instance then return false end
  if self.manager.instances_by_buf[instance.bufnr] ~= instance then return false end
  local group_name = instance.config and instance.config.gc and instance.config.gc.group
  local group = group_name and self.manager.groups[group_name]
  return group ~= nil and group.instances[instance.id] == instance
end

function Controller:_buffer_is_visible(instance)
  if not self:_registered(instance) or type(instance.bufnr) ~= "number"
      or not vim.api.nvim_buf_is_valid(instance.bufnr) then
    return false
  end
  for _, winid in ipairs(vim.fn.win_findbuf(instance.bufnr)) do
    if vim.api.nvim_win_is_valid(winid)
        and vim.api.nvim_win_get_buf(winid) == instance.bufnr then
      return true
    end
  end
  return false
end

function Controller:_sync_visibility(instance)
  if type(instance.sync_view) == "function" then
    pcall(instance.sync_view, instance, { report = true })
  end
end

function Controller:is_eligible(instance)
  if not self:_registered(instance) then return false end
  self:_sync_visibility(instance)
  if not instance:is_ready() or instance.hidden_since == nil
      or not vim.api.nvim_buf_is_valid(instance.bufnr)
      or self:_buffer_is_visible(instance) then
    return false
  end
  if instance.work:is_write_active() or instance.work:is_execution_active() then return false end
  if vim.bo[instance.bufnr].modified and not instance.config.gc.include_modified then
    return false
  end
  return true
end

function Controller:_close_timer_state(timer_state)
  if not timer_state or timer_state.closed then return end
  timer_state.closed = true
  pcall(self.adapter.timer_stop, timer_state.handle)
  pcall(self.adapter.close, timer_state.handle)
end

function Controller:_invalidate_timer(instance)
  instance._gc_generation = (instance._gc_generation or 0) + 1
  local timer_state = instance._gc_timer
  instance._gc_timer = nil
  instance._gc_expired_reconsider = nil
  self:_close_timer_state(timer_state)
end

function Controller:_now()
  local ok, value = pcall(self.adapter.now)
  if not ok then error(value, 0) end
  if type(value) ~= "number" or value ~= value then
    fail("adapter.now() must return a number", 4)
  end
  return value
end

function Controller:_arm(instance)
  local ttl = instance.config and instance.config.gc and instance.config.gc.ttl_ms or 0
  if ttl <= 0 or instance.hidden_since == nil or instance:is_destroyed() or instance:is_destroying() then return end
  local remaining = instance.hidden_since + ttl - self:_now()
  if remaining <= 0 then
    local pending = instance._gc_expired_reconsider
    if pending and pending.hidden_since == instance.hidden_since
        and pending.generation == instance._gc_generation then
      return
    end
    self:_invalidate_timer(instance)
    pending = {
      generation = instance._gc_generation,
      hidden_since = instance.hidden_since,
    }
    instance._gc_expired_reconsider = pending
    local ok, err = pcall(self.adapter.schedule, function()
      if instance._gc_expired_reconsider ~= pending then return end
      instance._gc_expired_reconsider = nil
      if not self:_registered(instance)
          or instance._gc_generation ~= pending.generation
          or instance.hidden_since ~= pending.hidden_since then
        return
      end
      self:reconsider(instance)
    end)
    if not ok then
      if instance._gc_expired_reconsider == pending then
        instance._gc_expired_reconsider = nil
      end
      pcall(vim.notify, "fre: GC scheduling failed: " .. tostring(err), vim.log.levels.ERROR)
    end
    return
  end
  self:_invalidate_timer(instance)
  local generation = instance._gc_generation
  local handle = self.adapter.new_timer()
  if handle == nil then fail("adapter.new_timer() returned nil", 4) end
  local timer_state = { handle = handle, closed = false }
  instance._gc_timer = timer_state
  local ok, result = pcall(self.adapter.timer_start, handle, remaining, function()
    self:_close_timer_state(timer_state)
    if instance._gc_timer == timer_state then instance._gc_timer = nil end
    local scheduled, schedule_err = pcall(self.adapter.schedule, function()
      if not self:_registered(instance) or instance._gc_generation ~= generation
          or instance.hidden_since == nil then
        return
      end
      self:reconsider(instance)
    end)
    if not scheduled then
      pcall(vim.notify, "fre: GC scheduling failed: " .. tostring(schedule_err), vim.log.levels.ERROR)
    end
  end)
  if not ok or result == false then
    if instance._gc_timer == timer_state then instance._gc_timer = nil end
    self:_close_timer_state(timer_state)
    error(ok and "fre.gc: adapter.timer_start() failed" or result, 0)
  end
end

function Controller:stop(instance)
  if type(instance) ~= "table" then return end
  self:_invalidate_timer(instance)
  instance._gc_reconsider_generation = (instance._gc_reconsider_generation or 0) + 1
  instance.hidden_since = nil
end

function Controller:on_register(instance)
  instance.hidden_since = self:_now()
  instance._gc_generation = instance._gc_generation or 0
  instance._gc_reconsider_generation = instance._gc_reconsider_generation or 0
  instance._gc_timer = nil
  instance._gc_expired_reconsider = nil
  self:_arm(instance)
  self:enforce_group(instance.config.gc.group, instance)
end

function Controller:presentation_enter(instance)
  if not self:_registered(instance) then return false end
  if instance.hidden_since ~= nil or instance._gc_timer ~= nil then
    instance.hidden_since = nil
    self:_invalidate_timer(instance)
  end
  return true
end

function Controller:presentation_leave(instance)
  if not self:_registered(instance) then return false end
  if instance.hidden_since == nil then instance.hidden_since = self:_now() end
  if instance._gc_timer == nil then self:_arm(instance) end
  self:enforce_group(instance.config.gc.group)
  return true
end

function Controller:reconsider(instance)
  if not self:_registered(instance) then return false end
  self:_sync_visibility(instance)
  if instance.hidden_since == nil then return false end
  local eligible = self:is_eligible(instance)
  local ttl = instance.config.gc.ttl_ms
  if ttl > 0 then
    local remaining = instance.hidden_since + ttl - self:_now()
    if eligible and remaining <= 0 then
      if self:is_eligible(instance) then instance:destroy() end
      return instance:is_destroyed()
    end
    if remaining > 0 and instance._gc_timer == nil then self:_arm(instance) end
  end
  if self:_registered(instance) then self:enforce_group(instance.config.gc.group) end
  return false
end

function Controller:defer_reconsider(instance)
  if not self:_registered(instance) then return end
  instance._gc_reconsider_generation = (instance._gc_reconsider_generation or 0) + 1
  local generation = instance._gc_reconsider_generation
  local ok, err = pcall(self.adapter.schedule, function()
    if not self:_registered(instance)
        or instance._gc_reconsider_generation ~= generation then return end
    local reconsidered, reconsider_err = pcall(self.reconsider, self, instance)
    if reconsidered then return end
    local message = "GC reconsideration failed: " .. tostring(reconsider_err)
    if type(instance._report_async_error) == "function" then
      pcall(instance._report_async_error, instance, message)
    else
      pcall(vim.notify, "fre: " .. message, vim.log.levels.ERROR)
    end
  end)
  if not ok then
    pcall(vim.notify, "fre: GC scheduling failed: " .. tostring(err), vim.log.levels.ERROR)
  end
end

local function older(left, right)
  local left_hidden = left.hidden_since or math.huge
  local right_hidden = right.hidden_since or math.huge
  if left_hidden ~= right_hidden then return left_hidden < right_hidden end
  return left.id < right.id
end

function Controller:_eligible_group(group_name)
  local group = self.manager.groups[group_name]
  local result = {}
  if not group then return result end
  for _, instance in pairs(group.instances) do
    if self:is_eligible(instance) then result[#result + 1] = instance end
  end
  table.sort(result, older)
  return result
end

local function group_size(group)
  local count = 0
  for _ in pairs(group.instances) do count = count + 1 end
  return count
end

function Controller:enforce_group(group_name, protected)
  local group = self.manager.groups[group_name]
  if not group or group.capacity == 0 or self.enforcing[group_name] then return end
  self.enforcing[group_name] = true
  local ok, err = pcall(function()
    while group_size(group) > group.capacity do
      local eligible = self:_eligible_group(group_name)
      local candidate
      for _, instance in ipairs(eligible) do
        if instance ~= protected then candidate = instance; break end
      end
      if not candidate then break end
      if self:is_eligible(candidate) then
        candidate:destroy()
      else
        break
      end
    end
  end)
  self.enforcing[group_name] = nil
  if not ok then error(err, 0) end
end

function Controller:enforce_all()
  local names = {}
  for name in pairs(self.manager.groups) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do self:enforce_group(name) end
end

function Controller:set_adapter(adapter)
  validate_adapter(adapter)
  if next(self.manager.instances_by_id) ~= nil then
    fail("cannot replace the GC adapter while live instances exist", 3)
  end
  self.adapter = adapter
end

function M.new(manager, adapter)
  return setmetatable({
    manager = manager,
    adapter = validate_adapter(adapter or M.default),
    enforcing = {},
  }, Controller)
end

M.validate_adapter = validate_adapter

return M
