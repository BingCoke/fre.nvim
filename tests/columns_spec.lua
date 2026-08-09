local columns = require("fre.columns")

local function error_contains(fragment, callback)
  local ok, err = pcall(callback)
  assert.is_false(ok)
  assert.is_truthy(tostring(err):find(fragment, 1, true), tostring(err))
end

local function context(descriptor, entry, metadata)
  return {
    descriptor = descriptor,
    config = descriptor,
    entry = entry,
    column_index = 1,
    is_last = true,
    metadata = metadata or {},
  }
end

local entry = {
  instance_id = 1,
  node_id = 2,
  absolute_path = "/tmp/item",
  relative_path = "item",
  name = "item",
  kind = "file",
}

describe("fre columns", function()
  it("constructs built-ins with stable identities and metadata requirements", function()
    local icon = columns.icon()
    local permissions = columns.permissions()
    local mtime = columns.mtime({ format = "%Y-%m-%d %H:%M" })

    assert.are.same({ "icon", "permissions", "mtime" }, {
      icon.id, permissions.id, mtime.id,
    })
    assert.are.same({ "kind" }, icon.metadata)
    assert.are.same({ "mode" }, permissions.metadata)
    assert.are.same({ "mtime" }, mtime.metadata)
    assert.are.equal("left", icon.align)
    assert.are.equal("left", permissions.align)
    assert.are.equal("left", mtime.align)
    assert.are.equal("%Y-%m-%d %H:%M", mtime.format)
  end)

  it("renders, parses, and compares built-in semantic values", function()
    for kind, expected in pairs({ directory = "d", file = "f", symlink = "l" }) do
      local descriptor = columns.icon({ provider = false })
      local kind_entry = vim.tbl_extend("force", {}, entry, { kind = kind })
      local ctx = context(descriptor, kind_entry, { kind = kind })
      local text = descriptor.render(kind_entry, ctx)
      assert.are.equal(expected, text)
      local value, remaining = descriptor.parse("  " .. text .. "   path", ctx)
      assert.are.equal(text, value)
      assert.are.equal("path", remaining)
      assert.is_true(descriptor.equals(kind_entry, value, ctx))
      assert.is_false(descriptor.equals(kind_entry, kind == "file" and "d" or "f", ctx))
    end

    local unsupported = vim.tbl_extend("force", {}, entry, { kind = "char" })
    for _, descriptor in ipairs({
      columns.icon({ provider = false }),
      columns.icon({ provider = function() return nil end }),
    }) do
      local icon, highlight = descriptor.render(
        unsupported, context(descriptor, unsupported, { kind = "char" })
      )
      assert.are.equal("?", icon)
      assert.are.equal("FreUnsupportedIcon", highlight)
    end

    local permissions = columns.permissions()
    local permissions_ctx = context(permissions, entry, { mode = 493 })
    assert.are.equal("rwxr-xr-x", permissions.render(entry, permissions_ctx))
    local permission_value, permission_rest = permissions.parse("rwxr-xr-x path", permissions_ctx)
    assert.are.equal("rwxr-xr-x", permission_value)
    assert.are.equal("path", permission_rest)
    assert.is_true(permissions.equals(entry, permission_value, permissions_ctx))
    assert.is_false(permissions.equals(entry, "rw-r--r--", permissions_ctx))

    local mtime = columns.mtime({ format = "%Y-%m-%d %H:%M" })
    local timestamp = 1704067200
    local mtime_ctx = context(mtime, entry, { mtime = { sec = timestamp, nsec = 7 } })
    local rendered = os.date(mtime.format, timestamp)
    assert.are.equal(rendered, mtime.render(entry, mtime_ctx))
    local mtime_value, mtime_rest = mtime.parse(" " .. rendered .. "  path", mtime_ctx)
    assert.are.equal(rendered, mtime_value)
    assert.are.equal("path", mtime_rest)
    assert.is_true(mtime.equals(entry, mtime_value, mtime_ctx))
    assert.is_false(mtime.equals(entry, rendered:gsub("^.", "9"), mtime_ctx))
  end)

  it("uses nvim-web-devicons with directory and symlink glyphs", function()
    local previous_loaded = package.loaded["nvim-web-devicons"]
    local previous_preload = package.preload["nvim-web-devicons"]
    local calls = 0
    package.loaded["nvim-web-devicons"] = nil
    package.preload["nvim-web-devicons"] = function()
      return {
        get_icon = function(name, extension, opts)
          calls = calls + 1
          assert.are.equal("init.lua", name)
          assert.is_nil(extension)
          assert.are.same({ default = true, strict = true }, opts)
          return "", "DevIconLua"
        end,
      }
    end

    local ok, err = xpcall(function()
      local descriptor = columns.icon({ provider = "nvim-web-devicons" })
      local cases = {
        { kind = "file", name = "init.lua", icon = "", highlight = "DevIconLua" },
        { kind = "directory", name = "lua", icon = "", highlight = "FreDirectoryIcon" },
        { kind = "symlink", name = "init-link", icon = "", highlight = "FreSymlinkIcon" },
        { kind = "char", name = "device", icon = "?", highlight = "FreUnsupportedIcon" },
      }
      for _, case in ipairs(cases) do
        local icon_entry = vim.tbl_extend("force", {}, entry, {
          kind = case.kind, name = case.name,
        })
        local ctx = context(descriptor, icon_entry, { kind = case.kind })
        local icon, highlight = descriptor.render(icon_entry, ctx)
        assert.are.equal(case.icon, icon)
        assert.are.equal(case.highlight, highlight)
        local value, remaining = descriptor.parse(" " .. icon .. "  path", ctx)
        assert.are.equal(icon, value)
        assert.are.equal("path", remaining)
        assert.is_true(descriptor.equals(icon_entry, value, ctx))
      end
      assert.are.equal(2, calls)
    end, debug.traceback)

    package.loaded["nvim-web-devicons"] = previous_loaded
    package.preload["nvim-web-devicons"] = previous_preload
    if not ok then error(err) end
  end)

  it("validates custom identities, alignment, metadata, and callbacks", function()
    local descriptor = columns.custom({
      id = "owner",
      align = "right",
      metadata = { "kind", "mode", "mtime" },
      extra = { value = 3 },
      render = function() return "me", "FreOwner" end,
      parse = function(suffix)
        local value, remaining = suffix:match("^ *(%a+) +(.*)$")
        return value, remaining
      end,
      equals = function(_, value) return value == "me" end,
    })
    assert.are.equal("owner", descriptor.id)
    assert.are.equal("right", descriptor.align)
    assert.are.same({ "kind", "mode", "mtime" }, descriptor.metadata)
    assert.are.same({ value = 3 }, descriptor.extra)
    assert.are.same({ descriptor }, columns.validate({ descriptor }))

    error_contains("custom options must be a table", function() columns.custom() end)
    error_contains("id must be a non-empty string", function()
      columns.custom({ render = function() end, parse = function() end, equals = function() end })
    end)
    error_contains("id must not contain whitespace", function()
      columns.custom({ id = "bad id", render = function() end, parse = function() end, equals = function() end })
    end)
    error_contains("align must be left, center, or right", function()
      columns.custom({ id = "bad", align = "middle", render = function() end, parse = function() end, equals = function() end })
    end)
    error_contains("unsupported field owner", function()
      columns.custom({ id = "bad", metadata = { "owner" }, render = function() end, parse = function() end, equals = function() end })
    end)
    error_contains("render must be a function", function()
      columns.custom({ id = "bad", render = true, parse = function() end, equals = function() end })
    end)
    error_contains("parse must be a function", function()
      columns.custom({ id = "bad", render = function() end, equals = function() end })
    end)
    error_contains("equals must be a function", function()
      columns.custom({ id = "bad", render = function() end, parse = function() end })
    end)
    error_contains("duplicate column id owner", function()
      columns.validate({ descriptor, descriptor })
    end)
    error_contains("must be created by fre.columns", function()
      columns.validate({ { id = "raw" } })
    end)
    error_contains("icon options must be a table", function() columns.icon("bad") end)
    error_contains("icon.provider", function() columns.icon({ provider = 42 }) end)
    error_contains("permissions options must be a table", function() columns.permissions("bad") end)
    error_contains("mtime.format must be a non-empty string", function()
      columns.mtime({ format = "" })
    end)
  end)

  it("preserves metadata declaration presence while normalizing requires", function()
    local function custom(opts)
      opts = vim.tbl_extend("force", {
        id = "dependency",
        render = function() return "x" end,
        parse = function(suffix) return "x", suffix end,
        equals = function() return true end,
      }, opts or {})
      return columns.custom(opts)
    end
    local omitted = custom()
    local empty = custom({ metadata = {} })
    local legacy = custom({ requires = { "size" } })
    local preferred = custom({ metadata = { "mode" }, requires = { "size" } })
    assert.are.same({}, omitted.metadata)
    assert.are.equal(false, omitted._metadata_declared)
    assert.are.same({}, empty.metadata)
    assert.are.equal(true, empty._metadata_declared)
    assert.are.same({ "size" }, legacy.metadata)
    assert.are.equal(true, legacy._metadata_declared)
    assert.is_nil(legacy.requires)
    assert.are.same({ "mode" }, preferred.metadata)
  end)

  it("normalizes descriptor enable without evaluating predicates", function()
    local calls = 0
    local predicate = function() calls = calls + 1; return true end
    local function custom(enable)
      return columns.custom({
        id = "enabled",
        enable = enable,
        render = function() return "x" end,
        parse = function(suffix) return "x", suffix:sub(3) end,
        equals = function() return true end,
      })
    end

    assert.is_true(custom(nil).enable)
    assert.is_false(custom(false).enable)
    assert.are.equal(predicate, custom(predicate).enable)
    assert.are.equal(0, calls)
    for _, invalid in ipairs({ 0, "yes", {}, coroutine.create(function() end) }) do
      error_contains("enable must be a boolean or function", function() custom(invalid) end)
    end
  end)

  it("rejects invalid renderer values, controls, and UTF-8", function()
    local function custom(render)
      return columns.custom({
        id = "rendered",
        render = render,
        parse = function(suffix) return "x", suffix:sub(2) end,
        equals = function() return true end,
      })
    end
    error_contains("render callback for column rendered failed", function()
      columns.render_text(custom(function() error("boom") end), entry, {})
    end)
    error_contains("must return text", function()
      columns.render_text(custom(function() return 3 end), entry, {})
    end)
    for _, text in ipairs({ "a\nb", "a" .. string.char(0) .. "b", string.char(127) }) do
      error_contains("contains a control byte", function()
        columns.render_text(custom(function() return text end), entry, {})
      end)
    end
    error_contains("not valid UTF-8", function()
      columns.render_text(custom(function() return string.char(0xff) end), entry, {})
    end)
    local text, highlight, width = columns.render_text(
      custom(function() return "é", "FreUtf" end), entry, {}
    )
    assert.are.equal("é", text)
    assert.are.equal("FreUtf", highlight)
    assert.are.equal(1, width)
  end)
end)
