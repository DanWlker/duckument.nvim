--- Shared scaffolding for the specs: scratch buffers, temp files, and the wait
--- every assertion about a duckdb result has to do, since the commands run the
--- process asynchronously.

local M = {}

M.rows = {
  'date,description,amt',
  '2025-10-15,rent,100',
  '2025-10-15,food,20',
  '2025-10-20,rent,110',
  '2025-10-20,gas,50',
}

--- Blocks until `cond` holds, failing the test rather than hanging forever.
---@param cond fun(): boolean
---@param what string described in the failure message
function M.wait(cond, what)
  assert.is_true(vim.wait(10000, cond, 20), 'timed out waiting for ' .. what)
end

---@param bufnr? integer
---@return string[]
function M.lines(bufnr) return vim.api.nvim_buf_get_lines(bufnr or 0, 0, -1, false) end

--- A nameless, unsaved buffer holding `lines`, current when this returns.
---@param lines? string[]
---@return integer bufnr
function M.scratch(lines)
  vim.cmd('enew!')
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or M.rows)
  return bufnr
end

--- A file on disk holding `lines`, opened and current when this returns.
---@param name string basename, whose extension picks the format
---@param lines? string[]
---@return integer bufnr
---@return string path
function M.file(name, lines)
  local path = vim.fn.tempname() .. '-' .. name
  assert.equals(0, vim.fn.writefile(lines or M.rows, path))
  vim.cmd.edit(path)
  return vim.api.nvim_get_current_buf(), path
end

--- Runs `cmd` and waits for it to report what it did, which is the only signal
--- that the query has come back: a result identical to what the buffer already
--- held is still a result.
---@param cmd string
---@return string? message
function M.await(cmd)
  local seen
  local notify = vim.notify
  vim.notify = function(msg) seen = msg end
  local ok, failed = pcall(vim.cmd, cmd)
  vim.wait(10000, function() return seen ~= nil end, 20)
  vim.notify = notify

  assert.is_true(ok, tostring(failed))
  return seen
end

--- Runs `cmd`, waiting for it to finish with the buffer, and returns what it
--- left there.
---@param bufnr integer
---@param cmd string
---@return string[] the new lines
function M.run(bufnr, cmd)
  local message = M.await(cmd)
  assert.is_truthy(message, 'no result reported by: ' .. cmd)
  assert.is_falsy(
    tostring(message):match('Error'),
    ('%s failed: %s'):format(cmd, message)
  )
  return M.lines(bufnr)
end

--- Runs `cmd`, waiting until it has opened its scratch window, and returns what
--- it rendered there. The window is closed again before returning.
---@param cmd string
---@return string[]
function M.render(cmd)
  local origin = vim.api.nvim_get_current_win()
  vim.cmd(cmd)
  M.wait(function() return vim.api.nvim_get_current_win() ~= origin end, cmd)
  local rendered = M.lines()
  vim.cmd('close')
  return rendered
end

--- Skips the calling spec when duckdb is not installed.
---@return boolean
function M.has_duckdb() return vim.fn.executable('duckdb') == 1 end

return M
