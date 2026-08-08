local fs = require("fre.fs")
local gc = require("fre.gc")
local mutation_fs = require("fre.mutation.fs")
local Instance = require("fre.instance")
local manager_module = require("fre.manager")
local watch = require("fre.watch")

local M = {}

M.view = {
  inspect = function(instance, location)
    return instance:inspect_view(location)
  end,
}

function M.setup(opts)
  manager_module.default:setup(opts)
end

function M.new(opts, construction)
  return manager_module.default:create_instance(opts, construction)
end

function M.get_instance(bufnr)
  if bufnr == nil then
    bufnr = vim.api.nvim_get_current_buf()
  end
  return manager_module.default:find_by_buf(bufnr)
end

function M.get_instance_by_id(id)
  return manager_module.default:find_by_id(id)
end

function M.set_group(instance, group)
  if type(instance) ~= "table" or getmetatable(instance) ~= Instance then
    error("fre: set_group instance must be a live Instance", 2)
  end
  if instance:is_destroying() or instance:is_destroyed() then
    error("fre: set_group instance must be live", 2)
  end
  if type(group) ~= "string" or group == "" then
    error("fre: set_group group must be a non-empty string", 2)
  end
  local manager = manager_module.default
  if manager:find_by_id(instance.id) ~= instance
      or manager:find_by_buf(instance.bufnr) ~= instance then
    error("fre: set_group instance is not registered with the default Manager", 2)
  end
  return manager:_set_group(instance, group)
end

-- Internal test seam: the public filesystem contract remains fre.new/refresh,
-- while deterministic adapters can defer or script initial-load completion.
function M._set_fs_adapter(adapter)
  manager_module.default:set_fs_adapter(adapter)
end

function M._reset_fs_adapter()
  manager_module.default:set_fs_adapter(fs.default)
end

-- Internal test seam for deterministic mutation completion and cancellation.
function M._set_mutation_adapter(adapter)
  manager_module.default:set_mutation_adapter(adapter)
end

function M._reset_mutation_adapter()
  manager_module.default:set_mutation_adapter(mutation_fs.default)
end

-- Internal test seam for deterministic fs-event and debounce behavior.
function M._set_watch_adapter(adapter)
  manager_module.default:set_watch_adapter(adapter)
end

function M._reset_watch_adapter()
  manager_module.default:set_watch_adapter(watch.default)
end

-- Internal deterministic clock/timer/scheduler seam for lifecycle tests.
function M._set_gc_adapter(adapter)
  manager_module.default:set_gc_adapter(adapter)
end

function M._reset_gc_adapter()
  manager_module.default:set_gc_adapter(gc.default)
end

return M
