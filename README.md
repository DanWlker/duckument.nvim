# duckument.nvim

## NOTE: Yes this is vibe coded. Yes I will clean this up. Yes I am in the process of cleaning it up. Yes I'm using this myself. Yes I do review the code, am in the process of reviewing all the code. The rust binary will be in "releases" once I have reviewed everything. In the meantime, `make build` should help.

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

Works on csv, tsv, json and ndjson, saved or not: an unsaved or modified buffer
is handed to duckdb as it appears on screen, not as it sits on disk. Every
result lands back in the buffer, so `u` undoes it and the file is untouched
until you `:w`.

## Requirements

Neovim 0.11+ and the `duckdb` CLI on your `$PATH`.

The statement completion lives in `ducktape`, a small Rust binary. Installing a
tagged version fetches the build for your platform the first time you run a
command; installing from `main` means building it yourself, which wants a Rust
toolchain and one `make build`. See [getting the binary](#getting-the-binary).

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

`:DuckU` with no argument reads the whole buffer back through duckdb. `DESCRIBE`
and `SUMMARIZE` render like `:DuckUPreview`, since writing a description of your
data over the data would be a poor trade.

## What gets filled in

The buffer answers to `this`. Anything you spell out yourself is left as you
wrote it — naming your own `FROM` opts straight out of all of this.

| You write                      | duckdb runs                                     |
| ------------------------------ | ----------------------------------------------- |
| _(nothing)_                    | `select * from this`                            |
| `where amt > 100`              | `select * from this where amt > 100`            |
| `date, count(*) group by date` | `select date, count(*) from this group by date` |
| `update set amt = 0`           | `update this set amt = 0`                       |
| `delete where amt is null`     | `delete from this where amt is null`            |
| `insert values ('a', 1)`       | `insert into this values ('a', 1)`              |
| `describe`                     | `describe from this`                            |

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
`select * `, and keep the first whose tree is _usable_. Usable means more than
"it parsed" — `select where amt > 100` parses quite happily, an empty projection
being valid grammar, and would become `select from this where amt > 100`, which
duckdb rejects. Each candidate's SELECT has to actually select something.

A statement that never named the relation it acts on is mended the same way,
off the same parse. `update set x = 1` comes back as one unreadable node rather
than `set` being mistaken for a table, and which relation is missing — and where
it goes — follows from the keyword the node opens with: naming the table a
mutation writes to (`update set x = 1` → `update this set x = 1`), and giving a
bare `describe` or `summarize` the buffer to work on (`describe` → `describe
this`). The keyword has to open the statement, not merely appear first inside a
bracket, or `(delete where y > 1)` — a subquery written without its SELECT —
would be read as a DELETE.

Every `SELECT` is completed this way, however deeply nested, so the buffer can be
joined to itself:

```vim
:DuckU select * inner join (select * where date = '2025-10-20') dt
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

### What it will not do

A statement sqruff cannot read in full is turned down, not guessed at. Its
duckdb dialect stops short of a few things, and those are errors now:

| not read                                    | write it as          |
| ------------------------------------------- | -------------------- |
| `select * qualify rn = 1`                   | —                    |
| `select * from this tablesample 10 percent` | —                    |
| `from this select a`                        | `select a from this` |

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

## Getting the binary

The binary is **required** — it is where the completion lives — and there are
two ways to have one.

**A tagged install fetches it.** Every release publishes a `ducktape` build per
platform. When your checkout sits exactly on one of those tags, the first
command that needs the binary and cannot find it fetches that release's build in
the background and says so when it lands; run the command again and it works.
Nothing blocks on the download, and nothing is fetched again afterwards.

Builds are published for:

|         | x86_64             | aarch64            |
| ------- | ------------------ | ------------------ |
| macOS   | ✓                  | ✓                  |
| Linux   | ✓ (glibc and musl) | ✓ (glibc and musl) |
| Windows | ✓                  | ✓                  |

**Anything else builds it.** A checkout on `main`, or on a platform with no
published build, has no release to match and is told to build instead:

```sh
make build       # cd src && cargo build --release
```

With `vim.pack`, on install and update:

```lua
vim.api.nvim_create_autocmd('PackChanged', {
  callback = function(ev)
    if ev.data.spec.name == 'duckument.nvim' and ev.data.kind ~= 'delete' then
      local crate = ev.data.path .. '/src'
      vim.system({ 'cargo', 'build', '--release' }, { cwd = crate }):wait()
    end
  end,
})
```

Both end up in the same place, `src/target/release/ducktape`, and a binary you
built is never replaced by a downloaded one: no version stamp beside it means
cargo put it there, and that build is the one you meant to run.

If none of this suits, these are the knobs:

|                                |                                                                         |
| ------------------------------ | ----------------------------------------------------------------------- |
| `vim.g.duckument_parse_binary` | Path to a `ducktape` of your own. `false` disables the lookup entirely. |
| `vim.g.duckument_download`     | `false` to never fetch, and only ever build.                            |
| `vim.g.duckument_version`      | Fetch this release rather than the tag you are on.                      |
| `vim.g.duckument_triple`       | Fetch this target triple rather than the detected one.                  |
| `vim.g.duckument_repo`         | Fetch from this `owner/repo` — for a fork.                              |

## One thing worth knowing

**Row order after an `UPDATE` is duckdb's to decide.** In practice rows stay
exactly where they were, on hundreds of thousands of rows too, but nothing in
duckdb guarantees it. Add an explicit `ORDER BY` if you depend on it.

## Tests

```sh
make test     # or ./tests/run_tests.sh
```

Runs on [plenary.nvim](https://github.com/nvim-lua/plenary.nvim), cloned into
your neovim data directory if it is not already installed.
`tests/ducktape_spec.lua` covers the statement completion,
`tests/duckument_spec.lua` runs the commands end to end,
`tests/format_spec.lua` the buffer detection, and `tests/download_spec.lua`
holds the published triples and the release workflow to each other. The first
two skip themselves when the binary, or duckdb, is not there; none of them
touches the network.
