local M = {}

local copyable = { file = true, directory = true, symlink = true }
local native_special = { char = true, block = true, fifo = true, socket = true }

function M.supports(operation, kind)
  if operation == "copy" then return copyable[kind] == true end
  if operation == "move" or operation == "delete" then
    return copyable[kind] == true or native_special[kind] == true
  end
  return false
end

function M.mutable(kind)
  return M.supports("move", kind) and M.supports("delete", kind)
end

return M
