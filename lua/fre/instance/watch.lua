local watch_adapter = require("fre.watch")

local M = {}

local Controller = {}
Controller.__index = Controller

local function operation(adapter, name, ...)
  local ok, result, detail = pcall(adapter[name], ...)
  if not ok then return nil, result end
  if result == nil or result == false then
    return nil, detail or (name .. " failed")
  end
  return result
end

function Controller:_current(entry)
  return not self.destroyed and entry.active and self.entries[entry.path] == entry
end

function Controller:is_current(entry)
  return self:_current(entry)
end

function Controller:_schedule(entry, callback)
  local ok, err = pcall(self.adapter.schedule, function()
    if self:_current(entry) then callback() end
  end)
  if not ok then self:_fail(entry, err) end
end

function Controller:_close_entry(entry)
  if not entry.active then return end
  entry.active = false
  entry.debounce_generation = entry.debounce_generation + 1
  pcall(self.adapter.timer_stop, entry.timer)
  pcall(self.adapter.close, entry.timer)
  pcall(self.adapter.close, entry.handle)
end

function Controller:_fail(entry, err)
  if not self:_current(entry) or entry.errored then return end
  entry.errored = true
  self.entries[entry.path] = nil
  self.failed[entry.path] = entry
  self:_close_entry(entry)
  local ok = pcall(self.adapter.schedule, function()
    if self.destroyed or self.failed[entry.path] ~= entry then return end
    self.on_error({ path = entry.path, node_id = entry.node_id }, err)
  end)
  if not ok then
    self.on_error({ path = entry.path, node_id = entry.node_id }, err)
  end
end

function Controller:_debounce(entry)
  if not self:_current(entry) then return end
  entry.debounce_generation = entry.debounce_generation + 1
  local generation = entry.debounce_generation
  pcall(self.adapter.timer_stop, entry.timer)
  local _, err = operation(self.adapter, "timer_start", entry.timer,
    self.adapter.debounce_ms or 100, function()
      if not self:_current(entry) or entry.debounce_generation ~= generation then return end
      pcall(self.adapter.timer_stop, entry.timer)
      self:_schedule(entry, function()
        self.on_event({ path = entry.path, node_id = entry.node_id })
      end)
    end)
  if err then self:_fail(entry, "debounce timer: " .. tostring(err)) end
end

function Controller:_start(spec)
  local entry = {
    path = spec.path,
    node_id = spec.node_id,
    generation = self.next_generation,
    debounce_generation = 0,
    active = true,
    errored = false,
  }
  self.next_generation = self.next_generation + 1
  self.entries[entry.path] = entry

  local handle, handle_err = operation(self.adapter, "new_fs_event")
  if not handle then self:_fail(entry, "cannot create fs event: " .. tostring(handle_err)); return end
  entry.handle = handle
  local timer, timer_err = operation(self.adapter, "new_timer")
  if not timer then self:_fail(entry, "cannot create debounce timer: " .. tostring(timer_err)); return end
  entry.timer = timer

  local _, start_err = operation(self.adapter, "fs_event_start", handle, entry.path,
    function(err, _filename, _events)
      if not self:_current(entry) then return end
      if err ~= nil then
        self:_fail(entry, err)
      else
        self:_debounce(entry)
      end
    end)
  if start_err then self:_fail(entry, "cannot start fs event: " .. tostring(start_err)) end
end

function Controller:sync(specs, opts)
  if self.destroyed then return end
  opts = opts or {}
  local desired = {}
  for _, spec in ipairs(specs or {}) do desired[spec.path] = spec end

  for watch_path, entry in pairs(self.entries) do
    local spec = desired[watch_path]
    if not spec then
      self.entries[watch_path] = nil
      self:_close_entry(entry)
    else
      entry.node_id = spec.node_id
    end
  end

  if opts.recreate_failed then self.failed = {} end
  for _, spec in ipairs(specs or {}) do
    if self.entries[spec.path] == nil and self.failed[spec.path] == nil then self:_start(spec) end
  end
end

function Controller:suspend()
  if self.destroyed then return end
  for watch_path, entry in pairs(self.entries) do
    self.entries[watch_path] = nil
    self:_close_entry(entry)
  end
end

function Controller:stop_all()
  if self.destroyed then return end
  self:suspend()
  self.destroyed = true
  self.failed = {}
end

function Controller:paths()
  local result = {}
  for watch_path in pairs(self.entries) do result[#result + 1] = watch_path end
  table.sort(result)
  return result
end

function M.new(options)
  options = options or {}
  local adapter = options.adapter or watch_adapter.default
  for _, method in ipairs({
    "new_fs_event", "fs_event_start", "new_timer", "timer_start",
    "timer_stop", "close", "schedule",
  }) do
    if type(adapter[method]) ~= "function" then
      error("fre.watch: adapter must provide " .. method .. "()", 2)
    end
  end
  return setmetatable({
    adapter = adapter,
    on_error = assert(options.on_error),
    on_event = assert(options.on_event),
    entries = {},
    failed = {},
    next_generation = 1,
    destroyed = false,
  }, Controller)
end

return M
