-- What the shorthand you type expands into. No duckdb involved: these are the
-- string rewrites on their own, which is where the guessing happens.

local sql = require('duckquery.sql')

--- The statement half of expand(), for the many cases that ignore the kind.
---@param args string
---@return string
local function expand(args) return (sql.expand(args)) end

--- The kind half.
---@param args string
---@return DuckqueryKind
local function kind_of(args) return select(2, sql.expand(args)) end

describe('reads', function()
  it('reads the whole buffer when given nothing', function()
    assert.equals('select * from this', expand(''))
    assert.equals('select * from this', expand('   '))
  end)

  it('supplies the select in front of a bare clause', function()
    assert.equals('select * from this where a > 1', expand('where a > 1'))
    assert.equals('select * from this limit 5', expand('limit 5'))
  end)

  it('supplies the select in front of a bare column list', function()
    assert.equals('select a, b from this', expand('a, b'))
    assert.equals(
      'select a, sum(b) as t from this group by a',
      expand('a, sum(b) as t group by a')
    )
  end)

  it('splices the from ahead of the first clause', function()
    assert.equals(
      "select name from this where region = 'EU' order by name",
      expand("select name where region = 'EU' order by name")
    )
  end)

  it('leaves a statement that names its own source alone', function()
    local given = "select * from read_csv('other.csv') where a > 1"
    assert.equals(given, expand(given))
  end)

  it('keeps clause keywords that are only part of an identifier', function()
    assert.equals(
      'select limit_col, ordered from this',
      expand('limit_col, ordered')
    )
  end)

  it('ignores keywords inside string literals', function()
    assert.equals(
      "select * from this where note = 'order by where'",
      expand("where note = 'order by where'")
    )
  end)

  it('ignores keywords inside comments', function()
    assert.equals(
      "select a from this where b = '-- not a comment'",
      expand("select a where b = '-- not a comment'")
    )
  end)

  it('keeps a trailing comment from swallowing the from', function()
    assert.equals('select a -- a note\nfrom this', expand('select a -- a note'))
    assert.equals(
      'select a -- a note\nfrom this where true',
      expand('select a -- a note\nwhere true')
    )
  end)
end)

describe('subqueries', function()
  it('completes a nested select', function()
    assert.equals(
      'select * from this where a in (select a from this where b > 1)',
      expand('where a in (select a where b > 1)')
    )
  end)

  it('leaves a nested select that names its own source alone', function()
    assert.equals(
      'select a, (select max(b) from this) as m from this',
      expand('a, (select max(b) from this) as m')
    )
  end)

  it('leaves groups that are not subqueries alone', function()
    assert.equals(
      'select date, count(*) as n from this group by date',
      expand('date, count(*) as n group by date')
    )
    assert.equals(
      "select * from this where d in ('rent', 'gas')",
      expand("where d in ('rent', 'gas')")
    )
  end)
end)

describe('joins', function()
  it('splices the from ahead of the join, not the where', function()
    assert.equals(
      'select * from this join other o on o.a = this.a where this.b > 1',
      expand('select * join other o on o.a = this.a where this.b > 1')
    )
  end)

  it('starts the join clause at its qualifiers', function()
    assert.equals(
      'select * from this left outer join other o on o.a = this.a',
      expand('select * left outer join other o on o.a = this.a')
    )
  end)

  it('does not mistake a function named like a qualifier for one', function()
    assert.equals(
      'select left(d, 2) as l from this where amt > 30',
      expand('left(d, 2) as l where amt > 30')
    )
  end)

  it('folds a clause written before the join into the left hand side', function()
    assert.equals(
      "select * from (select * from this where date = '1') this "
        .. "inner join (select * from this where date = '2') dt "
        .. 'on this.d = dt.d',
      expand(
        "select * where date = '1' "
          .. "inner join (select * where date = '2') dt "
          .. 'on this.d = dt.d'
      )
    )
  end)
end)

describe('writes', function()
  it('names this as the target of an update', function()
    assert.equals(
      "update this set region = 'EMEA' where region = 'EU'",
      expand("update set region = 'EMEA' where region = 'EU'")
    )
  end)

  it('names this as the target of a delete', function()
    assert.equals('delete from this where a > 1', expand('delete where a > 1'))
  end)

  it('names this as the target of an insert', function()
    assert.equals(
      "insert into this values ('a', 1)",
      expand("insert values ('a', 1)")
    )
  end)

  it('leaves a mutation that names its own target alone', function()
    assert.equals('update this set a = 1', expand('update this set a = 1'))
    assert.equals('delete from this', expand('delete from this'))
    assert.equals('insert into this select 1', expand('insert into this select 1'))
  end)

  it('completes a subquery inside a mutation', function()
    assert.equals(
      'update this set a = (select max(a) from this where b = 1)',
      expand('update set a = (select max(a) where b = 1)')
    )
  end)
end)

describe('kinds', function()
  it('classifies what the statement does with the buffer', function()
    assert.equals('read', kind_of('where a > 1'))
    assert.equals('read', kind_of('select * from other'))
    assert.equals('write', kind_of('update set a = 1'))
    assert.equals('write', kind_of('delete where a'))
    assert.equals('write', kind_of('insert values (1)'))
    assert.equals('inspect', kind_of('describe'))
  end)

  it('still completes a describe', function()
    assert.equals('describe from this', expand('describe'))
    assert.equals(
      'describe select a from this where b > 1',
      expand('describe select a where b > 1')
    )
  end)
end)

describe('quoting', function()
  it('doubles the quotes in a path', function()
    assert.equals("'/tmp/plain.csv'", sql.quote('/tmp/plain.csv'))
    assert.equals("'/tmp/it''s.csv'", sql.quote("/tmp/it's.csv"))
  end)
end)
