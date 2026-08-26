-- Minimal init for the test suite: this plugin plus plenary, nothing else.

local root = vim.fn.getcwd()

vim.opt.shadafile = 'NONE'
vim.opt.swapfile = false
vim.opt.rtp:prepend(root)

-- So a spec can require('tests.helpers') alongside the plugin's own modules.
package.path = package.path .. ';' .. root .. '/?.lua'

-- Plenary wherever it is already installed. The suite runs with --noplugin, so
-- packages are not added to the runtimepath for us and one has to be found by
-- hand; nothing is installed on your behalf, and a checkout without plenary
-- fails at the require below rather than growing a copy of it.
for _, dir in ipairs(vim.fn.globpath(vim.o.packpath, 'pack/*/*/plenary.nvim', 1, 1)) do
  vim.opt.rtp:prepend(dir)
end

require('plenary')

vim.cmd('runtime! plugin/*.lua')
