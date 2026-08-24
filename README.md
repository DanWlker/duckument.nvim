# nvim-duckquery

Run [DuckDB](https://duckdb.org) over the buffer you are looking at.

Your buffer is the table. Write the interesting half of a statement and the rest
is filled in — the `SELECT`, the `FROM`, the table an `UPDATE` writes to — then
the result comes back in the format it went out as, replacing the buffer's
contents.

```vim
:Duck where region = 'APAC'
:Duck date, sum(amt) as total group by date order by date
:Duck update set region = 'EMEA' where region = 'EU'
:Duck delete where amt is null
:Duck describe
```

Works on csv, tsv, json, ndjson and parquet, saved or not: an unsaved or
modified text buffer is handed to duckdb as it appears on screen, not as it sits
on disk.

## Requirements

Neovim 0.11+, the `duckdb` CLI on your `$PATH`, and a Rust toolchain to build
the `duckquery-parse` binary that does the statement completion — `make build`,
once. See [how the statement gets completed](#how-the-statement-gets-completed).

## Install

```lua
vim.pack.add({ 'https://github.com/DanWlker/nvim-duckquery' })
```

There is nothing to call — no `setup()`, no configuration.

## Commands

| Command | What it does |
| --- | --- |
| `:Duck {statement}` | Runs the statement and replaces the buffer with the result. `u` undoes it. |
| `:Duck! {statement}` | The same, without the confirmation a parquet file needs before being rewritten. |
| `:DuckPreview {statement}` | Renders the result in a scratch window and leaves every buffer alone. |

`:Duck` with no argument reads the whole buffer back through duckdb. `DESCRIBE`
and `SUMMARIZE` render like `:DuckPreview`, since writing a description of your
data over the data would be a poor trade.

## What gets filled in

The buffer answers to `this`. Anything you spell out yourself is left as you
wrote it — naming your own `FROM` opts straight out of all of this.

| You write | duckdb runs |
| --- | --- |
| *(nothing)* | `select * from this` |
| `where amt > 100` | `select * from this where amt > 100` |
| `date, count(*) group by date` | `select date, count(*) from this group by date` |
| `update set amt = 0` | `update this set amt = 0` |
| `delete where amt is null` | `delete from this where amt is null` |
| `insert values ('a', 1)` | `insert into this values ('a', 1)` |
| `describe` | `describe from this` |

## How the statement gets completed

All of it happens in `duckquery-parse`, a small Rust binary over
[sqruff](https://github.com/quarylabs/sqruff). Neovim hands it the string you
typed and takes back a statement; nothing on the lua side reads your SQL.

What the plugin then does with the result — replace the buffer, write through a
temp table, or render into a scratch window — turns on the statement's first
word, which the binary has already settled by supplying any missing `SELECT` and
naming any mutation's target. So that stays a keyword lookup in lua rather than
another reading of your SQL.

**From the parse, and only from the parse.** sqruff reads the statement and its
tree says where the FROM clauses belong. Because it parses leniently and keeps
every byte it read, the answer is an *offset* — the FROM is spliced in and
nothing else is touched:

```
select   A,  b   where  c = 'It''s'   -- note
select   A,  b from this   where  c = 'It''s'   -- note
```

No reformatting, no requoting, and no chance of a half-known dialect quietly
rewriting a construct it did not understand.

Comments are the one exception: they are dropped before any of this starts.
Nothing can be appended to a statement ending in `-- note` without landing
inside the note, and duckdb has no use for one anyway. A `--` inside a string
literal is left alone — the lexer hands those back whole.

When no candidate reads in full, the tree still says where the trouble starts.
A `GROUP BY` or `HAVING` cannot end a select list the way `WHERE` and `ORDER BY`
can, so without a FROM the list runs on and swallows them — and the parse marks
that spot as unreadable. Putting the FROM there and parsing again finishes the
statement:

```
a, count(*) group by a   →   select a, count(*) from this group by a
```

The result has to read afterwards, so a splice that fixes nothing is thrown
away rather than emitted.

A missing `SELECT` is supplied the same way: try nothing, then `select `, then
`select * `, and keep the first whose tree is *usable*. Usable means more than
"it parsed" — `select where amt > 100` parses quite happily, an empty projection
being valid grammar, and would become `select from this where amt > 100`, which
duckdb rejects. Each candidate's SELECT has to actually select something.

Two repairs happen before any of that, because there is nothing in the text for
a parser to find: naming the table a mutation writes to (`update set x = 1`),
and giving a bare `describe` or `summarize` the buffer to work on (`describe` →
`describe this`). Both are then checked by parsing the result like anything
else.

### What it will not do

A statement sqruff cannot read in full is turned down, not guessed at. Its
duckdb dialect stops short of a few things, and those are errors now:

| not read | write it as |
| --- | --- |
| `select * qualify rn = 1` | — |
| `select * from this tablesample 10 percent` | — |
| `from this select a` | `select a from this` |

Clauses also have to be in the order SQL wants them; a join written before the
clause it should follow is reported by duckdb rather than rearranged.

```
where amt > 100                    →  select * from this where amt > 100
a, b                               →  select a, b from this
update set amt = (select max(amt)) →  update this set amt = (select … from this)
describe                           →  describe this
summarize                          →  summarize this
a, count(*) group by a             →  declined
```

### Building it

```sh
make build       # cd src && cargo build --release
```

The binary is **required** — it is where the completion lives. The plugin looks
for `src/target/release/duckquery-parse` and then `bin/duckquery-parse` on its
runtimepath; point `vim.g.duckquery_parse_binary` at one somewhere else.

With `vim.pack`, building on install and update:

```lua
vim.api.nvim_create_autocmd('PackChanged', {
  callback = function(ev)
    if ev.data.spec.name == 'nvim-duckquery' and ev.data.kind ~= 'delete' then
      local crate = ev.data.path .. '/src'
      vim.system({ 'cargo', 'build', '--release' }, { cwd = crate }):wait()
    end
  end,
})
```

Every `SELECT` is completed this way, however deeply nested, so the buffer can be
joined to itself:

```vim
:Duck select * inner join (select * where date = '2025-10-20') dt
      on this.description = dt.description
      where this.date = '2025-10-15'
```

```sql
select * from this inner join (select * from this where date = '2025-10-20') dt
  on this.description = dt.description where this.date = '2025-10-15'
```

Clauses have to be in the order SQL wants them. Nothing here rewrites a
statement that is merely out of order — duckdb reports that better than a guess
would.

## Two things worth knowing

**Parquet is rewritten in place.** A parquet result cannot live in the buffer as
text, so it goes straight to the file on disk and the buffer reloads — there is
no undo. `:Duck` asks first; `:Duck!` does not. Every text format lands in the
buffer instead, unsaved until you `:w`, and undoes normally.

**Row order after an `UPDATE` is duckdb's to decide.** In practice rows stay
exactly where they were, on hundreds of thousands of rows too, but nothing in
duckdb guarantees it. Add an explicit `ORDER BY` if you depend on it.

## Tests

```sh
make test     # or ./tests/run_tests.sh
```

Runs on [plenary.nvim](https://github.com/nvim-lua/plenary.nvim), cloned into
your neovim data directory if it is not already installed.
`tests/sqruff_spec.lua` covers the statement completion,
`tests/duckquery_spec.lua` runs the commands end to end, and
`tests/format_spec.lua` the buffer detection. The first two skip themselves when
the binary, or duckdb, is not there.
