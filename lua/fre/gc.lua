local identity = require("fre.instance.identity")

local M = {}

local function fail(message, level)
  error("fre.gc: " .. message, level or 3)
end

local function copy(value)
  return vim.deepcopy(value)
end

local function positive_integer(value)
  return type(value) == "number" and value > 0 and value % 1 == 0
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

local function builtin_defaults()
  return {
    ttl_ms = 60000,
    include_modified = false,
    default_group = "default",
    groups = { default = 10, project = 5 },
  }
end

local function expect_table(value, path)
  if type(value) ~= "table" then fail(path .. " must be a table", 4) end
end

local function known_keys(value, allowed, path)
  for key in pairs(value) do
    if type(key) ~= "string" or not allowed[key] then
      fail(path .. " contains unknown field " .. tostring(key), 4)
    end
  end
end

local function nonnegative_number(value, path)
  if type(value) ~= "number" or value < 0 then
    fail(path .. " must be a non-negative number", 4)
  end
end

local function validate_groups(groups)
  expect_table(groups, "gc.groups")
  for name, capacity in pairs(groups) do
    if type(name) ~= "string" then fail("gc.groups keys must be strings", 4) end
    if type(capacity) ~= "number" or capacity < 0 or capacity % 1 ~= 0 then
      fail("gc.groups." .. name .. " must be a non-negative integer", 4)
    end
  end
end

local function resolve_setup(opts)
  opts = opts or {}
  expect_table(opts, "gc")
  known_keys(opts, {
    ttl_ms = true,
    include_modified = true,
    default_group = true,
    groups = true,
  }, "gc")
  local result = builtin_defaults()
  if opts.ttl_ms ~= nil then result.ttl_ms = opts.ttl_ms end
  if opts.include_modified ~= nil then result.include_modified = opts.include_modified end
  if opts.default_group ~= nil then result.default_group = opts.default_group end
  if opts.groups ~= nil then
    validate_groups(opts.groups)
    for name, capacity in pairs(opts.groups) do result.groups[name] = capacity end
  end
  nonnegative_number(result.ttl_ms, "gc.ttl_ms")
  if type(result.include_modified) ~= "boolean" then
    fail("gc.include_modified must be a boolean", 4)
  end
  if type(result.default_group) ~= "string" or result.default_group == "" then
    fail("gc.default_group must be a non-empty string", 4)
  end
  validate_groups(result.groups)
  if result.groups[result.default_group] == nil then
    fail("gc.default_group must name a configured group", 4)
  end
  return result
end

local Controller = {}
Controller.__index = Controller

function Controller:_entry(subject_or_id)
  local id = type(subject_or_id) == "table" and subject_or_id.id or subject_or_id
  local entry = self.entries[id]
  if type(subject_or_id) == "table" and entry and entry.subject ~= subject_or_id then return nil end
  return entry
end

function Controller:_registered(entry)
  if not entry or self.entries[entry.instance_id] ~= entry then return false end
  if entry.subject.id ~= entry.instance_id or entry.subject.bufnr ~= entry.bufnr then return false end
  return not entry.subject:is_destroyed()
end

function Controller:_now()
  local ok, value = pcall(self.adapter.now)
  if not ok then error(value, 0) end
  if type(value) ~= "number" or value ~= value then
    fail("adapter.now() must return a number", 4)
  end
  return value
end

function Controller:_close_timer_state(timer_state)
  if not timer_state or timer_state.closed then return end
  timer_state.closed = true
  pcall(self.adapter.timer_stop, timer_state.handle)
  pcall(self.adapter.close, timer_state.handle)
end

function Controller:_invalidate_timer(entry)
  entry.generation = entry.generation + 1
  local timer_state = entry.timer
  entry.timer = nil
  entry.expired_reconsider = nil
  self:_close_timer_state(timer_state)
end

function Controller:_report_async(message)
  local text = "fre: " .. tostring(message)
  local ok = pcall(self.adapter.schedule, function()
    pcall(vim.notify, text, vim.log.levels.ERROR)
  end)
  if not ok then pcall(vim.notify, text, vim.log.levels.ERROR) end
end

