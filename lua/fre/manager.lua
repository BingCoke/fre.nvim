local config = require("fre.config")
local gc = require("fre.gc")
local fs = require("fre.fs")
local mutation_fs = require("fre.mutation.fs")
local registry = require("fre.registry")
local watch = require("fre.watch")
local takeover = require("fre.takeover")
local write_ui = require("fre.write_ui")

local Manager = {}
Manager.__index = Manager

local function fail(message, level)
  error("fre.manager: " .. message, level or 3)
end

local function positive_integer(value)
  return type(value) == "number" and value > 0 and value % 1 == 0
end

local function copy_without(source, omitted)
  local result = {}
  for key, value in pairs(source or {}) do
    if not omitted[key] then result[key] = config.copy(value) end
  end
  return result
end

local next_observer_id = 0

local function observe_managed_events(manager)
  next_observer_id = next_observer_id + 1
  local group = vim.api.nvim_create_augroup(
    "FreManager" .. tostring(next_observer_id), { clear = true }
  )

  local function resolve(data)
    if type(data) ~= "table" or not positive_integer(data.instance_id)
        or not positive_integer(data.bufnr) then return nil end
    local instance = manager.instances_by_id[data.instance_id]
    if not instance or manager.instances_by_buf[data.bufnr] ~= instance
        or instance.id ~= data.instance_id or instance.bufnr ~= data.bufnr then
      return nil
    end
    return instance
  end

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = {
      "FreInstanceCreated",
      "FreReady",
      "FreInstancePresentationChanged",
      "FreInstanceActivityChanged",
      "FreInstanceDestroying",
      "FreInstanceDestroyed",
    },
    callback = function(args)
      local data = args.data
      local instance = resolve(data)
      if not instance then return end
      if args.match == "FreReady" then
        if not instance:is_destroying() and not instance:is_destroyed() then
          manager._gc:defer_reconsider(instance)
        end
      elseif args.match == "FreInstancePresentationChanged" then
        if type(data.visible) ~= "boolean" or instance:is_destroying()
            or instance:is_destroyed() then return end
        if data.visible then
          manager._gc:presentation_enter(instance)
        else
          manager._gc:presentation_leave(instance)
        end
      elseif args.match == "FreInstanceActivityChanged" then
        if type(data.active) ~= "boolean"
            or (data.activity ~= "refresh" and data.activity ~= "write"
              and data.activity ~= "execution")
            or instance:is_destroying() or instance:is_destroyed() then return end
        manager._gc:activity_changed(instance, data.activity, data.active)
      elseif args.match == "FreInstanceDestroying" then
        manager._gc:stop(instance)
      elseif args.match == "FreInstanceDestroyed" then
        manager:remove(instance)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufModifiedSet", {
    group = group,
    callback = function(args)
      local instance = manager.instances_by_buf[args.buf]
      if not instance or manager.instances_by_id[instance.id] ~= instance
          or instance.bufnr ~= args.buf or instance:is_destroying()
          or instance:is_destroyed() then return end
      manager._gc:defer_reconsider(instance)
    end,
  })

  return group
end

function Manager.new(opts)
  opts = opts or {}
  local self = setmetatable({
    _registry = opts.registry or registry.default,
    _setup_defaults = config.resolve_setup(),
    _default_file_explorer = nil,
    _fs_adapter = fs.default,
    _mutation_adapter = mutation_fs.default,
    _watch_adapter = watch.default,
    _write_ui_adapter = write_ui,
    instances_by_id = {},
    instances_by_buf = {},
    _gc = gc.new(),
  }, Manager)
  self._events_augroup = observe_managed_events(self)
  if opts.takeover ~= nil then self._takeover = opts.takeover(self) end
  return self
end

function Manager:create_instance(opts)
  if type(opts) ~= "table" then error("fre: new options must be a table", 2) end
  if opts.root == nil then error("fre: root is required", 2) end
  if type(opts.root) ~= "string" then error("fre: root must be a string", 2) end
  if opts.root == "" then error("fre: root must not be empty", 2) end

  local root = require("fre.path").absolute(opts.root)
  local effective, policy = self:resolve_instance_config(opts, root)
  local core_options = config.copy(effective)
  core_options.root = root
  core_options.registry = self._registry
  core_options.fs_adapter = self._fs_adapter
  core_options.watch_adapter = self._watch_adapter
  core_options.mutation_adapter = self._mutation_adapter
  core_options.write_ui_adapter = self._write_ui_adapter
  local instance = require("fre.instance").new(core_options)
  local ok, result = pcall(self.register, self, instance, policy)
  if ok then return result end

  local cleaned, cleanup_err = pcall(instance.destroy, instance)
  if not cleaned then
    error(tostring(result) .. "; cleanup failed: " .. tostring(cleanup_err), 0)
  end
  error(result, 0)
