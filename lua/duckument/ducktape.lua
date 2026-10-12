--- The whole of the statement completion, in the `ducktape` binary
--- built alongside this plugin.
---
--- Everything that reads what you typed happens over there, on sqruff's lexer
--- and parser: supplying the SELECT, naming the table a mutation writes to,
--- placing the FROM clauses. This side hands over a string and takes back a
--- statement -- there is no second opinion here to keep in step with that one.
---
--- The binary is therefore required. The plugin builds it whenever vim.pack
--- installs or updates it, and on first use when it is missing (see
--- `duckument.build`); otherwise build it with `make build`, or point
--- `vim.g.duckument_parse_binary` at one already built.

local build = require('duckument.build')

local M = {}

local MISSING =
  'ducktape not found -- building it, or run `make build` in the plugin directory'

-- nil until the first attempt, false once the binary turns out to be missing --
-- a checkout that never ran `make build` pays for one lookup and no more.
local available = nil
local binary
local built = false

---@return string? path to the binary, once it has been looked for
local function locate()
  if binary ~= nil then return binary or nil end

  local configured = vim.g.duckument_parse_binary
  if configured == false then
    binary = false
    return nil
  end
  if configured then
    binary = vim.fn.executable(configured) == 1 and configured or false
    return binary or nil
  end

  -- Built in place, beside this very file; then, for a checkout
  -- installed somewhere else entirely, wherever a packager left one.
  local candidates = { build.binary_path }
  for _, relative in ipairs({ 'out/release/ducktape', 'bin/ducktape' }) do
    vim.list_extend(candidates, vim.api.nvim_get_runtime_file(relative, true))
  end

  for _, candidate in ipairs(candidates) do
    if vim.fn.executable(candidate) == 1 then
      binary = candidate
      return binary
    end
  end

  binary = false
  return nil
end

--- Builds the binary, once a session, saying what came of it. Nothing waits on
--- this: the query that found it missing has already been turned down, and the
--- next one will find it there.
local function build_missing()
  if built then return end
  built = true

  build.run(function(why)
    if why then return vim.notify('duckument: ' .. why, vim.log.levels.WARN) end
    M.reset()
    vim.notify('duckument: ducktape is ready -- run that again')
  end)
end

--- Whether the binary has been found. nil while that is still unknown.
---@return boolean?
function M.available() return available end

--- Completes what was typed into a statement duckdb will run.
---
--- Returns nil when the binary could not be reached, and when it read the
--- statement but could not finish it -- sqruff's duckdb dialect does not stretch
--- to every statement duckdb itself will take.
---@param args string
---@return string? statement
---@return string? why  why there is none, when there is none
function M.complete(args)
  local path = locate()
  if not path then
    available = false
    -- Only when the looking was ours to do. A binary named outright, or the
    -- lookup turned off, is a decision to leave alone rather than answer by
    -- building something.
    if vim.g.duckument_parse_binary == nil then build_missing() end
    return nil, MISSING
  end

  local payload = vim.json.encode({ statement = args, table = 'this' })
  local ok, res = pcall(
    function()
      return vim.system({ path }, { stdin = payload, text = true }):wait(10000)
    end
  )
  if not ok or res.code ~= 0 then
    available = false
    return nil, MISSING
  end

  local decoded
  ok, decoded = pcall(vim.json.decode, res.stdout or '')
  if not ok or type(decoded) ~= 'table' then
    available = false
    return nil, MISSING
  end

  available = true
  -- The statement, or why there is none: whichever field came back is the
  -- answer, and there is always exactly one of them.
  if decoded.sql then return decoded.sql end
  return nil, decoded.error or 'could not complete that statement'
end

--- Forgets where the binary was, so the next call looks again. For tests, and
--- for after building it mid-session.
function M.reset()
  available = nil
  binary = nil
  built = false
end

return M
