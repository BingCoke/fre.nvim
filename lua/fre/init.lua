local fs = require("fre.fs")
local mutation_fs = require("fre.mutation.fs")
local Instance = require("fre.instance")
local manager_module = require("fre.manager")
local path = require("fre.path")

local M = {}

function M.setup(opts)
  manager_module.default:setup(opts)
end

function M.new(opts)
  if type(opts) ~= "table" then
    error("fre: new options must be a table", 2)
  end
  if opts.root == nil then
    error("fre: root is required", 2)
  end
  if type(opts.root) ~= "string" then
    error("fre: root must be a string", 2)
  end
  if opts.root == "" then
    error("fre: root must not be empty", 2)
  end

  local root = path.absolute(opts.root)
  local effective = manager_module.default:resolve_instance_config(opts, opts.inherit)
  return Instance.new(manager_module.default, root, effective)
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

return M