function Controller:_arm(entry)
  if entry.ttl_ms <= 0 or entry.hidden_since == nil or not self:_registered(entry)
      or entry.subject:is_destroying() then return end
  local remaining = entry.hidden_since + entry.ttl_ms - self:_now()
  if remaining <= 0 then
    local pending = entry.expired_reconsider
    if pending and pending.hidden_since == entry.hidden_since
        and pending.generation == entry.generation then return end
    self:_invalidate_timer(entry)
    pending = { generation = entry.generation, hidden_since = entry.hidden_since }
    entry.expired_reconsider = pending
    local ok, err = pcall(self.adapter.schedule, function()
      if entry.expired_reconsider ~= pending then return end
      entry.expired_reconsider = nil
      if not self:_registered(entry) or entry.generation ~= pending.generation
          or entry.hidden_since ~= pending.hidden_since then return end
      self:reconsider(entry.subject)
    end)
    if not ok then
      if entry.expired_reconsider == pending then entry.expired_reconsider = nil end
      self:_report_async("GC scheduling failed: " .. tostring(err))
    end
    return
  end

  self:_invalidate_timer(entry)
  local generation = entry.generation
  local handle = self.adapter.new_timer()
  if handle == nil then fail("adapter.new_timer() returned nil", 4) end
  local timer_state = { handle = handle, closed = false }
  entry.timer = timer_state
  local ok, result = pcall(self.adapter.timer_start, handle, remaining, function()
    self:_close_timer_state(timer_state)
    if entry.timer == timer_state then entry.timer = nil end
    local scheduled, schedule_err = pcall(self.adapter.schedule, function()
      if not self:_registered(entry) or entry.generation ~= generation
          or entry.hidden_since == nil then return end
      self:reconsider(entry.subject)
    end)
    if not scheduled then
      self:_report_async("GC scheduling failed: " .. tostring(schedule_err))
    end
  end)
  if not ok or result == false then
    if entry.timer == timer_state then entry.timer = nil end
    self:_close_timer_state(timer_state)
    error(ok and "fre.gc: adapter.timer_start() failed" or result, 0)
  end
end

function Controller:_buffer_is_visible(entry)
  if not self:_registered(entry) or not vim.api.nvim_buf_is_valid(entry.bufnr) then return false end
  for _, winid in ipairs(vim.fn.win_findbuf(entry.bufnr)) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == entry.bufnr then
      return true
    end
  end
  return false
end

function Controller:_sync_visibility(entry)
  if type(entry.subject.sync_view) == "function" then
    pcall(entry.subject.sync_view, entry.subject, { report = true })
  end
end

function Controller:is_eligible(subject)
  local entry = self:_entry(subject)
  if not self:_registered(entry) or entry.subject:is_destroying() then return false end
  self:_sync_visibility(entry)
  if not entry.subject:is_ready() or entry.hidden_since == nil
      or not vim.api.nvim_buf_is_valid(entry.bufnr) or self:_buffer_is_visible(entry) then
    entry.eligible = false
    return false
  end
  for _, active in pairs(entry.activities) do
    if active then entry.eligible = false; return false end
  end
  if vim.bo[entry.bufnr].modified and not entry.include_modified then
    entry.eligible = false
    return false
  end
  entry.eligible = true
  return true
end

function Controller:resolve_policy(opts)
  opts = opts or {}
  expect_table(opts, "gc")
  known_keys(opts, { ttl_ms = true, include_modified = true, group = true }, "gc")
  local policy = {
    ttl_ms = self.defaults.ttl_ms,
    include_modified = self.defaults.include_modified,
    group = self.defaults.default_group,
  }
  if opts.ttl_ms ~= nil then policy.ttl_ms = opts.ttl_ms end
  if opts.include_modified ~= nil then policy.include_modified = opts.include_modified end
  if opts.group ~= nil then policy.group = opts.group end
  nonnegative_number(policy.ttl_ms, "gc.ttl_ms")
  if type(policy.include_modified) ~= "boolean" then
    fail("gc.include_modified must be a boolean", 4)
  end
  if type(policy.group) ~= "string" or policy.group == "" then
    fail("gc.group must be a non-empty string", 4)
  end
  if self.groups[policy.group] == nil then
    fail("gc.group names an unknown group: " .. policy.group, 4)
  end
  return policy
end

