local M = {}

local next_id = 0

function M.valid(value)
  return type(value) == "string" and value ~= ""
    and not value:find("[%z\1-\31\127]")
end

function M.new()
  next_id = next_id + 1
  local digest = vim.fn.sha256(table.concat({
    tostring(vim.uv.hrtime()),
    tostring(vim.uv.os_getpid()),
    tostring(next_id),
  }, ":"))
  return digest:sub(1, 8) .. "-" .. digest:sub(9, 12)
    .. "-4" .. digest:sub(14, 16) .. "-8" .. digest:sub(18, 20)
    .. "-" .. digest:sub(21, 32)
end

function M.marker_source_resolver(resolve_instance)
  if resolve_instance == nil then return nil end
  if type(resolve_instance) ~= "function" then
    error("fre: resolve_instance must be a function", 3)
  end
  return function(instance_id)
    local peer = resolve_instance(instance_id)
    if peer == nil then return nil end
    if type(peer) ~= "table" or peer.id ~= instance_id
        or type(peer.is_destroying) ~= "function"
        or type(peer.is_destroyed) ~= "function" then
      error("resolver returned an invalid Instance for " .. tostring(instance_id), 0)
    end
    if peer:is_destroying() or peer:is_destroyed() then
      error("resolver returned a terminal Instance for " .. tostring(instance_id), 0)
    end
    local source = peer.buffer and peer.buffer.marker_source
    if type(source) ~= "table" or source.id ~= instance_id then
      error("resolved Instance has no marker source for " .. tostring(instance_id), 0)
    end
    return source
  end
end

function M.resolve(id, resolve_instance)
  id = id or M.new()
  if not M.valid(id) then
    error("fre: instance id must be a non-empty string without control characters", 3)
  end
  return {
    id = id,
    marker_source = M.marker_source_resolver(resolve_instance),
  }
end

return M
