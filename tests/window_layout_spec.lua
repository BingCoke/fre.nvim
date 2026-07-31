local fre = require("fre")
local fs = require("tests.helpers.fs")

local fixture
local instances = {}
local original_geometry
local scratch_buffers = {}

local function keep(instance)
  instances[#instances + 1] = instance
  return instance
end

local function wait_for(predicate)
  assert.is_true(vim.wait(2000, predicate, 10))
end

local function ready(entries, opts)
  fixture:tree(entries or { ["a.txt"] = "a", ["b.txt"] = "b", ["c.txt"] = "c" })
  opts = vim.tbl_extend("force", { root = fixture.root, columns = {} }, opts or {})
  local instance = keep(fre.new(opts))
  wait_for(function()
    return instance.state == "ready"
      or instance.state == "load-failed"
  end)
  assert.are_not.equal("load-failed", instance.state, tostring(instance.error))
  return instance
end

local function current_tab_views(instance)
  local result = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(winid)
        and vim.api.nvim_win_get_buf(winid) == instance.bufnr then
      result[#result + 1] = winid
    end
  end
  table.sort(result)
  return result
end

local function error_text(callback)
  local ok, err = pcall(callback)
  assert.is_false(ok)
  return tostring(err)
end

local function saved_view(winid)
  return vim.api.nvim_win_call(winid, vim.fn.winsaveview)
end

local function screenpos(winid)
  local position = vim.fn.win_screenpos(winid)
  return position[1], position[2]
end


local function open_view(instance, layout)
  local opened, winid = instance:open(layout)
  assert.are.equal(instance, opened)
  assert.are.equal(winid, vim.api.nvim_get_current_win())
  assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(winid))
  return winid
end

local function scratch()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
  scratch_buffers[#scratch_buffers + 1] = bufnr
  return bufnr
end

describe("fre editor-derived Views", function()
  before_each(function()
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
    vim.cmd("enew")
    fixture = fs.new()
    instances = {}
    scratch_buffers = {}
    fre._reset_fs_adapter()
    fre.setup({ default_file_explorer = false })
    original_geometry = {
      columns = vim.o.columns,
      lines = vim.o.lines,
      cmdheight = vim.o.cmdheight,
      laststatus = vim.o.laststatus,
      showtabline = vim.o.showtabline,
    }
    vim.o.columns = 120
    vim.o.lines = 40
    vim.o.cmdheight = 1
    vim.o.laststatus = 0
    vim.o.showtabline = 0
  end)

  after_each(function()
    for _, instance in ipairs(instances) do
      if instance.state ~= "destroyed" then instance:destroy() end
    end
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
    for _, bufnr in ipairs(scratch_buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
    vim.o.columns = original_geometry.columns
    vim.o.lines = original_geometry.lines
    vim.o.cmdheight = original_geometry.cmdheight
    vim.o.laststatus = original_geometry.laststatus
    vim.o.showtabline = original_geometry.showtabline
    fre._reset_fs_adapter()
    fixture:cleanup()
  end)

  it("materializes current, split, ratio, and float layouts for one selected View", function()
    local instance = ready()
    local original = vim.api.nvim_get_current_win()
    assert.are.equal(original, open_view(instance, { position = "current" }))

    local left = open_view(instance, { position = "left", size = 24 })
    assert.are.equal(24, vim.api.nvim_win_get_width(left))
    local row, col = screenpos(left)
    assert.are.equal(1, row)
    assert.are.equal(1, col)
    local right = open_view(instance, { position = "right", size = 25 })
    assert.are.equal(25, vim.api.nvim_win_get_width(right))
    row, col = screenpos(right)
    assert.are.equal(1, row)
    assert.is_true(col > 1)
    local top = open_view(instance, { position = "top", size = 0.25 })
    assert.are.equal(10, vim.api.nvim_win_get_height(top))
    row, col = screenpos(top)
    assert.are.equal(1, row)
    assert.are.equal(1, col)
    local bottom = open_view(instance, { position = "bottom", size = 9 })
    assert.are.equal(9, vim.api.nvim_win_get_height(bottom))
    row, col = screenpos(bottom)
    assert.is_true(row > 1)
    assert.are.equal(1, col)
    local floated = open_view(instance, {
      position = "float", width = 0.5, height = 0.5,
      row = 0.25, col = 0.25, border = "rounded",
    })
    local config = vim.api.nvim_win_get_config(floated)
    assert.are.equal("editor", config.relative)
    assert.are.equal(60, config.width)
    assert.are.equal(20, config.height)
    assert.are.equal(10, config.row)
    assert.are.equal(30, config.col)
    assert.are.equal(1, #current_tab_views(instance))
    assert.are.same({
      winid = floated, origin_winid = original,
      layout = {
        position = "float", width = 0.5, height = 0.5,
        row = 0.25, col = 0.25, border = "rounded",
      },
    }, fre.view.inspect(instance))
    instance:destroy()
    assert.is_false(vim.api.nvim_win_is_valid(floated))
  end)

  it("rejects one over-capacity split and one out-of-bounds bordered float", function()
    local instance = ready()
    local root = vim.api.nvim_get_current_win()
    local root_width = vim.api.nvim_win_get_width(root)
    local maximum = root_width - math.min(root_width, vim.o.winminwidth) - 1
    local exact = open_view(instance, { position = "left", size = maximum })
    assert.are.equal(maximum, vim.api.nvim_win_get_width(exact))
    instance:hidden()

    local before_wins = vim.api.nvim_tabpage_list_wins(0)
    local before_layout = vim.fn.winlayout()
    assert.is_truthy(error_text(function()
      instance:open({ position = "left", size = maximum + 1 })
    end):find("exactly", 1, true))
    assert.are.same(before_wins, vim.api.nvim_tabpage_list_wins(0))
    assert.are.same(before_layout, vim.fn.winlayout())

    assert.is_truthy(error_text(function()
      instance:open({
        position = "float", width = vim.o.columns, height = 5,
        row = 0, col = 0, border = "single",
      })
    end):find("bordered float", 1, true))
    assert.are.same(before_wins, vim.api.nvim_tabpage_list_wins(0))
    assert.are.same(before_layout, vim.fn.winlayout())
    assert.is_nil(fre.view.inspect(instance))
  end)

  it("focuses a visible View and reuses the same explicit normalized layout", function()
    local entries = {}
    for index = 1, 50 do entries[string.format("item-%02d.txt", index)] = "x" end
    local instance = ready(entries)
    local requested = { position = "left", size = 30 }
    local winid = open_view(instance, requested)
    vim.api.nvim_win_set_cursor(winid, instance:get_pos("item-30.txt"))
    vim.api.nvim_win_call(winid, function() vim.cmd("normal! zt") end)
    local cursor_before = vim.api.nvim_win_get_cursor(winid)
    local view_before = saved_view(winid)
    vim.cmd("wincmd p")

    assert.are.equal(winid, open_view(instance))
    vim.cmd("wincmd p")
    assert.are.equal(winid, open_view(instance, requested))
    assert.are.same(cursor_before, vim.api.nvim_win_get_cursor(winid))
    assert.are.same(view_before, saved_view(winid))
    assert.are.equal(1, #current_tab_views(instance))
  end)

  it("relayouts once for a different explicit layout and preserves cursor state", function()
    local instance = ready()
    local original = vim.api.nvim_get_current_win()
    local floated = open_view(instance, {
      position = "float", width = 40, height = 10,
    })
    vim.api.nvim_win_set_cursor(floated, instance:get_pos("b.txt"))

    local split = open_view(instance, { position = "left", size = 20 })
    assert.is_false(vim.api.nvim_win_is_valid(floated))
    assert.is_true(vim.api.nvim_win_is_valid(original))
    assert.are.equal(20, vim.api.nvim_win_get_width(split))
    assert.are.same(instance:get_pos("b.txt"), vim.api.nvim_win_get_cursor(split))
    assert.are.same({ split }, current_tab_views(instance))
    assert.are.same({ position = "left", size = 20 }, fre.view.inspect(instance).layout)
  end)

  it("physically relayouts split Views to their exact current origin and restores it", function()
    local instance = ready()
    local origin = vim.api.nvim_get_current_win()
    local previous = scratch()
    vim.api.nvim_win_set_buf(origin, previous)
    local split = open_view(instance, { position = "left", size = 20 })

    local current = open_view(instance, { position = "current" })
    assert.are.equal(origin, current)
    assert.is_false(vim.api.nvim_win_is_valid(split))
    assert.are.same({ current }, current_tab_views(instance))
    assert.are.same({ position = "current" }, fre.view.inspect(instance).layout)
    assert.are.equal(origin, fre.view.inspect(instance).origin_winid)

    instance:hidden()
    assert.are.equal(previous, vim.api.nvim_win_get_buf(origin))
  end)

  it("physically relayouts float Views to their exact current origin and restores it", function()
    local instance = ready()
    local origin = vim.api.nvim_get_current_win()
    local previous = scratch()
    vim.api.nvim_win_set_buf(origin, previous)
    local floated = open_view(instance, { position = "float", width = 30, height = 8 })

    local current = open_view(instance, { position = "current" })
    assert.are.equal(origin, current)
    assert.is_false(vim.api.nvim_win_is_valid(floated))
    assert.are.same({ current }, current_tab_views(instance))
    assert.are.same({ position = "current" }, fre.view.inspect(instance).layout)

    instance:hidden()
    assert.are.equal(previous, vim.api.nvim_win_get_buf(origin))
  end)

  it("rejects current relayout before mutation when the exact origin is invalid", function()
    local instance = ready()
    local origin = vim.api.nvim_get_current_win()
    local split = open_view(instance, { position = "left", size = 20 })
    vim.api.nvim_win_close(origin, true)
    local before_wins = vim.api.nvim_tabpage_list_wins(0)

    assert.is_truthy(error_text(function()
      instance:open({ position = "current" })
    end):find("origin", 1, true))
    assert.are.same(before_wins, vim.api.nvim_tabpage_list_wins(0))
    assert.are.same({ split }, current_tab_views(instance))
    assert.are.equal(split, fre.view.inspect(instance).winid)
  end)

  it("anchors float-to-split relayout to its non-lowest exact ordinary origin", function()
    local instance = ready()
    local lowest = vim.api.nvim_get_current_win()
    vim.cmd("split")
    local origin = vim.api.nvim_get_current_win()
    assert.is_true(origin > lowest)
    local floated = open_view(instance, { position = "float", width = 30, height = 8 })
    assert.are.equal(origin, fre.view.inspect(instance).origin_winid)

    local command = vim.cmd
    local actual_anchor
    vim.cmd = function(value)
      if tostring(value):find("vertical split", 1, true) then
        actual_anchor = vim.api.nvim_get_current_win()
      end
      return command(value)
    end
    local ok, split = pcall(open_view, instance, { position = "left", size = 20 })
    vim.cmd = command
    assert.is_true(ok, tostring(split))
    assert.is_false(vim.api.nvim_win_is_valid(floated))
    assert.are.equal(origin, actual_anchor)
    assert.are.equal(origin, fre.view.inspect(instance).origin_winid)
    assert.are.same({ split }, current_tab_views(instance))
  end)

  it("keeps independent active Views across tabs and supports tab-local and global hide", function()
    local entries = {}
    for index = 1, 60 do entries[string.format("item-%02d.txt", index)] = "x" end
    local instance = ready(entries)
    local first_tab = vim.api.nvim_get_current_tabpage()
    local first_previous = vim.api.nvim_get_current_buf()
    local first = open_view(instance, { position = "current" })
    vim.api.nvim_win_set_cursor(first, instance:get_pos("item-15.txt"))
    vim.api.nvim_win_call(first, function() vim.cmd("normal! zt") end)

    vim.cmd("tabnew")
    local second_tab = vim.api.nvim_get_current_tabpage()
    local second = open_view(instance, { position = "current" })
    vim.api.nvim_win_set_cursor(second, instance:get_pos("item-45.txt"))
    vim.api.nvim_win_call(second, function() vim.cmd("normal! zb") end)
    local first_cursor, first_view = vim.api.nvim_win_get_cursor(first), saved_view(first)
    local second_cursor, second_view = vim.api.nvim_win_get_cursor(second), saved_view(second)

    vim.api.nvim_set_current_tabpage(first_tab)
    assert.are.equal(first, open_view(instance))
    vim.api.nvim_set_current_tabpage(second_tab)
    assert.are.equal(second, open_view(instance))
    assert.are.same(first_cursor, vim.api.nvim_win_get_cursor(first))
    assert.are.same(first_view, saved_view(first))
    assert.are.same(second_cursor, vim.api.nvim_win_get_cursor(second))
    assert.are.same(second_view, saved_view(second))
    assert.are.equal(first, fre.view.inspect(instance, first_tab).winid)
    assert.are.equal(second, fre.view.inspect(instance, second_tab).winid)
    assert.is_true(instance:hidden(first_tab))
    assert.is_nil(fre.view.inspect(instance, first_tab))
    assert.are.equal(first_previous, vim.api.nvim_win_get_buf(first))
    assert.are.equal(second, fre.view.inspect(instance, second_tab).winid)
    assert.are.same(second_cursor, vim.api.nvim_win_get_cursor(second))
    assert.are.same(second_view, saved_view(second))

    assert.is_true(instance:hide_all())
    assert.is_nil(fre.view.inspect(instance, second_tab))
    assert.are_not.equal(instance.bufnr, vim.api.nvim_win_get_buf(second))
  end)

  it("derives closed-tab Views immediately through inspect and hidden", function()
    local instance = ready()
    vim.cmd("tabnew")
    local inspected_tab = vim.api.nvim_get_current_tabpage()
    open_view(instance, { position = "current" })
    assert.are.equal("ready", instance.state)

    vim.cmd("tabclose")
    assert.is_false(vim.api.nvim_tabpage_is_valid(inspected_tab))
    assert.is_nil(fre.view.inspect(instance, inspected_tab))
    assert.are.equal("ready", instance.state)

    vim.cmd("tabnew")
    local hidden_tab = vim.api.nvim_get_current_tabpage()
    open_view(instance, { position = "current" })
    vim.cmd("tabclose")
    assert.is_false(vim.api.nvim_tabpage_is_valid(hidden_tab))
    assert.is_true(instance:hidden(hidden_tab))
    assert.are.equal("ready", instance.state)
  end)


  it("reopens hidden Views from the immutable Instance default without layout history", function()
    local configured = { position = "right", size = 20 }
    local instance = ready(nil, { layout = configured })
    configured.size = 35
    local top = open_view(instance, { position = "top", size = 7 })
    assert.are.equal(7, vim.api.nvim_win_get_height(top))
    instance:hidden()

    local reopened = open_view(instance)
    assert.are.equal(20, vim.api.nvim_win_get_width(reopened))
    assert.are.same({ position = "right", size = 20 }, fre.view.inspect(instance).layout)
  end)

  it("restores current buffers and closes Fre-created destinations on hide", function()
    local instance = ready()
    local current = vim.api.nvim_get_current_win()
    local previous = scratch()
    vim.api.nvim_win_set_buf(current, previous)
    assert.are.equal(current, open_view(instance, { position = "current" }))
    assert.is_true(instance:hidden())
    assert.is_true(vim.api.nvim_win_is_valid(current))
    assert.are.equal(previous, vim.api.nvim_win_get_buf(current))

    local split = open_view(instance, { position = "left", size = 20 })
    assert.is_true(instance:hidden())
    assert.is_false(vim.api.nvim_win_is_valid(split))

    local floated = open_view(instance, {
      position = "float", width = 40, height = 10,
    })
    assert.is_true(instance:hidden())
    assert.is_false(vim.api.nvim_win_is_valid(floated))
  end)

  it("installs a safe buffer when a close-on-hide View is the final ordinary window", function()
    local instance = ready()
    local origin = vim.api.nvim_get_current_win()
    local split = open_view(instance, { position = "left", size = 20 })
    vim.api.nvim_win_close(origin, true)
    assert.is_true(vim.api.nvim_win_is_valid(split))

    assert.is_true(instance:hidden())
    assert.is_true(vim.api.nvim_win_is_valid(split))
    assert.are_not.equal(instance.bufnr, vim.api.nvim_win_get_buf(split))
    assert.is_nil(fre.view.inspect(instance))
  end)

  it("inspects editor truth defensively and retains requested layout through resize", function()
    local instance = ready()
    local origin = vim.api.nvim_get_current_win()
    local winid = open_view(instance, { position = "left", size = 20 })
    local inspected = assert(fre.view.inspect(instance))
    assert.are.equal(winid, inspected.winid)
    assert.are.equal(origin, inspected.origin_winid)
    inspected.layout.size = 99
    assert.are.equal(20, fre.view.inspect(instance).layout.size)

    vim.api.nvim_win_set_width(winid, 27)
    assert.are.equal(27, vim.api.nvim_win_get_width(winid))
    assert.are.equal(20, fre.view.inspect(instance).layout.size)
    assert.are.equal(winid, open_view(instance, { position = "left", size = 20 }))
    assert.are.equal(27, vim.api.nvim_win_get_width(winid))

    vim.api.nvim_win_set_buf(winid, scratch())
    assert.is_nil(fre.view.inspect(instance))
    assert.are_not.equal(instance.bufnr, vim.api.nvim_win_get_buf(winid))
  end)

  it("keeps the existing View when a replacement layout cannot be installed", function()
    local instance = ready()
    local managed = open_view(instance, { position = "current" })
    local before_wins = vim.api.nvim_tabpage_list_wins(0)
    local set_buf = vim.api.nvim_win_set_buf
    vim.api.nvim_win_set_buf = function(winid, bufnr)
      local result = set_buf(winid, bufnr)
      if winid ~= managed and bufnr == instance.bufnr then
        error("injected replacement failure")
      end
      return result
    end
    local ok, err = pcall(instance.open, instance, { position = "left", size = 20 })
    vim.api.nvim_win_set_buf = set_buf

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("injected replacement failure", 1, true))
    assert.are.same(before_wins, vim.api.nvim_tabpage_list_wins(0))
    assert.are.equal(managed, fre.view.inspect(instance).winid)
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(managed))
  end)

  it("rolls back only the exact destination when BufWinEnter creates an unrelated window", function()
    local owner = ready({ ["owner.txt"] = "owner" })
    local anchor = open_view(owner, { position = "current" })
    local tabpage = vim.api.nvim_get_current_tabpage()
    local owner_view = assert(fre.view.inspect(owner, tabpage))
    local anchor_cursor = vim.api.nvim_win_get_cursor(anchor)
    local anchor_view = saved_view(anchor)
    local layouts = {
      { position = "current" },
      { position = "right", size = 20 },
      { position = "float", width = 30, height = 8, row = 2, col = 4 },
    }

    for index, requested in ipairs(layouts) do
      local instance = ready({ ["target.txt"] = "target" })
      vim.api.nvim_set_current_win(anchor)
      local unrelated_buf = scratch()
      vim.api.nvim_buf_set_lines(unrelated_buf, 0, -1, false, { "callback window" })
      local before_buffers = vim.api.nvim_list_bufs()
      local before_windows = #vim.api.nvim_tabpage_list_wins(tabpage)
      local unrelated_win
      local raised = false
      local group = vim.api.nvim_create_augroup(
        "FreWindowExactRollback" .. tostring(instance.id) .. tostring(index), { clear = true })
      vim.api.nvim_create_autocmd("BufWinEnter", {
        group = group,
        once = true,
        callback = function(args)
          assert.are.equal(instance.bufnr, args.buf)
          raised = true
          unrelated_win = vim.api.nvim_open_win(unrelated_buf, false, {
            relative = "editor", width = 18, height = 3, row = 1, col = 1,
            noautocmd = true,
          })
          error("injected exact rollback BufWinEnter failure")
        end,
      })

      local ok, err = pcall(instance.open, instance, requested)
      vim.api.nvim_del_augroup_by_id(group)

      assert.is_false(ok)
      assert.is_truthy(tostring(err):find(
        "injected exact rollback BufWinEnter failure", 1, true))
      assert.is_true(raised)
      assert.is_not_nil(unrelated_win)
      assert.is_true(vim.api.nvim_win_is_valid(unrelated_win))
      assert.are.equal(unrelated_buf, vim.api.nvim_win_get_buf(unrelated_win))
      assert.are.equal(before_windows + 1, #vim.api.nvim_tabpage_list_wins(tabpage))
      assert.are.same(before_buffers, vim.api.nvim_list_bufs())
      assert.are.equal(tabpage, vim.api.nvim_get_current_tabpage())
      assert.are.equal(anchor, vim.api.nvim_get_current_win())
      assert.are.equal(owner.bufnr, vim.api.nvim_win_get_buf(anchor))
      assert.are.same(anchor_cursor, vim.api.nvim_win_get_cursor(anchor))
      assert.are.same(anchor_view, saved_view(anchor))
      assert.are.same(owner_view, fre.view.inspect(owner, tabpage))
      assert.is_nil(fre.view.inspect(instance, tabpage))
      vim.api.nvim_win_close(unrelated_win, true)
      instance:destroy()
    end
  end)

  it("captures a fresh origin after hide and reopen", function()
    local instance = ready()
    local first_origin = vim.api.nvim_get_current_win()
    open_view(instance, { position = "float", width = 30, height = 8 })
    assert.are.equal(first_origin, fre.view.inspect(instance).origin_winid)
    instance:hidden()

    vim.cmd("vsplit")
    local second_origin = vim.api.nvim_get_current_win()
    open_view(instance, { position = "float", width = 30, height = 8 })
    assert.are.equal(second_origin, fre.view.inspect(instance).origin_winid)
    assert.are_not.equal(first_origin, second_origin)
  end)

  it("implements strictly binary tab-local toggle", function()
    local instance = ready()
    assert.are.equal(instance, instance:toggle({ position = "left", size = 22 }))
    local first = assert(fre.view.inspect(instance)).winid
    assert.is_true(instance:toggle({ position = "top", size = 6 }))
    assert.is_nil(fre.view.inspect(instance))
    assert.is_false(vim.api.nvim_win_is_valid(first))

    assert.are.equal(instance, instance:toggle({ position = "top", size = 6 }))
    local opened = assert(fre.view.inspect(instance)).winid
    assert.are.equal(6, vim.api.nvim_win_get_height(opened))
  end)

  it("supports native duplicate Views and hides every duplicate in the tab", function()
    local instance = ready()
    local managed = open_view(instance, { position = "current" })
    vim.cmd("vsplit")
    local duplicate = vim.api.nvim_get_current_win()
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(duplicate))
    assert.are_not.equal(managed, duplicate)

    assert.are.same({
      winid = duplicate, origin_winid = duplicate, layout = { position = "current" },
    }, fre.view.inspect(instance))
    assert.are.same({ managed, duplicate }, current_tab_views(instance))
    assert.is_true(instance:hidden())
    assert.is_nil(fre.view.inspect(instance))
    assert.are.same({}, current_tab_views(instance))
    assert.is_true(vim.api.nvim_win_is_valid(managed))
    assert.is_true(vim.api.nvim_win_is_valid(duplicate))
    assert.are_not.equal(instance.bufnr, vim.api.nvim_win_get_buf(managed))
    assert.are_not.equal(instance.bufnr, vim.api.nvim_win_get_buf(duplicate))
  end)

  it("reconciles a noautocmd View before reusing it through open", function()
    local instance = ready()
    local winid = vim.api.nvim_get_current_win()
    assert.is_not_nil(instance.hidden_since)
    vim.cmd("noautocmd buffer " .. tostring(instance.bufnr))
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(winid))
    assert.is_not_nil(instance.hidden_since)

    assert.are.equal(winid, open_view(instance))
    assert.is_nil(instance.hidden_since)
  end)

  it("focuses a reused noncurrent View before surfacing its enter failure", function()
    local instance = ready()
    local caller = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local target = vim.api.nvim_get_current_win()
    vim.cmd("noautocmd buffer " .. tostring(instance.bufnr))
    vim.api.nvim_set_current_win(caller)
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(target))
    assert.are_not.equal(target, vim.api.nvim_get_current_win())
    assert.is_not_nil(instance.hidden_since)

    local original = instance._on_presentation_enter
    instance._on_presentation_enter = function()
      error("injected noncurrent open presentation failure")
    end
    local ok, err = pcall(instance.open, instance)
    instance._on_presentation_enter = original

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find(
      "injected noncurrent open presentation failure", 1, true
    ))
    assert.are.equal(target, vim.api.nvim_get_current_win())
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(target))
    assert.is_nil(instance.hidden_since)
    assert.are.equal(target, assert(fre.view.inspect(instance)).winid)
  end)

  it("surfaces an explicit open enter failure after keeping the View committed", function()
    local instance = ready()
    local original = instance._on_presentation_enter
    instance._on_presentation_enter = function()
      error("injected explicit open presentation failure")
    end

    local ok, err = pcall(instance.open, instance, { position = "current" })
    instance._on_presentation_enter = original
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find(
      "injected explicit open presentation failure", 1, true
    ))
    local inspected = assert(fre.view.inspect(instance))
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(inspected.winid))
    assert.are.equal(inspected.winid, vim.api.nvim_get_current_win())
    assert.is_nil(instance.hidden_since)
  end)

  it("discards malformed exact policy and hides with conservative View behavior", function()
    local instance = ready()
    local winid = open_view(instance, { position = "current" })
    vim.api.nvim_win_set_var(winid, "fre_view", {
      version = 1,
      winid = winid,
      tabpage = vim.api.nvim_win_get_tabpage(winid),
      layout = { position = "bogus" },
      mode = "restore",
      origin_winid = "bad",
      previous_bufnr = "bad",
    })

    assert.are.same({
      winid = winid, origin_winid = winid, layout = { position = "current" },
    }, fre.view.inspect(instance, { winid = winid }))
    assert.is_true(instance:hidden())
    assert.are_not.equal(instance.bufnr, vim.api.nvim_win_get_buf(winid))
  end)

  it("uses native View selection when open is ambiguous away from every View", function()
    local instance = ready()
    local first = open_view(instance, { position = "current" })
    vim.cmd("vsplit")
    local second = vim.api.nvim_get_current_win()
    vim.cmd("new")
    local ordinary = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(ordinary, scratch())

    local confirm = vim.fn.confirm
    local prompt, choices
    vim.fn.confirm = function(actual_prompt, actual_choices)
      prompt, choices = actual_prompt, actual_choices
      return 2
    end
    local ok, selected = pcall(function() return select(2, instance:open()) end)
    vim.fn.confirm = confirm
    assert.is_true(ok, tostring(selected))
    assert.are.equal(second, selected)
    assert.are.equal(second, vim.api.nvim_get_current_win())
    assert.are.equal("fre: select View", prompt)
    assert.is_truthy(choices:find("&a", 1, true))
    assert.is_truthy(choices:find("&b", 1, true))

    vim.api.nvim_set_current_win(ordinary)
    local before = current_tab_views(instance)
    vim.fn.confirm = function() return 0 end
    ok, selected = pcall(instance.open, instance)
    vim.fn.confirm = confirm
    assert.is_false(ok)
    assert.is_truthy(tostring(selected):find("selection was cancelled", 1, true))
    assert.are.same(before, current_tab_views(instance))
    assert.are.equal(ordinary, vim.api.nvim_get_current_win())
    assert.are.same({ first, second }, before)
  end)

  it("rejects invalid hidden opens before mutating editor state", function()
    local instance = ready()
    local before_wins = vim.api.nvim_tabpage_list_wins(0)
    local before_layout = vim.fn.winlayout()
    local invalid = {
      {},
      { position = "unknown" },
      { position = "left", size = 0 },
      { position = "float", width = 20 },
      { position = "float", width = 20, height = 10, border = "invalid" },
    }
    for _, requested in ipairs(invalid) do
      assert.is_truthy(error_text(function() instance:open(requested) end):find("layout", 1, true))
      assert.are.same(before_wins, vim.api.nvim_tabpage_list_wins(0))
      assert.are.same(before_layout, vim.fn.winlayout())
      assert.is_nil(fre.view.inspect(instance))
    end
  end)

  it("keeps omitted window options isolated across two Instances", function()
    local first = ready(nil, {
      layout = { position = "current" },
      window = { options = { cursorline = true, number = true } },
    })
    local second = ready(nil, { layout = { position = "current" } })
    local winid = open_view(second)
    vim.api.nvim_set_option_value("cursorline", false, { scope = "local", win = winid })
    vim.api.nvim_set_option_value("number", false, { scope = "local", win = winid })

    assert.are.equal(winid, open_view(first))
    assert.is_true(vim.api.nvim_get_option_value(
      "cursorline", { scope = "local", win = winid }
    ))
    assert.is_true(vim.api.nvim_get_option_value(
      "number", { scope = "local", win = winid }
    ))

    assert.are.equal(winid, open_view(second))
    assert.is_false(vim.api.nvim_get_option_value(
      "cursorline", { scope = "local", win = winid }
    ))
    assert.is_false(vim.api.nvim_get_option_value(
      "number", { scope = "local", win = winid }
    ))
  end)
end)
