local M = {}

function M.inspect(instance, location)
  return instance:inspect_view(location)
end

return M
