local fre = require("fre")
local fs = require("tests.helpers.fs")

local fixture
local instances = {}
local original_geometry

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
    return instance.state == "ready-hidden" or instance.state == "ready-visible"
      or instance.state == "load-failed"
  end)
  assert.are_not.equal("load-failed", instance.state, tostring(instance.error))
  return instance
end

local function current_tab_views(instance)
  local result = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == instance.bufnr then
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

local function view(winid)
  return vim.api.nvim_win_call(winid, vim.fn.winsaveview)
end

local function screenpos(winid)
  local pos = vim.fn.win_screenpos(winid)
  return pos[1], pos[2]
end

local function assert_fre_window(instance, winid)
  assert.is_true(vim.api.nvim_win_is_valid(winid))
  assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(winid))
  assert.are.equal(winid, vim.api.nvim_get_current_win())
end

local function open_view(instance, layout)
  assert.are.equal(instance, instance:open(layout))
  return vim.api.nvim_get_current_win()
end

describe("fre ticket 16 window layouts", function()
  before_each(function()
    pcall(vim.cmd, "silent! tabonly")
    pcall(vim.cmd, "silent! only")
    vim.cmd("enew")
    fixture = fs.new()
    instances = {}
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
    vim.o.columns = original_geometry.columns
    vim.o.lines = original_geometry.lines
    vim.o.cmdheight = original_geometry.cmdheight
    vim.o.laststatus = original_geometry.laststatus
    vim.o.showtabline = original_geometry.showtabline
    fre._reset_fs_adapter()
    fixture:cleanup()
  end)

  it("opens current and every absolute split layout with stable placement and focus", function()
    local instance = ready()
    local original = vim.api.nvim_get_current_win()
    assert.are.equal(original, open_view(instance, { position = "current" }))
    assert_fre_window(instance, original)

    local cases = {
      { position = "left", size = 24, axis = "width" },
      { position = "right", size = 25, axis = "width" },
      { position = "top", size = 8, axis = "height" },
      { position = "bottom", size = 9, axis = "height" }
    }
    for _, layout in ipairs(cases) do
      local winid = open_view(instance, { position = layout.position, size = layout.size })
      assert_fre_window(instance, winid)
      if layout.axis == "width" then
        assert.are.equal(layout.size, vim.api.nvim_win_get_width(winid))
      else
        assert.are.equal(layout.size, vim.api.nvim_win_get_height(winid))
      end
      local row, col = screenpos(winid)
      if layout.position == "left" then assert.are.equal(1, col) end
      if layout.position == "right" then assert.is_true(col > 1) end
      if layout.position == "top" then assert.are.equal(1, row) end
      if layout.position == "bottom" then assert.is_true(row > 1) end
    end
  end)

  it("resolves split ratios and float absolute, ratio, centered, border, and focus geometry", function()
    local instance = ready()
    local left = open_view(instance, { position = "left", size = 0.25 })
    assert.are.equal(30, vim.api.nvim_win_get_width(left))
    local top = open_view(instance, { position = "top", size = 0.25 })
    assert.are.equal(10, vim.api.nvim_win_get_height(top))

    local floated = open_view(instance, {
      position = "float", width = 0.5, height = 0.5,
      row = 0.25, col = 0.25, border = "rounded",
    })
    assert_fre_window(instance, floated)
    local config = vim.api.nvim_win_get_config(floated)
    assert.are.equal("editor", config.relative)
    assert.are.equal(60, config.width)
    assert.are.equal(20, config.height)
    assert.are.equal(10, config.row)
    assert.are.equal(30, config.col)
    assert.is_true(#config.border == 8)

    local centered = open_view(instance, {
      position = "float", width = 40, height = 10,
      border = { "-", "-", "-", "|", "-", "-", "-", "|" },
    })
    config = vim.api.nvim_win_get_config(centered)
    assert.are.equal(40, config.col)
    assert.are.equal(15, config.row)
    assert.are.equal(40, config.width)
    assert.are.equal(10, config.height)
  end)

  it("enforces exact split capacity and bordered float outer bounds before mutation", function()
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

    local bordered = open_view(instance, {
      position = "float", width = vim.o.columns - 2, height = 5,
      row = 0, col = 0, border = "single",
    })
    assert.are.equal(vim.o.columns - 2, vim.api.nvim_win_get_config(bordered).width)
    local right_only = { "", "", "", "|", "", "", "", "" }
    local edged = open_view(instance, {
      position = "float", width = vim.o.columns - 1, height = 5,
      row = 0, col = 0, border = right_only,
    })
    assert.are.equal(vim.o.columns - 1, vim.api.nvim_win_get_config(edged).width)
    before_wins = vim.api.nvim_tabpage_list_wins(0)
    before_layout = vim.fn.winlayout()
    assert.is_truthy(error_text(function()
      instance:open({
        position = "float", width = vim.o.columns, height = 5,
        row = 0, col = 0, border = "single",
      })
    end):find("bordered float", 1, true))
    assert.are.same(before_wins, vim.api.nvim_tabpage_list_wins(0))
    assert.are.same(before_layout, vim.fn.winlayout())
    assert.are.equal(edged, vim.api.nvim_get_current_win())
  end)

  it("rejects invalid exact layout shapes atomically before changing editor or instance state", function()
    local instance = ready()
    local winid = open_view(instance, { position = "left", size = 20 })
    local before = {
      wins = vim.api.nvim_tabpage_list_wins(0),
      current = vim.api.nvim_get_current_win(),
      buffers = {},
      state = instance.state,
      layouts = vim.deepcopy(instance._last_layout_by_tab),
    }
    for _, id in ipairs(before.wins) do before.buffers[id] = vim.api.nvim_win_get_buf(id) end
    local invalid = {
      "left",
      {},
      { position = "unknown" },
      { position = "current", size = 1 },
      { position = "left" },
      { position = "left", size = 0 },
      { position = "left", size = 1.5 },
      { position = "left", size = 20, width = 2 },
      { position = "float", width = 20 },
      { position = "float", width = 20, height = 10, row = -1 },
      { position = "float", width = 20, height = 10, border = "invalid" },
      { position = "float", width = 121, height = 10 },
      { position = "float", width = 20, height = 10, extra = true },
    }
    for _, layout in ipairs(invalid) do
      assert.is_truthy(error_text(function() instance:open(layout) end):find("layout", 1, true))
      assert.are.same(before.wins, vim.api.nvim_tabpage_list_wins(0))
      assert.are.equal(before.current, vim.api.nvim_get_current_win())
      for id, bufnr in pairs(before.buffers) do assert.are.equal(bufnr, vim.api.nvim_win_get_buf(id)) end
      assert.are.equal(before.state, instance.state)
      assert.are.same(before.layouts, instance._last_layout_by_tab)
      assert.are.equal(winid, current_tab_views(instance)[1])
    end
    assert.is_truthy(error_text(function()
      instance:toggle({ position = "left", size = 0 })
    end):find("layout", 1, true))
    assert.are.same(before.wins, vim.api.nvim_tabpage_list_wins(0))
    assert.are.equal(winid, current_tab_views(instance)[1])
  end)

  it("rolls back partial split and float creation failures without replacing the selected view", function()
    local instance = ready()
    local selected = open_view(instance, { position = "current" })
    local before = {
      wins = vim.api.nvim_tabpage_list_wins(0),
      layout = vim.fn.winlayout(),
      current = vim.api.nvim_get_current_win(),
      state = instance.state,
      layouts = vim.deepcopy(instance._last_layout_by_tab),
    }

    local set_buf = vim.api.nvim_win_set_buf
    vim.api.nvim_win_set_buf = function(winid, bufnr)
      local result = set_buf(winid, bufnr)
      if winid ~= selected and bufnr == instance.bufnr then error("injected split failure") end
      return result
    end
    local split_ok, split_err = pcall(instance.open, instance, { position = "left", size = 20 })
    vim.api.nvim_win_set_buf = set_buf
    assert.is_false(split_ok)
    assert.is_truthy(tostring(split_err):find("injected split failure", 1, true))
    assert.are.same(before.wins, vim.api.nvim_tabpage_list_wins(0))
    assert.are.same(before.layout, vim.fn.winlayout())
    assert.are.equal(before.current, vim.api.nvim_get_current_win())
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(selected))
    assert.are.equal(before.state, instance.state)
    assert.are.same(before.layouts, instance._last_layout_by_tab)

    local open_win = vim.api.nvim_open_win
    vim.api.nvim_open_win = function(...)
      open_win(...)
      error("injected float failure")
    end
    local float_ok, float_err = pcall(instance.open, instance, {
      position = "float", width = 40, height = 10,
    })
    vim.api.nvim_open_win = open_win
    assert.is_false(float_ok)
    assert.is_truthy(tostring(float_err):find("injected float failure", 1, true))
    assert.are.same(before.wins, vim.api.nvim_tabpage_list_wins(0))
    assert.are.same(before.layout, vim.fn.winlayout())
    assert.are.equal(before.current, vim.api.nvim_get_current_win())
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(selected))
    assert.are.equal(before.state, instance.state)
    assert.are.same(before.layouts, instance._last_layout_by_tab)
  end)

  it("rolls back construction and true retirement failures but commits post-retirement errors", function()
    local instance = ready()
    local selected = open_view(instance, { position = "current" })
    vim.api.nvim_win_set_cursor(selected, instance:get_pos("b.txt"))
    vim.cmd("new")
    local caller = vim.api.nvim_get_current_win()
    local before = {
      wins = vim.api.nvim_tabpage_list_wins(0),
      buffers = vim.api.nvim_list_bufs(),
      layout = vim.fn.winlayout(),
      history = vim.deepcopy(instance._last_layout_by_tab),
      view = view(selected),
    }

    local set_current = vim.api.nvim_set_current_win
    vim.api.nvim_set_current_win = function(winid)
      if winid == selected then error("injected focus failure") end
      return set_current(winid)
    end
    local focus_ok, focus_err = pcall(instance.open, instance, { position = "current" })
    vim.api.nvim_set_current_win = set_current
    assert.is_false(focus_ok)
    assert.is_truthy(tostring(focus_err):find("injected focus failure", 1, true))
    assert.are.same(before.wins, vim.api.nvim_tabpage_list_wins(0))
    assert.are.same(before.layout, vim.fn.winlayout())
    assert.are.same(before.history, instance._last_layout_by_tab)
    assert.are.equal(caller, vim.api.nvim_get_current_win())

    local close = vim.api.nvim_win_close
    vim.api.nvim_win_close = function(winid, force)
      if winid == selected then error("injected pre-close failure") end
      return close(winid, force)
    end
    local ok, err = pcall(instance.open, instance, { position = "left", size = 20 })
    vim.api.nvim_win_close = close
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("injected pre-close failure", 1, true))
    assert.are.same(before.wins, vim.api.nvim_tabpage_list_wins(0))
    assert.are.same(before.buffers, vim.api.nvim_list_bufs())
    assert.are.same(before.layout, vim.fn.winlayout())
    assert.are.same(before.history, instance._last_layout_by_tab)
    assert.are.same(before.view, view(selected))
    assert.are.equal(caller, vim.api.nvim_get_current_win())

    local set_var = vim.api.nvim_win_set_var
    vim.api.nvim_win_set_var = function(winid, name, value)
      if winid ~= selected and name:find("fre_layout_", 1, true) then
        error("injected metadata failure")
      end
      return set_var(winid, name, value)
    end
    ok, err = pcall(instance.open, instance, {
      position = "float", width = 30, height = 8,
    })
    vim.api.nvim_win_set_var = set_var
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("injected metadata failure", 1, true))
    assert.are.same(before.wins, vim.api.nvim_tabpage_list_wins(0))
    assert.are.same(before.buffers, vim.api.nvim_list_bufs())
    assert.are.same(before.layout, vim.fn.winlayout())
    assert.are.same(before.history, instance._last_layout_by_tab)
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(selected))

    local get_width = vim.api.nvim_win_get_width
    local existing = {}
    for _, winid in ipairs(before.wins) do existing[winid] = true end
    vim.api.nvim_win_get_width = function(winid)
      local width = get_width(winid)
      if not existing[winid] and vim.api.nvim_win_is_valid(winid)
          and vim.api.nvim_win_get_buf(winid) == instance.bufnr then return width + 1 end
      return width
    end
    ok, err = pcall(instance.open, instance, { position = "right", size = 21 })
    vim.api.nvim_win_get_width = get_width
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("materialized exactly", 1, true))
    assert.are.same(before.wins, vim.api.nvim_tabpage_list_wins(0))
    assert.are.same(before.layout, vim.fn.winlayout())
    assert.are.same(before.history, instance._last_layout_by_tab)

    vim.api.nvim_win_close = function(winid, force)
      local result = close(winid, force)
      if winid == selected then error("injected post-close failure") end
      return result
    end
    ok, err = pcall(instance.open, instance, { position = "left", size = 20 })
    vim.api.nvim_win_close = close
    assert.is_true(ok, tostring(err))
    local replacement = vim.api.nvim_get_current_win()
    assert.is_false(vim.api.nvim_win_is_valid(selected))
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(replacement))
    assert.are.equal(20, vim.api.nvim_win_get_width(replacement))
    assert.are.same({ position = "left", size = 20 },
      instance._last_layout_by_tab[vim.api.nvim_get_current_tabpage()])
  end)

  it("restores current destinations after option and BufWinEnter failures", function()
    local instance = ready(nil, {
      layout = { position = "current" },
      window = { options = { number = true, cursorline = true } },
    })
    local unrelated = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = unrelated })
    local caller = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(caller, unrelated)
    vim.wo[caller].number = false
    vim.wo[caller].cursorline = false
    local before_wins = vim.api.nvim_tabpage_list_wins(0)
    local before_buffers = vim.api.nvim_list_bufs()
    local before_history = vim.deepcopy(instance._last_layout_by_tab)

    local set_option = vim.api.nvim_set_option_value
    local raised = false
    vim.api.nvim_set_option_value = function(name, value, opts)
      if not raised and name == "number" and opts and opts.win == caller
          and vim.api.nvim_win_get_buf(caller) == instance.bufnr then
        set_option(name, value, opts)
        raised = true
        error("injected current option failure")
      end
      return set_option(name, value, opts)
    end
    local ok, err = pcall(instance.open, instance, { position = "current" })
    vim.api.nvim_set_option_value = set_option
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("injected current option failure", 1, true))
    assert.is_true(raised)
    assert.are.same(before_wins, vim.api.nvim_tabpage_list_wins(0))
    assert.are.same(before_buffers, vim.api.nvim_list_bufs())
    assert.are.same(before_history, instance._last_layout_by_tab)
    assert.are.equal(caller, vim.api.nvim_get_current_win())
    assert.are.equal(unrelated, vim.api.nvim_win_get_buf(caller))
    assert.is_true(vim.api.nvim_buf_is_valid(unrelated))
    assert.are.equal("wipe", vim.api.nvim_get_option_value("bufhidden", { buf = unrelated }))
    assert.is_false(vim.wo[caller].number)
    assert.is_false(vim.wo[caller].cursorline)
    assert.are.same({}, current_tab_views(instance))
    assert.are.equal("ready-hidden", instance.state)

    local set_var = vim.api.nvim_win_set_var
    local metadata_raised = false
    vim.api.nvim_win_set_var = function(winid, name, value)
      local result = set_var(winid, name, value)
      if not metadata_raised and winid == caller and name:find("fre_layout_", 1, true) then
        metadata_raised = true
        error("injected current metadata failure")
      end
      return result
    end
    ok, err = pcall(instance.open, instance, { position = "current" })
    vim.api.nvim_win_set_var = set_var
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("injected current metadata failure", 1, true))
    assert.is_true(metadata_raised)
    assert.are.same(before_wins, vim.api.nvim_tabpage_list_wins(0))
    assert.are.same(before_buffers, vim.api.nvim_list_bufs())
    assert.are.same(before_history, instance._last_layout_by_tab)
    assert.are.equal(caller, vim.api.nvim_get_current_win())
    assert.are.equal(unrelated, vim.api.nvim_win_get_buf(caller))
    assert.is_true(vim.api.nvim_buf_is_valid(unrelated))
    assert.are.equal("wipe", vim.api.nvim_get_option_value("bufhidden", { buf = unrelated }))
    assert.is_false(vim.wo[caller].number)
    assert.is_false(vim.wo[caller].cursorline)
    assert.is_false(pcall(vim.api.nvim_win_get_var, caller, "fre_layout_" .. instance.id))
    assert.are.same({}, current_tab_views(instance))
    assert.are.equal("ready-hidden", instance.state)

    local selected = open_view(instance, { position = "left", size = 20 })
    vim.api.nvim_win_set_cursor(selected, instance:get_pos("b.txt"))
    vim.cmd("new")
    local switch_caller = vim.api.nvim_get_current_win()
    local switch_buffer = vim.api.nvim_win_get_buf(switch_caller)
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = switch_buffer })
    vim.wo[switch_caller].number = false
    vim.wo[switch_caller].cursorline = false
    before_wins = vim.api.nvim_tabpage_list_wins(0)
    before_buffers = vim.api.nvim_list_bufs()
    before_history = vim.deepcopy(instance._last_layout_by_tab)
    local selected_view = view(selected)
    local group = vim.api.nvim_create_augroup("FreWindowInjected" .. instance.id, { clear = true })
    local autocmd_ran = false
    vim.api.nvim_create_autocmd("BufWinEnter", {
      group = group, buffer = instance.bufnr,
      callback = function()
        if not autocmd_ran then
          autocmd_ran = true
          error("injected BufWinEnter failure")
        end
      end,
    })
    ok, err = pcall(instance.open, instance, { position = "current" })
    vim.api.nvim_del_augroup_by_id(group)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("injected BufWinEnter failure", 1, true))
    assert.is_true(autocmd_ran)
    assert.are.same(before_wins, vim.api.nvim_tabpage_list_wins(0))
    assert.are.same(before_buffers, vim.api.nvim_list_bufs())
    assert.are.same(before_history, instance._last_layout_by_tab)
    assert.are.equal(switch_caller, vim.api.nvim_get_current_win())
    assert.are.equal(switch_buffer, vim.api.nvim_win_get_buf(switch_caller))
    assert.is_true(vim.api.nvim_buf_is_valid(switch_buffer))
    assert.are.equal("wipe", vim.api.nvim_get_option_value("bufhidden", { buf = switch_buffer }))
    assert.is_false(vim.wo[switch_caller].number)
    assert.is_false(vim.wo[switch_caller].cursorline)
    assert.is_true(vim.api.nvim_win_is_valid(selected))
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(selected))
    assert.are.same(selected_view, view(selected))
  end)

  it("cleans scratch retirement attempts when the last ordinary view cannot be replaced", function()
    local instance = ready()
    local selected = open_view(instance, { position = "current" })
    local before_wins = vim.api.nvim_tabpage_list_wins(0)
    local before_buffers = vim.api.nvim_list_bufs()
    local before_layout = vim.fn.winlayout()
    local before_history = vim.deepcopy(instance._last_layout_by_tab)
    local set_buf = vim.api.nvim_win_set_buf
    vim.api.nvim_win_set_buf = function(winid, bufnr)
      if winid == selected and bufnr ~= instance.bufnr then
        error("injected scratch retirement failure")
      end
      return set_buf(winid, bufnr)
    end
    local ok, err = pcall(instance.open, instance, {
      position = "float", width = 30, height = 8,
    })
    vim.api.nvim_win_set_buf = set_buf
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("injected scratch retirement failure", 1, true))
    assert.are.same(before_wins, vim.api.nvim_tabpage_list_wins(0))
    assert.are.same(before_buffers, vim.api.nvim_list_bufs())
    assert.are.same(before_layout, vim.fn.winlayout())
    assert.are.same(before_history, instance._last_layout_by_tab)
    assert.are.equal(selected, vim.api.nvim_get_current_win())
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(selected))
  end)

  it("resolves no-argument layout from independent per-tab history before the config snapshot", function()
    local configured_layout = { position = "right", size = 20 }
    local instance = ready(nil, { layout = configured_layout })
    configured_layout.size = 35
    local first_tab = vim.api.nvim_get_current_tabpage()
    local configured = open_view(instance)
    assert.are.equal(20, vim.api.nvim_win_get_width(configured))
    open_view(instance, { position = "top", size = 7 })
    instance:hidden()
    local remembered = open_view(instance)
    assert.are.equal(7, vim.api.nvim_win_get_height(remembered))

    vim.cmd("tabnew")
    local second_tab = vim.api.nvim_get_current_tabpage()
    local fallback = open_view(instance)
    assert.are.equal(20, vim.api.nvim_win_get_width(fallback))
    open_view(instance, { position = "left", size = 15 })
    instance:hidden()
    assert.are.equal(15, vim.api.nvim_win_get_width(open_view(instance)))

    vim.api.nvim_set_current_tabpage(first_tab)
    instance:hidden()
    assert.are.equal(7, vim.api.nvim_win_get_height(open_view(instance)))
    assert.are_not.same(instance._last_layout_by_tab[first_tab], instance._last_layout_by_tab[second_tab])
  end)

  it("reuses a matching effective layout without disturbing its cursor or saved view", function()
    local entries = {}
    for index = 1, 50 do entries[string.format("item-%02d.txt", index)] = "x" end
    local instance = ready(entries)
    local winid = open_view(instance, { position = "left", size = 0.25 })
    vim.api.nvim_win_set_cursor(winid, instance:get_pos("item-30.txt"))
    vim.api.nvim_win_call(winid, function() vim.cmd("normal! zt") end)
    local cursor_before = vim.api.nvim_win_get_cursor(winid)
    local view_before = view(winid)
    vim.cmd("wincmd p")

    assert.are.equal(winid, open_view(instance, { position = "left", size = 30 }))
    assert.are.same(cursor_before, vim.api.nvim_win_get_cursor(winid))
    assert.are.same(view_before, view(winid))
    assert.are.equal(1, #current_tab_views(instance))
  end)

  it("selects the current Fre window first and otherwise the lowest valid window ID", function()
    local instance = ready()
    local first = open_view(instance, { position = "current" })
    vim.cmd("vsplit")
    local second = vim.api.nvim_get_current_win()
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(second))
    assert.are.equal(second, open_view(instance, { position = "current" }))

    vim.cmd("new")
    local user = vim.api.nvim_get_current_win()
    assert.are_not.equal(instance.bufnr, vim.api.nvim_win_get_buf(user))
    assert.are.equal(math.min(first, second), open_view(instance, { position = "current" }))
  end)

  it("switches only the selected view while preserving current-tab and other-tab views and cursors", function()
    local instance = ready()
    local first = open_view(instance, { position = "current" })
    vim.cmd("vsplit")
    local selected = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(first, instance:get_pos("a.txt"))
    vim.api.nvim_win_set_cursor(selected, instance:get_pos("b.txt"))

    local first_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    local other_tab = vim.api.nvim_get_current_tabpage()
    local other = open_view(instance, { position = "current" })
    vim.api.nvim_win_set_cursor(other, instance:get_pos("c.txt"))
    vim.api.nvim_set_current_tabpage(first_tab)
    vim.api.nvim_set_current_win(selected)

    local replacement = open_view(instance, { position = "float", width = 50, height = 12 })
    assert.is_false(vim.api.nvim_win_is_valid(selected))
    assert.is_true(vim.api.nvim_win_is_valid(first))
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(first))
    assert.are.same(instance:get_pos("a.txt"), vim.api.nvim_win_get_cursor(first))
    assert.are.same(instance:get_pos("b.txt"), vim.api.nvim_win_get_cursor(replacement))
    assert.are.equal(replacement, open_view(instance, { position = "current" }))
    assert.is_true(vim.api.nvim_win_is_valid(first))
    assert.are.same(instance:get_pos("a.txt"), vim.api.nvim_win_get_cursor(first))
    assert.are.same(instance:get_pos("b.txt"), vim.api.nvim_win_get_cursor(replacement))
    assert.is_true(vim.api.nvim_win_is_valid(other))
    assert.are.same(instance:get_pos("c.txt"), vim.api.nvim_win_get_cursor(other))
    assert.are.equal(other_tab, vim.api.nvim_win_get_tabpage(other))
  end)

  it("hides all current-tab views while retaining other tabs and handles the last ordinary window", function()
    local instance = ready()
    local only = open_view(instance, { position = "current" })
    assert.is_true(instance:hidden())
    assert.is_true(vim.api.nvim_win_is_valid(only))
    assert.are_not.equal(instance.bufnr, vim.api.nvim_win_get_buf(only))
    assert.is_true(vim.api.nvim_buf_is_valid(instance.bufnr))
    assert.are.equal("ready-hidden", instance.state)

    local first_tab = vim.api.nvim_get_current_tabpage()
    local one = open_view(instance, { position = "current" })
    vim.cmd("vsplit")
    local two = vim.api.nvim_get_current_win()
    vim.cmd("new")
    vim.cmd("tabnew")
    local other = open_view(instance, { position = "current" })
    vim.api.nvim_set_current_tabpage(first_tab)
    local close = vim.api.nvim_win_close
    local closed = {}
    vim.api.nvim_win_close = function(winid, force)
      closed[#closed + 1] = winid
      return close(winid, force)
    end
    local ok, result = pcall(instance.hidden, instance)
    vim.api.nvim_win_close = close
    assert.is_true(ok, tostring(result))
    assert.is_true(result)
    assert.are.same({ math.min(one, two), math.max(one, two) }, closed)
    assert.are.same({}, current_tab_views(instance))
    assert.is_false(vim.api.nvim_win_is_valid(one) and vim.api.nvim_win_get_buf(one) == instance.bufnr)
    assert.is_false(vim.api.nvim_win_is_valid(two) and vim.api.nvim_win_get_buf(two) == instance.bufnr)
    assert.is_true(vim.api.nvim_win_is_valid(other))
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(other))
    assert.are.equal("ready-visible", instance.state)
  end)

  it("implements hidden, matching-visible, and different-visible toggle states", function()
    local instance = ready()
    local left = { position = "left", size = 22 }
    local top = { position = "top", size = 6 }
    assert.are.equal(instance, instance:toggle(left))
    local opened = vim.api.nvim_get_current_win()
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(opened))
    assert.is_true(instance:toggle(left))
    assert.are.same({}, current_tab_views(instance))

    assert.are.equal(instance, instance:toggle(left))
    opened = vim.api.nvim_get_current_win()
    assert.are.equal(instance, instance:toggle(top))
    local switched = vim.api.nvim_get_current_win()
    assert.are_not.equal(opened, switched)
    assert.are.equal(6, vim.api.nvim_win_get_height(switched))
    assert.are.equal(1, #current_tab_views(instance))
    assert.is_true(instance:toggle())
    assert.are.same({}, current_tab_views(instance))
  end)

  it("applies configured options without retaining option lifecycle metadata", function()
    local instance = ready(nil, {
      layout = { position = "current" },
      window = { options = { cursorline = true, number = true } },
    })
    local first = open_view(instance)
    assert.is_true(vim.api.nvim_get_option_value(
      "cursorline", { scope = "local", win = first }
    ))
    assert.is_true(vim.api.nvim_get_option_value(
      "number", { scope = "local", win = first }
    ))
    local metadata = vim.api.nvim_win_get_var(first, "fre_layout_" .. instance.id)
    assert.are.same({
      bufnr = instance.bufnr,
      layout = { position = "current" },
      effective = { position = "current" },
    }, metadata)

    vim.cmd("vsplit")
    local manual = vim.api.nvim_get_current_win()
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(manual))
    assert.is_true(vim.api.nvim_get_option_value(
      "cursorline", { scope = "local", win = manual }
    ))
    assert.is_true(vim.api.nvim_get_option_value(
      "number", { scope = "local", win = manual }
    ))

    instance:hidden()
    assert.are.same({}, vim.fn.win_findbuf(instance.bufnr))
    assert.is_true(vim.api.nvim_buf_is_valid(instance.bufnr))
    local actual = vim.api.nvim_get_current_win()
    local normal = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("bufhidden", "hide", { buf = normal })
    vim.api.nvim_win_set_buf(actual, normal)
    vim.api.nvim_set_option_value("cursorline", false, { scope = "local", win = actual })
    vim.api.nvim_set_option_value("number", false, { scope = "local", win = actual })
    vim.api.nvim_win_set_buf(actual, instance.bufnr)
    wait_for(function() return instance.state == "ready-visible" end)
    assert.is_true(vim.api.nvim_get_option_value(
      "cursorline", { scope = "local", win = actual }
    ))
    assert.is_true(vim.api.nvim_get_option_value(
      "number", { scope = "local", win = actual }
    ))
    vim.api.nvim_win_set_buf(actual, normal)
    wait_for(function() return instance.state == "ready-hidden" end)
    assert.is_false(vim.api.nvim_get_option_value(
      "cursorline", { scope = "local", win = actual }
    ))
    assert.is_false(vim.api.nvim_get_option_value(
      "number", { scope = "local", win = actual }
    ))
  end)

  it("keeps omitted options isolated across Fre buffer pairings", function()
    local first = ready(nil, {
      layout = { position = "current" },
      window = { options = { cursorline = true } },
    })
    local second = ready(nil, { layout = { position = "current" } })
    local winid = open_view(second)
    vim.api.nvim_set_option_value("cursorline", false, { scope = "local", win = winid })

    assert.are.equal(winid, open_view(first))
    assert.is_true(vim.api.nvim_get_option_value(
      "cursorline", { scope = "local", win = winid }
    ))
    assert.are.equal(winid, open_view(second))
    assert.is_false(vim.api.nvim_get_option_value(
      "cursorline", { scope = "local", win = winid }
    ))
  end)

  it("applies configured options to a no-autocmd same-buffer split", function()
    local instance = ready(nil, {
      layout = { position = "current" },
      window = { options = { scroll = 3 } },
    })
    open_view(instance)
    local split = open_view(instance, { position = "left", size = 20 })
    assert.are.equal(instance.bufnr, vim.api.nvim_win_get_buf(split))
    assert.are.equal(3, vim.api.nvim_get_option_value(
      "scroll", { scope = "local", win = split }
    ))
  end)

  it("shares one buffer while preserving independent cursor and winsaveview state", function()
    local entries = {}
    for index = 1, 60 do entries[string.format("item-%02d.txt", index)] = "x" end
    local instance = ready(entries)
    local first = open_view(instance, { position = "current" })
    vim.cmd("vsplit")
    local second = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(first, instance:get_pos("item-15.txt"))
    vim.api.nvim_win_set_cursor(second, instance:get_pos("item-45.txt"))
    vim.api.nvim_win_call(first, function() vim.cmd("normal! zt") end)
    vim.api.nvim_win_call(second, function() vim.cmd("normal! zb") end)
    local first_view, second_view = view(first), view(second)

    assert.are.equal(vim.api.nvim_win_get_buf(first), vim.api.nvim_win_get_buf(second))
    assert.are_not.same(vim.api.nvim_win_get_cursor(first), vim.api.nvim_win_get_cursor(second))
    assert.are_not.equal(first_view.topline, second_view.topline)
    assert.are.same(first_view, view(first))
    assert.are.same(second_view, view(second))
  end)

  it("applies a pending reveal only to the selected new current-tab view", function()
    local instance = ready()
    local other = open_view(instance, { position = "current" })
    vim.api.nvim_win_set_cursor(other, instance:get_pos("a.txt"))
    local other_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    instance:reveal("c.txt")
    assert.is_table(instance._pending_reveal)

    local current_tab = vim.api.nvim_get_current_tabpage()
    local opened = open_view(instance, { position = "float", width = 40, height = 10 })
    assert.are.equal(current_tab, vim.api.nvim_win_get_tabpage(opened))
    assert.are.same(instance:get_pos("c.txt"), vim.api.nvim_win_get_cursor(opened))
    assert.is_nil(instance._pending_reveal)
    assert.are.equal(other_tab, vim.api.nvim_win_get_tabpage(other))
    assert.are.same(instance:get_pos("a.txt"), vim.api.nvim_win_get_cursor(other))
  end)

  it("keeps a reveal pending through a manual view in another tab until its initiating tab enters", function()
    local instance = ready()
    local initiating_tab = vim.api.nvim_get_current_tabpage()
    local initiating_window = vim.api.nvim_get_current_win()
    instance:reveal("c.txt")
    local request = instance._pending_reveal
    assert.is_table(request)
    assert.are.equal(initiating_tab, request.tabpage)

    vim.cmd("tabnew")
    local other_tab = vim.api.nvim_get_current_tabpage()
    local other_window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(other_window, { 1, 0 })
    vim.api.nvim_set_current_tabpage(initiating_tab)
    assert.are_not.equal(initiating_tab, other_tab)
    assert.are.equal(initiating_window, vim.api.nvim_get_current_win())

    local other_cursor = vim.api.nvim_win_get_cursor(other_window)
    vim.api.nvim_win_set_buf(other_window, instance.bufnr)
    assert.are.same(other_cursor, vim.api.nvim_win_get_cursor(other_window))
    assert.are.equal(request, instance._pending_reveal)

    vim.api.nvim_win_set_buf(initiating_window, instance.bufnr)
    assert.are.same(instance:get_pos("c.txt"), vim.api.nvim_win_get_cursor(initiating_window))
    assert.is_nil(instance._pending_reveal)
    assert.are.same(other_cursor, vim.api.nvim_win_get_cursor(other_window))
  end)


  it("consumes a pending reveal in the manually entered current-tab view only", function()
    local instance = ready()
    local other = open_view(instance, { position = "current" })
    vim.api.nvim_win_set_cursor(other, instance:get_pos("a.txt"))
    local other_tab = vim.api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    instance:reveal("c.txt")
    assert.is_table(instance._pending_reveal)

    local target = vim.api.nvim_get_current_win()
    vim.cmd("vsplit")
    local caller = vim.api.nvim_get_current_win()
    assert.are_not.equal(target, caller)
    vim.api.nvim_win_set_buf(target, instance.bufnr)
    assert.are.equal(caller, vim.api.nvim_get_current_win())
    assert.are.same(instance:get_pos("c.txt"), vim.api.nvim_win_get_cursor(target))
    assert.is_nil(instance._pending_reveal)
    assert.are.equal(other_tab, vim.api.nvim_win_get_tabpage(other))
    assert.are.same(instance:get_pos("a.txt"), vim.api.nvim_win_get_cursor(other))
  end)
end)
