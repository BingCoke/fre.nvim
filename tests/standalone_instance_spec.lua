local buffer = require("fre.instance.buffer")
local Instance = require("fre.instance")
local manager_module = require("fre.manager")
local mutation_fs = require("fre.mutation.fs")
local Registry = require("fre.registry")
local real_fs = require("fre.fs").default
local real_watch = require("fre.watch").default
local path = require("fre.path")
local fs = require("tests.helpers.fs")

local fixture
local instances

local function keep(instance)
  instances[#instances + 1] = instance
  return instance
end

local function wait_for(predicate)
  assert.is_true(vim.wait(3000, predicate, 10))
end

local function wait_ready(instance)
  wait_for(function() return instance:status() ~= "creating" end)
  assert.are.equal("ready", instance:status(), tostring(instance:failure()))
  return instance
end

local function row_for(instance, relative)
  for row = 1, vim.api.nvim_buf_line_count(instance.bufnr) do
    local decoded = instance.buffer:decode(row)
    if decoded and decoded.row_kind == "entry"
        and decoded.entry.relative_path == relative then
      return row, decoded
    end
  end
  error("missing row " .. relative)
end

local function rename_row(instance, from, to)
  local row, decoded = row_for(instance, from)
  local line = vim.api.nvim_buf_get_lines(instance.bufnr, row - 1, row, false)[1]
  local replacement = line:sub(1, decoded.path_range.start_byte) .. to
    .. line:sub(decoded.path_range.end_byte + 1)
  vim.api.nvim_buf_set_lines(instance.bufnr, row - 1, row, false, { replacement })
end

local function write_command(instance)
  return pcall(vim.api.nvim_buf_call, instance.bufnr, function() vim.cmd("write") end)
end

local function write_ui()
  local handle = { update = function() end, close = function() end }
  return {
    confirm = function(_, _, decide)
      decide(true)
      return handle
    end,
    progress = function() return handle end,
    report = function() end,
  }
end

describe("fre standalone Instance", function()
  before_each(function()
    fixture = fs.new()
    instances = {}
  end)

  after_each(function()
    for _, instance in ipairs(instances) do
      if not instance:is_destroyed() then pcall(instance.destroy, instance) end
    end
    fixture:cleanup()
  end)

  it("uses built-in core dependencies and stays outside default management", function()
    fixture:write("alpha.txt", "alpha")
    local instance = wait_ready(keep(Instance.new({ root = fixture.root })))

    assert.are.equal(require("fre.registry").default:find_marker_source(instance.id),
      instance.buffer.marker_source)
    assert.are.equal(real_fs, instance.sync.fs_adapter)
    assert.are.equal(real_watch, instance.sync.watch.adapter)
    assert.are.equal(mutation_fs.default, instance.work.mutation_adapter)
    assert.is_nil(rawget(instance, "manager"))
    assert.is_nil(instance.setGroup)
    assert.is_nil(manager_module.default:find_by_id(instance.id))
    assert.is_nil(manager_module.default:find_by_buf(instance.bufnr))
    assert.is_nil(manager_module.default:get_gc_controller():inspect(instance))
    assert.is_nil(manager_module.default:find_by_group("default")[instance.id])
    local _, winid = instance:open({ position = "current" })
    assert.is_nil(manager_module.default._takeover:check(instance.bufnr, winid))
    assert.has_error(function()
      manager_module.default:move_to_group(instance, "project")
    end)

    local bufnr, id = instance.bufnr, instance.id
    instance:destroy()
    assert.are.equal("destroyed", instance:status())
    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
    assert.is_nil(require("fre.registry").default:find_marker_source(id))
  end)

  it("supports async load, presentation, edit/write, and refresh with explicit dependencies", function()
    fixture:write("old.txt", "old")
    local registry = Registry.new()
    local pending
    local fs_adapter = {
      load = function(root, done)
        if pending == nil then
          pending = { root = root, done = done }
        else
          return real_fs.load(root, done)
        end
      end,
    }
    local mutation_adapter = mutation_fs.default
    local ui_adapter = write_ui()
    local instance = keep(Instance.new({
      root = fixture.root,
      columns = {},
      skip_confirm_for_simple_edits = true,
      registry = registry,
      fs_adapter = fs_adapter,
      watch_adapter = real_watch,
      mutation_adapter = mutation_adapter,
      write_ui_adapter = ui_adapter,
    }))

    assert.are.equal("creating", instance:status())
    assert.are.equal(path.absolute(fixture.root), pending.root)
    assert.are.equal(fs_adapter, instance.sync.fs_adapter)
    assert.are.equal(real_watch, instance.sync.watch.adapter)
    assert.are.equal(mutation_adapter, instance.work.mutation_adapter)
    assert.are.equal(ui_adapter, instance.work.write_ui_adapter)
    real_fs.load(pending.root, pending.done)
    wait_ready(instance)
    assert.are.same({ path.absolute(fixture.root) }, instance.sync:watch_paths())

    local opened, winid = instance:open({ position = "current" })
    assert.are.equal(instance, opened)
    assert.are.equal(winid, assert(instance:inspect_view()).winid)

    rename_row(instance, "old.txt", "renamed.txt")
    local ok, err = write_command(instance)
    assert.is_true(ok, tostring(err))
    wait_for(function()
      return not instance.work:is_write_active()
        and vim.uv.fs_stat(fixture:path("renamed.txt")) ~= nil
    end)
    assert.is_nil(vim.uv.fs_stat(fixture:path("old.txt")))

    fixture:write("external.txt", "external")
    instance:refresh()
    wait_for(function()
      return not instance.sync:is_busy() and instance:get_pos("external.txt") ~= nil
    end)
  end)

  it("keeps standalone buffer-deletion failure retryable until terminal cleanup", function()
    local registry = Registry.new()
    local instance = wait_ready(keep(Instance.new({
      root = fixture.root,
      columns = {},
      registry = registry,
    })))
    local id, bufnr = instance.id, instance.bufnr
    local original_delete = vim.api.nvim_buf_delete
    local original_call = vim.api.nvim_buf_call
    vim.api.nvim_buf_delete = function() error("API delete failed") end
    vim.api.nvim_buf_call = function() error("fallback delete failed") end
    local ok, err = pcall(instance.destroy, instance)
    vim.api.nvim_buf_delete = original_delete
    vim.api.nvim_buf_call = original_call

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("fallback delete failed", 1, true))
    assert.are.equal("destroying", instance:status())
    assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
    assert.is_not_nil(registry:find_marker_source(id))
    assert.is_nil(manager_module.default:find_by_id(id))

    instance:destroy()
    assert.are.equal("destroyed", instance:status())
    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
    assert.is_nil(registry:find_marker_source(id))
  end)

  it("finishes standalone destruction after external buffer deletion", function()
    local registry = Registry.new()
    local instance = wait_ready(keep(Instance.new({
      root = fixture.root,
      columns = {},
      registry = registry,
    })))
    local id, bufnr = instance.id, instance.bufnr

    vim.cmd("bdelete! " .. tostring(bufnr))
    wait_for(function() return instance:is_destroyed() end)

    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
    assert.is_nil(registry:find_marker_source(id))
    assert.is_nil(manager_module.default:find_by_id(id))
  end)

  it("consumes identity and removes the marker source when core construction fails", function()
    local registry = Registry.new()
    local allocated_id
    local allocate = registry.allocate_instance_id
    registry.allocate_instance_id = function(owner)
      allocated_id = allocate(owner)
      return allocated_id
    end
    local original_setup = buffer.setup
    buffer.setup = function(subject)
      original_setup(subject)
      error("injected standalone constructor failure")
    end

    local before = vim.api.nvim_list_bufs()
    local ok, err = pcall(Instance.new, {
      root = fixture.root,
      columns = {},
      registry = registry,
    })
    buffer.setup = original_setup

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("injected standalone constructor failure", 1, true))
    assert.is_true(registry:is_instance_id_consumed(allocated_id))
    assert.is_nil(registry:find_marker_source(allocated_id))
    assert.are.same(before, vim.api.nvim_list_bufs())
    assert.is_nil(manager_module.default:find_by_id(allocated_id))
  end)
end)
