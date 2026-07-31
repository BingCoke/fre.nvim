local row = require("fre.row")
local path = require("fre.path")
local window = require("fre.window")
local view = require("fre.view")

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

local function clear_undo_history(instance)
  local bufnr = instance.bufnr
  local was_modifiable = vim.bo[bufnr].modifiable
  local undolevels = vim.bo[bufnr].undolevels
  local ok, err = pcall(function()
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].undolevels = -1
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, { "" })
    vim.api.nvim_buf_set_lines(bufnr, line_count, line_count + 1, false, {})
    vim.bo[bufnr].modified = false
  end)
  local undo_ok, undo_err = pcall(function()
    vim.bo[bufnr].undolevels = undolevels
  end)
  local modifiable_ok, modifiable_err = pcall(function()
    vim.bo[bufnr].modifiable = was_modifiable
  end)
  if not ok then error(err, 0) end
  if not undo_ok then error(undo_err, 0) end
  if not modifiable_ok then error(modifiable_err, 0) end
end

local function managed_windows(instance)
  local windows = {}
  for _, inspected in ipairs(view.list(instance)) do
    windows[inspected.winid] = inspected.tabpage
  end
  return windows
end

local function capture_windows(instance)
  local windows = {}
  for winid in pairs(managed_windows(instance)) do
    pcall(function()
      local saved_view = vim.api.nvim_win_call(winid, vim.fn.winsaveview)
      local cursor = vim.api.nvim_win_get_cursor(winid)
      windows[winid] = { view = saved_view, cursor = cursor }
    end)
  end
  return windows
end

local function navigation_path(instance)
  return path.parent(instance.root) or instance.root
end

