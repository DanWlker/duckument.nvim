if vim.g.loaded_duckument == 1 then return end
vim.g.loaded_duckument = 1

vim.api.nvim_create_user_command(
  'DuckU',
  function(opts) require('duckument').query(opts.args) end,
  {
    nargs = '*',
    desc = 'Query this buffer with duckdb, replacing its contents',
  }
)

vim.api.nvim_create_user_command(
  'DuckUPreview',
  function(opts) require('duckument').preview(opts.args) end,
  {
    nargs = '*',
    desc = 'Query this buffer with duckdb, showing the result in a scratch window',
  }
)