function Controller:configure(opts)
  local candidate = resolve_setup(opts)
  for name, group in pairs(self.groups) do
    if next(group.members) ~= nil and candidate.groups[name] == nil then
      fail("cannot remove GC group used by a live instance: " .. name, 3)
    end
  end
  local groups = {}
  for name, capacity in pairs(candidate.groups) do
    groups[name] = {
      capacity = capacity,
      members = self.groups[name] and self.groups[name].members or {},
    }
  end
  self.defaults = candidate
  self.groups = groups
  self:enforce_all()
  return self:get_defaults()
end

function Controller:get_defaults()
  return copy(self.defaults)
end

function Controller:register(subject, policy)
  if type(subject) ~= "table" then fail("instance must be a table", 3) end
  if not identity.valid(subject.id) then fail("instance.id must be a valid opaque string", 3) end
  if not positive_integer(subject.bufnr) then fail("instance.bufnr must be a positive integer", 3) end
  if self.entries[subject.id] ~= nil then
    fail("instance ID is already registered: " .. subject.id, 3)
  end
  policy = self:resolve_policy(policy)
  local group = self.groups[policy.group]
  local entry = {
    instance_id = subject.id,
    subject = subject,
    bufnr = subject.bufnr,
    group = policy.group,
    ttl_ms = policy.ttl_ms,
    include_modified = policy.include_modified,
    hidden_since = self:_now(),
    timer = nil,
    generation = 0,
    reconsider_generation = 0,
    expired_reconsider = nil,
    activities = { refresh = false, write = false, execution = false },
    deferred = false,
    eligible = false,
    registration_order = self.next_registration_order,
  }
  self.next_registration_order = self.next_registration_order + 1
  self.entries[subject.id] = entry
  group.members[subject.id] = entry
  local ok, err = pcall(self._arm, self, entry)
  if not ok then
    self:_invalidate_timer(entry)
    group.members[subject.id] = nil
    self.entries[subject.id] = nil
    error(err, 0)
  end
  self:is_eligible(subject)
  return subject
end

function Controller:enforce_after_register(subject)
  local entry = self:_entry(subject)
  if not entry then return end
  local ok, err = pcall(self.enforce_group, self, entry.group, subject)
  if not ok then self:_report_async("GC capacity enforcement failed: " .. tostring(err)) end
end

function Controller:stop(subject)
  local entry = self:_entry(subject)
  if not entry then return false end
  self:_invalidate_timer(entry)
  entry.reconsider_generation = entry.reconsider_generation + 1
  entry.deferred = false
  entry.hidden_since = nil
  entry.eligible = false
  return true
end

function Controller:unregister(subject_or_id)
  local entry = self:_entry(subject_or_id)
  if not entry then return nil end
  self:stop(entry.subject)
  local group = self.groups[entry.group]
  if group and group.members[entry.instance_id] == entry then
    group.members[entry.instance_id] = nil
  end
  self.entries[entry.instance_id] = nil
  return entry.subject
end

function Controller:presentation_enter(subject)
  local entry = self:_entry(subject)
  if not self:_registered(entry) or entry.subject:is_destroying() then return false end
  if entry.hidden_since ~= nil or entry.timer ~= nil then
    entry.hidden_since = nil
    self:_invalidate_timer(entry)
  end
  entry.eligible = false
  return true
end

function Controller:presentation_leave(subject)
  local entry = self:_entry(subject)
  if not self:_registered(entry) or entry.subject:is_destroying() then return false end
  if entry.hidden_since == nil then entry.hidden_since = self:_now() end
  if entry.timer == nil then self:_arm(entry) end
  self:enforce_group(entry.group)
  return true
end

function Controller:activity_changed(subject, activity, active)
  local entry = self:_entry(subject)
  if not self:_registered(entry) or entry.activities[activity] == nil then return false end
  entry.activities[activity] = active == true
  if active then
    entry.eligible = false
  else
    self:defer_reconsider(subject)
  end
  return true
end

function Controller:reconsider(subject)
  local entry = self:_entry(subject)
  if not self:_registered(entry) or entry.subject:is_destroying() then return false end
  self:_sync_visibility(entry)
  if entry.hidden_since == nil then return false end
  local eligible = self:is_eligible(subject)
  if entry.ttl_ms > 0 then
    local remaining = entry.hidden_since + entry.ttl_ms - self:_now()
    if eligible and remaining <= 0 then
      if self:is_eligible(subject) then entry.subject:destroy() end
      return entry.subject:is_destroyed()
    end
    if remaining > 0 and entry.timer == nil then self:_arm(entry) end
  end
  if self:_registered(entry) then self:enforce_group(entry.group) end
  return false
