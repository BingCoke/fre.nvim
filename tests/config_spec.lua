local columns = require("fre.columns")
local config = require("fre.config")
local manager_module = require("fre.manager")

local function new_manager()
  return manager_module.new()
end

local function noop() end

local function assert_error_contains(fragment, callback)
  local ok, err = pcall(callback)
  assert.is_false(ok)
  assert.is_truthy(tostring(err):find(fragment, 1, true))
end

local function custom_column(id, data)
  return columns.custom({
    id = id,
    data = data,
    render = function() return id end,
    parse = function(suffix)
      local value, rest = suffix:match("^(%S+)%s+(.*)$")
      return value, rest
    end,
    equals = function() return true end,
  })
end

describe("fre configuration", function()
  it("exposes the exact built-in ordinary defaults", function()
    local defaults = config.builtins()
    assert.is_true(defaults.default_file_explorer)
    assert.is_false(defaults.hidden_file)
    assert.is_true(defaults.use_mapping_default)
    assert.are.same({ "icon", "permissions", "mtime" }, {
      defaults.columns[1].id,
      defaults.columns[2].id,
      defaults.columns[3].id,
    })
    assert.are.equal("%Y-%m-%d %H:%M", defaults.columns[3].format)
    assert.are.same({ ttl_ms = 60000, include_modified = false, default_group = "default", groups = {
      default = 10,
      project = 5,
    } }, defaults.gc)
    assert.are.same({ position = "left", size = 40 }, defaults.layout)
    assert.are.same({
      buftype = "acwrite",
      bufhidden = "hide",
      swapfile = false,
      buflisted = false,
    }, defaults.buffer.options)
    assert.are.same({
      wrap = false,
      number = false,
      relativenumber = false,
      signcolumn = "no",
      conceallevel = 3,
      concealcursor = "nvic",
    }, defaults.window.options)

    assert.is_true(defaults.sort(nil,
      { kind = "directory", name = "z" },
      { kind = "file", name = "a" }))
    assert.is_true(defaults.sort(nil,
      { kind = "file", name = "A" },
      { kind = "file", name = "a" }))
  end)

  it("merges fields deliberately and recomputes later setup from built-ins", function()
    local manager = new_manager()
    manager:setup({
      hidden_file = true,
      layout = { position = "right" },
      gc = { ttl_ms = 25, groups = { extra = 2 } },
      buffer = { options = { modifiable = false } },
    })
    local first = manager:get_setup_defaults()
    assert.is_true(first.hidden_file)
    assert.are.same({ position = "right", size = 40 }, first.layout)
    assert.are.equal(25, first.gc.ttl_ms)
    assert.are.equal(2, first.gc.groups.extra)
    assert.is_false(first.buffer.options.modifiable)

    manager:setup({ window = { options = { cursorline = true } } })
    local second = manager:get_setup_defaults()
    assert.is_false(second.hidden_file)
    assert.are.same({ position = "left", size = 40 }, second.layout)
    assert.are.equal(60000, second.gc.ttl_ms)
    assert.is_nil(second.gc.groups.extra)
    assert.is_nil(second.buffer.options.modifiable)
    assert.is_true(second.window.options.cursorline)
  end)

  it("rejects winfixbuf true while accepting false", function()
    local manager = new_manager()
    assert_error_contains("window.options.winfixbuf", function()
      manager:setup({ window = { options = { winfixbuf = true } } })
    end)
    assert_error_contains("window.options.winfixbuf", function()
      manager:resolve_instance_config({ window = { options = { winfixbuf = true } } })
    end)
    assert.is_false(manager:resolve_instance_config({
      window = { options = { winfixbuf = false } },
    }).window.options.winfixbuf)
  end)

  it("merges layouts by position family and rejects explicitly irrelevant fields", function()
    local manager = new_manager()
    manager:setup({ layout = { position = "right" } })
    assert.are.same({ position = "right", size = 40 }, manager:get_setup_defaults().layout)

    local invalid_setup = {
      { position = "current", size = 1 },
      { position = "left", width = 20 },
      { width = 20 },
      { position = "float", size = 10, width = 20, height = 5 },
      { position = "float" },
    }
    local committed = manager:get_setup_defaults()
    for _, layout in ipairs(invalid_setup) do
      assert_error_contains("layout", function() manager:setup({ layout = layout }) end)
      assert.are.same(committed, manager:get_setup_defaults())
    end

    manager:setup({
      layout = { position = "float", width = 40, height = 12, row = 2, border = "single" },
    })
    assert.are.same({
      position = "float", width = 40, height = 12, row = 2, border = "single",
    }, manager:get_setup_defaults().layout)
    local inherited = manager:resolve_instance_config({ layout = { width = 50 } })
    assert.are.same({
      position = "float", width = 50, height = 12, row = 2, border = "single",
    }, inherited.layout)
    assert_error_contains("layout.size", function()
      manager:resolve_instance_config({ layout = { size = 8 } })
    end)

    local left_manager = new_manager()
    assert_error_contains("layout.width", function()
      left_manager:resolve_instance_config({ layout = { width = 20 } })
    end)
    assert_error_contains("layout.width is required", function()
      left_manager:resolve_instance_config({ layout = { position = "float", height = 8 } })
    end)
    local switched = left_manager:resolve_instance_config({
      layout = { position = "float", width = 30, height = 8 },
    })
    assert.are.same({ position = "float", width = 30, height = 8 }, switched.layout)
  end)

  it("locks the first valid explorer decision and silently ignores later values", function()
    local manager = new_manager()
    assert.is_nil(manager:get_default_file_explorer())
    manager:setup({ default_file_explorer = false })
    assert.is_false(manager:get_default_file_explorer())

    manager:setup({ default_file_explorer = "ignored", hidden_file = true })
    assert.is_false(manager:get_default_file_explorer())
    assert.is_true(manager:get_setup_defaults().hidden_file)
    assert.is_false(manager:get_setup_defaults().default_file_explorer)
  end)

  it("rejects invalid setup atomically without consuming the first decision", function()
    local manager = new_manager()
    local before = manager:get_setup_defaults()
    assert.has_error(function()
      manager:setup({ default_file_explorer = false, hidden_file = "yes" })
    end)
    assert.are.same(before, manager:get_setup_defaults())
    assert.is_nil(manager:get_default_file_explorer())

    manager:setup({ default_file_explorer = true, hidden_file = true })
    local committed = manager:get_setup_defaults()
    assert.has_error(function()
      manager:setup({ mapping = { n = { x = "not a function" } } })
    end)
    assert.are.same(committed, manager:get_setup_defaults())
    assert.is_true(manager:get_default_file_explorer())
  end)

  it("replaces sequences, merges mapping modes by LHS, and only merges named records at their declared level", function()
    local manager = new_manager()
    local setup_x = function() end
    local setup_y = function() end
    local new_x = function() end
    manager:setup({
      columns = { custom_column("only") },
      mapping = { n = { x = setup_x, y = setup_y } },
      buffer = { variables = { nested = { retained = true, replaced = true } } },
    })
    local effective = manager:resolve_instance_config({
      columns = { custom_column("replacement"), custom_column("second") },
      mapping = { n = { x = new_x }, v = { x = noop } },
      buffer = { variables = { nested = { replaced = false } } },
    })

    assert.are.same({ "replacement", "second" }, {
      effective.columns[1].id,
      effective.columns[2].id,
    })
    assert.are.equal(new_x, effective.mapping.n.x)
    assert.are.equal(setup_y, effective.mapping.n.y)
    assert.are.equal(noop, effective.mapping.v.x)
    assert.are.same({ replaced = false }, effective.buffer.variables.nested)
  end)

  it("keeps setup inputs, returned defaults, mappings, and effective snapshots independent", function()
    local manager = new_manager()
    local setup_opts = {
      columns = { custom_column("custom", { value = 1 }) },
      mapping = { n = { x = noop } },
      buffer = { variables = { record = { value = 1 } } },
    }
    manager:setup(setup_opts)
    setup_opts.columns[1].data.value = 9
    setup_opts.mapping.n.y = noop
    setup_opts.buffer.variables.record.value = 9

    local returned = manager:get_setup_defaults()
    returned.columns[1].data.value = 8
    returned.mapping.n.y = noop
    returned.buffer.variables.record.value = 8

    local new_opts = {
      columns = { custom_column("new", { value = 2 }) },
      mapping = { n = { z = noop } },
      buffer = { variables = { extra = { value = 2 } } },
    }
    local first = manager:resolve_instance_config(new_opts)
    new_opts.columns[1].data.value = 9
    new_opts.mapping.n.z = function() end
    new_opts.buffer.variables.extra.value = 9
    assert.are.equal(2, first.columns[1].data.value)
    assert.are.equal(noop, first.mapping.n.z)
    assert.are.equal(2, first.buffer.variables.extra.value)

    local second = manager:resolve_instance_config()
    first.columns[1].data.value = 7
    first.mapping.n.y = noop
    first.buffer.variables.record.value = 7

    assert.are.equal(1, second.columns[1].data.value)
    assert.is_nil(second.mapping.n.y)
    assert.are.equal(1, second.buffer.variables.record.value)
  end)

  it("copies cyclic non-variable descriptor data without recursing forever", function()
    local descriptor = custom_column("cyclic")
    descriptor.self = descriptor
    local manager = new_manager()
    manager:setup({ columns = { descriptor } })
    descriptor.id = "mutated"

    local effective = manager:resolve_instance_config()
    assert.are.equal("cyclic", effective.columns[1].id)
    assert.are.equal(effective.columns[1], effective.columns[1].self)
  end)

  it("rejects instance inheritance and resolves only setup defaults plus explicit options", function()
    local manager = new_manager()
    local setup_sort = function() end
    local explicit_sort = function() end
    manager:setup({ sort = setup_sort, hidden_file = false })

    assert_error_contains("unknown field inherit", function()
      manager:resolve_instance_config({ inherit = {} })
    end)

    local effective = manager:resolve_instance_config({
      sort = explicit_sort,
      hidden_file = true,
    })
    assert.are.equal(explicit_sort, effective.sort)
    assert.is_true(effective.hidden_file)
    assert.are.equal(60000, effective.gc.ttl_ms)
    assert.is_false(effective.gc.include_modified)
    assert.are.equal("default", effective.gc.group)
  end)

  it("resolves effective GC fields and rejects setup-only or unknown groups", function()
    local manager = new_manager()
    manager:setup({
      gc = {
        ttl_ms = 100,
        include_modified = true,
        default_group = "project",
      },
    })
    local effective = manager:resolve_instance_config({
      gc = { ttl_ms = 0, include_modified = false, group = "default" },
    })
    assert.are.same({ ttl_ms = 0, include_modified = false, group = "default" }, effective.gc)

    assert_error_contains("unknown group", function()
      manager:resolve_instance_config({ gc = { group = "missing" } })
    end)
    assert_error_contains("setup-only", function()
      manager:resolve_instance_config({ default_file_explorer = false })
    end)
    assert.has_error(function()
      manager:resolve_instance_config({ gc = { groups = { default = 1 } } })
    end)
  end)

  it("accepts serializable buffer variables and snapshots them", function()
    local manager = new_manager()
    local variables = {
      flag = true,
      count = 3,
      text = "ok",
      array = { "a", false, { nested = 2 } },
      record = { child = { 1, 2, 3 } },
    }
    manager:setup({ buffer = { variables = variables } })
    variables.array[3].nested = 9
    variables.record.child[1] = 9

    local effective = manager:resolve_instance_config()
    assert.are.equal(2, effective.buffer.variables.array[3].nested)
    assert.are.same({ 1, 2, 3 }, effective.buffer.variables.record.child)
  end)

  it("rejects invalid buffer variable shapes and values", function()
    local manager = new_manager()
    local cyclic = {}
    cyclic.self = cyclic
    local cases = {
      { cyclic = cyclic },
      { hole = { [1] = "a", [3] = "c" } },
      { mixed = { [1] = "a", named = "b" } },
      { bad_key = { [{ object = true }] = "value" } },
      { callback = noop },
      { thread = coroutine.create(noop) },
      { userdata = vim.uv.new_timer() },
    }
    for _, variables in ipairs(cases) do
      assert.has_error(function()
        manager:setup({ buffer = { variables = variables } })
      end)
      if variables.userdata then
        variables.userdata:close()
      end
    end
    assert.has_error(function()
      manager:setup({ buffer = { variables = { fre = "reserved" } } })
    end)
  end)
end)
