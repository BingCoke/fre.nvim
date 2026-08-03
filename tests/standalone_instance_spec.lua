local buffer = require("fre.instance.buffer")
local fre = require("fre")
local Instance = require("fre.instance")
local manager_module = require("fre.manager")
local mutation_fs = require("fre.mutation.fs")
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

    assert.is_truthy(instance.id:match(
      "^[0-9a-f]+%-[0-9a-f]+%-4[0-9a-f]+%-8[0-9a-f]+%-[0-9a-f]+$"
    ))
    assert.is_nil(instance.buffer._resolve_marker_source)
    assert.are.equal(real_fs, instance.sync.fs_adapter)
    assert.are.equal(real_watch, instance.sync.watch.adapter)
    assert.are.equal(mutation_fs.default, instance.work.mutation_adapter)
    assert.is_nil(rawget(instance, "manager"))
    assert.is_nil(instance.setGroup)
    assert.is_nil(instance.set_group)
    assert.is_nil(manager_module.default:find_by_id(instance.id))
    assert.is_nil(manager_module.default:find_by_buf(instance.bufnr))
    assert.is_nil(manager_module.default:get_gc_controller():inspect(instance))
    assert.is_nil(manager_module.default:find_by_group("default")[instance.id])
    local _, winid = instance:open({ position = "current" })
    assert.is_nil(manager_module.default._takeover:check(instance.bufnr, winid))
    assert.has_error(function() fre.set_group(instance, "project") end)

    local bufnr = instance.bufnr
    instance:destroy()
    assert.are.equal("destroyed", instance:status())
    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
  end)

  it("accepts explicit opaque IDs and narrows a caller-owned resolver", function()
    local source_root = fixture:mkdir("source")
    local target_root = fixture:mkdir("target")
    fixture:write("source/from.txt", "source")
    local source = wait_ready(keep(Instance.new({
      root = source_root, id = "source:standalone", columns = {},
    })))
    local target = wait_ready(keep(Instance.new({
      root = target_root, id = "target:standalone", columns = {},
      resolve_instance = function(id)
        return id == source.id and source or nil
      end,
    })))
    local source_row = row_for(source, "from.txt")
    local source_line = vim.api.nvim_buf_get_lines(
      source.bufnr, source_row - 1, source_row, false
    )[1]
    vim.bo[target.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(target.bufnr, 1, -1, false, { source_line })
    vim.bo[target.bufnr].modifiable = false
    assert.are.same({ {
      type = "copy",
      from = path.resolve(source_root, "from.txt"),
      to = path.resolve(target_root, "from.txt"),
      kind = "file",
    } }, target:prepare().operations)
    assert.is_function(target.buffer._resolve_marker_source)
    assert.is_nil(rawget(target.buffer, "resolve_instance"))
  end)

  it("rejects invalid identity inputs before creating a buffer", function()
    local before = vim.api.nvim_list_bufs()
    for _, options in ipairs({
      { root = fixture.root, id = "" },
      { root = fixture.root, id = "bad\nidentity" },
      { root = fixture.root, resolve_instance = true },
    }) do
      assert.is_false(pcall(Instance.new, options))
      assert.are.same(before, vim.api.nvim_list_bufs())
    end
  end)

  it("never invokes a resolver for local markers", function()
    fixture:write("local.txt", "local")
    local calls = 0
    local instance = wait_ready(keep(Instance.new({
      root = fixture.root,
      columns = {},
      resolve_instance = function()
        calls = calls + 1
        error("local decode invoked resolver")
      end,
    })))
    assert.is_not_nil(instance:get_entry(row_for(instance, "local.txt")))
    assert.are.same({ operations = {}, display = {} }, instance:prepare())
    assert.are.equal(0, calls)
  end)

  it("reports resolver exceptions with row and source context", function()
    local source_root = fixture:mkdir("error-source")
    local target_root = fixture:mkdir("error-target")
    fixture:write("error-source/from.txt", "source")
    local source = wait_ready(keep(Instance.new({
      root = source_root, id = "resolver:error:source", columns = {},
    })))
    local target = wait_ready(keep(Instance.new({
      root = target_root, id = "resolver:error:target", columns = {},
      resolve_instance = function() error("resolver exploded") end,
    })))
    local source_row = row_for(source, "from.txt")
    local source_line = vim.api.nvim_buf_get_lines(
      source.bufnr, source_row - 1, source_row, false
    )[1]
    vim.bo[target.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(target.bufnr, 1, -1, false, { source_line })
    vim.bo[target.bufnr].modifiable = false
    local before = vim.api.nvim_buf_get_lines(target.bufnr, 0, -1, false)

    local ok, err = pcall(target.prepare, target)
    assert.is_false(ok)
    local text = tostring(err)
    assert.is_truthy(text:find("row 2", 1, true), text)
    assert.is_truthy(text:find(source.id, 1, true), text)
    assert.is_truthy(text:find("resolver exploded", 1, true), text)
    assert.are.same(before, vim.api.nvim_buf_get_lines(target.bufnr, 0, -1, false))
    assert.is_false(target.work:is_write_active())
  end)

  it("reports terminal resolver sources with row and source context", function()
    local source_root = fixture:mkdir("terminal-source")
    local target_root = fixture:mkdir("terminal-target")
    fixture:write("terminal-source/from.txt", "source")
    local source = wait_ready(keep(Instance.new({
      root = source_root, id = "resolver:terminal:source", columns = {},
    })))
    local target = wait_ready(keep(Instance.new({
      root = target_root, id = "resolver:terminal:target", columns = {},
      resolve_instance = function() return source end,
    })))
    local source_row = row_for(source, "from.txt")
    local source_line = vim.api.nvim_buf_get_lines(
      source.bufnr, source_row - 1, source_row, false
    )[1]
    source:destroy()
    vim.bo[target.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(target.bufnr, 1, -1, false, { source_line })
    vim.bo[target.bufnr].modifiable = false
    local before = vim.api.nvim_buf_get_lines(target.bufnr, 0, -1, false)

    local ok, err = pcall(target.prepare, target)
    assert.is_false(ok)
    local text = tostring(err)
    assert.is_truthy(text:find("row 2", 1, true), text)
    assert.is_truthy(text:find(source.id, 1, true), text)
    assert.is_truthy(text:find("terminal Instance", 1, true), text)
    assert.are.same(before, vim.api.nvim_buf_get_lines(target.bufnr, 0, -1, false))
    assert.is_false(target.work:is_write_active())
  end)

  it("does not load or install plugin mappings during core construction", function()
    local loaded_mapping = package.loaded["fre.mapping"]
    local preload_mapping = package.preload["fre.mapping"]
    local loaded_instance = package.loaded["fre.instance"]
    package.loaded["fre.mapping"] = nil
    package.loaded["fre.instance"] = nil
    package.preload["fre.mapping"] = function()
      error("standalone core loaded fre.mapping")
    end

    local ok, core_or_error = pcall(require, "fre.instance")
    package.loaded["fre.instance"] = loaded_instance
    package.loaded["fre.mapping"] = loaded_mapping
    package.preload["fre.mapping"] = preload_mapping
    assert.is_true(ok, tostring(core_or_error))

    local instance = wait_ready(keep(core_or_error.new({
      root = fixture.root,
      mapping = { n = { x = function() error("mapping should not be installed") end } },
    })))
    local normal = vim.api.nvim_buf_get_keymap(instance.bufnr, "n")
    assert.are.equal(0, #normal)
  end)

  it("supports async load, presentation, edit/write, and refresh with explicit dependencies", function()
    fixture:write("old.txt", "old")
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
    local instance = wait_ready(keep(Instance.new({
      root = fixture.root,
      columns = {},
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
    assert.is_nil(manager_module.default:find_by_id(id))

    instance:destroy()
    assert.are.equal("destroyed", instance:status())
    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
  end)

  it("finishes standalone destruction after external buffer deletion", function()
    local instance = wait_ready(keep(Instance.new({
      root = fixture.root,
      columns = {},
    })))
    local id, bufnr = instance.id, instance.bufnr

    vim.cmd("bdelete! " .. tostring(bufnr))
    wait_for(function() return instance:is_destroyed() end)

    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
    assert.is_nil(manager_module.default:find_by_id(id))
  end)

  it("cleans an explicitly identified standalone construction failure", function()
    local allocated_id = "failed:standalone:id"
    local original_setup = buffer.setup
    buffer.setup = function(subject)
      original_setup(subject)
      error("injected standalone constructor failure")
    end

    local before = vim.api.nvim_list_bufs()
    local ok, err = pcall(Instance.new, {
      root = fixture.root,
      id = allocated_id,
      columns = {},
    })
    buffer.setup = original_setup

    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("injected standalone constructor failure", 1, true))
    assert.are.same(before, vim.api.nvim_list_bufs())
    assert.is_nil(manager_module.default:find_by_id(allocated_id))
  end)
end)
