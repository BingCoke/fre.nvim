local fixture_fs = require("tests.helpers.fs")
local fs = require("fre.fs")

local uv = vim.uv

local function create_files(fixture, count)
  for index = 1, count do
    fixture:write(string.format("%03d.txt", index), tostring(index))
  end
end

local function defer_lstats()
  local state = {
    active = 0,
    max_active = 0,
    pending = {},
    started_paths = {},
  }

  uv.fs_lstat = function(path, callback)
    state.active = state.active + 1
    state.max_active = math.max(state.max_active, state.active)
    state.started_paths[#state.started_paths + 1] = path
    state.pending[#state.pending + 1] = {
      callback = callback,
      path = path,
    }
  end

  return state
end

describe("filesystem adapter", function()
  local fixture
  local original_lstat

  before_each(function()
    fixture = fixture_fs.new()
    original_lstat = uv.fs_lstat
  end)

  after_each(function()
    uv.fs_lstat = original_lstat
    fixture:cleanup()
  end)

  it("stats directory entries concurrently and preserves scan order", function()
    create_files(fixture, 40)
    local deferred = defer_lstats()
    local result
    local callback_count = 0

    fs.default.load(fixture.root, function(err, children, real_root)
      callback_count = callback_count + 1
      result = {
        children = children,
        err = err,
        real_root = real_root,
      }
    end)

    assert.is_true(vim.wait(1000, function()
      return #deferred.pending > 0
    end, 1))
    assert.are.equal(32, deferred.max_active)
    assert.are.equal(32, #deferred.pending)
    assert.are.equal(0, callback_count)

    while #deferred.pending > 0 do
      local request = table.remove(deferred.pending)
      deferred.active = deferred.active - 1
      local stat, err = original_lstat(request.path)
      request.callback(err, stat)
    end

    assert.are.equal(1, callback_count)
    assert.is_nil(result.err)
    assert.are.equal(assert(uv.fs_realpath(fixture.root)), result.real_root)
    assert.are.equal(40, #result.children)

    local expected_paths = deferred.started_paths
    local actual_paths = {}
    for _, child in ipairs(result.children) do
      actual_paths[#actual_paths + 1] = child.real_path
    end
    assert.are.same(expected_paths, actual_paths)
  end)

  it("ignores entries that disappear between scanning and stat", function()
    create_files(fixture, 6)
    local deferred = defer_lstats()
    local result
    local missing_path

    fs.default.load(fixture.root, function(err, children)
      result = { err = err, children = children }
    end)

    assert.is_true(vim.wait(1000, function()
      return #deferred.pending > 0
    end, 1))
    missing_path = deferred.started_paths[3]

    while #deferred.pending > 0 do
      local request = table.remove(deferred.pending)
      deferred.active = deferred.active - 1
      if request.path == missing_path then
        assert.is_true(uv.fs_unlink(request.path))
      end
      local stat, err = original_lstat(request.path)
      request.callback(err, stat)
    end

    assert.is_not_nil(result)
    assert.is_nil(result.err)
    assert.are.equal(5, #result.children)
    for _, child in ipairs(result.children) do
      assert.is_not.equal(missing_path, child.real_path)
    end
  end)

  it("reports the earliest scan-order stat error after in-flight requests settle", function()
    create_files(fixture, 6)
    local deferred = defer_lstats()
    local callback_count = 0
    local result_err

    fs.default.load(fixture.root, function(err)
      callback_count = callback_count + 1
      result_err = err
    end)

    assert.is_true(vim.wait(1000, function()
      return #deferred.pending > 0
    end, 1))
    assert.is_true(deferred.max_active > 1)

    local earlier_path = deferred.started_paths[2]
    local later_path = deferred.started_paths[5]
    while #deferred.pending > 0 do
      local request = table.remove(deferred.pending)
      deferred.active = deferred.active - 1
      if request.path == earlier_path then
        request.callback("earlier failure")
      elseif request.path == later_path then
        request.callback("later failure")
      else
        local stat, err = original_lstat(request.path)
        request.callback(err, stat)
      end
      if #deferred.pending > 0 then
        assert.are.equal(0, callback_count)
      end
    end

    assert.are.equal(1, callback_count)
    assert.are.equal(
      string.format("cannot stat entry %s: earlier failure", earlier_path),
      result_err
    )
  end)
end)
