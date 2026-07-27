local fs = require("fre.fs")
local gc = require("fre.gc")
local mutation_fs = require("fre.mutation.fs")
local manager_module = require("fre.manager")
local watch = require("fre.watch")

local M = {}

function M.setup(opts)
  manager_module.default:setup(opts)
end

function M.new(opts)
  return manager_module.default:create_instance(opts)
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
