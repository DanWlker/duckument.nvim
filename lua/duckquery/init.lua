--- duckquery: run duckdb over the buffer you are looking at.
---
--- The buffer is handed to duckdb as `this` -- saved or not -- the statement is
--- completed by `duckquery.sqruff`, and the result comes back in the format it
--- went out as, replacing the buffer's contents or, for a query that only
--- reports on the data, rendering into a scratch window.

local format = require('duckquery.format')
local sqruff = require('duckquery.sqruff')

local M = {}

local function err(msg) vim.notify('Duck: ' .. msg, vim.log.levels.ERROR) end

---@param s string
---@return string quoted SQL string literal
local function quote(s) return "'" .. s:gsub("'", "''") .. "'" end

--- What a statement does with the buffer: reads it, writes to it, or reports on
--- it. Only what to do with the result turns on this.
---@alias DuckqueryKind 'read'|'write'|'inspect'

local kinds = {
  update = 'write',
  delete = 'write',
  insert = 'write',
  describe = 'inspect',
  summarize = 'inspect',
}

--- A completed statement opens with the keyword that decides its kind -- the
--- binary has already supplied any missing SELECT and named any mutation's
--- target -- so the first word settles it, and nothing here has to read SQL.
---@param statement string as the binary completed it
---@return DuckqueryKind
local function kind_of(statement)
  return kinds[(statement:match('^%s*(%a+)') or ''):lower()] or 'read'
end

--- Resolves what duckdb should read for `bufnr`, dumping unsaved text to a temp
--- file so the query sees the buffer rather than the file behind it.
---@param bufnr integer
---@param spec DuckqueryFormat
---@return string? path
---@return string? temp path to clean up
---@return string? error
local function source_for(bufnr, spec)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local on_disk = name ~= '' and vim.uv.fs_stat(name) ~= nil

  if on_disk and not vim.bo[bufnr].modified then return name end

  if spec.binary then
    -- A binary buffer holds bytes neovim has already mangled, so the file on
    -- disk is the only faithful copy of it.
    if not on_disk then return nil, nil, 'binary buffers must exist on disk' end
    vim.notify(
      'Duck: buffer is modified, querying the file on disk',
      vim.log.levels.WARN
    )
    return name
  end

  local temp = vim.fn.tempname() .. '.' .. spec.ext
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if vim.fn.writefile(lines, temp) ~= 0 then
    return nil, nil, 'could not write ' .. temp
  end
  return temp, temp
end

---@class DuckqueryJob
---@field bufnr integer
---@field spec DuckqueryFormat
---@field src string
---@field temp? string
---@field source string statement exposing the buffer's data as `this`
---@field query string
---@field kind DuckqueryKind

--- Everything a command needs before shelling out, or nil after reporting why.
---@param bufnr integer
---@param args string
---@return DuckqueryJob?
local function prepare(bufnr, args)
  if vim.fn.executable('duckdb') ~= 1 then
    err('duckdb executable not found in $PATH')
    return nil
  end

  local spec = format.detect(bufnr)
  if not spec then
    err('unsupported filetype (expected csv, tsv, json or parquet)')
    return nil
  end

  local src, temp, why = source_for(bufnr, spec)
  if not src then
    err(why or 'no source for this buffer')
    return nil
  end

  local query, why = sqruff.complete(args)
  if not query then
    err(why or 'could not complete that statement')
    return nil
  end
  local kind = kind_of(query)

  return {
    bufnr = bufnr,
    spec = spec,
    src = src,
    temp = temp,
    -- A mutation needs somewhere to write, so it gets a real temp table; a read
    -- stays a view, which lets duckdb push the filters into the file scan.
    source = ('create or replace temp %s this as select * from %s(%s%s);\n'):format(
      kind == 'write' and 'table' or 'view',
      spec.reader,
      quote(src),
      spec.reader_args or ''
    ),
    query = query,
    kind = kind,
  }
end

