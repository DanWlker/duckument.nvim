--- Building the `ducktape` binary with cargo, in place: `make build` without the
--- make. Run by `:DuckBuild`, and on first use when no binary is there at all.
---
--- Asynchronous, like everything that touches the binary from the editor: the
--- build takes as long as cargo takes, and nothing waits on it.

local build = {}

--- <root>/lua/duckument/build.lua -> <root>
build.root_dir =
  vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))

local crate_dir = vim.fs.joinpath(build.root_dir, 'src')
local out_dir = vim.fs.joinpath(build.root_dir, 'out')

build.binary_path = vim.fs.joinpath(
  out_dir,
  'release',
  'ducktape' .. (jit.os:lower() == 'windows' and '.exe' or '')
)

-- Callbacks waiting on the build in flight, or nil when there is none. A second
-- request while cargo is still running waits on that build rather than starting
-- its own.
local waiting = nil

--- Runs `cargo build --release` in the crate, with its output in `out/`.
---@param callback? fun(err: string?)
function build.run(callback)
  callback = vim.schedule_wrap(callback or function() end)

  if waiting then
    table.insert(waiting, callback)
    return
  end

  if vim.fn.executable('cargo') ~= 1 then
    return callback('cargo not found -- install a Rust toolchain to build ducktape')
  end

  waiting = { callback }
  vim.system(
    { 'cargo', 'build', '--release', '--target-dir', out_dir },
    { cwd = crate_dir, text = true },
    function(res)
      local err
      if res.code ~= 0 then
        local stderr = vim.trim(res.stderr or '')
        local last = stderr:match('[^\n]*$')
        err = 'cargo build failed'
          .. (last ~= '' and (': ' .. last) or '')
          .. ' -- run `make build` in the plugin directory to see why'
      end

      local done = waiting
      waiting = nil
      for _, cb in ipairs(done) do
        cb(err)
      end
    end
  )
end

return build
