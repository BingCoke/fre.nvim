local fs = require("tests.helpers.fs")

local uv = vim.uv

describe("temporary filesystem fixtures", function()
  local fixture

  before_each(function()
    fixture = fs.new()
  end)

  after_each(function()
    fixture:cleanup()
  end)

  it("creates isolated directories, files, and trees", function()
    fixture:tree({
      ["empty"] = true,
      ["nested/child.txt"] = "child contents",
      ["root.txt"] = "root contents",
    })

    assert.are.equal("directory", uv.fs_stat(fixture:path("empty")).type)
    assert.are.equal("file", uv.fs_stat(fixture:path("nested", "child.txt")).type)
    local fd = assert(uv.fs_open(fixture:path("nested", "child.txt"), "r", 438))
    local contents = assert(uv.fs_read(fd, 128, 0))
    assert(uv.fs_close(fd))
    assert.are.equal("child contents", contents)
  end)

  it("cleans up the complete fixture tree", function()
    local root = fixture.root
    fixture:write("nested/file", "contents")
    fixture:cleanup()
    assert.is_nil(uv.fs_lstat(root))
  end)

  it("creates and removes a symlink when the platform permits it", function()
    local target = fixture:write("target.txt", "target")
    local link, err = fixture:symlink(target, "link.txt")
    if not link then
      assert.is_truthy(err)
      return
    end

    assert.are.equal("link", uv.fs_lstat(link).type)
    fixture:cleanup()
    assert.is_nil(uv.fs_lstat(link))
    assert.is_nil(uv.fs_lstat(fixture.root))
  end)
end)