local function ancestor_paths(instance, absolute_path)
  local result = { absolute_path }
  local current = absolute_path
  while path.contains(instance.root, current) and not path.equal(current, instance.root) do
    current = path.parent(current)
    if not current then break end
    result[#result + 1] = current
  end
  return result
end

local function capture_view_cursors(instance)
  if not vim.api.nvim_buf_is_valid(instance.bufnr) then return {} end
  local baseline = instance.view and instance.view.baseline or {}
  local snapshots = {}
  for winid, tabpage in pairs(managed_windows(instance)) do
    pcall(function()
      local saved_view = vim.api.nvim_win_call(winid, vim.fn.winsaveview)
      local cursor = vim.api.nvim_win_get_cursor(winid)
      local line = get_line(instance, cursor[1])
      local decoded = row.decode_marker(instance.manager, cursor[1], line)
      if decoded.instance_id ~= instance.id then return end
      local semantic_ok, semantic = pcall(row.decode, instance, cursor[1], line, {
        allow_empty_path = true,
        validate_metadata = false,
      })
      local anchor
      if semantic_ok and semantic and semantic.marked then
        anchor = row.cursor_anchor(semantic, cursor[2])
      end
      local is_navigation = decoded.node_id == 0
      local absolute_path = is_navigation
        and navigation_path(instance) or baseline[decoded.node_id]
      if type(absolute_path) ~= "string" or absolute_path == "" then return end
      snapshots[#snapshots + 1] = {
        winid = winid,
        tabpage = tabpage,
        navigation = is_navigation,
        paths = ancestor_paths(instance, absolute_path),
        old_row = cursor[1],
        old_topline = saved_view.topline,
        column = cursor[2],
        anchor = anchor,
        view = saved_view,
      }
    end)
  end
  return snapshots
end

local function restore_view_cursors(instance, snapshots, prepared)
  if not vim.api.nvim_buf_is_valid(instance.bufnr) then return end
  local count = vim.api.nvim_buf_line_count(instance.bufnr)
  if count < 1 then return end
  local rows_by_path = {}
  local row_offset = prepared.row_offset or 0
  local visible_nodes = prepared.visible_nodes or {}
  for index, node in ipairs(visible_nodes) do
    if type(node.path) == "string" and rows_by_path[node.path] == nil then
      rows_by_path[node.path] = index + row_offset
    end
  end
  local first_entry_row
  if visible_nodes[1] then
    local candidate = row_offset + 1
    local decoded_ok, decoded = pcall(M.decode, instance, candidate)
    if decoded_ok and decoded and decoded.row_kind == "entry"
        and decoded.instance_id == instance.id then
      first_entry_row = candidate
    end
  end
  local navigation_row
  if row_offset > 0 then
    local decoded_ok, decoded = pcall(M.decode, instance, 1)
    if decoded_ok and decoded and decoded.row_kind == "navigation"
        and decoded.instance_id == instance.id then
      navigation_row = 1
    end
  end
  for _, saved in ipairs(snapshots or {}) do
    local natural_view
    local ok = pcall(function()
      if not vim.api.nvim_win_is_valid(saved.winid)
          or vim.api.nvim_win_get_buf(saved.winid) ~= instance.bufnr then return end
      local row_number
      if saved.navigation then
        row_number = navigation_row
      else
        for _, absolute_path in ipairs(saved.paths or {}) do
          row_number = rows_by_path[absolute_path]
          if row_number then break end
        end
        row_number = row_number or first_entry_row
      end
      if not row_number then return end
      row_number = math.max(1, math.min(row_number, count))
      local line = vim.api.nvim_buf_get_lines(
        instance.bufnr, row_number - 1, row_number, false
      )[1] or ""
      local col = math.max(0, math.min(saved.column or 0, #line))
      local semantic_mapped = false
      if saved.anchor then
        local decoded_ok, decoded = pcall(row.decode, instance, row_number, line, {
          allow_empty_path = true,
          validate_metadata = false,
        })
        if decoded_ok and decoded and decoded.marked then
          local mapped_col = row.cursor_column(decoded, saved.anchor)
          if mapped_col ~= nil then
            col = mapped_col
            semantic_mapped = true
          end
        end
      end
      col = math.max(0, math.min(col, #line))
      vim.api.nvim_win_call(saved.winid, function()
        natural_view = vim.fn.winsaveview()
        vim.api.nvim_win_set_cursor(0, { row_number, col })
        local restored = vim.deepcopy(saved.view)
        restored.lnum = row_number
        restored.col = col
        restored.topline = math.max(1, math.min(
          (saved.old_topline or 1) + row_number - saved.old_row, count
        ))
        if semantic_mapped then
          restored.coladd = 0
          restored.curswant = vim.fn.winsaveview().curswant
        end
        vim.fn.winrestview(restored)
        M.constrain_cursor(instance, saved.winid)
      end)
    end)
    if not ok and natural_view then
      pcall(vim.api.nvim_win_call, saved.winid, function()
        vim.fn.winrestview(natural_view)
      end)
    end
  end
end

local function restore_windows(instance, windows)
  if not vim.api.nvim_buf_is_valid(instance.bufnr) then return end
  for winid, saved in pairs(windows or {}) do
    pcall(function()
      if not vim.api.nvim_win_is_valid(winid)
          or vim.api.nvim_win_get_buf(winid) ~= instance.bufnr then return end
      local count = vim.api.nvim_buf_line_count(instance.bufnr)
      local row_number = math.max(1, math.min(saved.cursor[1], count))
      local line = vim.api.nvim_buf_get_lines(
        instance.bufnr, row_number - 1, row_number, false
      )[1] or ""
      local restored = vim.deepcopy(saved.view)
      restored.lnum = row_number
      restored.col = math.max(0, math.min(saved.cursor[2], #line))
      restored.topline = math.max(1, math.min(restored.topline or 1, count))
      vim.api.nvim_win_call(winid, function() vim.fn.winrestview(restored) end)
    end)
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
  restore_windows(instance, snapshot.windows)
  return true
end

function M.commit(instance, prepared)
  if not vim.api.nvim_buf_is_valid(instance.bufnr) then return false end
  local captured, cursor_snapshots = pcall(capture_view_cursors, instance)
  if not captured then cursor_snapshots = {} end
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
    local row_offset = prepared.row_offset or 0
    for row, node in ipairs(prepared.visible_nodes) do
      local buffer_row = row + row_offset
      set_node_extmark(instance, node, buffer_row)
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
    vim.bo[instance.bufnr].modified = false
    pcall(restore_view_cursors, instance, cursor_snapshots, prepared)
    local pending = {}
    for winid in pairs(instance._pending_initial_cursor or {}) do
      pending[#pending + 1] = winid
    end
    for _, winid in ipairs(pending) do M.place_initial_cursor(instance, winid) end
    instance._marker_width_stale = prepared.marker_generation
      < instance.manager:get_marker_widths().generation
    clear_undo_history(instance)
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
    local row_number = first_row + offset - 1
    local ok, decorations = pcall(row.decorations, instance, row_number, line)
    for _, template in ipairs(ok and decorations or {}) do
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

local function externally_deleted(instance)
  if instance.state == "destroyed" or instance._external_delete_cleanup_scheduled then return end
  instance._external_delete_cleanup_scheduled = true
  local ok, err = pcall(vim.schedule, function()
    if instance.state == "destroyed" then
      instance._external_delete_cleanup_scheduled = nil
      return
    end

    if instance.state ~= "destroying" then
      local start_ok, start_err = pcall(instance._start_destroy, instance)
      if not start_ok then
        if type(instance._report_async_error) == "function" then
          instance:_report_async_error(
            "external buffer deletion cleanup start failed: " .. tostring(start_err)
          )
        end
        if instance.state ~= "destroying" then
          instance._external_delete_cleanup_scheduled = nil
          return
        end
      end
    end

    local finish_ok, finish_err = pcall(instance._finish_destroy, instance)
    if not finish_ok and type(instance._report_async_error) == "function" then
      instance:_report_async_error(
        "external buffer deletion cleanup finish failed: " .. tostring(finish_err)
      )
    end
    instance._external_delete_cleanup_scheduled = nil
  end)
  if not ok then
    instance._external_delete_cleanup_scheduled = nil
    instance:_report_async_error(
      "external buffer deletion cleanup scheduling failed: " .. tostring(err)
    )
  end
end

function M.setup(instance)
  vim.api.nvim_set_hl(0, "FreStableMarker", { default = true, link = "Conceal" })
  vim.api.nvim_set_hl(0, "FreDirectoryIcon", { default = true, link = "Directory" })
  vim.api.nvim_set_hl(0, "FreSymlinkIcon", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "FreFileIcon", { default = true, link = "Normal" })
  vim.api.nvim_set_hl(0, "FreUnsupportedIcon", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "FreDirectoryPath", { default = true, link = "Directory" })
  vim.api.nvim_set_hl(0, "FreHiddenPath", { default = true, link = "Comment" })
  vim.api.nvim_buf_call(instance.bufnr, function()
    vim.cmd("runtime! syntax/fre.vim")
  end)
  attach_highlight_updates(instance)

  local group_name = "FreBuffer" .. tostring(instance.bufnr)
  instance._buffer_augroup = vim.api.nvim_create_augroup(group_name, { clear = true })
  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = instance._buffer_augroup, buffer = instance.bufnr,
    callback = function() externally_deleted(instance) end,
  })

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

  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = instance._buffer_augroup, buffer = instance.bufnr,
    callback = function()
      local winid = vim.api.nvim_get_current_win()
      window.apply(instance, winid)
      view.sync(instance, { report = true })
      M.place_initial_cursor(instance, winid)
    end,
  })
  vim.api.nvim_create_autocmd({ "WinLeave", "BufWinLeave", "BufHidden" }, {
    group = instance._buffer_augroup, buffer = instance.bufnr,
    callback = function()
      local winid = vim.api.nvim_get_current_win()
      if instance._pending_initial_cursor then
        instance._pending_initial_cursor[winid] = nil
      end
      vim.schedule(function()
        if instance._destroyed then return end
        view.sync(instance, { report = true })
      end)
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