end

function Controller:defer_reconsider(subject)
  local entry = self:_entry(subject)
  if not self:_registered(entry) then return end
  entry.reconsider_generation = entry.reconsider_generation + 1
  local generation = entry.reconsider_generation
  entry.deferred = true
  local ok, err = pcall(self.adapter.schedule, function()
    if not self:_registered(entry) or entry.reconsider_generation ~= generation then return end
    entry.deferred = false
    local reconsidered, reconsider_err = pcall(self.reconsider, self, entry.subject)
    if not reconsidered then
      self:_report_async("GC reconsideration failed: " .. tostring(reconsider_err))
    end
  end)
  if not ok then
    entry.deferred = false
    self:_report_async("GC scheduling failed: " .. tostring(err))
  end
end

local function group_size(group)
  local count = 0
  for _ in pairs(group.members) do count = count + 1 end
  return count
end

local function older(left, right)
  local left_hidden = left.hidden_since or math.huge
  local right_hidden = right.hidden_since or math.huge
  if left_hidden ~= right_hidden then return left_hidden < right_hidden end
  return left.registration_order < right.registration_order
end

function Controller:_eligible_group(group_name)
  local group = self.groups[group_name]
  local result = {}
  if not group then return result end
  for _, entry in pairs(group.members) do
    if self:is_eligible(entry.subject) then result[#result + 1] = entry end
  end
  table.sort(result, older)
  return result
end

function Controller:enforce_group(group_name, protected)
  local group = self.groups[group_name]
  if not group or group.capacity == 0 or self.enforcing[group_name] then return end
  self.enforcing[group_name] = true
  local ok, err = pcall(function()
    while group_size(group) > group.capacity do
      local candidate
      for _, entry in ipairs(self:_eligible_group(group_name)) do
        if entry.subject ~= protected then candidate = entry; break end
      end
      if not candidate then break end
      if self:is_eligible(candidate.subject) then
        candidate.subject:destroy()
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
  for name in pairs(self.groups) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do self:enforce_group(name) end
end

function Controller:move(subject, group_name)
  local entry = self:_entry(subject)
  if not self:_registered(entry) then fail("instance is not registered", 3) end
  local target = self.groups[group_name]
  if not target then fail("unknown GC group: " .. tostring(group_name), 3) end
  if entry.group == group_name then return subject end
  local previous_name = entry.group
  local previous = self.groups[previous_name]
  previous.members[entry.instance_id] = nil
  target.members[entry.instance_id] = entry
  entry.group = group_name
  local ok, err = pcall(self.enforce_group, self, group_name, subject)
  if not ok then
    entry.group = previous_name
    target.members[entry.instance_id] = nil
    previous.members[entry.instance_id] = entry
    error(err, 0)
  end
  return subject
end

function Controller:find_by_group(group_name)
  local group = self.groups[group_name]
  if not group then return nil end
  local result = {}
  for id, entry in pairs(group.members) do result[id] = entry.subject end
  return result
end

function Controller:group_capacity(group_name)
  local group = self.groups[group_name]
  return group and group.capacity or nil
end

function Controller:inspect(subject_or_id)
  local entry = self:_entry(subject_or_id)
  if not entry then return nil end
  return {
    instance_id = entry.instance_id,
    bufnr = entry.bufnr,
    group = entry.group,
    ttl_ms = entry.ttl_ms,
    include_modified = entry.include_modified,
    hidden = entry.hidden_since ~= nil,
    eligible = self:is_eligible(entry.subject),
  }
end

function Controller:set_adapter(adapter)
  validate_adapter(adapter)
  if next(self.entries) ~= nil then
    fail("cannot replace the GC adapter while live instances exist", 3)
  end
  self.adapter = adapter
end

function M.new(adapter)
  local defaults = builtin_defaults()
  local groups = {}
  for name, capacity in pairs(defaults.groups) do
    groups[name] = { capacity = capacity, members = {} }
  end
  return setmetatable({
    adapter = validate_adapter(adapter or M.default),
    defaults = defaults,
    groups = groups,
    entries = {},
    enforcing = {},
    next_registration_order = 1,
  }, Controller)
end

M.validate_adapter = validate_adapter
M.resolve_setup = resolve_setup

return M
