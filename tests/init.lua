-- Minimal init for the test suite: this plugin plus plenary, nothing else.

local root = vim.fn.getcwd()

vim.opt.shadafile = 'NONE'
vim.opt.swapfile = false
vim.opt.rtp:prepend(root)

-- So a spec can require('tests.helpers') alongside the plugin's own modules.
package.path = package.path .. ';' .. root .. '/?.lua'

-- Plenary lives wherever it is already installed; failing that it is cloned
-- into the data directory, so a fresh checkout can run the suite unaided.
local plenary = vim.fn.stdpath('data') .. '/plenary.nvim'
if vim.fn.isdirectory(plenary) == 0 then
  local packed = vim.fn.globpath(vim.o.packpath, 'pack/*/*/plenary.nvim', 1, 1)[1]
  if packed then
    plenary = packed
  else
    print('Cloning plenary.nvim for tests...')
    vim.fn.system({
      'git',
      'clone',
      '--depth=1',
      'https://github.com/nvim-lua/plenary.nvim',
      plenary,
    })
  end
end
vim.opt.rtp:prepend(plenary)

vim.cmd('runtime! plugin/*.lua')
