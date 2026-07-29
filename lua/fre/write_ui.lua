local M = {}

local function display_width(lines)
  local width = 1
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  return width
end

local function close_resources(handle, bufnr, winid)
  if handle ~= nil then handle.closing = true end
  if winid ~= nil then
    pcall(vim.api.nvim_win_close, winid, true)
  elseif bufnr ~= nil then
    local listed, windows = pcall(vim.api.nvim_list_wins)
    if listed then
      for _, candidate in ipairs(windows) do
        local valid, candidate_bufnr = pcall(vim.api.nvim_win_get_buf, candidate)
        if valid and candidate_bufnr == bufnr then
          pcall(vim.api.nvim_win_close, candidate, true)
        end
      end
    end
  end
  if bufnr ~= nil then pcall(vim.api.nvim_buf_delete, bufnr, { force = true }) end
  if handle ~= nil then
    handle.closed = true
    handle.closing = false
  end
end

local function scratch_float(lines, title, on_explicit_close)
  local bufnr
  local winid
  local handle
  local ok, result = pcall(function()
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false

    local max_width = math.max(1, vim.o.columns - 4)
    local max_height = math.max(1, vim.o.lines - vim.o.cmdheight - 4)
    local width = math.min(max_width, math.max(math.min(24, max_width), display_width(lines)))
    local height = math.min(max_height, math.max(1, #lines))
    local row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1)
    local col = math.max(0, math.floor((vim.o.columns - width) / 2))
    winid = vim.api.nvim_open_win(bufnr, true, {
      relative = "editor",
      style = "minimal",
      border = "rounded",
      title = title,
      title_pos = "center",
      width = width,
      height = height,
      row = row,
      col = col,
      focusable = true,
      noautocmd = true,
    })

    handle = {
      bufnr = bufnr,
      winid = winid,
      closed = false,
      closing = false,
    }

    local function explicit_close()
      if handle.closed or handle.closing then return end
      handle.closed = true
      if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
      on_explicit_close()
    end

    function handle:close()
      if self.closed then return false end
      close_resources(self, bufnr, winid)
      return true
    end

    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(winid),
      once = true,
      callback = explicit_close,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = bufnr,
      once = true,
      callback = explicit_close,
    })

    return handle
  end)
  if not ok then
    close_resources(handle, bufnr, winid)
    error(result, 0)
  end
  return result
end

local function initialize_handle(handle, callback)
  local ok, err = pcall(callback)
  if not ok then
    pcall(handle.close, handle)
    error(err, 0)
  end
  return handle
end

function M.confirm(ctx, display, on_decision)
  local source_winid = type(ctx) == "table" and ctx.winid or nil
  local decided = false
  local handle
  local function decide(accepted)
    if decided then return end
    decided = true
    on_decision(accepted == true)
  end
  handle = scratch_float(display, " Fre write: Enter accept, q cancel ", function()
    decide(false)
  end)
  local function accept() decide(true) end
  local function cancel() decide(false) end
  handle = initialize_handle(handle, function()
    vim.keymap.set("n", "<CR>", accept, { buffer = handle.bufnr, nowait = true, silent = true })
    vim.keymap.set("n", "y", accept, { buffer = handle.bufnr, nowait = true, silent = true })
    vim.keymap.set("n", "q", cancel, { buffer = handle.bufnr, nowait = true, silent = true })
    vim.keymap.set("n", "<Esc>", cancel, { buffer = handle.bufnr, nowait = true, silent = true })
  end)
  vim.schedule(function()
    if type(source_winid) ~= "number" or handle.closed
        or not vim.api.nvim_win_is_valid(handle.winid)
        or vim.api.nvim_win_get_buf(handle.winid) ~= handle.bufnr then
      return
    end
    local current_winid = vim.api.nvim_get_current_win()
    if current_winid ~= source_winid and current_winid ~= handle.winid then return end
    pcall(vim.api.nvim_set_current_win, handle.winid)
  end)
  return handle
end

local function inspect_one_line(value)
  return vim.inspect(value, { newline = " ", indent = "" })
end

local function progress_lines(status)
  return {
    "State: " .. tostring(status.state),
    string.format("Progress: %d/%d", tonumber(status.completed) or 0, tonumber(status.total) or 0),
    "Current: " .. (status.current == nil and "-" or inspect_one_line(status.current)),
    "Detail: " .. (status.detail == nil and "-" or inspect_one_line(status.detail)),
    "q / <Esc>: cancel",
  }
end

function M.progress(_ctx, status, on_cancel)
  local handle = scratch_float(progress_lines(status), " Fre write progress ", on_cancel)
  local function cancel()
    on_cancel()
  end
  return initialize_handle(handle, function()
    vim.keymap.set("n", "q", cancel, { buffer = handle.bufnr, nowait = true, silent = true })
    vim.keymap.set("n", "<Esc>", cancel, { buffer = handle.bufnr, nowait = true, silent = true })

    function handle:update(next_status)
      if self.closed or not vim.api.nvim_buf_is_valid(self.bufnr) then return false end
      vim.bo[self.bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, progress_lines(next_status))
      vim.bo[self.bufnr].modifiable = false
      return true
    end
  end)
end

local function outcome_text(outcome)
  if outcome == nil then return "no Execution was started" end
  local text = "Execution " .. tostring(outcome.state or outcome.status or "unknown")
    .. string.format(" (%d/%d)", tonumber(outcome.completed) or 0, tonumber(outcome.total) or 0)
  if outcome.error ~= nil then text = text .. ": " .. inspect_one_line(outcome.error) end
  return text
end

function M.report(_ctx, outcome, reconciliation_error)
  if reconciliation_error ~= nil then
    vim.notify(
      "fre: " .. outcome_text(outcome) .. "; reconciliation failed: "
        .. tostring(reconciliation_error)
        .. "; run instance:refresh({ force = true }) to recover",
      vim.log.levels.ERROR
    )
    return
  end
  if outcome and (outcome.state == "failed" or outcome.status == "failed") then
    vim.notify("fre: " .. outcome_text(outcome), vim.log.levels.ERROR)
  elseif outcome and (outcome.state == "canceled" or outcome.status == "canceled") then
    vim.notify("fre: " .. outcome_text(outcome), vim.log.levels.WARN)
  end
end

return M
