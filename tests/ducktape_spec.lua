-- The whole of the statement completion, which lives in the binary. Skips
-- itself unless it has been built (`make build`).

local ducktape = require('duckument.ducktape')

-- Every attempt to build a binary, so a spec can say that none was made. None
-- is actually run: a spec has no business starting cargo.
local builds = {}
require('duckument.build').run = function() table.insert(builds, true) end

ducktape.reset()
if not ducktape.complete('select 1 from t') then
  describe(
    'sqruff',
    function() pending('needs out/release/ducktape -- run `make build`') end
  )
  return
end

--- The completed statement, asserting the binary answered.
---@param args string
---@return string
local function complete(args)
  local completed = ducktape.complete(args)
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

  it(
    'leaves a comment marker inside a string alone',
    function()
      assert.equals(
        "select * from this where note = '-- not a comment'",
        complete("where note = '-- not a comment'")
      )
    end
  )

  it(
    'reaches both branches of a union',
    function()
      assert.equals(
        'select a from this where b > 1 union select c from this',
        complete('select a where b > 1 union select c')
      )
    end
  )

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

  it(
    'leaves a mutation unprefixed',
    function()
      assert.equals(
        'update this set amt = (select max(amt) from this) where a = 1',
        complete('update this set amt = (select max(amt)) where a = 1')
      )
    end
  )
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

describe('putting the from where the parse stopped', function()
  it('finishes a group by, which cannot end a select list itself', function()
    assert.equals(
      'select a, count(*) from this group by a',
      complete('a, count(*) group by a')
    )
    assert.equals('select a from this group by a', complete('select a group by a'))
  end)

  it(
    'finishes a having the same way',
    function()
      assert.equals(
        'select a from this having count(*) > 1',
        complete('select a having count(*) > 1')
      )
    end
  )

  it(
    'still reaches the selects nested inside one',
    function()
      assert.equals(
        'select a, (select max(b) from this) as m from this group by a',
        complete('a, (select max(b)) as m group by a')
      )
    end
  )

  it('supplies a select a subquery was written without', function()
    -- The bracket parses as far as it can and holds the rest as unreadable,
    -- which says where the SELECT should have been.
    assert.equals(
      'select * from this where a in (select b from this where c > 1)',
      complete('where a in (b where c > 1)')
    )
  end)

  it('mends every source-less select in one pass', function()
    -- These are all visible in a single parse, unlike a site hidden inside an
    -- unreadable stretch, so the repair budget is not spent one per SELECT.
    assert.equals(
      'select a from this where b > 1 union select c from this',
      complete('select a where b > 1 union select c')
    )
    assert.equals(
      'select * from this where a in (select b from this where c in '
        .. '(select d from this))',
      complete('where a in (select b where c in (select d))')
    )
  end)

  it('mends one level at a time, as each parse reveals the next', function()
    -- Everything past an unreadable stretch is held as raw words, so the inner
    -- site does not exist in the tree until the outer one is mended.
    assert.equals(
      'select a, count(*) from this group by a '
        .. 'having a in (select b, count(*) from this group by b)',
      complete('a, count(*) group by a having a in (select b, count(*) group by b)')
    )
  end)

  it('refuses a splice that does not actually help', function()
    -- The repair is only taken if the result reads. Putting a FROM in front of
    -- something unreadable for another reason fixes nothing.
    assert.is_nil(ducktape.complete('select a, xyz!! group by a'))
    assert.is_nil(ducktape.complete('select from from from'))
  end)
end)

describe('turning down what it cannot read', function()
  it('declines rather than guessing', function()
    -- sqruff's duckdb dialect has no grammar for these at all, so there is
    -- nowhere for a FROM to help. Saying so is the whole answer.
    for _, args in ipairs({
      'select * qualify rn = 1',
      'select * from this qualify rn = 1',
      'select * from this tablesample 100 percent',
      'from this select a',
      'pivot this on description using sum(amt)',
    }) do
      local completed, why = ducktape.complete(args)
      assert.is_nil(completed, args)
      assert.is_truthy(why, args)
    end
  end)

  it('says which it was: no binary, or no reading it', function()
    local _, why = ducktape.complete('from this select a')
    assert.is_nil(why:match('make build'))

    local saved = vim.g.duckument_parse_binary
    ducktape.reset()
    vim.g.duckument_parse_binary = '/nonexistent/ducktape'

    local _, missing = ducktape.complete('select a')
    assert.is_truthy(missing:match('make build'))

    vim.g.duckument_parse_binary = saved
    ducktape.reset()
  end)

  it(
    'does not read keywords out of a string',
    function()
      assert.equals(
        "select * from this where note = 'group by x'",
        complete("where note = 'group by x'")
      )
    end
  )
end)

describe('falling back', function()
  it('can be turned off outright', function()
    local saved = vim.g.duckument_parse_binary
    ducktape.reset()
    vim.g.duckument_parse_binary = false

    assert.is_nil(ducktape.complete('select a'))
    assert.is_false(ducktape.available())
    -- And nothing was built to make up for it: turning the lookup off is a
    -- decision, not a gap to fill in.
    assert.is_nil(builds[1])

    vim.g.duckument_parse_binary = saved
    ducktape.reset()
  end)

  it('reports itself missing when the binary is not there', function()
    local saved = vim.g.duckument_parse_binary
    ducktape.reset()
    vim.g.duckument_parse_binary = '/nonexistent/ducktape'

    assert.is_nil(ducktape.complete('select a'))
    assert.is_false(ducktape.available())
    -- And nothing was built to make up for it: turning the lookup off is a
    -- decision, not a gap to fill in.
    assert.is_nil(builds[1])

    vim.g.duckument_parse_binary = saved
    ducktape.reset()
  end)
end)

