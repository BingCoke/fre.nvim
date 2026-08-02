local view = require("fre.instance.view")

local M = {}

function M.inspect(instance, location)
  return view.inspect(instance, location)
end

return M
