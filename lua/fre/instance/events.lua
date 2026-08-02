local M = {}

local function report_error(pattern, err)
  local message = "fre: " .. pattern .. " observer failed: " .. tostring(err)
  local scheduled = pcall(vim.schedule, function()
    pcall(vim.notify, message, vim.log.levels.ERROR)
  end)
  if not scheduled then
    pcall(vim.notify, message, vim.log.levels.ERROR)
  end
end

local function event_error(err)
  if err == nil then return nil end
  if pcall(vim.json.encode, err) then return err end
  return "non-serializable error (" .. type(err) .. ")"
end

local function emit(pattern, data)
  local previous_error = vim.v.errmsg
  vim.v.errmsg = ""
  local ok, err = pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = pattern,
    modeline = false,
    data = data,
  })
  local observer_error = not ok and err or vim.v.errmsg
  vim.v.errmsg = previous_error
  if observer_error ~= nil and observer_error ~= "" then
    report_error(pattern, observer_error)
  end
end

function M.created(instance_id, bufnr)
  emit("FreInstanceCreated", { instance_id = instance_id, bufnr = bufnr })
end

function M.ready(instance_id, bufnr, err, result)
  emit("FreReady", {
    instance_id = instance_id,
    bufnr = bufnr,
    error = event_error(err),
    result = result,
  })
end

function M.presentation_changed(instance_id, bufnr, visible)
  emit("FreInstancePresentationChanged", {
    instance_id = instance_id,
    bufnr = bufnr,
    visible = visible,
  })
end

function M.activity_changed(instance_id, bufnr, activity, active)
  emit("FreInstanceActivityChanged", {
    instance_id = instance_id,
    bufnr = bufnr,
    activity = activity,
    active = active,
  })
end

function M.destroying(instance_id, bufnr)
  emit("FreInstanceDestroying", { instance_id = instance_id, bufnr = bufnr })
end

function M.destroyed(instance_id, bufnr)
  emit("FreInstanceDestroyed", { instance_id = instance_id, bufnr = bufnr })
end

return M