describe('edges', function()
  it('declines text the lexer stops partway through', function()
    -- A non-ASCII letter in an unquoted identifier ends sqruff's lexer, and
    -- the rest is left out of the tree rather than marked unreadable. Without
    -- the check that the tree reaches the end, an offset taken from it would
    -- be spliced into text the parse never saw:
    --     select descripci from thisón, count(*) group by descripción
    local truncated = 'descripción, count(*) group by descripción'
    assert.is_nil(ducktape.complete(truncated))
    assert.is_nil(ducktape.complete('señor, count(*) group by señor'))
  end)

  it('keeps multibyte the lexer does read', function()
    assert.equals(
      "select * from this where note = 'café ☕'",
      complete("where note = 'café ☕'")
    )
    assert.equals(
      'select "descripción" from this where b > 1',
      complete('select "descripción" where b > 1')
    )
  end)

  it('reads nothing at all as the whole buffer', function()
    assert.equals('select * from this', complete(''))
    assert.equals('select * from this', complete('     '))
    assert.equals('select * from this', complete('-- nothing but a note'))
  end)

  it('leaves a statement that needs nothing exactly alone', function()
    for _, given in ipairs({
      'select * from this where a > 1',
      'select a, count(*) from this group by a',
      "select * from read_csv('x.csv')",
      'delete from this where a = 1',
    }) do
      assert.equals(given, complete(given), given)
    end
  end)

  it('completes across newlines without flattening them', function()
    assert.equals(
      'select a from this\nwhere b > 1',
      complete('select a\nwhere b > 1')
    )
    assert.equals(
      'select a, count(*)\nfrom this group by a',
      complete('a, count(*)\ngroup by a')
    )
  end)

  it('treats a quoted keyword as the identifier it is', function()
    assert.equals(
      'select "group", count(*) from this group by "group"',
      complete('"group", count(*) group by "group"')
    )
    assert.equals(
      'select "group" from this where "from" > 1',
      complete('select "group" where "from" > 1')
    )
  end)

  it('keeps a trailing semicolon where it was', function()
    assert.equals('select * from this where a > 1;', complete('where a > 1;'))
    assert.equals(
      'select a, count(*) from this group by a;',
      complete('a, count(*) group by a;')
    )
  end)

  it(
    'mends every level of a nest, one parse at a time',
    function()
      assert.equals(
        'select * from this where a in '
          .. '(select b from this where c in (select d from this where e > 1))',
        complete('where a in (b where c in (d where e > 1))')
      )
    end
  )

  it('does not mistake a keyword inside brackets for the opening one', function()
    -- The first word of `(select max(amt)) as peak, cat` sits inside a bracket:
    -- the statement opens a select *list*, not a query, and refusing it a
    -- SELECT in front leaves it unreadable.
    assert.equals(
      'select (select max(amt) from this) as peak, cat from this group by cat',
      complete('(select max(amt)) as peak, cat group by cat')
    )
    assert.equals(
      'select (select 1 from this) as x from this',
      complete('(select 1) as x')
    )
  end)

  it('names a relation only where the statement plainly has none', function()
    -- A statement that already says what it acts on is unreadable for some
    -- other reason, and wedging a second relation into it mends nothing.
    assert.is_nil(ducktape.complete('update t set x = 1 group by y'))
  end)

  it('leaves a statement this dialect cannot read to duckdb', function()
    -- Nothing is decided about a statement before it is parsed, so a keyword
    -- sqruff has no grammar for is offered a SELECT like anything else and
    -- read as a column name. The completion is not what was meant, but it is
    -- not silent either: duckdb answers `syntax error at or near "table"`,
    -- naming the word, which beats refusing it here without saying which.
    assert.equals('select table this from this', complete('table this'))
    assert.equals('select describe foo from this bar', complete('describe foo bar'))
  end)

  it(
    'completes a from-first statement it can read',
    function() assert.equals('select * from t', complete('from t')) end
  )

  it('does not take a relation keyword out of a bracket either', function()
    -- The head of a statement is its *first* word, not the first word found
    -- anywhere in it. A column named `delete` inside a subquery does not make
    -- the statement a DELETE.
    assert.equals(
      'select (select delete from this where y > 1) from this',
      complete('(delete where y > 1)')
    )
    assert.is_nil(ducktape.complete('(update set x = 1)'))
  end)

  it('leaves a bracket that reads perfectly well as an expression', function()
    -- `(d)` is a column in parentheses, not a subquery missing its SELECT.
    -- Nothing in it is unreadable, so there is nothing to mend and no guess
    -- to make.
    assert.equals(
      'select * from this where a in (select b from this where c in (d))',
      complete('where a in (b where c in (d))')
    )
    assert.equals(
      'select * from this where a in (1, 2, 3)',
      complete('where a in (1, 2, 3)')
    )
    assert.equals('select count(*) from this', complete('count(*)'))
  end)
end)
