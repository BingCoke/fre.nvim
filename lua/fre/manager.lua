local config = require("fre.config")
local gc = require("fre.gc")
local fs = require("fre.fs")
local mutation_fs = require("fre.mutation.fs")
local watch = require("fre.watch")

local Manager = {}
Manager.__index = Manager

local function fail(message, level)
  error("fre.manager: " .. message, level or 3)
end

local function positive_integer(value)
  return type(value) == "number" and value > 0 and value % 1 == 0
end

local function new_group(capacity)
  return {
    capacity = capacity,
    instances = {},
  }
end

function Manager.new()
  local defaults = config.resolve_setup()
  local groups = {}
  for name, capacity in next, defaults.gc.groups do
    groups[name] = new_group(capacity)
  end
  local self = setmetatable({
    _next_id = 1,
    _consumed_ids = {},
    _setup_defaults = defaults,
    _default_file_explorer = nil,
    _fs_adapter = fs.default,
    _mutation_adapter = mutation_fs.default,
    _watch_adapter = watch.default,
    instances_by_id = {},
    instances_by_buf = {},
    groups = groups,
  }, Manager)
  self._gc = gc.new(self)
  return self
end

function Manager:allocate_id()
  local id = self._next_id
  self._next_id = id + 1
  return id
end

function Manager:get_setup_defaults()
  return config.copy(self._setup_defaults)
end

function Manager:get_default_file_explorer()
  return self._default_file_explorer
end

function Manager:get_fs_adapter()
  return self._fs_adapter
end

function Manager:set_fs_adapter(adapter)
  if type(adapter) ~= "table" or type(adapter.load) ~= "function" then
    fail("filesystem adapter must provide load(root, done)")
  end
  self._fs_adapter = adapter
end

function Manager:get_mutation_adapter()
  return self._mutation_adapter
end

function Manager:set_mutation_adapter(adapter)
  local methods = { "create_file", "create_directory", "copy", "move", "delete" }
  if type(adapter) ~= "table" then
    fail("mutation adapter must be a table")
  end
  for _, method in ipairs(methods) do
    if type(adapter[method]) ~= "function" then
      fail("mutation adapter must provide " .. method .. "()")
    end
  end
  self._mutation_adapter = adapter
end

function Manager:get_watch_adapter()
  return self._watch_adapter
end

function Manager:set_watch_adapter(adapter)
  if type(adapter) ~= "table" then fail("watch adapter must be a table") end
  for _, method in ipairs({
    "new_fs_event", "fs_event_start", "new_timer", "timer_start",
    "timer_stop", "close", "schedule",
  }) do
    if type(adapter[method]) ~= "function" then
      fail("watch adapter must provide " .. method .. "()")
    end
  end
  self._watch_adapter = adapter
end

function Manager:get_gc_controller()
  return self._gc
end

function Manager:set_gc_adapter(adapter)
  self._gc:set_adapter(adapter)
end

function Manager:is_gc_eligible(instance)
  return self._gc:is_eligible(instance)
end

function Manager:gc_visibility_changed(instance)
  return self._gc:visibility_changed(instance)
end

function Manager:gc_reconsider(instance, deferred)
  if deferred then
    self._gc:defer_reconsider(instance)
  else
    self._gc:reconsider(instance)
  end
end

function Manager:setup(opts)
  local first_setup = self._default_file_explorer == nil
  local candidate = config.resolve_setup(opts, not first_setup)
  if not first_setup then
    candidate.default_file_explorer = self._default_file_explorer
  end

  for group_name, group in next, self.groups do
    if next(group.instances) ~= nil and candidate.gc.groups[group_name] == nil then
      fail("cannot remove GC group used by a live instance: " .. group_name)
    end
  end

  local replacement_groups = {}
  for name, capacity in next, candidate.gc.groups do
    local existing = self.groups[name]
    replacement_groups[name] = {
      capacity = capacity,
      instances = existing and existing.instances or {},
    }
  end

  self._setup_defaults = config.copy(candidate)
  self.groups = replacement_groups
  if first_setup then
    self._default_file_explorer = candidate.default_file_explorer
  end
  self._gc:enforce_all()
  return self:get_setup_defaults()
end

function Manager:resolve_instance_config(opts, predecessor)
  return config.resolve_instance(self._setup_defaults, opts, predecessor)
end

function Manager:register(instance)
  if type(instance) ~= "table" then
    fail("instance must be a table")
  end
  if not positive_integer(instance.id) then
    fail("instance.id must be a positive integer")
  end
  if instance.id >= self._next_id then
    fail("instance.id must be allocated by this manager")
  end
  if self._consumed_ids[instance.id] then
    fail("instance ID was already consumed: " .. instance.id)
  end
  if not positive_integer(instance.bufnr) then
    fail("instance.bufnr must be a positive integer")
  end
  if self.instances_by_id[instance.id] ~= nil then
    fail("instance ID is already registered: " .. instance.id)
  end
  if self.instances_by_buf[instance.bufnr] ~= nil then
    fail("buffer is already registered: " .. instance.bufnr)
  end
  local group_name = instance.config
    and instance.config.gc
    and instance.config.gc.group
  local group = group_name and self.groups[group_name]
  if not group then
    fail("instance has unknown GC group: " .. tostring(group_name))
  end

  self._consumed_ids[instance.id] = true
  self.instances_by_id[instance.id] = instance
  self.instances_by_buf[instance.bufnr] = instance
  group.instances[instance.id] = instance
  local ok, err = pcall(self._gc.on_register, self._gc, instance)
  if not ok then
    self._gc:stop(instance)
    self.instances_by_id[instance.id] = nil
    self.instances_by_buf[instance.bufnr] = nil
    group.instances[instance.id] = nil
    error(err, 0)
  end
  return instance
end

function Manager:find_by_id(id)
  return self.instances_by_id[id]
end

function Manager:find_by_buf(bufnr)
  return self.instances_by_buf[bufnr]
end

function Manager:find_by_group(group_name)
  local group = self.groups[group_name]
  if not group then
    return nil
  end
  local result = {}
  for id, instance in next, group.instances do
    result[id] = instance
  end
  return result
end

function Manager:remove(instance_or_id)
  local instance = instance_or_id
  if type(instance_or_id) ~= "table" then
    instance = self.instances_by_id[instance_or_id]
  end
  if not instance or self.instances_by_id[instance.id] ~= instance then
    return nil
  end

  if not instance._destroyed then self._gc:stop(instance) end

  self.instances_by_id[instance.id] = nil
  for bufnr, indexed in next, self.instances_by_buf do
    if indexed == instance then
      self.instances_by_buf[bufnr] = nil
    end
  end
  for _, group in next, self.groups do
    if group.instances[instance.id] == instance then
      group.instances[instance.id] = nil
    end
  end
  return instance
end

local M = {
  new = Manager.new,
  default = Manager.new(),
}

return M
