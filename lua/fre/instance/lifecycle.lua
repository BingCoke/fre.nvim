local Lifecycle = {}
Lifecycle.__index = Lifecycle

local function fail(message, level)
  error("fre: " .. message, level or 3)
end

local function call_observer(self, observer, err)
  if not observer.active then return end
  observer.active = false
  local ok, callback_err = pcall(observer.fn, err)
  if not ok then
    self.schedule(function() error(callback_err) end)
  end
end

function Lifecycle.new(options)
  if type(options) ~= "table" then fail("lifecycle options are required", 2) end
  return setmetatable({
    state = "creating",
    error = nil,
    observers = {},
    schedule = assert(options.schedule),
    emit_ready = assert(options.emit_ready),
  }, Lifecycle)
end

function Lifecycle:status()
  return self.state
end

function Lifecycle:failure()
  return self.error
end


function Lifecycle:is(state)
  return self.state == state
end

function Lifecycle:is_ready()
  return self.state == "ready"
end

function Lifecycle:is_creating()
  return self.state == "creating"
end

function Lifecycle:is_load_failed()
  return self.state == "load-failed"
end

function Lifecycle:is_destroying()
  return self.state == "destroying"
end

function Lifecycle:is_destroyed()
  return self.state == "destroyed"
end

function Lifecycle:is_dead()
  return self.state == "destroying" or self.state == "destroyed"
end

function Lifecycle:begin_load()
  self.state = "creating"
  self.error = nil
end

function Lifecycle:complete_load(err, result, before_observers)
  if self.state ~= "creating" then return false end
  local observers = self.observers
  self.observers = {}
  if err ~= nil then
    self.state = "load-failed"
    self.error = err
  else
    self.state = "ready"
    self.error = nil
  end
  if before_observers then before_observers(err) end
  for _, observer in ipairs(observers) do call_observer(self, observer, err) end
  self.emit_ready(err, result)
  return true
end


function Lifecycle:observe(callback)
  if self:is_dead() then fail("instance is destroyed", 2) end
  local observer = { fn = callback, active = true }
  if self:is_ready() then
    self.schedule(function() call_observer(self, observer, nil) end)
  elseif self:is_load_failed() then
    local err = self.error
    self.schedule(function() call_observer(self, observer, err) end)
  else
    self.observers[#self.observers + 1] = observer
  end
end

function Lifecycle:begin_destroy()
  if self:is_dead() then return false end
  self.state = "destroying"
  local observers = self.observers
  self.observers = {}
  for _, observer in ipairs(observers) do
    self.schedule(function()
      call_observer(self, observer, "instance was destroyed before becoming ready")
    end)
  end
  return true
end

function Lifecycle:finish_destroy()
  self.state = "destroyed"
  self.error = nil
end

function Lifecycle:discard()
  for _, observer in ipairs(self.observers) do observer.active = false end
  self.observers = {}
  self.state = "destroyed"
  self.error = nil
end

return Lifecycle
