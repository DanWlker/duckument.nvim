--- Turning what you typed into a statement duckdb will accept.
---
--- The buffer answers to `this`, and everything that goes with it is filled in:
--- the SELECT, the FROM of every query however deeply nested, and the table an
--- UPDATE / DELETE / INSERT writes to. Anything you spell out yourself is left
--- alone -- naming your own FROM opts straight out of all of this.

local M = {}

--- What a statement does with `this`: reads it, writes to it, or reports on it.
---@alias DuckqueryKind 'read'|'write'|'inspect'

---@param s string
---@return string quoted SQL string literal
function M.quote(s) return "'" .. s:gsub("'", "''") .. "'" end

--- Splits `q` into the bare words and the parenthesised groups sitting at paren
--- depth 0, skipping string literals, quoted identifiers and comments. Only
--- depth-0 words can be clause keywords of the statement itself; anything
--- deeper belongs to one of the groups, which are completed on their own.
---@param q string
---@return { word: string, at: integer }[] words
---@return { open: integer, close: integer }[] groups
---@return boolean open_comment whether `q` ends inside a -- comment
local function scan(q)
  local words, groups = {}, {}
  local depth, opened, i, n = 0, nil, 1, #q
  local open_comment = false

  while i <= n do
    local c = q:sub(i, i)

    if c == "'" or c == '"' then
      i = i + 1
      while i <= n do
        if q:sub(i, i) ~= c then
          i = i + 1
        elseif q:sub(i + 1, i + 1) == c then -- a doubled quote escapes itself
          i = i + 2
        else
          i = i + 1
          break
        end
      end
    elseif q:sub(i, i + 1) == '--' then
      local eol = q:find('\n', i, true)
      open_comment = eol == nil
      i = (eol or n) + 1
    elseif q:sub(i, i + 1) == '/*' then
      i = (select(2, q:find('*/', i + 2, true)) or n) + 1
    elseif c == '(' then
      if depth == 0 then opened = i end
      depth, i = depth + 1, i + 1
    elseif c == ')' then
      depth = depth - 1
      if depth == 0 and opened then
        groups[#groups + 1] = { open = opened, close = i }
        opened = nil
      end
      i = i + 1
    else
      local s, e, word = q:find('^([%a_][%w_]*)', i)
      if word then
        if depth == 0 then words[#words + 1] = { word = word:lower(), at = s } end
        i = e + 1
      else
        i = i + 1
      end
    end
  end

  return words, groups, open_comment
end

-- Keywords that may open a query on their own; anything else means you started
-- with a bare select list (or a bare clause, hence `select *`).
local opening = {
  select = true,
  with = true,
  from = true,
  describe = true,
  summarize = true,
  pivot = true,
  unpivot = true,
  table = true,
  values = true,
}

-- Clauses that must follow FROM, i.e. the point to splice the missing one in.
local clause = {
  where = true,
  group = true,
  having = true,
  qualify = true,
  window = true,
  order = true,
  limit = true,
  offset = true,
  using = true, -- USING SAMPLE
}

-- Words that may sit in front of JOIN. A join clause starts at the first of
-- them, which is where the FROM in front of it belongs.
local join_prefix = {
  inner = true,
  outer = true,
  left = true,
  right = true,
  full = true,
  cross = true,
  natural = true,
  semi = true,
  anti = true,
  asof = true,
  positional = true,
}

-- Statements that write rather than read. They need `this` to be a real table
-- to write into, and the buffer is rebuilt from that table afterwards.
local mutation = {
  update = true,
  delete = true,
  insert = true,
}

-- Statements that answer a question *about* the buffer rather than producing
-- rows to keep. Writing their answer back would destroy the data it describes,
-- so they are rendered rather than applied.
local inspection = {
  describe = true,
}

--- Names `this` as the target of a mutation that left its table out:
--- `update set x = 1`, `delete where x`, `insert values (...)`.
---@param q string
---@param words { word: string, at: integer }[]
---@return string
local function name_target(q, words)
  local head = words[1]
  local next_word = words[2] and words[2].word
  local target

  if head.word == 'update' and next_word == 'set' then
    target = ' this'
  elseif head.word == 'delete' and next_word ~= 'from' then
    target = ' from this'
  elseif head.word == 'insert' and next_word ~= 'into' then
    target = ' into this'
  else
    return q -- the statement already names what it writes to
  end

  local after_head = head.at + #head.word
  return q:sub(1, after_head - 1) .. target .. q:sub(after_head)
end

--- Where the join clause holding `words[i]` (a JOIN) starts: at the first
--- qualifier in front of it, so `left outer join` starts at `left`.
---@param words { word: string, at: integer }[]
---@param i integer
---@return integer
local function join_start(words, i)
  while i > 1 and join_prefix[words[i - 1].word] do
    i = i - 1
  end
  return words[i].at
end

local complete

--- Completes every parenthesised subquery in `q`, so the buffer can be left
--- unnamed at any depth rather than only in the outermost query. Groups that
--- are not subqueries -- `count(*)`, an IN list, a function's arguments -- are
--- left exactly as they are.
---@param q string
---@return string
local function complete_groups(q)
  local _, groups = scan(q)

  -- Back to front, so the offsets of the groups still ahead stay valid.
  for i = #groups, 1, -1 do
    local g = groups[i]
    local inner = q:sub(g.open + 1, g.close - 1)
    local words = scan(inner)
    if words[1] and words[1].word == 'select' then
      q = q:sub(1, g.open) .. complete(inner) .. q:sub(g.close)
    end
  end

  return q
end

--- Completes an abbreviated query into one duckdb will accept, adding the
--- SELECT and the `from this` you left out. A query that already says what it
--- reads from keeps its own FROM; only its subqueries are completed.
---@param q string
---@return string
function complete(q)
  q = complete_groups(q)

  local words, _, open_comment = scan(q)
  local first = words[1] and words[1].word or ''
  if not opening[first] then
    q = (clause[first] and 'select * ' or 'select ') .. q
    words, _, open_comment = scan(q)
  end

  local clause_at, join_at
  for i, w in ipairs(words) do
    if w.word == 'from' then return q end
    if w.word == 'join' and not join_at then join_at = join_start(words, i) end
    if clause[w.word] and not clause_at then clause_at = w.at end
  end

  -- A join written after the clauses it is supposed to follow is not valid SQL,
  -- but the intent is plain: everything up to the join is the left hand side of
  -- it. Fold that into a derived table, which goes on answering to `this`.
  if join_at and clause_at and clause_at < join_at then
    local left = q:sub(1, clause_at - 1)
      .. 'from this '
      .. q:sub(clause_at, join_at - 1)
    return ('select * from (%s) this %s'):format(vim.trim(left), q:sub(join_at))
  end

  local splice = math.min(clause_at or math.huge, join_at or math.huge)
  -- A trailing -- comment would swallow a FROM put on the same line as it.
  if splice == math.huge then
    return q .. (open_comment and '\n' or ' ') .. 'from this'
  end
  return q:sub(1, splice - 1) .. 'from this ' .. q:sub(splice)
end

--- Completes an abbreviated statement into one duckdb will accept.
---@param args string
---@return string statement
---@return DuckqueryKind kind
function M.expand(args)
  local q = vim.trim(args)
  if q == '' then q = '*' end

  local words = scan(q)
  local first = words[1] and words[1].word or ''

  if mutation[first] then
    return complete_groups(name_target(q, words)), 'write'
  end

  -- DESCRIBE has its FROM filled in like any other read; only what becomes of
  -- the result differs.
  return complete(q), inspection[first] and 'inspect' or 'read'
end

return M
