local buffer = require("fre.instance.buffer")
local columns = require("fre.columns")
local fre = require("fre")
local row = require("fre.instance.row")
local fs = require("tests.helpers.fs")

local fixture
local instances = {}

local function keep(instance)
  instances[#instances + 1] = instance
  return instance
end

local function wait_for(predicate)
  assert.is_true(vim.wait(2500, predicate, 10))
end

local function ready(entries, configured_columns)
  fixture:tree(entries)
  local instance = keep(fre.new({
    root = fixture.root,
    columns = configured_columns or {},
  }))
  wait_for(function()
    return instance:status() == "ready"
      or instance:status() == "load-failed"
  end)
  assert.are_not.equal("load-failed", instance:status(), tostring(instance:failure()))
  return instance
end

local function open_current(instance)
  local opened, winid = instance:open({ position = "current" })
  assert.are.equal(instance, opened)
  return winid
end

local function entry_at(instance, winid)
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local decoded = assert(instance.buffer:decode(cursor[1]))
  return decoded.entry
end

local function saved_view(winid)
  return vim.api.nvim_win_call(winid, vim.fn.winsaveview)
end

local function complete_refresh(instance)
  local completed, completion_error = false, nil
  instance:refresh({ on_complete = function(err)
    completion_error = err
    completed = true
  end })
  wait_for(function() return completed end)
  return completion_error
end

local function cursor_state(instance, winid)
  local cursor = vim.api.nvim_win_get_cursor(winid)
  local decoded = assert(instance.buffer:decode(cursor[1]))
  return decoded, assert(row.cursor_anchor(decoded, cursor[2]))
end

local function variable_width_columns()
  local function parse_token(suffix)
    local _, value, _, rest = suffix:match("^( *)(%S+)( +)(.*)$")
    if not value then error("malformed semantic cursor test column") end
    return value, rest
  end
  return {
    columns.custom({
      id = "variable",
      render = function(entry)
        return entry.relative_path:find("/", 1, true) and "expanded-child-width" or "x"
      end,
      parse = parse_token,
      equals = function() return true end,
    }),
    columns.custom({
      id = "tag",
      render = function() return "FIELD" end,
      parse = parse_token,
      equals = function(_, value) return value == "FIELD" end,
    }),
  }
end

describe("fre semantic cursor preservation", function()
  before_each(function()
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
    vim.cmd("enew")
    fixture = fs.new()
    instances = {}
    fre._reset_fs_adapter()
    fre.setup({ default_file_explorer = false })
  end)

  after_each(function()
    for _, instance in ipairs(instances) do
      if instance:status() ~= "destroyed" then instance:destroy() end
    end
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
    fre._reset_fs_adapter()
    fixture:cleanup()
  end)

  it("retains exact Entries and relative toplines in two tabs without changing focus", function()
    local entries = {}
    for index = 1, 60 do entries[string.format("item-%02d.txt", index)] = "x" end
    for index = 1, 8 do entries[string.format("a-dir/child-%02d.txt", index)] = "x" end
    local instance = ready(entries)

    local first_tab = vim.api.nvim_get_current_tabpage()
    local first = open_current(instance)
    vim.api.nvim_win_set_cursor(first, instance:get_pos("item-35.txt"))
    vim.api.nvim_win_call(first, function() vim.cmd("normal! zt") end)
    local first_row = vim.api.nvim_win_get_cursor(first)[1]
    local first_topline = saved_view(first).topline

    vim.cmd("tabnew")
    local second_tab = vim.api.nvim_get_current_tabpage()
    local second = open_current(instance)
    vim.api.nvim_win_set_cursor(second, instance:get_pos("item-50.txt"))
    vim.api.nvim_win_call(second, function() vim.cmd("normal! zz") end)
    local second_row = vim.api.nvim_win_get_cursor(second)[1]
    local second_topline = saved_view(second).topline
    local focused_tab = vim.api.nvim_get_current_tabpage()
    local focused_win = vim.api.nvim_get_current_win()

    instance:expand("a-dir")
    wait_for(function() return instance:get_pos("a-dir/child-08.txt") ~= nil end)

    assert.are.equal("item-35.txt", entry_at(instance, first).name)
    assert.are.equal("item-50.txt", entry_at(instance, second).name)
    local line_count = vim.api.nvim_buf_line_count(instance.bufnr)
    local first_delta = vim.api.nvim_win_get_cursor(first)[1] - first_row
    local second_delta = vim.api.nvim_win_get_cursor(second)[1] - second_row
    assert.are.equal(math.min(first_topline + first_delta, line_count), saved_view(first).topline)
    assert.are.equal(math.min(second_topline + second_delta, line_count), saved_view(second).topline)
    assert.are.equal(focused_tab, vim.api.nvim_get_current_tabpage())
    assert.are.equal(focused_win, vim.api.nvim_get_current_win())
    assert.are.equal(first, fre.view.inspect(instance, first_tab).winid)
    assert.are.equal(second, fre.view.inspect(instance, second_tab).winid)
  end)

  it("preserves semantic columns when an expanded child widens a preceding column", function()
    local entries = { ["a-dir/child.txt"] = "x" }
    for index = 1, 40 do entries[string.format("item-%02d.txt", index)] = "x" end
    local instance = ready(entries, variable_width_columns())

    local first_tab = vim.api.nvim_get_current_tabpage()
    local first = open_current(instance)
    local first_target = assert(instance:get_pos("item-25.txt"))[1]
    local first_decoded = assert(instance.buffer:decode(first_target))
    local first_anchor = { field_id = "tag", zone = "content", display_offset = 2 }
    vim.api.nvim_win_set_cursor(first, {
      first_target, assert(row.cursor_column(first_decoded, first_anchor)),
    })
    vim.api.nvim_win_call(first, function() vim.cmd("normal! zz") end)
    local first_row = vim.api.nvim_win_get_cursor(first)[1]
    local first_topline = saved_view(first).topline

    vim.cmd("tabnew")
    local second_tab = vim.api.nvim_get_current_tabpage()
    local second = open_current(instance)
    local second_target = assert(instance:get_pos("item-35.txt"))[1]
    local second_decoded = assert(instance.buffer:decode(second_target))
    local second_anchor = { field_id = "path", zone = "content", display_offset = 4 }
    vim.api.nvim_win_set_cursor(second, {
      second_target, assert(row.cursor_column(second_decoded, second_anchor)),
    })
    vim.api.nvim_win_call(second, function() vim.cmd("normal! zt") end)
    local second_row = vim.api.nvim_win_get_cursor(second)[1]
    local second_topline = saved_view(second).topline
    local old_width = instance.buffer.view.column_widths[1]
    local focused_tab = vim.api.nvim_get_current_tabpage()
    local focused_win = vim.api.nvim_get_current_win()

    instance:expand("a-dir")
    wait_for(function() return instance:get_pos("a-dir/child.txt") ~= nil end)

    assert.is_true(instance.buffer.view.column_widths[1] > old_width)
    local restored_first, restored_first_anchor = cursor_state(instance, first)
    local restored_second, restored_second_anchor = cursor_state(instance, second)
    assert.are.equal("item-25.txt", restored_first.entry.relative_path)
    assert.are.same(first_anchor, restored_first_anchor)
    assert.are.equal("item-35.txt", restored_second.entry.relative_path)
    assert.are.same(second_anchor, restored_second_anchor)
    local line_count = vim.api.nvim_buf_line_count(instance.bufnr)
    local first_delta = vim.api.nvim_win_get_cursor(first)[1] - first_row
    local second_delta = vim.api.nvim_win_get_cursor(second)[1] - second_row
    assert.are.equal(math.min(first_topline + first_delta, line_count), saved_view(first).topline)
    assert.are.equal(math.min(second_topline + second_delta, line_count), saved_view(second).topline)
    assert.are.equal(focused_tab, vim.api.nvim_get_current_tabpage())
    assert.are.equal(focused_win, vim.api.nvim_get_current_win())
    assert.are.equal(first, fre.view.inspect(instance, first_tab).winid)
    assert.are.equal(second, fre.view.inspect(instance, second_tab).winid)
  end)

  it("falls back to the nearest surviving ancestor after collapse", function()
    local instance = ready({ ["dir/child/grandchild.txt"] = "x", ["tail.txt"] = "x" })
    local winid = open_current(instance)
    instance:expand("dir/child")
    wait_for(function() return instance:get_pos("dir/child/grandchild.txt") ~= nil end)
    vim.api.nvim_win_set_cursor(winid, instance:get_pos("dir/child/grandchild.txt"))

    instance:collapse("dir")

    assert.are.equal("dir", entry_at(instance, winid).relative_path)
    local cursor = vim.api.nvim_win_get_cursor(winid)
    local decoded = assert(instance.buffer:decode(cursor[1]))
    assert.is_true(cursor[2] >= decoded.navigable_range.start_byte)
    assert.is_true(cursor[2] <= decoded.navigable_range.end_byte)
    assert.are.same(instance:get_pos("dir"), cursor)
  end)

  it("falls back to the first projected Entry when no ancestor survives", function()
    local instance = ready({ ["gone.txt"] = "x", ["remain.txt"] = "x" })
    local winid = open_current(instance)
    vim.api.nvim_win_set_cursor(winid, instance:get_pos("gone.txt"))
    fs.remove_tree(fixture:path("gone.txt"))

    assert.is_nil(complete_refresh(instance))

    local cursor = vim.api.nvim_win_get_cursor(winid)
    local decoded = assert(instance.buffer:decode(cursor[1]))
    assert.are.equal("entry", decoded.row_kind)
    assert.are.equal("remain.txt", decoded.entry.relative_path)
    assert.is_true(cursor[2] >= decoded.navigable_range.start_byte)
    assert.is_true(cursor[2] <= decoded.navigable_range.end_byte)
    assert.are.same(instance:get_pos("remain.txt"), cursor)
  end)

  it("silently skips one failed View restoration and continues with another", function()
    local entries = { [".inserted.txt"] = "x" }
    for index = 1, 20 do entries[string.format("item-%02d.txt", index)] = "x" end
    local instance = ready(entries)
    local bad = open_current(instance)
    vim.api.nvim_win_set_cursor(bad, instance:get_pos("item-10.txt"))
    vim.cmd("vsplit")
    local manual = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(manual, instance:get_pos("item-10.txt"))

    vim.cmd("tabnew")
    local good = open_current(instance)
    vim.api.nvim_win_set_cursor(good, instance:get_pos("item-15.txt"))
    local focused_tab = vim.api.nvim_get_current_tabpage()
    local focused_win = vim.api.nvim_get_current_win()
    local generation = instance.buffer.view.projection_generation

    local set_cursor = vim.api.nvim_win_set_cursor
    local injected = false
    vim.api.nvim_win_set_cursor = function(winid, cursor)
      local target = winid == 0 and vim.api.nvim_get_current_win() or winid
      if not injected and target == bad then
        injected = true
        error("injected restoration failure")
      end
      return set_cursor(winid, cursor)
    end
    local ok, err = pcall(instance.set_hidden_file, instance, true)
    vim.api.nvim_win_set_cursor = set_cursor

    assert.is_true(injected)
    assert.is_true(ok, tostring(err))
    assert.is_true(instance.buffer:hidden_files())
    assert.are.equal(generation + 1, instance.buffer.view.projection_generation)
    assert.are.same(
      vim.api.nvim_win_get_cursor(manual), vim.api.nvim_win_get_cursor(bad)
    )
    assert.are.equal("item-15.txt", entry_at(instance, good).name)
    assert.are.equal(focused_tab, vim.api.nvim_get_current_tabpage())
    assert.are.equal(focused_win, vim.api.nvim_get_current_win())
  end)

  it("does not defer a hidden reveal cursor until a later open", function()
    local instance = ready({ ["a/b/target.txt"] = "x", ["tail.txt"] = "x" })

    instance:reveal("a/b/target.txt")
    wait_for(function() return instance:get_pos("a/b/target.txt") ~= nil end)
    local winid = open_current(instance)

    assert.are.equal(1, vim.api.nvim_win_get_cursor(winid)[1])
    assert.are_not.same(instance:get_pos("a/b/target.txt"), vim.api.nvim_win_get_cursor(winid))
  end)
end)
