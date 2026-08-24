-- The whole of the statement completion, which lives in the binary. Skips
-- itself unless it has been built (`make build`).

local sqruff = require('duckquery.sqruff')

sqruff.reset()
if not sqruff.complete('select 1 from t') then
  describe('sqruff', function()
    pending('needs target/release/duckquery-parse -- run `make build`')
  end)
  return
end

--- The completed statement, asserting the binary answered.
---@param args string
---@return string
local function complete(args)
  local completed = sqruff.complete(args)
  assert.is_truthy(completed, 'no answer for: ' .. args)
  return completed
end


describe('splicing', function()
  it('names the buffer as the source of a select without one', function()
    assert.equals('select * from this', complete('select *'))
    assert.equals('select a from this where b > 1', complete('select a where b > 1'))
  end)

  it('leaves every other byte exactly as it was', function()
    -- The whole point of a lossless parse: no requoting, no recasing, no
    -- reformatting of what was already there. Odd spacing and a doubled quote
    -- both come back untouched.
    local given = "select   A,  b   where  c = 'It''s'"
    local completed = complete(given)

    local expected = "select   A,  b from this   where  c = 'It''s'"
    assert.equals(expected, completed)
    -- The invariant behind that: taking the addition back out gives the input.
    assert.equals(given, (completed:gsub(' from this', '', 1)))
  end)

  it('drops comments, which are the one thing it will not keep', function()
    -- Nothing can be appended to a statement ending in a comment without
    -- landing inside it, and duckdb has no use for one either.
    assert.equals('select a from this', complete('select a -- a note'))
    assert.equals('select * from this where x = 1', complete('where x = 1 -- t'))
    assert.equals('select * from this', complete('-- only a comment'))
  end)

  it('leaves a comment marker inside a string alone', function()
    assert.equals(
      "select * from this where note = '-- not a comment'",
      complete("where note = '-- not a comment'")
    )
  end)

  it('reaches both branches of a union', function()
    assert.equals(
      'select a from this where b > 1 union select c from this',
      complete('select a where b > 1 union select c')
    )
  end)

  it('reaches nested selects, innermost offsets first', function()
    assert.equals(
      'select (select max(a) from this) as m from this',
      complete('select (select max(a)) as m')
    )
    assert.equals(
      'select a from this where b in (select c from this where d > 1)',
      complete('select a where b in (select c where d > 1)')
    )
  end)

  it('reaches inside a cte and a mutation', function()
    assert.equals(
      'with x as (select a from this) select * from x',
      complete('with x as (select a) select * from x')
    )
    assert.equals(
      'update this set amt = (select max(amt) from this) where a = 1',
      complete('update this set amt = (select max(amt)) where a = 1')
    )
  end)

  it('leaves a source that is already named alone', function()
    local given = "select * from read_csv('x.csv') where a > 1"
    assert.equals(given, complete(given))
  end)
end)

describe('supplying the select', function()
  it('puts a star in front of a bare clause', function()
    assert.equals('select * from this where amt > 100', complete('where amt > 100'))
    assert.equals('select * from this limit 5', complete('limit 5'))
  end)

  it('puts a bare select in front of a column list', function()
    assert.equals('select a, b from this', complete('a, b'))
    assert.equals(
      'select amt * 2 as doubled from this',
      complete('amt * 2 as doubled')
    )
  end)

  it('rejects the prefix that parses but selects nothing', function()
    -- `select where amt > 100` is valid grammar with an empty projection, and
    -- duckdb rejects the `select from this ...` it would turn into. The star
    -- form has to win, and only checking the projection gets us there.
    local completed = complete('where amt > 100')
    assert.is_nil(completed:match('select%s+from'))
  end)

  it('leaves a statement that already opens a query alone', function()
    -- `describe` reads as a column name to a dialect that does not know the
    -- word, so it must never be offered a prefix. The FROM inside it is still
    -- filled in.
    assert.equals('describe select a from this', complete('describe select a'))
  end)

  it('gives a bare describe or summarize the buffer to work on', function()
    -- Both take a table, and there is nothing in `describe` for a parser to
    -- find -- the same repair a bare mutation needs, for the same reason.
    assert.equals('describe this', complete('describe'))
    assert.equals('summarize this', complete('summarize'))
  end)

  it('leaves one that names its own subject alone', function()
    assert.equals('describe this', complete('describe this'))
    assert.equals('describe other', complete('describe other'))
    assert.equals('summarize other', complete('summarize other'))
    assert.equals('summarize select amt from this', complete('summarize select amt'))
  end)

  it('leaves a mutation unprefixed', function()
    assert.equals(
      'update this set amt = (select max(amt) from this) where a = 1',
      complete('update this set amt = (select max(amt)) where a = 1')
    )
  end)
end)

describe('naming what a mutation writes to', function()
  it('names the target a bare mutation left out', function()
    assert.equals('update this set amt = 0', complete('update set amt = 0'))
    assert.equals('delete from this where a < 5', complete('delete where a < 5'))
    assert.equals(
      "insert into this values ('x', 1)",
      complete("insert values ('x', 1)")
    )
  end)

  it('leaves a target that is already named alone', function()
    local given = 'delete from this where a = 1'
    assert.equals(given, complete(given))
  end)
end)

describe('turning down what it cannot read', function()
  it('declines rather than guessing', function()
    -- sqruff's duckdb dialect stops short of these. With nothing behind it,
    -- saying so is the whole answer.
    for _, args in ipairs({
      'a, count(*) group by a',
      'select * qualify rn = 1',
      'select * from this tablesample 100 percent',
      'from this select a',
    }) do
      local completed, why = sqruff.complete(args)
      assert.is_nil(completed, args)
      assert.is_truthy(why, args)
    end
  end)

  it('says which it was: no binary, or no reading it', function()
    local _, why = sqruff.complete('from this select a')
    assert.is_nil(why:match('make build'))

    local saved = vim.g.duckquery_parse_binary
    sqruff.reset()
    vim.g.duckquery_parse_binary = '/nonexistent/duckquery-parse'

    local _, missing = sqruff.complete('select a')
    assert.is_truthy(missing:match('make build'))

    vim.g.duckquery_parse_binary = saved
    sqruff.reset()
  end)

  it('does not read keywords out of a string', function()
    assert.equals(
      "select * from this where note = 'group by x'",
      complete("where note = 'group by x'")
    )
  end)
end)

describe('falling back', function()

  it('can be turned off outright', function()
    local saved = vim.g.duckquery_parse_binary
    sqruff.reset()
    vim.g.duckquery_parse_binary = false

    assert.is_nil(sqruff.complete('select a'))
    assert.is_false(sqruff.available())

    vim.g.duckquery_parse_binary = saved
    sqruff.reset()
  end)

  it('reports itself missing when the binary is not there', function()
    local saved = vim.g.duckquery_parse_binary
    sqruff.reset()
    vim.g.duckquery_parse_binary = '/nonexistent/duckquery-parse'

    assert.is_nil(sqruff.complete('select a'))
    assert.is_false(sqruff.available())

    vim.g.duckquery_parse_binary = saved
    sqruff.reset()
  end)
end)
