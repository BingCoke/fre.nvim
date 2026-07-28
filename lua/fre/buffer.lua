local row = require("fre.row")
local window = require("fre.window")

local M = {}

local row_namespace = vim.api.nvim_create_namespace("fre-row-identity")
local highlight_namespace = vim.api.nvim_create_namespace("fre-column-highlights")

local function fail(message, level)
  error("fre: " .. message, level or 3)
end

local function get_line(instance, row)
  if type(row) ~= "number" or row % 1 ~= 0 then fail("row must be a 1-based integer", 4) end
  if row < 1 or not vim.api.nvim_buf_is_valid(instance.bufnr) then return nil end
  local count = vim.api.nvim_buf_line_count(instance.bufnr)
  if row > count then return nil end
  return vim.api.nvim_buf_get_lines(instance.bufnr, row - 1, row, false)[1]
end

local function set_node_extmark(instance, node, row)
  if node.row_extmark then
    pcall(vim.api.nvim_buf_del_extmark, instance.bufnr, row_namespace, node.row_extmark)
  end
  node.row_extmark = vim.api.nvim_buf_set_extmark(instance.bufnr, row_namespace, row - 1, 0, {
    right_gravity = true,
  })
end

function M.constrain_cursor(instance, winid)
  winid = winid or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_buf(winid) ~= instance.bufnr then return end
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local row_number = cursor[1]
  local ok, decoded = pcall(M.decode, instance, row_number, {
    allow_empty_path = true,
    validate_metadata = false,
  })
  if not ok or not decoded or not decoded.marked then return end
  local lower = decoded.navigable_range.start_byte
  local upper = math.max(lower, decoded.path_range.end_byte)
  local col = math.max(lower, math.min(cursor[2], upper))
  if cursor[2] ~= col then vim.api.nvim_win_set_cursor(winid, { row_number, col }) end
end

function M.place_initial_cursor(instance, winid)
  if not instance._pending_initial_cursor then instance._pending_initial_cursor = {} end
  if not winid or not vim.api.nvim_win_is_valid(winid)
      or vim.api.nvim_win_get_buf(winid) ~= instance.bufnr then
    if winid then instance._pending_initial_cursor[winid] = nil end
    return false
  end
  local ok, decoded = pcall(M.decode, instance, 1, {
    allow_empty_path = true,
    validate_metadata = false,
  })
  if ok and decoded and decoded.marked and decoded.synthetic
      and decoded.instance_id == instance.id and decoded.node_id == 0 then
    vim.api.nvim_win_set_cursor(winid, { 1, decoded.path_range.start_byte })
    instance._pending_initial_cursor[winid] = nil
    return true
  end
  instance._pending_initial_cursor[winid] = true
  return false
end

function M.decode(instance, row_number, opts)
  return row.decode(instance, row_number, get_line(instance, row_number), opts)
end

function M.prepare(instance, projection, render_path, opts)
  return row.prepare(instance, projection, render_path, opts)
end

function M.row_matches_identity(instance, row_number, instance_id, node_id)
  local line = get_line(instance, row_number)
  return line ~= nil and row.matches_identity(instance, line, instance_id, node_id)
end

