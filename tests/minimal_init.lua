local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(source)))
local dependency_root = vim.fs.joinpath(root, ".deps")
local plenary = vim.fs.joinpath(dependency_root, "plenary.nvim")
local plenary_commit = "74b06c6c75e4eeb3108ec01852001636d85a932b"

local function run(command, opts)
  local result = vim.system(command, vim.tbl_extend("force", { cwd = root, text = true }, opts or {})):wait()
  if result.code ~= 0 then
    error(table.concat(command, " ") .. " failed:\n" .. (result.stderr or result.stdout or ""))
  end
  return vim.trim(result.stdout or "")
end

vim.fn.mkdir(dependency_root, "p")
if vim.uv.fs_stat(vim.fs.joinpath(plenary, ".git")) == nil then
  if vim.uv.fs_stat(plenary) ~= nil then
    error("dependency path exists but is not a git checkout: " .. plenary)
  end
  run({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/nvim-lua/plenary.nvim.git",
    plenary,
  })
end

local current_commit = run({ "git", "-C", plenary, "rev-parse", "HEAD" })
if current_commit ~= plenary_commit then
  run({ "git", "-C", plenary, "fetch", "origin", plenary_commit })
  run({ "git", "-C", plenary, "checkout", "--detach", plenary_commit })
end

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(plenary)
vim.g.fre_test_root = root