end

function Manager:get_setup_defaults()
  local result = config.copy(self._setup_defaults)
  result.gc = self._gc:get_defaults()
  return result
end

function Manager:get_default_file_explorer()
  return self._default_file_explorer
end


function Manager:set_fs_adapter(adapter)
  if type(adapter) ~= "table" or type(adapter.load) ~= "function" then
    fail("filesystem adapter must provide load(root, done)")
  end
  self._fs_adapter = adapter
end


function Manager:set_mutation_adapter(adapter)
  local methods = { "create_file", "create_directory", "copy", "move", "delete" }
  if type(adapter) ~= "table" then fail("mutation adapter must be a table") end
  for _, method in ipairs(methods) do
    if type(adapter[method]) ~= "function" then
      fail("mutation adapter must provide " .. method .. "()")
    end
  end
  self._mutation_adapter = adapter
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

function Manager:set_write_ui_adapter(adapter)
  if type(adapter) ~= "table" or type(adapter.confirm) ~= "function"
      or type(adapter.progress) ~= "function" then
    fail("write UI adapter must provide confirm() and progress()")
  end
  self._write_ui_adapter = adapter
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

function Manager:setup(opts)
  opts = opts or {}
  if type(opts) ~= "table" then error("fre.config: setup options must be a table", 2) end
  local first_setup = self._default_file_explorer == nil
  local core_opts = copy_without(opts, { gc = true })
  local candidate = config.resolve_setup(core_opts, not first_setup)
  local gc_opts = opts.gc
  local gc_candidate = gc.resolve_setup(gc_opts)
  if not first_setup then candidate.default_file_explorer = self._default_file_explorer end

  self._gc:configure(gc_candidate)
  self._setup_defaults = config.copy(candidate)
  if first_setup then self._default_file_explorer = candidate.default_file_explorer end
  if first_setup and candidate.default_file_explorer and self._takeover then
    self._takeover:enable()
  end
  return self:get_setup_defaults()
end

function Manager:resolve_instance_config(opts, normalized_root)
  opts = opts or {}
  if type(opts) ~= "table" then error("fre.config: new options must be a table", 2) end
  local policy = self._gc:resolve_policy(opts.gc)
  local core_opts = copy_without(opts, { gc = true })
  local effective = config.resolve_instance(self._setup_defaults, core_opts, normalized_root)
  return effective, policy
end

function Manager:register(instance, policy)
  if type(instance) ~= "table" then fail("instance must be a table") end
  if not positive_integer(instance.id) then fail("instance.id must be a positive integer") end
  if not positive_integer(instance.bufnr) then fail("instance.bufnr must be a positive integer") end
  if self.instances_by_id[instance.id] ~= nil then
    fail("instance ID is already registered: " .. instance.id)
  end
  if self.instances_by_buf[instance.bufnr] ~= nil then
    fail("buffer is already registered: " .. instance.bufnr)
  end

  self.instances_by_id[instance.id] = instance
  self.instances_by_buf[instance.bufnr] = instance
  local ok, err = pcall(self._gc.register, self._gc, instance, policy)
  if not ok then
    self.instances_by_id[instance.id] = nil
    self.instances_by_buf[instance.bufnr] = nil
    self._gc:unregister(instance)
    error(err, 0)
  end

  self._gc:enforce_after_register(instance)
  return instance
end

function Manager:move_to_group(instance, group_name)
  if type(instance) ~= "table" or self.instances_by_id[instance.id] ~= instance
      or self.instances_by_buf[instance.bufnr] ~= instance then
    fail("instance is not registered")
  end
  return self._gc:move(instance, group_name)
end

function Manager:find_by_id(id)
  return self.instances_by_id[id]
end

function Manager:find_by_buf(bufnr)
  return self.instances_by_buf[bufnr]
end

function Manager:find_by_group(group_name)
  return self._gc:find_by_group(group_name)
end

function Manager:remove(instance_or_id)
  local instance = instance_or_id
  if type(instance_or_id) ~= "table" then instance = self.instances_by_id[instance_or_id] end
  if not instance or self.instances_by_id[instance.id] ~= instance then return nil end

  self.instances_by_id[instance.id] = nil
  for bufnr, indexed in pairs(self.instances_by_buf) do
    if indexed == instance then self.instances_by_buf[bufnr] = nil end
  end
  self._gc:unregister(instance)
  return instance
end

local M = {
  new = Manager.new,
  default = Manager.new({ takeover = takeover.new }),
}

return M
