# duckument.nvim

Run [DuckDB](https://duckdb.org) over the buffer you are looking at.

Your buffer is the table. Write the interesting half of a statement and the rest
is filled in — the `SELECT`, the `FROM`, the table an `UPDATE` writes to — then
the result comes back in the format it went out as, replacing the buffer's
contents.

```vim
:DuckU where region = 'APAC'
:DuckU date, sum(amt) as total group by date order by date
:DuckU update set region = 'EMEA' where region = 'EU'
:DuckU delete where amt is null
:DuckU describe
```

Saved or not: an unsaved or modified buffer is handed to duckdb as it appears on
screen, not as it sits on disk. Every result lands back in the buffer, so `u`
undoes it and the file is untouched until you `:w`.

## Requirements

Neovim 0.11+ and the `duckdb` CLI on your `$PATH`.

The statement completion lives in `ducktape`, a small Rust binary. The plugin
builds it with cargo when `vim.pack` installs or updates it, so you also need a
Rust toolchain. See [getting the binary](#getting-the-binary).

## Install

```lua
vim.pack.add({ 'https://github.com/DanWlker/duckument.nvim' })
```

There is no `setup()` to call, and nothing that has to be configured.

## Commands

| Command                     | What it does                                                               |
| --------------------------- | -------------------------------------------------------------------------- |
| `:DuckU {statement}`        | Runs the statement and replaces the buffer with the result. `u` undoes it. |
| `:DuckUPreview {statement}` | Renders the result in a scratch window and leaves every buffer alone.      |
| `!` on either               | Runs the statement exactly as typed, with nothing filled in.               |

`:DuckU` with no argument reads the whole buffer back through duckdb. `DESCRIBE`
and `SUMMARIZE` render like `:DuckUPreview`, since writing a description of your
data over the data would be a poor trade.

### Formats

| Recognised by  |                                                      |
| -------------- | ---------------------------------------------------- |
| extension      | `.csv`, `.tsv`, `.tab`, `.json`, `.jsonl`, `.ndjson` |
| filetype       | `csv`, `tsv`, `json`, `jsonl`, `ndjson`              |
| nothing at all | a nameless scratch buffer is taken for csv           |

Extension wins, being the more specific of the two — a `.tsv` opened as `csv` is
still tab-separated. Anything else is turned down rather than guessed at.

## What gets filled in

The buffer answers to `this`. Anything you spell out yourself is left as you
wrote it — naming your own `FROM` opts straight out of all of this.

| You write                            | duckdb runs                                         |
| ------------------------------------ | --------------------------------------------------- |
| _(nothing)_                          | `select * from this`                                |
| `where amt > 100`                    | `select * from this where amt > 100`                |
| `a, b`                               | `select a, b from this`                             |
| `date, count(*) group by date`       | `select date, count(*) from this group by date`     |
| `update set amt = 0`                 | `update this set amt = 0`                           |
| `update set amt = (select max(amt))` | `update this set amt = (select max(amt) from this)` |
| `delete where amt is null`           | `delete from this where amt is null`                |
| `insert values ('a', 1)`             | `insert into this values ('a', 1)`                  |
| `describe`                           | `describe this`                                     |
| `summarize`                          | `summarize this`                                    |

Every `SELECT` is completed, however deeply nested, so the buffer can be joined
to itself:

```vim
:DuckU select * inner join (select * where date = '2025-10-20') dt
      on this.description = dt.description
      where this.date = '2025-10-15'
```

```sql
select * from this inner join (select * from this where date = '2025-10-20') dt
  on this.description = dt.description where this.date = '2025-10-15'
```

## What it will not do

A statement sqruff cannot read in full is turned down, not guessed at. Its
duckdb dialect stops short of a few things:

| not read                                    | write it as          |
| ------------------------------------------- | -------------------- |
| `select * qualify rn = 1`                   | `:DuckU!`            |
| `select * from this tablesample 10 percent` | `:DuckU!`            |
| `from this select a`                        | `select a from this` |

None of these is a limit of duckdb — only of the parser filling your statement
in — so `!` runs them, the completion being the only thing in the way:

```vim
:DuckU  where amt > 100                      " completed for you
:DuckU! select * from this where amt > 100   " run as typed
```

With `!` the buffer is still `this`, and the statement is otherwise yours to
write in full. Nothing reads it but duckdb, so duckdb is what reports on it.

Clauses also have to be in the order SQL wants them. Nothing here rewrites a
statement that is merely out of order — a join written before the clause it
should follow is reported by duckdb rather than rearranged, which is the better
error of the two.

## How the statement gets completed

All of it happens in `ducktape`, a small Rust binary over
[sqruff](https://github.com/quarylabs/sqruff). Neovim hands it the string you
typed and takes back a statement; nothing on the lua side reads your SQL.

What the plugin then does with the result — replace the buffer, write through a
temp table, or render into a scratch window — turns on the statement's first
word, which the binary has already settled by supplying any missing `SELECT` and
naming any mutation's target. So that stays a keyword lookup in lua rather than
another reading of your SQL.

**From the parse, and only from the parse.** sqruff reads the statement and its
tree says where the FROM clauses belong. Because it parses leniently and keeps
every byte it read, the answer is an _offset_ — the FROM is spliced in and
nothing else is touched:

```
select   A,  b   where  c = 'It''s'
select   A,  b from this   where  c = 'It''s'
```

No reformatting, no requoting, and no chance of a half-known dialect quietly
rewriting a construct it did not understand.

Comments are the one exception, and they are dropped before any of this starts.
Nothing can be appended to a statement ending in `-- note` without landing
inside the note, and duckdb has no use for one anyway. A `--` inside a string
literal is left alone — the lexer hands those back whole.

**A missing `SELECT`** is supplied by trying nothing, then `select `, then
`select * `, and keeping the first whose tree is _usable_. Usable means more
than "it parsed": `select where amt > 100` parses quite happily, an empty
projection being valid grammar, and would become `select from this where amt >
100`, which duckdb rejects. Each candidate's SELECT has to actually select
something.

**Where no candidate reads in full**, the tree still says where the trouble
starts. A `GROUP BY` or `HAVING` cannot end a select list the way `WHERE` and
`ORDER BY` do, so without a FROM the list runs on and swallows them — and the
parse marks that spot as unreadable. Putting the FROM there and parsing again
finishes the statement:

```
a, count(*) group by a   →   select a, count(*) from this group by a
```

**A statement that never named the relation it acts on** is mended the same way,
off the same parse. `update set x = 1` comes back as one unreadable node rather
than `set` being mistaken for a table, and which relation is missing — and where
it goes — follows from the keyword the node opens with. The keyword has to open
the statement, not merely appear first inside a bracket, or `(delete where y >
1)` — a subquery written without its SELECT — would be read as a DELETE.

Every mend is located by the parse and none is trusted until the mended
statement has been read again, so a splice that fixes nothing is thrown away
rather than emitted.

## Getting the binary

The binary is **required**, because it holds the statement completion. The
plugin builds it with cargo, so you need a Rust toolchain.

**vim.pack builds it for you.** When `vim.pack` installs or updates this plugin,
the plugin runs `cargo build --release` in the background. A message tells you
when the build is done. You do not need a `PackChanged` hook of your own.

**First use builds it too.** If a command cannot find the binary, the plugin
starts the same build and tells you when it is ready. Run the command again
after that. This covers plugin managers other than `vim.pack`.

**Or build it yourself:**

```sh
make build       # cd src && cargo build --release --target-dir ../out
```

All of these put the binary in `out/release/ducktape`.

To use a different binary, set this knob:

|                                |                                                                         |
| ------------------------------ | ----------------------------------------------------------------------- |
| `vim.g.duckument_parse_binary` | Path to a `ducktape` of your own. `false` disables the lookup entirely. |

When you set this knob, the plugin does not build a binary on first use.

Without a binary, `:DuckU!` still works: it never needed one.

## One thing worth knowing

**Row order after an `UPDATE` is duckdb's to decide.** In practice rows stay
exactly where they were, on hundreds of thousands of rows too, but nothing in
duckdb guarantees it. Add an explicit `ORDER BY` if you depend on it.

## Tests

```sh
make test     # or ./tests/run_tests.sh
```

Runs on [plenary.nvim](https://github.com/nvim-lua/plenary.nvim), which has to
be installed already — the suite will not fetch it for you.
`tests/ducktape_spec.lua` covers the statement completion,
`tests/duckument_spec.lua` runs the commands end to end,
and `tests/format_spec.lua` the buffer detection. The first two skip
themselves when the binary, or duckdb, is not there; none of them touches the
network.
