--- The file formats duckquery can read a buffer as, and write a result back in.
--- A result always comes back in the format it went in as, so the buffer never
--- changes shape underneath you.

---@class DuckqueryFormat
---@field ext string          extension for the temp copy of an unsaved buffer
---@field reader string       duckdb table function used to read the source
---@field reader_args? string extra arguments for that table function
---@field copy string         COPY ... TO options used to write the result
---@field binary? boolean     true when the result cannot live in the buffer as text

local M = {}

---@type table<string, DuckqueryFormat>
M.formats = {
  csv = { ext = 'csv', reader = 'read_csv', copy = 'FORMAT csv, HEADER' },
  tsv = {
    ext = 'tsv',
    reader = 'read_csv',
    reader_args = ", delim = '\\t'",
    copy = "FORMAT csv, DELIMITER '\\t', HEADER",
  },
  json = {
    ext = 'json',
    reader = 'read_json_auto',
    copy = 'FORMAT json, ARRAY true',
  },
  ndjson = {
    ext = 'ndjson',
    reader = 'read_json_auto',
    copy = 'FORMAT json, ARRAY false',
  },
  parquet = {
    ext = 'parquet',
    reader = 'read_parquet',
    copy = 'FORMAT parquet',
    binary = true,
  },
}

local by_ext = {
  csv = M.formats.csv,
  tsv = M.formats.tsv,
  tab = M.formats.tsv,
  json = M.formats.json,
  jsonl = M.formats.ndjson,
  ndjson = M.formats.ndjson,
  parquet = M.formats.parquet,
  pq = M.formats.parquet,
}

local by_filetype = {
  csv = M.formats.csv,
  tsv = M.formats.tsv,
  json = M.formats.json,
  jsonl = M.formats.ndjson,
  ndjson = M.formats.ndjson,
}

--- What `bufnr` holds: its extension decides, since that is what a parquet
--- buffer has to go on, and its filetype is the fallback for everything else.
---@param bufnr integer
---@return DuckqueryFormat?
function M.detect(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local ext = name:match('%.([%w]+)$')

  return (ext and by_ext[ext:lower()])
    or by_filetype[vim.bo[bufnr].filetype]
    -- A nameless scratch buffer of pasted rows is overwhelmingly csv.
    or (name == '' and M.formats.csv)
    or nil
end

return M
