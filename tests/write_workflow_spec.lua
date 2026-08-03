local actions = require("fre.actions")
local buffer = require("fre.instance.buffer")
local fre = require("fre")
local mutation_fs = require("fre.mutation.fs")
local real_fs = require("fre.fs").default
local write_ui = require("fre.write_ui")
local fs = require("tests.helpers.fs")

local fixture
local instances = {}
local original_notify
local active_ui
local ui_adapter
local active_mutation
local mutation_adapter
local active_load
local fs_adapter

local function keep(instance)
  instances[#instances + 1] = instance
  return instance
end

local function wait_for(predicate)
  assert.is_true(vim.wait(3000, predicate, 10))
end

local function wait_ready(instance)
  wait_for(function()
    return instance:status() == "ready"
      or instance:status() == "load-failed"
  end)
  assert.are_not.equal("load-failed", instance:status(), tostring(instance:failure()))
  return instance
end

local function ready(entries, opts)
  fixture:tree(entries or {})
  opts = vim.tbl_extend("force", { root = fixture.root, columns = {} }, opts or {})
  return wait_ready(keep(fre.new(opts)))
end

local function lines(instance)
  return vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)
end

local function set_lines(instance, replacement)
  local navigation = lines(instance)[1]
  assert.are.equal("navigation", assert(instance.buffer:decode(1)).row_kind)
  local next_lines = {}
  if replacement[1] ~= navigation then next_lines[1] = navigation end
  vim.list_extend(next_lines, replacement)
  local modifiable = vim.bo[instance.bufnr].modifiable
  vim.bo[instance.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(instance.bufnr, 0, -1, false, next_lines)
  vim.bo[instance.bufnr].modifiable = modifiable
end

local function row_for(instance, relative)
  for row = 1, vim.api.nvim_buf_line_count(instance.bufnr) do
    local decoded = instance.buffer:decode(row)
    if decoded and decoded.row_kind == "entry"
        and decoded.entry.relative_path == relative then
      return row
    end
  end
  error("missing row " .. relative)
end

local function physical_line(instance, relative)
  return lines(instance)[row_for(instance, relative)]
end

local function edited_line(instance, relative, target)
  local row = row_for(instance, relative)
  local physical = lines(instance)[row]
  local decoded = instance.buffer:decode(row)
  return physical:sub(1, decoded.path_range.start_byte) .. target
    .. physical:sub(decoded.path_range.end_byte + 1)
end

local function projected_paths(instance)
  local result = {}
  for row = 1, vim.api.nvim_buf_line_count(instance.bufnr) do
    local decoded = assert(instance.buffer:decode(row))
    if decoded.row_kind == "entry" then result[#result + 1] = decoded.path end
  end
  return result
end

local function error_text(callback)
  local ok, err = pcall(callback)
  assert.is_false(ok)
  return tostring(err)
end

local function write_command(instance)
  return pcall(vim.api.nvim_buf_call, instance.bufnr, function() vim.cmd("write") end)
end

local function wait_unlocked(instance)
  wait_for(function()
    return not instance.work:is_write_active()
      and not instance.work:is_execution_active() and not instance.sync:is_busy()
  end)
end

local function resource_snapshot()
  local snapshot = { buffers = {}, windows = {} }
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then snapshot.buffers[#snapshot.buffers + 1] = bufnr end
  end
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then snapshot.windows[#snapshot.windows + 1] = winid end
  end
  table.sort(snapshot.buffers)
  table.sort(snapshot.windows)
  return snapshot
end

local function with_override(owner, key, replacement, callback)
  local original = owner[key]
  owner[key] = replacement(original)
  local first, second
  local ok, err = pcall(function() first, second = callback() end)
  owner[key] = original
  if not ok then error(err, 0) end
  return first, second
end

local function invoke_mapping(bufnr, lhs)
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if mapping.lhs == lhs and type(mapping.callback) == "function" then
      mapping.callback()
      return
    end
  end
  error("missing buffer mapping " .. lhs)
end

local function wait_for_float()
  local result
  wait_for(function()
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(winid).relative ~= "" then
        result = { winid = winid, bufnr = vim.api.nvim_win_get_buf(winid) }
        return true
      end
    end
    return false
  end)
  return result
end

local function scripted_ui(opts)
  opts = opts or {}
  local ui = {
    confirmations = {},
    progress_statuses = {},
    reports = {},
    confirmation_closes = 0,
    progress_closes = 0,
  }
  function ui.confirm(_ctx, display, on_decision)
    if opts.confirm_error then error(opts.confirm_error) end
    ui.confirmations[#ui.confirmations + 1] = vim.deepcopy(display)
    ui.decide = on_decision
    local handle = {}
    function handle:close()
      ui.confirmation_closes = ui.confirmation_closes + 1
      if opts.confirm_close_error then error(opts.confirm_close_error) end
    end
    if opts.accept_synchronously then on_decision(true) end
    return handle
  end
  function ui.progress(_ctx, status, on_cancel)
    if opts.progress_error then error(opts.progress_error) end
    ui.progress_statuses[#ui.progress_statuses + 1] = vim.deepcopy(status)
    ui.cancel_progress = on_cancel
    local handle = {}
    function handle:update(next_status)
      ui.progress_statuses[#ui.progress_statuses + 1] = vim.deepcopy(next_status)
      if opts.update_error then error(opts.update_error) end
    end
    function handle:close()
      ui.progress_closes = ui.progress_closes + 1
      if opts.progress_close_error then error(opts.progress_close_error) end
    end
    ui.progress_handle = handle
    return handle
  end
  function ui.report(_ctx, outcome, reconciliation_error)
    ui.reports[#ui.reports + 1] = {
      outcome = outcome and vim.deepcopy(outcome) or nil,
      reconciliation_error = reconciliation_error,
    }
    if opts.report_error then error(opts.report_error) end
  end
  active_ui = ui
  return ui
end

local function complete_adapter()
  local function done_now(_, done) done(nil) end
  return {
    create_file = done_now,
    create_directory = done_now,
    copy = function(_, _, _, done) done(nil) end,
    move = function(_, _, done) done(nil) end,
    delete = function(_, _, done) done(nil) end,
  }
end

local function pending_adapter(pending)
  local function hold(name, done, report)
    pending[#pending + 1] = { name = name, done = done, report = report }
  end
  return {
    create_file = function(path, done, report) hold(path, done, report) end,
    create_directory = function(path, done, report) hold(path, done, report) end,
    copy = function(from, _, _, done, report) hold(from, done, report) end,
    move = function(from, _, done, report) hold(from, done, report) end,
    delete = function(path, _, done, report) hold(path, done, report) end,
  }
end

describe("fre ticket 11 write workflow", function()
  before_each(function()
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
    fixture = fs.new()
    instances = {}
    original_notify = vim.notify
    vim.notify = function() end
    active_ui = write_ui
    ui_adapter = {
      confirm = function(...) return active_ui.confirm(...) end,
      progress = function(...) return active_ui.progress(...) end,
      report = function(...)
        if type(active_ui.report) == "function" then return active_ui.report(...) end
      end,
    }
    actions._set_ui_adapter(ui_adapter)
    active_load = real_fs.load
    fs_adapter = { load = function(...) return active_load(...) end }
    fre._set_fs_adapter(fs_adapter)
    active_mutation = mutation_fs.default
    mutation_adapter = {
      create_file = function(...) return active_mutation.create_file(...) end,
      create_directory = function(...) return active_mutation.create_directory(...) end,
      copy = function(...) return active_mutation.copy(...) end,
      move = function(...) return active_mutation.move(...) end,
      delete = function(...) return active_mutation.delete(...) end,
    }
    fre._set_mutation_adapter(mutation_adapter)
  end)

  after_each(function()
    actions._reset_ui_adapter()
    fre._reset_fs_adapter()
    fre._reset_mutation_adapter()
    vim.notify = original_notify
    for _, instance in ipairs(instances) do
      if instance.work and instance.work:is_write_active() then
        local execution = instance.work:active_execution()
        if execution then pcall(execution.cancel, execution) end
        vim.wait(500, function()
          return not instance.work or not instance.work:is_write_active()
        end, 10)
      end
      if instance:status() ~= "destroyed" then pcall(instance.destroy, instance) end
    end
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
    fixture:cleanup()
  end)

  it("routes actual BufWriteCmd through confirmation, real mutations, and successful truth reconciliation", function()
    local instance = ready({ ["a.txt"] = "a", ["delete.txt"] = "d" })
    assert.are.equal(mutation_adapter, instance.work.mutation_adapter)
    assert.are.equal(ui_adapter, instance.work.write_ui_adapter)
    local ui = scripted_ui()
    set_lines(instance, {
      edited_line(instance, "a.txt", "moved.txt"),
      "created.txt",
    })

    local ok, err = write_command(instance)
    assert.is_true(ok, tostring(err))
    assert.are.same({ "MOVE  a.txt -> moved.txt", "CREATE FILE  created.txt", "DELETE  delete.txt" },
      ui.confirmations[1])
    assert.is_false(vim.bo[instance.bufnr].modifiable)
    ui.decide(true)
    wait_unlocked(instance)

    assert.is_nil(vim.uv.fs_lstat(fixture:path("a.txt")))
    assert.is_nil(vim.uv.fs_lstat(fixture:path("delete.txt")))
    assert.is_not_nil(vim.uv.fs_lstat(fixture:path("moved.txt")))
    assert.is_not_nil(vim.uv.fs_lstat(fixture:path("created.txt")))
    assert.are.same({ "created.txt", "moved.txt" }, projected_paths(instance))
    assert.is_false(vim.bo[instance.bufnr].modified)
    assert.is_true(vim.bo[instance.bufnr].modifiable)
    local reconciled = lines(instance)
    vim.api.nvim_buf_call(instance.bufnr, function() vim.cmd("silent! undo") end)
    assert.are.same(reconciled, lines(instance))
    assert.is_false(vim.bo[instance.bufnr].modified)
    local result = instance.work:last_write_result()
    assert.are.equal("succeeded", result.execution.state)
    assert.is_nil(result.reconciliation_error)
  end)

  it("skips confirmation at the exact Oil-style simple-edit limits", function()
    local instance = ready({ ["move.txt"] = "move", ["copy.txt"] = "copy" }, {
      skip_confirm_for_simple_edits = true,
    })
    local ui = scripted_ui()
    set_lines(instance, {
      edited_line(instance, "move.txt", "moved.txt"),
      physical_line(instance, "copy.txt"),
      edited_line(instance, "copy.txt", "copied.txt"),
      "created-1.txt",
      "created-2.txt",
      "created-3.txt",
      "created-4.txt",
      "created-dir/",
    })

    local counts = {}
    for _, operation in ipairs(instance:prepare().operations) do
      counts[operation.type] = (counts[operation.type] or 0) + 1
    end
    assert.are.same({
      copy = 1,
      create_directory = 1,
      create_file = 4,
      move = 1,
    }, counts)

    assert.is_true(write_command(instance))
    wait_unlocked(instance)
    assert.are.equal(0, #ui.confirmations)
    assert.is_nil(vim.uv.fs_lstat(fixture:path("move.txt")))
    assert.is_not_nil(vim.uv.fs_lstat(fixture:path("moved.txt")))
    assert.is_not_nil(vim.uv.fs_lstat(fixture:path("copy.txt")))
    assert.is_not_nil(vim.uv.fs_lstat(fixture:path("copied.txt")))
    for index = 1, 4 do
      assert.is_not_nil(vim.uv.fs_lstat(fixture:path("created-" .. index .. ".txt")))
    end
    assert.are.equal("directory", vim.uv.fs_lstat(fixture:path("created-dir")).type)
    assert.are.equal("succeeded", instance.work:last_write_result().execution.state)
  end)

  it("keeps confirmation for deletes, unknown operations, and edits beyond simple limits", function()
    local function operation_counts(instance)
      local counts = {}
      for _, operation in ipairs(instance:prepare().operations) do
        counts[operation.type] = (counts[operation.type] or 0) + 1
      end
      return counts
    end

    local function expect_confirmation(expected, replacement)
      local instance = ready({ ["a.txt"] = "a", ["b.txt"] = "b" }, {
        skip_confirm_for_simple_edits = true,
      })
      local ui = scripted_ui()
      set_lines(instance, replacement(instance))
      assert.are.same(expected, operation_counts(instance))
      assert.is_true(write_command(instance))
      assert.are.equal(1, #ui.confirmations)
      ui.decide(false)
      assert.is_false(instance.work:is_write_active())
    end

    expect_confirmation({ delete = 1 }, function(instance)
      return { physical_line(instance, "b.txt") }
    end)
    expect_confirmation({ move = 2 }, function(instance)
      return {
        edited_line(instance, "a.txt", "moved-a.txt"),
        edited_line(instance, "b.txt", "moved-b.txt"),
      }
    end)
    expect_confirmation({ copy = 2 }, function(instance)
      return {
        physical_line(instance, "a.txt"),
        edited_line(instance, "a.txt", "copied-a.txt"),
        physical_line(instance, "b.txt"),
        edited_line(instance, "b.txt", "copied-b.txt"),
      }
    end)
    expect_confirmation({ create_file = 6 }, function(instance)
      local replacement = {
        physical_line(instance, "a.txt"),
        physical_line(instance, "b.txt"),
      }
      for index = 1, 6 do replacement[#replacement + 1] = "created-" .. index .. ".txt" end
      return replacement
    end)

    local unknown = ready({}, { skip_confirm_for_simple_edits = true })
    local ui = scripted_ui()
    unknown.work._prepare = function()
      return { operations = { { type = "future_operation" } }, display = { "FUTURE" } }
    end
    assert.is_true(write_command(unknown))
    assert.are.same({ "FUTURE" }, ui.confirmations[1])
    ui.decide(false)
    assert.is_false(unknown.work:is_write_active())
  end)

  it("holds one nonmodifiable lock, rejects mutators, and allows snapshot lookup, reveal, and windows", function()
    local instance = ready({ ["a.txt"] = "a", ["dir/child.txt"] = "child" })
    local ui = scripted_ui()
    local pending = {}
    active_mutation = pending_adapter(pending)
    set_lines(instance, {
      physical_line(instance, "a.txt"), physical_line(instance, "dir"), "held.txt",
    })
    assert.is_true(write_command(instance))
    ui.decide(true)

    assert.are.equal(1, #ui.progress_statuses)
    assert.are.equal("running", ui.progress_statuses[1].state)
    assert.is_true(instance.work:is_write_active())
    assert.is_false(vim.bo[instance.bufnr].modifiable)
    local second_write_ok, second_write_error = write_command(instance)
    assert.is_false(second_write_ok)
    assert.is_truthy(tostring(second_write_error):find("write%-locked"), tostring(second_write_error))
    local rejected = {
      function() actions.write({ instance = instance, bufnr = instance.bufnr }) end,
      function() instance:expand("dir") end,
      function() instance:collapse("dir") end,
      function() instance:toggle_expand("dir") end,
      function() instance:set_hidden_file(true) end,
      function() instance:set_sort(function() return false end) end,
      function() instance:refresh({ force = true }) end,
      function() instance:destroy() end,
      function() instance:execute({ operations = {} }) end,
      function() instance:prepare() end,
      function() instance:reveal("dir/child.txt") end,
    }
    for _, operation in ipairs(rejected) do
      assert.is_truthy(error_text(operation):find("write%-locked"))
    end

    assert.is_table(instance:get_entry(row_for(instance, "a.txt")))
    assert.is_table(instance:get_pos("a.txt"))
    assert.is_nil(instance:reveal("a.txt"))
    assert.are.equal(instance, instance:open())
    assert.is_true(instance:hidden())

    wait_for(function() return pending[1] ~= nil end)
    pending[1].done(nil)
    wait_unlocked(instance)
    assert.is_true(vim.bo[instance.bufnr].modifiable)
  end)

  it("releases exactly after a prepare error while preserving the exact modified draft", function()
    local instance = ready({ ["a.txt"] = "a" })
    local ui = scripted_ui()
    local draft = {
      lines(instance)[1], string.char(31) .. "fre:malformed", " exact second line ",
    }
    set_lines(instance, draft)
    local ok, err = write_command(instance)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("row 2", 1, true), tostring(err))
    assert.are.same(draft, lines(instance))
    assert.is_true(vim.bo[instance.bufnr].modified)
    assert.is_true(vim.bo[instance.bufnr].modifiable)
    assert.is_false(instance.work:is_write_active())
    assert.are.equal(0, #ui.confirmations)
    assert.are.equal(0, #ui.progress_statuses)
    assert.is_false(instance.work:is_execution_active())
  end)

  it("passes display lines verbatim and cancellation preserves the draft without execution", function()
    local instance = ready({ ["a.txt"] = "a" })
    local ui = scripted_ui()
    active_mutation = complete_adapter()
    local draft = {
      lines(instance)[1], physical_line(instance, "a.txt"), "new name  with spaces.txt",
    }
    set_lines(instance, draft)
    assert.is_true(write_command(instance))
    assert.are.same({ "CREATE FILE  new name  with spaces.txt" }, ui.confirmations[1])
    ui.decide(false)

    assert.are.same(draft, lines(instance))
    assert.is_true(vim.bo[instance.bufnr].modified)
    assert.is_true(vim.bo[instance.bufnr].modifiable)
    assert.is_false(instance.work:is_write_active())
    assert.is_false(instance.work:is_execution_active())
    assert.are.equal(0, #ui.progress_statuses)
    assert.are.equal(1, ui.confirmation_closes)
  end)

  it("uses verbatim default confirmation and cancels progress only on explicit close", function()
    active_ui = write_ui
    local decision
    local display = { "literal  one", "NOT DERIVED -> \"two\"" }
    local confirmation = write_ui.confirm({}, display, function(value) decision = value end)
    assert.are.same(display, vim.api.nvim_buf_get_lines(confirmation.bufnr, 0, -1, false))
    vim.api.nvim_win_close(confirmation.winid, true)
    wait_for(function() return decision ~= nil end)
    assert.is_false(decision)

    local base_win = vim.api.nvim_get_current_win()
    local cancel_count = 0
    local progress = write_ui.progress({}, {
      state = "running", completed = 1, total = 3,
      current = { type = "move", from = "a", to = "b" },
      detail = { phase = "rename" },
    }, function() cancel_count = cancel_count + 1 end)
    assert.is_truthy(vim.api.nvim_buf_get_lines(progress.bufnr, 0, -1, false)[3]:find("move", 1, true))
    vim.api.nvim_set_current_win(base_win)
    vim.wait(30, function() return false end, 10)
    assert.are.equal(0, cancel_count)
    vim.api.nvim_win_close(progress.winid, true)
    wait_for(function() return cancel_count == 1 end)

    local completion_cancel = 0
    local completed = write_ui.progress({}, { state = "succeeded", completed = 1, total = 1 },
      function() completion_cancel = completion_cancel + 1 end)
    completed:close()
    vim.wait(30, function() return false end, 10)
    assert.are.equal(0, completion_cancel)
  end)

  it("refocuses the restored caller without overriding a later window selection", function()
    active_ui = write_ui
    local instance = ready({ ["a.txt"] = "a" })
    instance:open({ position = "current" })
    set_lines(instance, { physical_line(instance, "a.txt"), "new.txt" })
    local caller_win = vim.api.nvim_get_current_win()

    assert.is_true(write_command(instance))
    local confirmation
    wait_for(function()
      for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(winid).relative ~= "" then
          confirmation = { winid = winid, bufnr = vim.api.nvim_win_get_buf(winid) }
          return true
        end
      end
      return false
    end)
    vim.api.nvim_set_current_win(caller_win)
    wait_for(function() return vim.api.nvim_get_current_win() == confirmation.winid end)
    invoke_mapping(confirmation.bufnr, "q")
    wait_unlocked(instance)

    local source_win = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local alternate_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(source_win)

    local second = ready({ ["a.txt"] = "a" })
    second:open({ position = "current" })
    set_lines(second, { physical_line(second, "a.txt"), "other.txt" })
    assert.is_true(write_command(second))
    local second_confirmation
    wait_for(function()
      for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(winid).relative ~= "" then
          second_confirmation = { winid = winid, bufnr = vim.api.nvim_win_get_buf(winid) }
          return true
        end
      end
      return false
    end)
    vim.api.nvim_set_current_win(alternate_win)
    vim.wait(50, function() return false end, 10)
    assert.are.equal(alternate_win, vim.api.nvim_get_current_win())

    invoke_mapping(second_confirmation.bufnr, "q")
    wait_unlocked(second)
  end)

  it("rolls back partial scratch floats when window creation or float autocmd initialization throws", function()
    local function expect_construction_failure(label, api_name, replacement)
      local instance = ready({ ["a.txt"] = "a" })
      local draft = {
        lines(instance)[1], physical_line(instance, "a.txt"), label .. ".txt",
      }
      set_lines(instance, draft)
      local original_modifiable = vim.bo[instance.bufnr].modifiable
      local before = resource_snapshot()
      local ok, err = with_override(vim.api, api_name, replacement, function()
        return write_command(instance)
      end)

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find(label, 1, true), tostring(err))
      assert.are.same(before, resource_snapshot())
      assert.are.same(draft, lines(instance))
      assert.is_true(vim.bo[instance.bufnr].modified)
      assert.are.equal(original_modifiable, vim.bo[instance.bufnr].modifiable)
      assert.is_false(instance.work:is_write_active())
      assert.is_false(instance.work:is_execution_active())
    end

    expect_construction_failure("open window exploded", "nvim_open_win", function(original)
      return function(...)
        original(...)
        error("open window exploded")
      end
    end)
    expect_construction_failure("float autocmd exploded", "nvim_create_autocmd", function(original)
      return function(...)
        original(...)
        error("float autocmd exploded")
      end
    end)
  end)

  it("closes a live confirmation float when post-return keymap initialization throws", function()
    local instance = ready({ ["a.txt"] = "a" })
    local draft = {
      lines(instance)[1], physical_line(instance, "a.txt"), "confirm-keymap.txt",
    }
    set_lines(instance, draft)
    local original_modifiable = vim.bo[instance.bufnr].modifiable
    local before = resource_snapshot()
    local ok, err = with_override(vim.keymap, "set", function(original)
      return function(...)
        original(...)
        error("confirm keymap exploded")
      end
    end, function()
      return write_command(instance)
    end)

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("confirm keymap exploded", 1, true), tostring(err))
    assert.are.same(before, resource_snapshot())
    assert.are.same(draft, lines(instance))
    assert.is_true(vim.bo[instance.bufnr].modified)
    assert.are.equal(original_modifiable, vim.bo[instance.bufnr].modifiable)
    assert.is_false(instance.work:is_write_active())
    assert.is_false(instance.work:is_execution_active())
  end)

  it("closes progress floats and safely terminalizes Execution when progress initialization throws", function()
    local cases = {
      {
        name = "progress-autocmd",
        owner = vim.api,
        key = "nvim_create_autocmd",
        replacement = function(original)
          local calls = 0
          return function(...)
            calls = calls + 1
            local result = original(...)
            if calls == 3 then error("progress autocmd exploded") end
            return result
          end
        end,
      },
      {
        name = "progress-keymap",
        owner = vim.keymap,
        key = "set",
        replacement = function(original)
          local calls = 0
          return function(...)
            calls = calls + 1
            local result = original(...)
            if calls == 5 then error("progress keymap exploded") end
            return result
          end
        end,
      },
    }

    for _, case in ipairs(cases) do
      local instance = ready({ ["a.txt"] = "a" })
      local baseline = lines(instance)
      set_lines(instance, { physical_line(instance, "a.txt"), case.name .. ".txt" })
      local original_modifiable = vim.bo[instance.bufnr].modifiable
      local before = resource_snapshot()
      local execution = with_override(case.owner, case.key, case.replacement, function()
        local ok, err = write_command(instance)
        assert.is_true(ok, tostring(err))
        local confirmation = wait_for_float()
        invoke_mapping(confirmation.bufnr, "y")
        return assert(instance.work:active_execution())
      end)

      assert.are.equal("canceling", execution:get_status().state)
      wait_unlocked(instance)
      assert.are.same(before, resource_snapshot())
      assert.are.same(baseline, lines(instance))
      assert.is_false(vim.bo[instance.bufnr].modified)
      assert.are.equal(original_modifiable, vim.bo[instance.bufnr].modifiable)
      assert.are.equal("canceled", execution:get_status().state)
      assert.are.equal("canceled", instance.work:last_write_result().execution.state)
      assert.is_nil(vim.uv.fs_lstat(fixture:path(case.name .. ".txt")))
      assert.is_false(instance.work:is_write_active())
      assert.is_false(instance.work:is_execution_active())
      assert.is_false(instance.sync:is_busy())
    end
  end)

  it("reconciles partial filesystem truth after a failed execution", function()
    local instance = ready({ ["keep.txt"] = "keep" })
    local ui = scripted_ui()
    local count = 0
    local adapter = mutation_fs.default
    active_mutation = {
      create_file = function(path, done, report)
        count = count + 1
        if count == 2 then done("forced second create failure", nil, false); return end
        return adapter.create_file(path, done, report)
      end,
      create_directory = adapter.create_directory,
      copy = adapter.copy,
      move = adapter.move,
      delete = adapter.delete,
    }
    set_lines(instance, { physical_line(instance, "keep.txt"), "first.txt", "second.txt" })
    assert.is_true(write_command(instance))
    ui.decide(true)
    wait_unlocked(instance)

    assert.is_not_nil(vim.uv.fs_lstat(fixture:path("first.txt")))
    assert.is_nil(vim.uv.fs_lstat(fixture:path("second.txt")))
    assert.are.same({ "first.txt", "keep.txt" }, projected_paths(instance))
    assert.is_false(vim.bo[instance.bufnr].modified)
    local result = instance.work:last_write_result()
    assert.are.equal("failed", result.execution.state)
    assert.is_truthy(tostring(result.execution.error)
      :find("forced second create failure", 1, true))
    assert.are.equal("failed", ui.reports[1].outcome.state)
  end)

  it("shows progress immediately, ignores focus loss, and explicit progress close cancels then reconciles", function()
    local instance = ready({})
    local ui = scripted_ui()
    active_mutation = {
      create_file = function(path, done)
        return {
          cancel = function()
            local relative = vim.fs.basename(path)
            fixture:write(relative, "partial")
            done(nil, { phase = "canceled after effect" }, true, true)
            return true
          end,
        }
      end,
      create_directory = function(_, done) done(nil) end,
      copy = function(_, _, _, done) done(nil) end,
      move = function(_, _, done) done(nil) end,
      delete = function(_, _, done) done(nil) end,
    }
    set_lines(instance, { "partial.txt" })
    assert.is_true(write_command(instance))
    ui.decide(true)
    assert.are.equal(1, #ui.progress_statuses)
    vim.wait(30, function() return false end, 10)
    assert.are.equal("running", instance.work:active_execution():get_status().state)
    assert.is_true(instance.work:is_write_active())

    ui.cancel_progress()
    wait_unlocked(instance)
    assert.is_not_nil(vim.uv.fs_lstat(fixture:path("partial.txt")))
    assert.are.same({ "partial.txt" }, projected_paths(instance))
    assert.are.equal("canceled", instance.work:last_write_result().execution.state)
    assert.is_false(vim.bo[instance.bufnr].modified)
    assert.are.equal(1, ui.progress_closes)
  end)

  it("preserves execution and refresh errors, unlocks, and supports forced truth recovery", function()
    local instance = ready({ ["keep.txt"] = "keep" })
    local ui = scripted_ui()
    local draft = {
      lines(instance)[1], physical_line(instance, "keep.txt"), "actual.txt",
    }
    set_lines(instance, draft)
    assert.is_true(write_command(instance))
    active_load = function(_, done) done("forced reconciliation failure") end
    ui.decide(true)
    wait_unlocked(instance)

    assert.is_not_nil(vim.uv.fs_lstat(fixture:path("actual.txt")))
    assert.are.same(draft, lines(instance))
    assert.is_true(vim.bo[instance.bufnr].modified)
    assert.is_true(vim.bo[instance.bufnr].modifiable)
    assert.is_true(instance.sync:is_dirty())
    local result = instance.work:last_write_result()
    assert.are.equal("succeeded", result.execution.state)
    assert.is_truthy(tostring(result.reconciliation_error)
      :find("forced reconciliation failure", 1, true))
    assert.are.equal("succeeded", ui.reports[1].outcome.state)
    assert.is_truthy(tostring(ui.reports[1].reconciliation_error)
      :find("forced reconciliation failure", 1, true))

    active_load = real_fs.load
    local refreshed, refresh_error = false, nil
    instance:refresh({ force = true, on_complete = function(err)
      refresh_error = err
      refreshed = true
    end })
    wait_for(function() return refreshed end)
    assert.is_nil(refresh_error)
    assert.are.same({ "actual.txt", "keep.txt" }, projected_paths(instance))
    assert.is_false(instance.sync:is_dirty())
    assert.is_false(vim.bo[instance.bufnr].modified)
  end)

  it("normalizes an empty Plan through private reconciliation without UI or Execution", function()
    local instance = ready({ ["a.txt"] = "a" })
    local ui = scripted_ui()
    local baseline = lines(instance)
    local row = row_for(instance, "a.txt")
    local physical = baseline[row]
    local decoded = instance.buffer:decode(row)
    local padded = physical:sub(1, decoded.path_range.start_byte) .. "  a.txt  "
    set_lines(instance, { "", padded, "" })
    assert.are.same({ operations = {}, display = {} }, instance:prepare())
    assert.is_true(write_command(instance))
    assert.is_false(instance.work:is_execution_active())
    wait_unlocked(instance)

    assert.are.same(baseline, lines(instance))
    assert.are.equal(0, #ui.confirmations)
    assert.are.equal(0, #ui.progress_statuses)
    assert.is_false(vim.bo[instance.bufnr].modified)
    assert.is_true(vim.bo[instance.bufnr].modifiable)
    assert.is_nil(instance.work:last_write_result().execution)
  end)

  it("writes retained unsupported snapshot kinds through the empty Plan path", function()
    active_load = function(scan_path, done)
      done(nil, { { name = "device", kind = "char" } }, scan_path)
    end
    local instance = wait_ready(keep(fre.new({ root = fixture.root, columns = {} })))
    local ui = scripted_ui()
    local baseline = lines(instance)
    set_lines(instance, { "", physical_line(instance, "device"), "" })

    assert.are.same({ operations = {}, display = {} }, instance:prepare())
    assert.is_true(write_command(instance))
    assert.is_false(instance.work:is_execution_active())
    wait_unlocked(instance)

    assert.are.same(baseline, lines(instance))
    assert.are.equal(0, #ui.confirmations)
    assert.are.equal(0, #ui.progress_statuses)
    assert.is_false(vim.bo[instance.bufnr].modified)
    assert.is_nil(instance.work:last_write_result().execution)
  end)

  it("cleans lock and UI references when confirmation, progress, update, close, or report throws", function()
    local confirm_instance = ready({ ["a.txt"] = "a" })
    scripted_ui({ confirm_error = "confirmation exploded" })
    set_lines(confirm_instance, { physical_line(confirm_instance, "a.txt"), "new.txt" })
    local ok, err = write_command(confirm_instance)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("confirmation exploded", 1, true))
    assert.is_false(confirm_instance.work:is_write_active())
    assert.is_true(vim.bo[confirm_instance.bufnr].modifiable)

    local progress_instance = wait_ready(keep(fre.new({ root = fixture.root, columns = {} })))
    scripted_ui({
      accept_synchronously = true,
      update_error = "update exploded",
      progress_close_error = "close exploded",
      report_error = "report exploded",
    })
    active_mutation = complete_adapter()
    set_lines(progress_instance, { physical_line(progress_instance, "a.txt"), "other.txt" })
    assert.is_true(write_command(progress_instance))
    wait_unlocked(progress_instance)
    assert.is_false(progress_instance.work:is_write_active())
    assert.is_false(progress_instance.work:is_execution_active())
    assert.is_false(progress_instance.sync:is_busy())
    assert.is_true(vim.bo[progress_instance.bufnr].modifiable)
    assert.is_false(vim.bo[progress_instance.bufnr].modified)
  end)

  it("keeps direct execute isolated from write lock, UI, refresh, tree, and buffer state", function()
    local load_count = 0
    active_load = function(path, done)
      load_count = load_count + 1
      real_fs.load(path, done)
    end
    local instance = ready({ ["a.txt"] = "a" })
    local ui = scripted_ui()
    local calls = 0
    local adapter = complete_adapter()
    adapter.create_file = function(_, done) calls = calls + 1; done(nil) end
    active_mutation = adapter
    local before = {
      lines = lines(instance),
      tree = instance.tree,
      root_node = instance.tree.root,
      view = instance.buffer.view,
      modified = vim.bo[instance.bufnr].modified,
      modifiable = vim.bo[instance.bufnr].modifiable,
      needs_refresh = instance.sync:is_dirty(),
      load_count = load_count,
    }
    local execution = instance:execute({
      display = { "ignored" },
      operations = { { type = "create_file", path = fixture:path("not-created-by-injected-adapter") } },
    })
    wait_for(function() return execution:get_status().state == "succeeded" end)

    assert.are.equal(1, calls)
    assert.are.same(before.lines, lines(instance))
    assert.are.equal(before.tree, instance.tree)
    assert.are.equal(before.root_node, instance.tree.root)
    assert.are.equal(before.view, instance.buffer.view)
    assert.are.equal(before.modified, vim.bo[instance.bufnr].modified)
    assert.are.equal(before.modifiable, vim.bo[instance.bufnr].modifiable)
    assert.are.equal(before.needs_refresh, instance.sync:is_dirty())
    assert.are.equal(before.load_count, load_count)
    assert.is_false(instance.work:is_write_active())
    assert.are.equal(0, #ui.confirmations)
    assert.are.equal(0, #ui.progress_statuses)
  end)
end)
