--- The file formats duckument can read a buffer as, and write a result back in.
--- A result always comes back in the format it went in as, so the buffer never
--- changes shape underneath you.

---@class DuckumentFormat
---@field ext string          extension for the temp copy of an unsaved buffer
---@field reader string       duckdb table function used to read the source
---@field reader_args? string extra arguments for that table function
---@field copy string         COPY ... TO options used to write the result

local M = {}

---@type table<string, DuckumentFormat>
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
}

local by_ext = {
  csv = M.formats.csv,
  tsv = M.formats.tsv,
  tab = M.formats.tsv,
  json = M.formats.json,
  jsonl = M.formats.ndjson,
  ndjson = M.formats.ndjson,
}

local by_filetype = {
  csv = M.formats.csv,
  tsv = M.formats.tsv,
  json = M.formats.json,
  jsonl = M.formats.ndjson,
  ndjson = M.formats.ndjson,
}

--- What `bufnr` holds: its extension decides, being the more specific of the
--- two -- a `.tsv` opened as `csv` is still tab-separated -- and its filetype is
--- the fallback for a buffer whose name says nothing.
---@param bufnr integer
---@return DuckumentFormat?
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