--- Feeds `sql_text` to duckdb, reporting failures and calling `on_ok(stdout)` on
--- the main loop otherwise. `temp`, when given, is removed either way.
---@param sql_text string
---@param extra_args string[]
---@param temp? string
---@param on_ok fun(stdout: string)
local function run(sql_text, extra_args, temp, on_ok)
  local cmd = vim.list_extend({ 'duckdb', '-bail' }, extra_args)
  vim.system(cmd, { stdin = sql_text, text = true }, function(res)
    vim.schedule(function()
      if temp then os.remove(temp) end
      if res.code ~= 0 then
        local msg = vim.trim(res.stderr or '')
        err(msg ~= '' and msg or 'duckdb exited with code ' .. res.code)
        return
      end
      on_ok(res.stdout or '')
    end)
  end)
end

--- Runs `job` for display only, dropping the result into a scratch window and
--- leaving every buffer that holds real data alone.
---@param job DuckqueryJob
local function show(job)
  local script = job.source
    .. job.query
    .. ';\n'
    -- A mutation prints nothing of its own, so the dry-run table is asked for.
    .. (job.kind == 'write' and 'select * from this;\n' or '')

  run(script, { '-box' }, job.temp, function(stdout)
    local lines = vim.split(vim.trim(stdout), '\n', { trimempty = true })
    if #lines == 0 then lines = { '(no rows)' } end

    vim.cmd.new()
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].bufhidden = 'wipe'
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    vim.wo.wrap = false
    vim.api.nvim_win_set_height(0, math.min(#lines + 1, 20))
  end)
end

--- Runs `args` over the current buffer and replaces its contents with the
--- result. `bang` skips the confirmation a binary format needs, since its
--- result can only be written straight to disk.
---@param args string
---@param bang? boolean
function M.query(args, bang)
  local bufnr = vim.api.nvim_get_current_buf()
  local job = prepare(bufnr, args)
  if not job then return end

  -- Nothing to replace the buffer with: DESCRIBE reports on the data instead
  -- of returning it, so it renders like a preview.
  if job.kind == 'inspect' then return show(job) end

  -- Text results land in the buffer, where u still works. Binary ones can only
  -- go straight to disk, so they get a confirmation instead.
  if job.spec.binary and not bang then
    local prompt = ('Overwrite %s on disk with the query result?'):format(
      vim.fn.fnamemodify(job.src, ':t')
    )
    if vim.fn.confirm(prompt, '&Yes\n&No', 2) ~= 1 then
      if job.temp then os.remove(job.temp) end
      return
    end
  end

  local out = vim.fn.tempname() .. '.' .. job.spec.ext
  -- A mutation leaves its result in the table, so it runs first and the whole
  -- table is what gets written back out.
  local script = job.source
    .. (job.kind == 'write' and (job.query .. ';\n') or '')
    .. ('copy (%s) to %s (%s);\n'):format(
      job.kind == 'write' and 'select * from this' or job.query,
      quote(out),
      job.spec.copy
    )

  run(script, {}, job.temp, function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      os.remove(out)
      return
    end

    if job.spec.binary then
      local ok, why = vim.uv.fs_copyfile(out, job.src)
      os.remove(out)
      if not ok then
        err('could not replace ' .. job.src .. ': ' .. (why or '?'))
        return
      end
      vim.api.nvim_buf_call(bufnr, function() vim.cmd.edit({ bang = true }) end)
      vim.notify('Duck: rewrote ' .. vim.fn.fnamemodify(job.src, ':t'))
    else
      local lines = vim.fn.readfile(out)
      os.remove(out)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.notify(('Duck: %d line%s'):format(#lines, #lines == 1 and '' or 's'))
    end
  end)
end

--- Runs `args` over the current buffer and renders the result in a scratch
--- window, leaving the buffer itself untouched.
---@param args string
function M.preview(args)
  local job = prepare(vim.api.nvim_get_current_buf(), args)
  if job then show(job) end
end

return M
