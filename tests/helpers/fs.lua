local uv = vim.uv

local Fixture = {}
Fixture.__index = Fixture

local function raise(action, path, err)
  error(string.format("%s %s: %s", action, path, err or "unknown error"), 3)
end

local function mkdir_p(path)
  if path == "" or uv.fs_stat(path) then
    return
  end
  local parent = vim.fs.dirname(path)
  if parent and parent ~= path then
    mkdir_p(parent)
  end
  local ok, err = uv.fs_mkdir(path, 448)
  if not ok and not uv.fs_stat(path) then
    raise("mkdir", path, err)
  end
end

local function remove_tree(path)
  local stat = uv.fs_lstat(path)
  if not stat then
    return
  end
  if stat.type ~= "directory" then
    local ok, err = uv.fs_unlink(path)
    if not ok then
      raise("unlink", path, err)
    end
    return
  end

  local handle, open_err = uv.fs_scandir(path)
  if not handle then
    raise("scan", path, open_err)
  end
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    remove_tree(vim.fs.joinpath(path, name))
  end
  local ok, err = uv.fs_rmdir(path)
  if not ok then
    raise("rmdir", path, err)
  end
end

function Fixture.new()
  local root, err = uv.fs_mkdtemp(vim.fn.tempname() .. "-fre-XXXXXX")
  if not root then
    raise("mkdtemp", "fixture", err)
  end
  return setmetatable({ root = root, cleaned = false }, Fixture)
end

function Fixture:path(...)
  return vim.fs.joinpath(self.root, ...)
end

function Fixture:mkdir(relative)
  local path = self:path(relative)
  mkdir_p(path)
  return path
end

function Fixture:write(relative, contents)
  local path = self:path(relative)
  mkdir_p(vim.fs.dirname(path))
  local fd, open_err = uv.fs_open(path, "w", 384)
  if not fd then
    raise("open", path, open_err)
  end
  local ok, write_err = uv.fs_write(fd, contents or "", -1)
  local close_ok, close_err = uv.fs_close(fd)
  if not ok then
    raise("write", path, write_err)
  end
  if not close_ok then
    raise("close", path, close_err)
  end
  return path
end

function Fixture:tree(entries)
  for relative, value in pairs(entries) do
    if value == true then
      self:mkdir(relative)
    else
      self:write(relative, value)
    end
  end
  return self.root
end

function Fixture:symlink(target, relative, flags)
  local path = self:path(relative)
  mkdir_p(vim.fs.dirname(path))
  local ok, err = uv.fs_symlink(target, path, flags)
  if not ok then
    return nil, err
  end
  return path
end

function Fixture:cleanup()
  if not self.cleaned then
    remove_tree(self.root)
    self.cleaned = true
  end
end

return {
  new = Fixture.new,
  remove_tree = remove_tree,
}
