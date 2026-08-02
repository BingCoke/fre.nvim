local uv = vim.uv

local M = {}

local function stop_handle(handle)
  if handle == nil then return end
  if type(handle.is_closing) == "function" then
    local ok, closing = pcall(handle.is_closing, handle)
    if ok and closing then return end
  end
  if type(handle.stop) == "function" then pcall(handle.stop, handle) end
  if type(handle.close) == "function" then pcall(handle.close, handle) end
end

M.default = {
  debounce_ms = 100,
  new_fs_event = function() return uv.new_fs_event() end,
  fs_event_start = function(handle, watch_path, callback)
    return handle:start(watch_path, {}, callback)
  end,
  new_timer = function() return uv.new_timer() end,
  timer_start = function(timer, timeout, callback)
    return timer:start(timeout, 0, callback)
  end,
  timer_stop = function(timer) return timer:stop() end,
  close = stop_handle,
  schedule = vim.schedule,
}

return M
