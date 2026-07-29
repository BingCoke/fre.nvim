local fre = require("fre")
local buffer = require("fre.buffer")
local columns = require("fre.columns")
local fs = require("tests.helpers.fs")

local instances = {}
local fixture

local function keep(instance)
  instances[#instances + 1] = instance
  return instance
end

local function wait_ready(instance)
  assert.is_true(vim.wait(1500, function()
    return instance.state == "ready-hidden" or instance.state == "ready-visible"
      or instance.state == "load-failed"
  end, 10))
  assert.are_not.equal("load-failed", instance.state, tostring(instance.error))
  return instance
end

local function ready(entries, opts)
  fixture:tree(entries or { ["a.txt"] = "x" })
  opts = vim.tbl_extend("force", { root = fixture.root }, opts or {})
  return wait_ready(keep(fre.new(opts)))
end

local function lines(instance)
  return vim.api.nvim_buf_get_lines(instance.bufnr, 0, -1, false)
end

local function row_for(instance, relative)
  for row = 1, vim.api.nvim_buf_line_count(instance.bufnr) do
    local decoded = assert(buffer.decode(instance, row))
    if decoded.row_kind == "entry" and decoded.entry.relative_path == relative then
      return row
    end
  end
  error("missing row for " .. relative)
end

local function set_line(instance, row, line)
  local modifiable = vim.bo[instance.bufnr].modifiable
  vim.bo[instance.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(instance.bufnr, row - 1, row, false, { line })
  vim.bo[instance.bufnr].modifiable = modifiable
end

local function error_contains(row, fragment, callback)
  local ok, err = pcall(callback)
  assert.is_false(ok)
  local text = tostring(err)
  assert.is_truthy(text:find("fre: row " .. row .. ":", 1, true), text)
  assert.is_truthy(text:find(fragment, 1, true), text)
end

local function value_column(id, align, render)
  return columns.custom({
    id = id,
    align = align,
    render = render,
    parse = function(suffix)
      local value, remaining = suffix:match("^ *(%S+) +(.*)$")
      return value, remaining
    end,
    equals = function(entry, value, ctx)
      return value == ctx.descriptor.render(entry, ctx)
    end,
  })
end

describe("fre metadata buffer rows", function()
  before_each(function()
    fixture = fs.new()
    instances = {}
    fre._reset_fs_adapter()
  end)

  after_each(function()
    for _, instance in ipairs(instances) do
      if instance.state ~= "destroyed" then instance:destroy() end
    end
    fre._reset_fs_adapter()
    fixture:cleanup()
  end)

  it("renders real built-in metadata bytes and decodes exact ranges", function()
    local instance = ready({ ["dir"] = true, ["file.txt"] = "x" })
    local physical = lines(instance)
    assert.are.equal(3, #physical)
    local navigation = assert(buffer.decode(instance, 1))
    assert.are.equal("navigation", navigation.row_kind)
    assert.are.equal("../", navigation.path)

    for row = 2, 3 do
      local decoded = buffer.decode(instance, row)
      local marker = decoded.marker
      assert.are.equal(marker, physical[row]:sub(1, #marker))
      assert.are.same({ "icon", "permissions", "size", "mtime" }, {
        decoded.fields[1].id, decoded.fields[2].id,
        decoded.fields[3].id, decoded.fields[4].id,
      })
      assert.are.equal(4, #decoded.column_ranges)
      assert.are.equal(4, #decoded.separator_ranges)
      assert.are.same({ start_byte = 0, end_byte = #marker }, decoded.marker_range)
      assert.are.equal(#marker, decoded.column_ranges[1].start_byte)
      for index = 1, 4 do
        local range = decoded.column_ranges[index]
        local separator = decoded.separator_ranges[index]
        assert.is_true(range.start_byte < range.end_byte)
        assert.is_true(separator.start_byte >= range.start_byte)
        assert.are.equal(range.end_byte, separator.end_byte)
        assert.are.equal(" ", physical[row]:sub(separator.start_byte + 1, separator.end_byte))
        if index > 1 then
          assert.are.equal(decoded.column_ranges[index - 1].end_byte, range.start_byte)
        end
      end
      assert.are.equal(decoded.column_ranges[4].end_byte, decoded.path_range.start_byte)
      assert.are.equal(decoded.path, physical[row]:sub(
        decoded.path_range.start_byte + 1, decoded.path_range.end_byte
      ))
      assert.are.equal(decoded.entry.kind == "directory" and "d" or "f", decoded.column_values.icon)
      assert.is_truthy(decoded.column_values.permissions:match("^[rwxstST%-][rwxstST%-][rwxstST%-][rwxstST%-][rwxstST%-][rwxstST%-][rwxstST%-][rwxstST%-][rwxstST%-]$"))
      assert.is_truthy(decoded.column_values.size:match("^%d+%.?%d*[kMG]?$"))
      assert.is_truthy(decoded.column_values.mtime:match("^%d%d%d%d%-%d%d%-%d%d %d%d:%d%d$"))
    end
  end)

  it("computes projection widths and applies left, center, and right alignment", function()
    local descriptors = {
      value_column("left", "left", function(entry)
        return entry.name == "a.txt" and "L" or "LEFT"
      end),
      value_column("center", "center", function(entry)
        return entry.name == "a.txt" and "C" or "MID"
      end),
      value_column("right", "right", function(entry)
        return entry.name == "a.txt" and "R" or "RIGHT"
      end),
    }
    local instance = ready({ ["a.txt"] = "a", ["bbbbb.txt"] = "b" }, {
      columns = descriptors,
    })
    assert.are.same({ 4, 3, 5 }, instance.view.column_widths)

    local first_row = row_for(instance, "a.txt")
    local second_row = row_for(instance, "bbbbb.txt")
    local first = buffer.decode(instance, first_row)
    local second = buffer.decode(instance, second_row)
    assert.are.same({ "L", "C", "R" }, {
      first.column_values.left, first.column_values.center, first.column_values.right,
    })
    assert.are.same({ "LEFT", "MID", "RIGHT" }, {
      second.column_values.left, second.column_values.center, second.column_values.right,
    })
    local first_suffix = lines(instance)[first_row]:sub(first.marker_range.end_byte + 1)
    local second_suffix = lines(instance)[second_row]:sub(second.marker_range.end_byte + 1)
    assert.are.equal("L     C      R a.txt", first_suffix)
    assert.are.equal("LEFT MID RIGHT bbbbb.txt", second_suffix)
  end)

  it("keeps exact provider highlights through copy move delete undo and redo", function()
    vim.api.nvim_set_hl(0, "FreTestIcon", { fg = "#ff3366" })
    local glyph = ""
    local icon = columns.icon({
      provider = function() return glyph, "FreTestIcon" end,
    })
    local instance = ready({ ["a.txt"] = "x" }, { columns = { icon } })
    instance:open({ position = "current" })

    local function icon_marks()
      local result = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        instance.bufnr, -1, 0, -1, { details = true }
      )) do
        if mark[4].hl_group == "FreTestIcon" then result[#result + 1] = mark end
      end
      table.sort(result, function(left, right) return left[2] < right[2] end)
      return result
    end

    local function assert_icon_marks(expected)
      local entries = {}
      assert.is_true(vim.wait(1000, function()
        entries = {}
        local navigation_count = 0
        for _, mark in ipairs(icon_marks()) do
          local decoded = buffer.decode(instance, mark[2] + 1)
          if not decoded or mark[4].end_col <= mark[3] then return false end
          if decoded.row_kind == "entry" then
            entries[#entries + 1] = mark
          elseif decoded.row_kind == "navigation" then
            navigation_count = navigation_count + 1
          end
        end
        return navigation_count == 1 and #entries == expected
      end, 10), vim.inspect(icon_marks()))
      return entries
    end

    assert_icon_marks(1)
    local original_row = row_for(instance, "a.txt")
    vim.api.nvim_win_set_cursor(0, {
      original_row, buffer.decode(instance, original_row).visible_range.start_byte,
    })
    vim.cmd.normal({ args = { "yyp" }, bang = true })
    assert.are.equal(3, #lines(instance))
    local marks = assert_icon_marks(2)
    for _, mark in ipairs(marks) do
      local decoded = buffer.decode(instance, mark[2] + 1)
      assert.are.equal(decoded.column_ranges[1].start_byte, mark[3])
      assert.are.equal(decoded.column_ranges[1].start_byte + #glyph, mark[4].end_col)
    end

    local copied_row = original_row + 1
    vim.api.nvim_win_set_cursor(0, {
      copied_row, buffer.decode(instance, copied_row).visible_range.start_byte,
    })
    vim.cmd.normal({ args = { "yyp" }, bang = true })
    assert.are.equal(4, #lines(instance))
    assert_icon_marks(3)

    local copied = buffer.decode(instance, copied_row)
    set_line(instance, copied_row, lines(instance)[copied_row]:sub(1, copied.path_range.start_byte) .. "copy.lua")
    assert_icon_marks(3)
    for _ = 1, 3 do
      vim.api.nvim_win_set_cursor(
        0, { copied_row, buffer.decode(instance, copied_row).visible_range.start_byte }
      )
      vim.cmd.normal({ args = { "ddp" }, bang = true })
    end
    assert_icon_marks(3)

    vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(instance.bufnr), 0 })
    vim.cmd.normal({ args = { "dd" }, bang = true })
    assert.are.equal(3, #lines(instance))
    assert_icon_marks(2)
  end)

  it("redecorates EOF deletions through undo and redo", function()
    local icon = columns.icon({
      provider = function() return "X", "FreTestIcon" end,
    })
    local instance = ready({
      ["a.txt"] = "a", ["b.txt"] = "b", ["c.txt"] = "c", ["d.txt"] = "d",
    }, { columns = { icon } })
    instance:open({ position = "current" })

    local function highlight_marks()
      local result = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        instance.bufnr, -1, 0, -1, { details = true }
      )) do
        if mark[4].hl_group == "FreTestIcon" then result[#result + 1] = mark end
      end
      return result
    end

    local function assert_highlights(expected)
      assert.is_true(vim.wait(1000, function()
        local entry_count, navigation_count = 0, 0
        for _, mark in ipairs(highlight_marks()) do
          if mark[4].end_col <= mark[3] then return false end
          local decoded = buffer.decode(instance, mark[2] + 1)
          if decoded.row_kind == "entry" then
            entry_count = entry_count + 1
          elseif decoded.row_kind == "navigation" then
            navigation_count = navigation_count + 1
          end
        end
        return entry_count == expected and navigation_count == 1
      end, 10), vim.inspect(highlight_marks()))
    end

    assert_highlights(4)
    vim.api.nvim_win_set_cursor(0, { row_for(instance, "d.txt"), 0 })
    vim.api.nvim_feedkeys("dd", "xt", false)
    assert.are.equal(4, #lines(instance))
    assert_highlights(3)
    vim.cmd("silent undo")
    assert.are.equal(5, #lines(instance))
    assert_highlights(4)
    vim.cmd("silent redo")
    assert.are.equal(4, #lines(instance))
    assert_highlights(3)
    vim.cmd("silent undo")
    assert_highlights(4)

    vim.api.nvim_win_set_cursor(0, { row_for(instance, "b.txt"), 0 })
    vim.api.nvim_feedkeys("dG", "xt", false)
    assert.are.equal(2, #lines(instance))
    assert_highlights(1)
    vim.cmd("silent undo")
    assert.are.equal(5, #lines(instance))
    assert_highlights(4)
    vim.cmd("silent redo")
    assert.are.equal(2, #lines(instance))
    assert_highlights(1)
  end)

  it("rolls back lines view and highlights when decoration commit fails", function()
    local icon = columns.icon({
      provider = function() return "X", "FreTestIcon" end,
    })
    local instance = ready({ ["a.txt"] = "x" }, { columns = { icon } })
    local before_lines = lines(instance)
    local before_view = instance.view

    local function highlight_state()
      local result = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
        instance.bufnr, -1, 0, -1, { details = true }
      )) do
        local details = mark[4]
        if details.hl_group == "FreTestIcon" then
          result[#result + 1] = {
            row = mark[2], col = mark[3], end_col = details.end_col,
            hl_group = details.hl_group, priority = details.priority,
          }
        end
      end
      return result
    end

    local before_highlights = highlight_state()
    local prepared = buffer.prepare(instance, instance.view.projection)
    local original_set_extmark = vim.api.nvim_buf_set_extmark
    local injected = false
    vim.api.nvim_buf_set_extmark = function(bufnr, namespace, row, col, opts)
      if not injected and opts and opts.hl_group == "FreTestIcon" then
        injected = true
        error("injected highlight commit failure")
      end
      return original_set_extmark(bufnr, namespace, row, col, opts)
    end

    local test_ok, test_err = xpcall(function()
      local commit_ok, commit_err = pcall(buffer.commit, instance, prepared)
      assert.is_false(commit_ok)
      assert.is_truthy(tostring(commit_err):find(
        "injected highlight commit failure", 1, true
      ))
    end, debug.traceback)
    vim.api.nvim_buf_set_extmark = original_set_extmark
    if not test_ok then error(test_err) end

    assert.is_true(injected)
    assert.are.same(before_lines, lines(instance))
    assert.are.equal(before_view, instance.view)
    assert.are.same(before_highlights, highlight_state())
  end)

  it("conceals physical identity on screen while preserving it in ordinary yanks", function()
    local instance = ready({ ["a.txt"] = "x" })
    instance:open({ position = "current" })
    local row = row_for(instance, "a.txt")
    local decoded = buffer.decode(instance, row)
    local marker = decoded.marker
    vim.api.nvim_win_set_cursor(0, { row, decoded.visible_range.start_byte })
    vim.cmd.normal({ args = { "yy" }, bang = true })
    local yanked = vim.fn.getreg('"')
    local physical = lines(instance)[row]
    assert.are.equal(physical .. "\n", yanked)
    assert.are.equal(string.char(31), yanked:sub(1, 1))
    assert.is_truthy(yanked:find(" f ", 1, true) or yanked:find("\31f "))
    assert.is_truthy(yanked:find("a.txt", 1, true))

    assert.are.equal(3, vim.wo.conceallevel)
    assert.are.equal("nvic", vim.wo.concealcursor)
    for column = 1, #marker do
      assert.are.equal(1, vim.fn.synconcealed(row, column)[1], "marker byte " .. column)
    end
    vim.api.nvim__redraw({ flush = true })
    local screen = {}
    for column = 1, vim.api.nvim_win_get_width(0) do
      screen[#screen + 1] = vim.fn.screenstring(row, column)
    end
    local visible = table.concat(screen)
    assert.is_nil(visible:find("fre:", 1, true))
    assert.is_truthy(visible:find("a.txt", 1, true), visible)
  end)

  it("accepts layout whitespace but rejects semantic metadata and kind suffix changes", function()
    local instance = ready({ ["file.txt"] = "x" })
    local row = row_for(instance, "file.txt")
    local original = lines(instance)[row]
    local decoded = buffer.decode(instance, row)

    local separator = decoded.separator_ranges[1]
    local whitespace_edit = original:sub(1, separator.start_byte)
      .. "   " .. original:sub(separator.end_byte + 1)
    set_line(instance, row, whitespace_edit)
    assert.are.equal("file.txt", instance:get_entry(row).name)

    set_line(instance, row, original:sub(1, decoded.column_ranges[1].start_byte)
      .. "d" .. original:sub(decoded.column_ranges[1].start_byte + 2))
    error_contains(row, "column icon metadata changed", function() instance:get_entry(row) end)

    local permissions = decoded.column_ranges[2].start_byte
    local replacement = decoded.column_values.permissions:sub(1, 1) == "r" and "-" or "r"
    set_line(instance, row, original:sub(1, permissions) .. replacement
      .. original:sub(permissions + 2))
    error_contains(row, "column permissions metadata changed", function() instance:get_entry(row) end)

    local mtime = decoded.column_ranges[4].start_byte
    local digit = original:sub(mtime + 1, mtime + 1) == "9" and "8" or "9"
    set_line(instance, row, original:sub(1, mtime) .. digit .. original:sub(mtime + 2))
    error_contains(row, "column mtime metadata changed", function() instance:get_entry(row) end)

    set_line(instance, row, original .. "/")
    error_contains(row, "file path must not end in /", function() instance:get_entry(row) end)
  end)

  it("validates parser errors, progress, literal suffixes, and consumed separators", function()
    local cases = {
      {
        fragment = "parser failed",
        parse = function() error("broken") end,
      },
      {
        fragment = "parser returned no value",
        parse = function(suffix) return nil, suffix:sub(2) end,
      },
      {
        fragment = "suffix string",
        parse = function() return "x", nil end,
      },
      {
        fragment = "made no progress",
        parse = function(suffix) return "x", suffix end,
      },
      {
        fragment = "non-literal suffix",
        parse = function() return "x", "zz" end,
      },
      {
        fragment = "did not consume its separator",
        parse = function(suffix) return "x", suffix:sub(2) end,
      },
      {
        fragment = "did not consume its separator",
        parse = function() return "x", "" end,
      },
    }
    for index, case in ipairs(cases) do
      local root = fixture:mkdir("case" .. index)
      fixture:write("case" .. index .. "/a.txt", "x")
      local descriptor = columns.custom({
        id = "broken" .. index,
        render = function() return "x" end,
        parse = case.parse,
        equals = function() return true end,
      })
      local instance = wait_ready(keep(fre.new({ root = root, columns = { descriptor } })))
      local row = vim.api.nvim_buf_line_count(instance.bufnr)
      error_contains(row, case.fragment, function() instance:get_entry(row) end)
    end
  end)

  it("rejects invalid custom render output before committing a ready projection", function()
    local outputs = {
      { fragment = "contains a control byte", value = "bad\nvalue" },
      { fragment = "contains a control byte", value = string.char(127) },
      { fragment = "not valid UTF-8", value = string.char(0xff) },
    }
    for index, output in ipairs(outputs) do
      local root = fixture:mkdir("render" .. index)
      fixture:write("render" .. index .. "/a.txt", "x")
      local descriptor = columns.custom({
        id = "invalid" .. index,
        render = function() return output.value end,
        parse = function(suffix) return "x", suffix:sub(3) end,
        equals = function() return true end,
      })
      local instance = keep(fre.new({ root = root, columns = { descriptor } }))
      assert.is_true(vim.wait(1500, function() return instance.state == "load-failed" end, 10))
      assert.is_truthy(tostring(instance.error):find(output.fragment, 1, true), tostring(instance.error))
    end
  end)

  it("uses decoded visible and editable boundaries while leaving new rows editable", function()
    local instance = ready({ ["a.txt"] = "x" })
    instance:open()
    local row = row_for(instance, "a.txt")
    local decoded = buffer.decode(instance, row)
    assert.is_true(decoded.navigable_range.start_byte < decoded.path_range.start_byte)

    vim.api.nvim_win_set_cursor(0, { row, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = instance.bufnr })
    assert.are.same({ row, decoded.navigable_range.start_byte }, vim.api.nvim_win_get_cursor(0))

    vim.api.nvim_win_set_cursor(0, { row, decoded.navigable_range.start_byte + 1 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = instance.bufnr })
    assert.are.same({ row, decoded.navigable_range.start_byte + 1 }, vim.api.nvim_win_get_cursor(0))

    for _, event in ipairs({ "InsertEnter", "InsertCharPre", "CursorMovedI" }) do
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      vim.api.nvim_exec_autocmds(event, { buffer = instance.bufnr })
      assert.are.same({ row, decoded.navigable_range.start_byte },
        vim.api.nvim_win_get_cursor(0))
    end

    local modifiable = vim.bo[instance.bufnr].modifiable
    vim.bo[instance.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(instance.bufnr, -1, -1, false, { "new.txt" })
    vim.bo[instance.bufnr].modifiable = modifiable
    local new_row = vim.api.nvim_buf_line_count(instance.bufnr)
    vim.api.nvim_win_set_cursor(0, { new_row, 0 })
    vim.api.nvim_exec_autocmds("InsertEnter", { buffer = instance.bufnr })
    assert.are.same({ new_row, 0 }, vim.api.nvim_win_get_cursor(0))
  end)

  it("returns independent exact six-field Entries after column callbacks", function()
    local descriptor = columns.custom({
      id = "mutator",
      render = function(entry) entry.extra = true; return "x" end,
      parse = function(suffix, ctx)
        ctx.entry.extra = true
        local value, rest = suffix:match("^(x) +(.*)$")
        return value, rest
      end,
      equals = function(entry, value) entry.extra = true; return value == "x" end,
    })
    local instance = ready({ ["a.txt"] = "x" }, { columns = { descriptor } })
    local row = row_for(instance, "a.txt")
    local first = instance:get_entry(row)
    first.name = "changed"
    local second = instance:get_entry(row)
    assert.are_not.equal(first, second)
    assert.are.equal("a.txt", second.name)
    local count = 0
    local allowed = {
      instance_id = true, node_id = true, absolute_path = true,
      relative_path = true, name = true, kind = true,
    }
    for key in pairs(second) do
      assert.is_true(allowed[key] == true)
      count = count + 1
    end
    assert.are.equal(6, count)
  end)

  it("loads symlinks from lstat metadata without a directory display suffix when supported", function()
    local target = fixture:write("target.txt", "x")
    local link, err = fixture:symlink(target, "link.txt")
    if not link then assert.is_truthy(err); return end
    local instance = wait_ready(keep(fre.new({ root = fixture.root })))
    local symlink_row
    for row = 1, #lines(instance) do
      local decoded = buffer.decode(instance, row)
      if decoded.row_kind == "entry" and decoded.entry.name == "link.txt" then
        symlink_row = decoded
        break
      end
    end
    assert.is_not_nil(symlink_row)
    assert.are.equal("symlink", symlink_row.entry.kind)
    assert.are.equal("l", symlink_row.column_values.icon)
    assert.is_false(symlink_row.path:sub(-1) == "/")
  end)
end)
