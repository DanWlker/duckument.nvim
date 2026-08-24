-- The commands end to end, against a real duckdb over real buffers and files.

local h = require('tests.helpers')

if not h.has_duckdb() then
  describe('duckquery', function()
    pending('needs duckdb on $PATH')
  end)
  return
end

describe('reading', function()
  it('replaces an unsaved buffer with the result', function()
    local bufnr = h.scratch()
    assert.same({
      'date,description,amt',
      '2025-10-15,rent,100',
      '2025-10-20,rent,110',
    }, h.run(bufnr, "Duck where description = 'rent'"))
  end)

  it('queries the buffer, not the stale file behind it', function()
    local bufnr = h.file('edited.csv')
    vim.api.nvim_buf_set_lines(bufnr, 1, -1, false, { '2025-11-01,new,7' })

    assert.same(
      { 'date,description,amt', '2025-11-01,new,7' },
      h.run(bufnr, 'Duck select * order by date')
    )
  end)

  it('leaves the file on disk alone until the buffer is written', function()
    local bufnr, path = h.file('untouched.csv')
    h.run(bufnr, 'Duck limit 1')

    assert.is_true(vim.bo[bufnr].modified)
    assert.same(h.rows, vim.fn.readfile(path))
  end)

  it('aggregates', function()
    local bufnr = h.scratch()
    assert.same({
      'date,n',
      '2025-10-15,2',
      '2025-10-20,2',
    }, h.run(
      bufnr,
      'Duck date, count(*) as n from this group by date order by date'
    ))
  end)

  it('keeps a tsv a tsv on the way back', function()
    local bufnr = h.file('tabbed.tsv', {
      'a\tb',
      '1\tx',
      '2\ty',
    })
    assert.same({ 'a\tb', '2\ty' }, h.run(bufnr, 'Duck where a > 1'))
  end)

  it('reports what duckdb complained about', function()
    h.scratch()
    local message = h.await('Duck select nope_col')
    assert.is_truthy(message:match('nope_col'))
  end)
end)

describe('writing', function()
  it('applies an update to the whole buffer', function()
    local bufnr = h.scratch()
    assert.same({
      'date,description,amt',
      '2025-10-15,rent,100',
      '2025-10-15,food,20',
      '2025-10-20,housing,110',
      '2025-10-20,gas,50',
    }, h.run(bufnr, "Duck update set description = 'housing' where amt = 110"))
  end)

  it('keeps the rows an update did not touch, in order', function()
    local bufnr = h.scratch()
    local after =
      h.run(bufnr, "Duck update set amt = 0 where description = 'food'")
    assert.equals(#h.rows, #after)
    assert.equals('2025-10-15,food,0', after[3])
  end)

  it('applies a delete', function()
    local bufnr = h.scratch()
    assert.same({
      'date,description,amt',
      '2025-10-15,rent,100',
      '2025-10-20,rent,110',
    }, h.run(bufnr, 'Duck delete where amt < 100'))
  end)

  it('applies an insert', function()
    local bufnr = h.scratch()
    local after = h.run(bufnr, "Duck insert values ('2025-10-21', 'water', 30)")
    assert.equals(#h.rows + 1, #after)
    assert.equals('2025-10-21,water,30', after[#after])
  end)
end)

describe('inspecting', function()
  it('renders a describe instead of overwriting the buffer', function()
    local bufnr = h.scratch()
    local rendered = h.render('Duck describe')

    assert.is_truthy(table.concat(rendered, '\n'):match('column_name'))
    assert.is_truthy(table.concat(rendered, '\n'):match('description'))
    assert.same(h.rows, h.lines(bufnr))
  end)

  it('renders a preview in a scratch window', function()
    local bufnr = h.scratch()
    local rendered = h.render('DuckPreview where amt > 100')

    assert.is_truthy(table.concat(rendered, '\n'):match('110'))
    assert.same(h.rows, h.lines(bufnr))
  end)

  it('previews a mutation without applying it', function()
    local bufnr = h.scratch()
    local rendered = h.render('DuckPreview update set amt = 99')

    assert.is_truthy(table.concat(rendered, '\n'):match('99'))
    assert.same(h.rows, h.lines(bufnr))
  end)

  it('opens the scratch window read only', function()
    h.scratch()
    local origin = vim.api.nvim_get_current_win()
    vim.cmd('DuckPreview')
    h.wait(function() return vim.api.nvim_get_current_win() ~= origin end, 'preview')

    assert.equals('nofile', vim.bo.buftype)
    assert.is_false(vim.bo.modifiable)
    vim.cmd('close')
  end)
end)

describe('parquet', function()
  --- A parquet file written from `h.rows`, opened and current when this returns.
  ---@return integer bufnr
  ---@return string path
  local function open_parquet()
    local _, csv = h.file('source.csv')
    local path = vim.fn.tempname() .. '-data.parquet'
    h.read_back(
      csv,
      ("copy (select * from read_csv('%s')) to '" .. path .. "' (FORMAT parquet)")
    )
    vim.cmd.edit(path)
    return vim.api.nvim_get_current_buf(), path
  end

  it('rewrites the file on disk and reloads the buffer', function()
    local _, path = open_parquet()
    h.await("Duck! update set description = 'housing' where amt = 110")

    local changed = "select description from read_parquet('%s') where amt = 110"
    assert.equals('description\nhousing', h.read_back(path, changed))

    assert.equals(
      'count_star()\n' .. tostring(#h.rows - 1),
      h.read_back(path, "select count(*) from read_parquet('%s')")
    )
  end)

  it('describes without touching the file', function()
    local _, path = open_parquet()
    local count = "select count(*) from read_parquet('%s')"
    local before = h.read_back(path, count)

    local rendered = h.render('Duck describe')
    assert.is_truthy(table.concat(rendered, '\n'):match('column_name'))
    assert.equals(before, h.read_back(path, count))
  end)
end)

describe('unsupported buffers', function()
  it('says so rather than guessing', function()
    vim.cmd('enew!')
    vim.api.nvim_buf_set_name(0, vim.fn.tempname() .. '-notes.md')
    vim.bo.filetype = 'markdown'

    local message = h.await('Duck')
    assert.is_truthy(message:match('unsupported filetype'))
  end)
end)
