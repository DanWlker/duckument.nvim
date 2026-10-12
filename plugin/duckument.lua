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

-- Rebuild `ducktape` whenever vim.pack installs or updates this plugin, so the
-- binary always matches the lua beside it. Matched on the plugin's directory
-- rather than its name, which the spec is free to change.
local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)))

vim.api.nvim_create_autocmd('PackChanged', {
  group = vim.api.nvim_create_augroup('duckument_build', { clear = true }),
  desc = 'Build ducktape after duckument.nvim is installed or updated',
  callback = function(ev)
    local data = ev.data
    print(vim.inspect(ev))
    if data.kind ~= 'install' and data.kind ~= 'update' then return end
    if vim.uv.fs_realpath(data.path) ~= vim.uv.fs_realpath(root) then return end

    vim.notify('duckument: building ducktape')
    require('duckument.build').run(function(why)
      if why then return vim.notify('duckument: ' .. why, vim.log.levels.WARN) end
      require('duckument.ducktape').reset()
      vim.notify('duckument: ducktape is built')
    end)
  end,
})