function M.find_identity_rows(instance, instance_id, node_id)
  if not vim.api.nvim_buf_is_valid(instance.bufnr) then return {} end
  local result = {}
  local lines = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)
  for index, line in ipairs(lines) do
    if row.matches_identity(instance, line, instance_id, node_id) then
      result[#result + 1] = index
    end
  end
  return result
end

function M.rebind(instance, node, row) set_node_extmark(instance, node, row) end

function M.hint_row(instance, node)
  if not node.row_extmark or not vim.api.nvim_buf_is_valid(instance.bufnr) then return nil end
  local position = vim.api.nvim_buf_get_extmark_by_id(
    instance.bufnr, row_namespace, node.row_extmark, {}
  )
  if #position == 0 then return nil end
  return position[1] + 1
end

local function same_widths(left, right)
  if not left or not right or #left ~= #right then return false end
  for index = 1, #left do
    if left[index] ~= right[index] then return false end
  end
  return true
end

local function set_lines_raw(instance, first, last, lines)
  if not vim.api.nvim_buf_is_valid(instance.bufnr) then return false end
  local was_modifiable = vim.bo[instance.bufnr].modifiable
  vim.bo[instance.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(instance.bufnr, first, last, false, lines)
  vim.bo[instance.bufnr].modified = false
  vim.bo[instance.bufnr].modifiable = was_modifiable
  return true
end

local function capture_windows(instance)
  local windows = {}
  for _, winid in ipairs(vim.fn.win_findbuf(instance.bufnr)) do
    if vim.api.nvim_win_is_valid(winid)
        and vim.api.nvim_win_get_buf(winid) == instance.bufnr then
      local view = vim.api.nvim_win_call(winid, vim.fn.winsaveview)
      local cursor = vim.api.nvim_win_get_cursor(winid)
      local line = get_line(instance, cursor[1]) or ""
      local ok, decoded = pcall(
        row.decode, instance, cursor[1], line,
        { allow_empty_path = true, validate_metadata = false }
      )
      local node_id, anchor
      if ok and decoded and decoded.marked then
        anchor = row.cursor_anchor(decoded, cursor[2])
        if not decoded.synthetic and decoded.instance_id == instance.id then
          node_id = decoded.node_id
        end
      end
      windows[winid] = {
        view = view,
        cursor = cursor,
        node_id = node_id,
        anchor = anchor,
      }
    end
  end
  return windows
end

local function restore_windows(instance, windows, rows_by_id, exact)
  if not vim.api.nvim_buf_is_valid(instance.bufnr) then return end
  local count = vim.api.nvim_buf_line_count(instance.bufnr)
  for winid, saved in pairs(windows or {}) do
    if vim.api.nvim_win_is_valid(winid)
        and vim.api.nvim_win_get_buf(winid) == instance.bufnr then
      local row_number = saved.cursor[1]
      if not exact and saved.node_id and rows_by_id[saved.node_id] then
        row_number = rows_by_id[saved.node_id]
      end
      row_number = math.max(1, math.min(row_number, count))
      local line = vim.api.nvim_buf_get_lines(
        instance.bufnr, row_number - 1, row_number, false
      )[1] or ""
      local col = math.max(0, math.min(saved.cursor[2], #line))
      local semantic_mapped = false
      if saved.anchor then
        local ok, decoded = pcall(row.decode, instance, row_number, line, {
          allow_empty_path = true,
          validate_metadata = false,
        })
        if ok and decoded and decoded.marked then
          local mapped_col = row.cursor_column(decoded, saved.anchor)
          if mapped_col ~= nil then
            col = mapped_col
            semantic_mapped = true
          end
        end
      end
      col = math.max(0, math.min(col, #line))
      local view = vim.deepcopy(saved.view)
      local delta = row_number - saved.cursor[1]
      view.lnum = row_number
      view.col = col
      if not exact then view.topline = (view.topline or 1) + delta end
      view.topline = math.max(1, math.min(view.topline or 1, count))
      pcall(vim.api.nvim_win_call, winid, function()
        if semantic_mapped then
          vim.api.nvim_win_set_cursor(0, { row_number, col })
          view.coladd = 0
          view.curswant = vim.fn.winsaveview().curswant
        end
        vim.fn.winrestview(view)
      end)
      M.constrain_cursor(instance, winid)
    end
  end
end

function M.snapshot(instance)
  if not vim.api.nvim_buf_is_valid(instance.bufnr) then return nil end
  local node_extmarks = {}
  for _, node in pairs(instance.nodes_by_id or {}) do
    node_extmarks[node] = node.row_extmark
  end
  return {
    lines = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false),
    modified = vim.bo[instance.bufnr].modified,
    modifiable = vim.bo[instance.bufnr].modifiable,
    extmarks = vim.api.nvim_buf_get_extmarks(
      instance.bufnr, row_namespace, 0, -1, { details = true }
    ),
    highlights = vim.api.nvim_buf_get_extmarks(
      instance.bufnr, highlight_namespace, 0, -1, { details = true }
    ),
    node_extmarks = node_extmarks,
    windows = capture_windows(instance),
  }
end

function M.restore(instance, snapshot)
  if not snapshot or not vim.api.nvim_buf_is_valid(instance.bufnr) then return false end
  vim.bo[instance.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(instance.bufnr, 0, -1, false, snapshot.lines)
  vim.api.nvim_buf_clear_namespace(instance.bufnr, row_namespace, 0, -1)
  for _, node in pairs(instance.nodes_by_id or {}) do node.row_extmark = nil end
  for _, mark in ipairs(snapshot.extmarks) do
    local details = mark[4] or {}
    vim.api.nvim_buf_set_extmark(instance.bufnr, row_namespace, mark[2], mark[3], {
      id = mark[1],
      right_gravity = details.right_gravity ~= false,
    })
  end
  vim.api.nvim_buf_clear_namespace(instance.bufnr, highlight_namespace, 0, -1)
  for _, mark in ipairs(snapshot.highlights or {}) do
    local details = mark[4] or {}
    vim.api.nvim_buf_set_extmark(instance.bufnr, highlight_namespace, mark[2], mark[3], {
      end_row = details.end_row,
      end_col = details.end_col,
      hl_group = details.hl_group,
      priority = details.priority,
      undo_restore = false,
    })
  end
  for node, mark in pairs(snapshot.node_extmarks) do node.row_extmark = mark end
  vim.bo[instance.bufnr].modified = snapshot.modified
  vim.bo[instance.bufnr].modifiable = snapshot.modifiable
  restore_windows(instance, snapshot.windows, nil, true)
  return true
end

function M.commit(instance, prepared)
  if not vim.api.nvim_buf_is_valid(instance.bufnr) then return false end
  local snapshot = M.snapshot(instance)
  local previous_view = instance.view or {}
  local old_nodes = {}
  for _, node in pairs(instance.nodes_by_id or {}) do old_nodes[#old_nodes + 1] = node end
  local ok, result = pcall(function()
    local previous_widths = previous_view.column_widths
    local current = vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)
    local patch
    if same_widths(previous_widths, prepared.column_widths) then
      local prefix = 0
      while prefix < #current and prefix < #prepared.lines
          and current[prefix + 1] == prepared.lines[prefix + 1] do
        prefix = prefix + 1
      end
      local suffix = 0
      while suffix < #current - prefix and suffix < #prepared.lines - prefix
          and current[#current - suffix] == prepared.lines[#prepared.lines - suffix] do
        suffix = suffix + 1
      end
      if prefix == #current and prefix == #prepared.lines then
        patch = { kind = "none" }
      else
        local replacement = {}
        for index = prefix + 1, #prepared.lines - suffix do
          replacement[#replacement + 1] = prepared.lines[index]
        end
        if not set_lines_raw(instance, prefix, #current - suffix, replacement) then
          return false
        end
        patch = {
          kind = "interval", start_row = prefix + 1,
          old_end_row = #current - suffix, new_end_row = #prepared.lines - suffix,
        }
      end
    else
      if not set_lines_raw(instance, 0, -1, prepared.lines) then return false end
      patch = { kind = "full", start_row = 1, old_end_row = -1, new_end_row = #prepared.lines }
    end

    vim.api.nvim_buf_clear_namespace(instance.bufnr, row_namespace, 0, -1)
    for _, node in ipairs(old_nodes) do node.row_extmark = nil end
    local rows_by_id = {}
    local row_offset = prepared.row_offset or 0
    for row, node in ipairs(prepared.visible_nodes) do
      local buffer_row = row + row_offset
      set_node_extmark(instance, node, buffer_row)
      rows_by_id[node.id] = buffer_row
    end
    vim.api.nvim_buf_clear_namespace(instance.bufnr, highlight_namespace, 0, -1)
    for _, highlight in ipairs(prepared.highlights or {}) do
      vim.api.nvim_buf_set_extmark(
        instance.bufnr, highlight_namespace, highlight.row, highlight.start_col, {
          end_col = highlight.end_col,
          hl_group = highlight.hl_group,
          priority = 100,
          undo_restore = false,
        }
      )
    end
    instance.view = {
      baseline = prepared.baseline,
      marker_widths = prepared.marker_widths,
      marker_generation = prepared.marker_generation,
      column_widths = prepared.column_widths,
      row_templates = prepared.row_templates,
      projection = prepared.projection,
      visible_nodes = prepared.visible_nodes,
      row_offset = prepared.row_offset,
      last_patch = patch,
      projection_generation = (previous_view.projection_generation or 0) + 1,
    }
    instance._marker_width_stale = prepared.marker_generation
      < instance.manager:get_marker_widths().generation
    vim.bo[instance.bufnr].modified = false
    restore_windows(instance, snapshot.windows, rows_by_id, false)
    local pending = {}
    for winid in pairs(instance._pending_initial_cursor or {}) do
      pending[#pending + 1] = winid
    end
    for _, winid in ipairs(pending) do M.place_initial_cursor(instance, winid) end
    return true
  end)
  if not ok or result == false then
    instance.view = previous_view
    local restore_ok, restore_err = pcall(M.restore, instance, snapshot)
    if not restore_ok then
      error(tostring(result) .. "; rollback failed: " .. tostring(restore_err), 0)
    end
    if not ok then error(result, 0) end
    return false
  end
  return true
end

function M.project(instance, projection, render_path)
  local prepared = M.prepare(instance, projection, render_path)
  return M.commit(instance, prepared)
end

local function row_highlight_templates(instance, line)
  local ok, identity = pcall(row.decode_marker, instance.manager, 0, line)
  if not ok then return nil end
  local source = identity.instance_id == instance.id and instance
    or instance.manager:find_by_id(identity.instance_id)
  if not source or source._destroyed then return nil end
  local templates = source.view and source.view.row_templates
  local template = templates and templates[identity.node_id]
  if not template then return nil end
  local result = {}
  for _, field in ipairs(template.fields or {}) do
    local highlight = field.highlight
    if highlight then result[#result + 1] = highlight end
  end
  return result
end

local function redecorate_rows(instance, first_row, last_row)
  if not vim.api.nvim_buf_is_valid(instance.bufnr) or last_row < first_row then return end
  local count = vim.api.nvim_buf_line_count(instance.bufnr)
  first_row = math.max(1, first_row)
  last_row = math.min(count, last_row)
  if last_row < first_row then return end
  vim.api.nvim_buf_clear_namespace(
    instance.bufnr, highlight_namespace, first_row - 1, last_row
  )
  local lines = vim.api.nvim_buf_get_lines(
    instance.bufnr, first_row - 1, last_row, false
  )
  for offset, line in ipairs(lines) do
    local templates = row_highlight_templates(instance, line)
    for _, template in ipairs(templates or {}) do
      if line:sub(template.start_col + 1, template.end_col) == template.text then
        vim.api.nvim_buf_set_extmark(
          instance.bufnr, highlight_namespace, first_row + offset - 2,
          template.start_col, {
            end_col = template.end_col,
            hl_group = template.hl_group,
            priority = 100,
            undo_restore = false,
          }
        )
      end
    end
  end
end

local function apply_pending_highlight_update(instance)
  instance._highlight_update_scheduled = false
  local pending = instance._highlight_pending
  instance._highlight_pending = nil
  if not pending or instance._highlight_disabled or instance._destroyed
      or instance.state == "destroying" or instance.state == "destroyed"
      or not vim.api.nvim_buf_is_valid(instance.bufnr) then
    return
  end

  local ok, err = pcall(function()
    if pending.full then
      vim.api.nvim_buf_clear_namespace(instance.bufnr, highlight_namespace, 0, -1)
      redecorate_rows(
        instance, 1, vim.api.nvim_buf_line_count(instance.bufnr)
      )
    else
      redecorate_rows(instance, pending.first_row, pending.last_row)
    end
  end)
  if ok then
    instance._highlight_error_reported = nil
  elseif not instance._highlight_error_reported then
    instance._highlight_error_reported = true
    instance:_report_async_error("column highlight update failed: " .. tostring(err))
  end
end

local function queue_highlight_update(instance, first_line, old_last_line, new_last_line)
  local pending = instance._highlight_pending
  if pending then
    -- Multiple edits before the scheduled pass can shift every prior range.
    pending.full = true
  else
    instance._highlight_pending = {
      full = old_last_line > new_last_line,
      first_row = first_line + 1,
      last_row = new_last_line,
    }
  end
  if instance._highlight_update_scheduled then return end
  instance._highlight_update_scheduled = true
  vim.schedule(function() apply_pending_highlight_update(instance) end)
end

local function attach_highlight_updates(instance)
  instance._highlight_disabled = false
  instance._highlight_pending = nil
  instance._highlight_update_scheduled = false
  local attached = vim.api.nvim_buf_attach(instance.bufnr, false, {
    on_lines = function(_, bufnr, _, first_line, old_last_line, new_last_line)
      if instance._highlight_disabled or instance._destroyed
          or instance.state == "destroying" or instance.state == "destroyed" then
        return true
      end
      if bufnr ~= instance.bufnr then return true end
      queue_highlight_update(instance, first_line, old_last_line, new_last_line)
    end,
    on_detach = function()
      instance._highlight_attached = false
      instance._highlight_pending = nil
      instance._highlight_update_scheduled = false
    end,
  })
  if not attached then fail("could not attach column highlight updates", 3) end
  instance._highlight_attached = true
end

function M.setup(instance)
  vim.api.nvim_set_hl(0, "FreStableMarker", { default = true, link = "Conceal" })
  vim.api.nvim_set_hl(0, "FreDirectoryIcon", { default = true, link = "Directory" })
  vim.api.nvim_set_hl(0, "FreSymlinkIcon", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "FreFileIcon", { default = true, link = "Normal" })
  vim.api.nvim_set_hl(0, "FreUnsupportedIcon", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_buf_call(instance.bufnr, function()
    vim.cmd("runtime! syntax/fre.vim")
  end)
  attach_highlight_updates(instance)

  local group_name = "FreBuffer" .. tostring(instance.bufnr)
  instance._buffer_augroup = vim.api.nvim_create_augroup(group_name, { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = instance._buffer_augroup, buffer = instance.bufnr,
    callback = function(args)
      local winid = vim.api.nvim_get_current_win()
      local row, col = 1, 0
      if vim.api.nvim_get_current_buf() == args.buf then
        local cursor = vim.api.nvim_win_get_cursor(winid)
        row, col = cursor[1], cursor[2]
      end
      require("fre.actions").write({
        instance = instance,
        bufnr = args.buf,
        winid = winid,
        tabpage = vim.api.nvim_get_current_tabpage(),
        mode = vim.api.nvim_get_mode().mode,
        row = row,
        col = col,
      })
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = instance._buffer_augroup, buffer = instance.bufnr,
    callback = function()
      if not instance._window_transition then instance:_on_visibility_enter() end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = instance._buffer_augroup, buffer = instance.bufnr,
    callback = function()
      local winid = vim.api.nvim_get_current_win()
      window.prepare(instance, winid)
      if instance._window_transition then return end
      M.place_initial_cursor(instance, winid)
      instance:_on_visibility_enter()
      if instance._pending_reveal then instance:_apply_pending_reveal(winid) end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = instance._buffer_augroup, buffer = instance.bufnr,
    callback = function()
      local winid = vim.api.nvim_get_current_win()
      if instance._pending_initial_cursor then
        instance._pending_initial_cursor[winid] = nil
      end
      window.release(instance, winid)
      vim.schedule(function() window.sync_visibility(instance) end)
    end,
  })
  vim.api.nvim_create_autocmd("BufModifiedSet", {
    group = instance._buffer_augroup, buffer = instance.bufnr,
    callback = function()
      if not instance._destroyed then instance.manager:gc_reconsider(instance, true) end
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = instance._buffer_augroup, buffer = instance.bufnr,
    callback = function() M.constrain_cursor(instance) end,
  })
  for _, event in ipairs({ "InsertEnter", "InsertCharPre", "CursorMovedI" }) do
    vim.api.nvim_create_autocmd(event, {
      group = instance._buffer_augroup, buffer = instance.bufnr,
      callback = function() M.constrain_cursor(instance) end,
    })
  end
end

function M.teardown(instance)
  instance._highlight_disabled = true
  instance._highlight_pending = nil
  if instance._buffer_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, instance._buffer_augroup)
    instance._buffer_augroup = nil
  end
end

M.namespace = row_namespace
return M
