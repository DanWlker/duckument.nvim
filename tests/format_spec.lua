-- Which format a buffer is taken to hold.

local format = require('duckument.format')

--- The format detected for a buffer named `name` with filetype `ft`.
---@param name string
---@param ft? string
---@return DuckumentFormat?
local function detect(name, ft)
  local bufnr = vim.api.nvim_create_buf(false, true)
  if name ~= '' then vim.api.nvim_buf_set_name(bufnr, name) end
  if ft then vim.bo[bufnr].filetype = ft end
  local spec = format.detect(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  return spec
end

describe('format detection', function()
  it('goes by extension first', function()
    assert.equals(format.formats.csv, detect('/tmp/a.csv'))
    assert.equals(format.formats.tsv, detect('/tmp/a.tsv'))
    assert.equals(format.formats.json, detect('/tmp/a.json'))
    assert.equals(format.formats.ndjson, detect('/tmp/a.jsonl'))
    assert.equals(format.formats.ndjson, detect('/tmp/a.ndjson'))
    assert.equals(format.formats.tsv, detect('/tmp/a.tab'))
  end)

  it(
    'does not care how the extension is cased',
    function() assert.equals(format.formats.csv, detect('/tmp/A.CSV')) end
  )

  it('falls back to the filetype', function()
    assert.equals(format.formats.csv, detect('/tmp/report', 'csv'))
    assert.equals(format.formats.tsv, detect('/tmp/report', 'tsv'))
  end)

  it(
    'takes a nameless buffer for csv',
    function() assert.equals(format.formats.csv, detect('')) end
  )

  it(
    'gives up on anything else',
    function() assert.is_nil(detect('/tmp/notes.md', 'markdown')) end
  )

  it('can read and write back every format it detects', function()
    for name, spec in pairs(format.formats) do
      assert.is_truthy(spec.reader, name .. ' has no way to read a source')
      assert.is_truthy(spec.copy, name .. ' has no way to write a result back')
      assert.is_truthy(spec.ext, name .. ' has no extension for a temp copy')
    end
  end)
end)
