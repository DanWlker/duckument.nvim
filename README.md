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

Neovim 0.11+ and the `duckdb` CLI on your `$PATH`.

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

`:Duck` with no argument reads the whole buffer back through duckdb; a `DESCRIBE`
renders like `:DuckPreview`, since writing a description of your data over the
data would be a poor trade.

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

Every `SELECT` is completed this way, however deeply nested, so the buffer can be
joined to itself:

```vim
:Duck select * where date = '2025-10-15'
      inner join (select * where date = '2025-10-20') dt
      on this.description = dt.description
```

That is not valid SQL as typed — the join lands after the clause it should
precede — but the intent is plain, so the filtered left hand side is folded into
a derived table that goes on answering to `this`:

```sql
select * from (select * from this where date = '2025-10-15') this
  inner join (select * from this where date = '2025-10-20') dt
  on this.description = dt.description
```

Ordinary SQL ordering works too.

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
your neovim data directory if it is not already installed. `tests/sql_spec.lua`
covers the statement completion on its own — no duckdb needed — while
`tests/duckquery_spec.lua` runs the commands end to end against a real one, and
skips itself when duckdb is missing.
