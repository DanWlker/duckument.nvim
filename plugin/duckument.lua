if vim.g.loaded_duckument == 1 then return end
vim.g.loaded_duckument = 1

vim.api.nvim_create_user_command(
  'Duck',
  function(opts) require('duckument').query(opts.args, opts.bang) end,
  {
    nargs = '*',
    bang = true,
    desc = 'Query this buffer with duckdb, replacing its contents (! skips prompts)',
  }
)

vim.api.nvim_create_user_command(
  'DuckPreview',
  function(opts) require('duckument').preview(opts.args) end,
  {
    nargs = '*',
    desc = 'Query this buffer with duckdb, showing the result in a scratch window',
  }
)
