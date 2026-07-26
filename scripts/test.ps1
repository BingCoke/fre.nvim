param(
  [Parameter(Position = 0)]
  [string]$Spec = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $RepoRoot
try {
  $env:FRE_TEST_FILE = $Spec
  & nvim --headless --noplugin -u tests/minimal_init.lua -l scripts/run_tests.lua
  exit $LASTEXITCODE
}
finally {
  Remove-Item Env:FRE_TEST_FILE -ErrorAction SilentlyContinue
  Pop-Location
}
