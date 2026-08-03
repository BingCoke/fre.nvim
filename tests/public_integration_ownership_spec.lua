local actions = require("fre.actions")
local fre = require("fre")
local manager_module = require("fre.manager")
local mapping = require("fre.mapping")
local takeover_module = require("fre.takeover")
local fs = require("tests.helpers.fs")

local function source(path)
  local file = assert(io.open(path, "r"))
  local text = assert(file:read("*a"))
  file:close()
  return text
end

local function retained_path(root, target)
  local seen = {}
  local function visit(value, path)
    if rawequal(value, target) then return path end
    local kind = type(value)
    if kind ~= "table" and kind ~= "function" then return nil end
    if seen[value] then return nil end
    seen[value] = true
    if kind == "table" then
      for key, child in pairs(value) do
        local found = visit(key, path .. "[key]") or visit(child, path .. "." .. tostring(key))
        if found then return found end
      end
      return visit(getmetatable(value), path .. ".<metatable>")
    end
    local index = 1
    while true do
      local name, child = debug.getupvalue(value, index)
      if not name then return nil end
      local found = visit(child, path .. ".<upvalue:" .. name .. ">")
      if found then return found end
      index = index + 1
    end
  end
  return visit(root, "instance")
end

local function wait_ready(instance)
  assert.is_true(vim.wait(2000, function()
    return instance:is_ready() or instance:failure() ~= nil
  end, 10))
  assert.is_true(instance:is_ready(), tostring(instance:failure()))
end

describe("public integration ownership", function()
  local fixture
  local instances

  before_each(function()
    fixture = fs.new()
    fixture:tree({ ["alpha.txt"] = "alpha" })
    instances = {}
    fre.setup({ default_file_explorer = false })
  end)

  after_each(function()
    for _, instance in ipairs(instances) do
      if not instance:is_destroyed() then pcall(instance.destroy, instance) end
    end
    fixture:cleanup()
  end)

  it("keeps integration modules outside stateful Instance children", function()
    for _, path in ipairs({
      "lua/fre/actions.lua",
      "lua/fre/gc.lua",
      "lua/fre/init.lua",
      "lua/fre/mapping.lua",
      "lua/fre/manager.lua",
      "lua/fre/takeover.lua",
      "lua/fre/window.lua",
    }) do
      local text = source(path)
      if path == "lua/fre/gc.lua" or path == "lua/fre/manager.lua" then
        text = text:gsub('require%("fre%.instance%.identity"%)', "")
      end
      assert.is_nil(text:find('require("fre.instance.', 1, true), path)
    end
    assert.is_nil(source("lua/fre/mutation/prepare.lua"):find(
      'require("fre.instance.buffer")', 1, true
    ))
    assert.is_nil(source("lua/fre/instance.lua"):find(
      'require("fre.mapping")', 1, true
    ))
    assert.is_nil(source("lua/fre/instance/work.lua"):find(
      'require("fre.write_ui")', 1, true
    ))
    local Work = require("fre.instance.work")
    assert.is_nil(Work.confirm)
    assert.is_nil(Work._set_ui_adapter)
    assert.is_nil(Work._reset_ui_adapter)
  end)

  it("routes integration runtime calls through public Instance operations", function()
    local calls = {}
    local fake
    fake = {
      id = 101,
      bufnr = vim.api.nvim_get_current_buf(),
      root = fixture.root,
      is_destroying = function() return false end,
      is_destroyed = function() return false end,
      inspect_action_row = function(_, row, allow)
        calls.context = { row = row, allow = allow }
        return {}
      end,
      inspect_view = function(_, location)
        calls.inspect = location
        return { winid = 77 }
      end,
      write = function(_, ctx)
        calls.write = ctx
        return "written"
      end,
    }

    assert.are.equal(fake, mapping.context(fake).instance)
    assert.are.equal(vim.api.nvim_win_get_cursor(0)[1], calls.context.row)
    assert.is_false(calls.context.allow)
    assert.are.same({ winid = 77 }, fre.view.inspect(fake, { winid = 3 }))
    assert.are.same({ winid = 3 }, calls.inspect)
    assert.are.equal("written", actions.write({ instance = fake, bufnr = fake.bufnr }))
    assert.are.equal(fake.bufnr, calls.write.bufnr)

    local controller = takeover_module.new()
    assert.is_nil(rawget(controller, "manager"))
    local original_new = fre.new
    local token = {}
    fre.new = function(opts)
      calls.takeover_root = opts.root
      return token
    end
    local created_ok, created = pcall(controller._create_instance, fixture.root)
    fre.new = original_new
    assert.is_true(created_ok, tostring(created))
    assert.are.equal(token, created)
    assert.are.equal(fixture.root, calls.takeover_root)
  end)

  it("retains no Manager or GC ownership and publishes only core buffer metadata", function()
    local instance = require("fre.instance").new({ root = fixture.root, columns = {} })
    instances[#instances + 1] = instance
    wait_ready(instance)

    for _, field in ipairs({
      "manager", "_manager", "gc", "_gc", "config", "_views", "views",
      "group", "gc_group", "callbacks", "context", "_create_child",
      "_installed_mappings",
    }) do
      assert.is_nil(rawget(instance, field), field)
    end
    assert.is_nil(retained_path(instance, manager_module.default))
    assert.is_nil(retained_path(instance, manager_module.default:get_gc_controller()))
    assert.are.same({
      version = 1,
      instance_id = instance.id,
      root = instance.root,
    }, vim.b[instance.bufnr].fre)
  end)

  it("keeps every Instance child free of retained Instance callbacks", function()
    local instance = require("fre.instance").new({ root = fixture.root, columns = {} })
    instances[#instances + 1] = instance
    wait_ready(instance)

    for _, child_name in ipairs({ "lifecycle", "buffer", "sync", "work", "view" }) do
      local retained = retained_path(instance[child_name], instance)
      assert.is_nil(retained, child_name .. " retains Instance through " .. tostring(retained))
    end
  end)

  it("keeps finite serializable event payloads free of runtime owners", function()
    local seen = {}
    local group = vim.api.nvim_create_augroup("FrePublicIntegrationOwnership", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = "FreInstanceCreated",
      callback = function(args) seen[#seen + 1] = args.data end,
    })
    local instance = require("fre.instance").new({ root = fixture.root, columns = {} })
    instances[#instances + 1] = instance
    assert.are.equal(1, #seen)
    assert.are.same({ instance_id = instance.id, bufnr = instance.bufnr }, seen[1])
    for _, payload in ipairs(seen) do
      assert.is_nil(payload.instance)
      assert.is_nil(payload.manager)
      assert.is_nil(payload.gc)
      for _, value in pairs(payload) do
        assert.is_true(type(value) == "number" or type(value) == "string"
          or type(value) == "boolean" or value == nil)
      end
    end
    vim.api.nvim_del_augroup_by_id(group)
  end)
end)
