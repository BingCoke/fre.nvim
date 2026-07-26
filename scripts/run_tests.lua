local root = assert(vim.g.fre_test_root, "tests/minimal_init.lua must be used")
local focused = vim.env.FRE_TEST_FILE

if focused and focused ~= "" then
  local spec = vim.fs.normalize(focused)
  if not vim.startswith(spec, "/") and not spec:match("^%a:[/\\]") then
    spec = vim.fs.joinpath(root, spec)
  end
  require("plenary.busted").run(spec)
else
  require("plenary.test_harness").test_directory(vim.fs.joinpath(root, "tests"), {
    minimal_init = vim.fs.joinpath(root, "tests", "minimal_init.lua"),
    sequential = true,
    keep_going = true,
  })
end
