--- The whole of the statement completion, in the `duckquery-parse` binary
--- built alongside this plugin.
---
--- Everything that reads what you typed happens over there, on sqruff's lexer
--- and parser: supplying the SELECT, naming the table a mutation writes to,
--- placing the FROM clauses, deciding what the statement does with the buffer.
--- This side hands over a string and takes back a statement -- there is no
--- second opinion here to keep in step with that one.
---
--- The binary is therefore required. Build it with `make build`, or point
--- `vim.g.duckquery_parse_binary` at one already built.

local M = {}

local MISSING =
  'duckquery-parse not found -- run `make build` in the plugin directory'

-- nil until the first attempt, false once the binary turns out to be missing --
-- a checkout that never ran `make build` pays for one lookup and no more.
local available = nil
local binary

---@return string? path to the binary, once it has been looked for
local function locate()
  if binary ~= nil then return binary or nil end

  local configured = vim.g.duckquery_parse_binary
  if configured == false then
    binary = false
    return nil
  end
  if configured then
    binary = vim.fn.executable(configured) == 1 and configured or false
    return binary or nil
  end

  -- Built in place by `make build`, or shipped next to the lua for a release.
  local candidates =
    { 'src/target/release/duckquery-parse', 'bin/duckquery-parse' }
  for _, relative in ipairs(candidates) do
    local found = vim.api.nvim_get_runtime_file(relative, false)[1]
    if found and vim.fn.executable(found) == 1 then
      binary = found
      return binary
    end
  end

  binary = false
  return nil
end

--- Whether the binary has been found. nil while that is still unknown.
---@return boolean?
function M.available() return available end

--- Completes what was typed into a statement duckdb will run.
---
--- Returns nil only when the binary could not be reached: it always has an
--- answer otherwise, falling back to its own token-driven completion for the
--- statements sqruff's duckdb dialect cannot read in full.
---@param args string
---@return string? statement
---@return string? why  why there is none, when there is none
function M.complete(args)
  if available == false then return nil, MISSING end

  local path = locate()
  if not path then
    available = false
    return nil, MISSING
  end

  local payload = vim.json.encode({ statement = args, table = 'this' })
  local ok, res = pcall(function()
    return vim.system({ path }, { stdin = payload, text = true }):wait(10000)
  end)
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
end

return M
