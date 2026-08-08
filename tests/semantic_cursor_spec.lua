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
    local second_anchor = {
      field_id = "path", path_field = true, zone = "content", display_offset = 4,
    }
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

  it("restores removed fields rightward while preserving path and every View", function()
    local function descriptor(id, text, navigable, align, enable)
      return columns.custom({
        id = id, text = text, navigable = navigable,
        align = align or "left", enable = enable,
        render = function(_, ctx) return ctx.descriptor.text end,
        parse = function(suffix)
          local value, rest = suffix:match("^ *(%S+) +(.*)$")
          return value, rest
        end,
        equals = function() return true end,
      })
    end
    local configured = {
      descriptor("left", "LEFT", true),
      descriptor("middle", "中间", true, "right"),
      descriptor("disabled", "DISABLED", true, "left", false),
      descriptor("skip", "SKIP", false),
      descriptor("right", "右侧", true),
    }
    local entries = { ["报告.txt"] = "x" }
    for index = 1, 40 do entries[string.format("item-%02d.txt", index)] = "x" end
    local instance = ready(entries, configured)

    local first = open_current(instance)
    local first_target = assert(instance:get_pos("item-25.txt"))[1]
    local first_decoded = assert(instance.buffer:decode(first_target))
    vim.api.nvim_win_set_cursor(first, {
      first_target, assert(row.cursor_column(first_decoded, {
        field_id = "middle", zone = "content", display_offset = 2,
      })),
    })
    vim.api.nvim_win_call(first, function() vim.cmd("normal! zz") end)
    local first_row = vim.api.nvim_win_get_cursor(first)[1]
    local first_topline = saved_view(first).topline

    vim.cmd("tabnew")
    local second = open_current(instance)
    local second_target = assert(instance:get_pos("报告.txt"))[1]
    local second_decoded = assert(instance.buffer:decode(second_target))
    local path_anchor = {
      field_id = "path", path_field = true, zone = "content", display_offset = 4,
    }
    vim.api.nvim_win_set_cursor(second, {
      second_target, assert(row.cursor_column(second_decoded, path_anchor)),
    })
    vim.api.nvim_win_call(second, function() vim.cmd("normal! zt") end)
    local second_row = vim.api.nvim_win_get_cursor(second)[1]
    local second_topline = saved_view(second).topline
    local focused_tab = vim.api.nvim_get_current_tabpage()
    local focused_win = vim.api.nvim_get_current_win()

    instance:hide_columns({ "middle" })

    local restored_first, first_anchor = cursor_state(instance, first)
    local restored_second, second_anchor = cursor_state(instance, second)
    assert.are.equal("item-25.txt", restored_first.entry.relative_path)
    assert.are.same({
      field_id = "right", zone = "content", display_offset = 0,
    }, first_anchor)
    assert.are.equal("报告.txt", restored_second.entry.relative_path)
    assert.are.same(path_anchor, second_anchor)
    local count = vim.api.nvim_buf_line_count(instance.bufnr)
    assert.are.equal(math.min(
      first_topline + vim.api.nvim_win_get_cursor(first)[1] - first_row, count
    ), saved_view(first).topline)
    assert.are.equal(math.min(
      second_topline + vim.api.nvim_win_get_cursor(second)[1] - second_row, count
    ), saved_view(second).topline)
    assert.are.equal(focused_tab, vim.api.nvim_get_current_tabpage())
    assert.are.equal(focused_win, vim.api.nvim_get_current_win())
  end)

  it("clamps a shortened multibyte field to a valid byte boundary", function()
    local text = "字段"
    local detail = columns.custom({
      id = "detail",
      render = function() return text end,
      parse = function(suffix)
        local value, rest = suffix:match("^(%S+)%s+(.*)$")
        return value, rest
      end,
      equals = function() return true end,
    })
    local instance = ready({ ["a.txt"] = "x" }, { detail })
    local winid = open_current(instance)
    local target = assert(instance:get_pos("a.txt"))[1]
    local decoded = assert(instance.buffer:decode(target))
    vim.api.nvim_win_set_cursor(winid, {
      target, assert(row.cursor_column(decoded, {
        field_id = "detail", zone = "content", display_offset = 4,
      })),
    })

    text = "短"
    assert.is_nil(complete_refresh(instance))

    local restored, anchor = cursor_state(instance, winid)
    assert.are.equal("a.txt", restored.entry.relative_path)
    assert.are.same({
      field_id = "detail", zone = "content", display_offset = 2,
    }, anchor)
    local cursor = vim.api.nvim_win_get_cursor(winid)
    assert.are.equal(restored.fields[1].content_range.start_byte + #text, cursor[2])
  end)

  it("attributes a final column separator leftward before falling back to path", function()
    local function descriptor(id)
      return columns.custom({
        id = id,
        render = function() return id:upper() end,
        parse = function(suffix)
          local value, rest = suffix:match("^(%S+)%s+(.*)$")
          return value, rest
        end,
        equals = function() return true end,
      })
    end
    local instance = ready({ ["a.txt"] = "x" }, {
      descriptor("first"), descriptor("final"),
    })
    local winid = open_current(instance)
    local target = assert(instance:get_pos("a.txt"))[1]
    local decoded = assert(instance.buffer:decode(target))
    local final = assert(decoded.fields[2])
    vim.api.nvim_win_set_cursor(winid, { target, final.separator_range.start_byte })
    local _, before = cursor_state(instance, winid)
    assert.are.equal("final", before.field_id)

    instance:hide_columns({ "final" })

    local restored, anchor = cursor_state(instance, winid)
    assert.are.equal("a.txt", restored.entry.relative_path)
    assert.are.same({
      field_id = "path", path_field = true, zone = "content", display_offset = 0,
    }, anchor)
  end)

  it("distinguishes a custom path column from the filesystem path", function()
    local function descriptor(id, text)
      return columns.custom({
        id = id,
        render = function() return text end,
        parse = function(suffix)
          local value, rest = suffix:match("^(%S+)%s+(.*)$")
          return value, rest
        end,
        equals = function() return true end,
      })
    end
    local instance = ready({ ["a.txt"] = "x" }, {
      descriptor("path", "CUSTOM"), descriptor("other", "OTHER"),
    })
    local winid = open_current(instance)
    local target = assert(instance:get_pos("a.txt"))[1]
    local decoded = assert(instance.buffer:decode(target))
    local custom = assert(decoded.fields[1])
    vim.api.nvim_win_set_cursor(winid, {
      target, custom.content_range.start_byte + 2,
    })

    instance:hide_columns({ "other" })

    local restored = assert(instance.buffer:decode(target))
    local cursor = vim.api.nvim_win_get_cursor(winid)
    assert.are.equal("path", restored.fields[1].id)
    assert.are.equal(restored.fields[1].content_range.start_byte + 2, cursor[2])
  end)

  it("preserves the semantic cursor when the instance node width grows", function()
    local entries = {}
    for index = 1, 6 do entries[string.format("item-%02d.txt", index)] = "x" end
    for index = 1, 3 do entries[string.format("a-dir/child-%02d.txt", index)] = "x" end
    local instance = ready(entries, variable_width_columns())
    local winid = open_current(instance)
    local target_row = assert(instance:get_pos("item-04.txt"))[1]
    local decoded = assert(instance.buffer:decode(target_row))
    local anchor = { field_id = "tag", zone = "content", display_offset = 2 }
    vim.api.nvim_win_set_cursor(winid, {
      target_row, assert(row.cursor_column(decoded, anchor)),
    })
    local old_column_width = instance.buffer.view.column_widths[1]
    assert.are.equal(1, #assert(decoded.marker:match(
      ":([0-9]+)" .. string.char(31) .. "$"
    )))

    instance:expand("a-dir")
    wait_for(function() return instance:get_pos("a-dir/child-03.txt") ~= nil end)

    local restored, restored_anchor = cursor_state(instance, winid)
    assert.are.equal("item-04.txt", restored.entry.relative_path)
    assert.are.same(anchor, restored_anchor)
    assert.is_true(instance.buffer.view.column_widths[1] > old_column_width)
    assert.are.equal(2, #assert(restored.marker:match(
      ":([0-9]+)" .. string.char(31) .. "$"
    )))
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
    local instance = ready(entries, variable_width_columns())
    local function set_variable(winid, relative_path)
      local target = assert(instance:get_pos(relative_path))[1]
      local decoded = assert(instance.buffer:decode(target))
      vim.api.nvim_win_set_cursor(winid, {
        target, assert(row.cursor_column(decoded, {
          field_id = "variable", zone = "content", display_offset = 0,
        })),
      })
    end
    local bad = open_current(instance)
    set_variable(bad, "item-10.txt")
    vim.cmd("vsplit")
    local manual = vim.api.nvim_get_current_win()
    set_variable(manual, "item-10.txt")

    vim.cmd("tabnew")
    local good = open_current(instance)
    set_variable(good, "item-15.txt")
    local focused_tab = vim.api.nvim_get_current_tabpage()
    local focused_win = vim.api.nvim_get_current_win()
    local generation = instance.buffer.view.projection_generation
    local bad_cursor = vim.api.nvim_win_get_cursor(bad)

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
    local ok, err = pcall(instance.hide_columns, instance, { "variable" })
    vim.api.nvim_win_set_cursor = set_cursor

    assert.is_true(injected)
    assert.is_true(ok, tostring(err))
    assert.are.same({ "variable" }, instance:get_hidden_columns())
    assert.are.equal(generation + 1, instance.buffer.view.projection_generation)
    assert.are.same(bad_cursor, vim.api.nvim_win_get_cursor(bad))
    local restored_manual, manual_anchor = cursor_state(instance, manual)
    assert.are.equal("item-10.txt", restored_manual.entry.name)
    assert.are.same({
      field_id = "tag", zone = "content", display_offset = 0,
    }, manual_anchor)
    local restored_good, restored_anchor = cursor_state(instance, good)
    assert.are.equal("item-15.txt", restored_good.entry.name)
    assert.are.same({
      field_id = "tag", zone = "content", display_offset = 0,
    }, restored_anchor)
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
