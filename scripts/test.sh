#!/usr/bin/env sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"
FRE_TEST_FILE=${1-} nvim --headless --noplugin -u tests/minimal_init.lua -l scripts/run_tests.lua
