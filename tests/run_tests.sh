#!/usr/bin/env bash
# Runs the whole suite in a headless neovim, one spec file at a time.
set -e

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

nvim --headless --noplugin -u tests/init.lua \
  -c "lua require('plenary.test_harness').test_directory('tests', { minimal_init = 'tests/init.lua', sequential = true, keep_going = true })"
