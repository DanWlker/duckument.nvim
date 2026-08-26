if vim.g.loaded_duckument == 1 then return end
vim.g.loaded_duckument = 1

-- `!` on either command hands the statement to duckdb exactly as typed, with
-- nothing filled in: the buffer is still `this`, but the whole statement is
-- yours to write.
vim.api.nvim_create_user_command(
  'DuckU',
  function(opts) require('duckument').query(opts.args, opts.bang) end,
  {
    nargs = '*',
    bang = true,
    desc = 'Query this buffer with duckdb, replacing its contents (! runs the statement as typed)',
  }
)

vim.api.nvim_create_user_command(
  'DuckUPreview',
  function(opts) require('duckument').preview(opts.args, opts.bang) end,
  {
    nargs = '*',
    bang = true,
    desc = 'Query this buffer with duckdb into a scratch window (! runs the statement as typed)',
  }
)
