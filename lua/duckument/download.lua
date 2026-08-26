--- Getting hold of the `ducktape` binary.
---
--- Built here by `make build`, or -- when this checkout sits on a release tag --
--- fetched from that release, the way blink.cmp does it.
---
--- A binary with no stamp beside it was built from source, and is left alone
--- whatever github has: somebody ran cargo on this working copy, and their build
--- is the one they meant to run.

local M = {}

--- Where the releases hang off. Point `vim.g.duckument_repo` at a fork.
local REPO = 'DanWlker/duckument.nvim'

--- <root>/lua/duckument/download.lua -> <root>
local here = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here)))

local system = jit.os:lower() == 'osx' and 'mac' or jit.os:lower()
local suffix = system == 'windows' and '.exe' or ''

-- Beside whatever cargo would have built, so a downloaded binary and a built
-- one are found by the same lookup and `make build` overwrites the download.
local dir = vim.fs.joinpath(root, 'src', 'target', 'release')
local stamp = vim.fs.joinpath(dir, 'ducktape.version')

--- Where the binary lives, built or fetched.
---@return string
function M.path() return vim.fs.joinpath(dir, 'ducktape' .. suffix) end

--- Rust target triples, by what luajit calls this machine. Only the pairs the
--- release workflow actually builds are here: a triple with no asset behind it
--- would turn a plain "unsupported" into a 404. `tests/download_spec.lua` holds
--- the two to that agreement.
M.triples = {
  mac = {
    arm64 = 'aarch64-apple-darwin',
    x64 = 'x86_64-apple-darwin',
  },
  windows = {
    arm64 = 'aarch64-pc-windows-msvc',
    x64 = 'x86_64-pc-windows-msvc',
  },
  linux = {
    arm64 = function(libc) return 'aarch64-unknown-linux-' .. libc end,
    x64 = function(libc) return 'x86_64-unknown-linux-' .. libc end,
  },
}

--- This machine's target triple, or nil when nothing is published for it.
---@return string?
function M.triple()
  if vim.g.duckument_triple then return vim.g.duckument_triple end

  local triple = (M.triples[system] or {})[jit.arch:lower()]
  if type(triple) ~= 'function' then return triple end

  -- The musl build is for the distributions that have no glibc to link
  -- against; everywhere else the gnu one is the better neighbour.
  return triple(vim.uv.fs_stat('/etc/alpine-release') and 'musl' or 'gnu')
end

--- The release this checkout is: the tag it sits exactly on, or the one asked
--- for. A checkout between tags has no release to match and builds its own.
---@return string?
function M.version()
  if vim.g.duckument_version then return vim.g.duckument_version end

  local git = { 'git', '-C', root, 'describe', '--tags', '--exact-match' }
  local res = vim.system(git, { text = true }):wait()
  if res.code ~= 0 then return nil end

  local tag = vim.trim(res.stdout or '')
  return tag ~= '' and tag or nil
end

--- The release the binary sitting there came from, if it came from one at all.
---@return string?
local function installed()
  local ok, lines = pcall(vim.fn.readfile, stamp)
  return ok and lines[1] or nil
end

--- Fetches `version` for `triple` and puts it where `M.path()` says.
---@param version string
---@param triple string
---@param done fun(err: string?)
local function fetch(version, triple, done)
  if vim.fn.executable('curl') ~= 1 then
    return done('curl is needed to fetch ducktape')
  end

  local url = ('https://github.com/%s/releases/download/%s/ducktape-%s%s'):format(
    vim.g.duckument_repo or REPO,
    version,
    triple,
    suffix
  )
  -- Downloaded beside itself and moved into place at the end, so a fetch cut
  -- off half way through never leaves a runnable binary behind.
  local part = M.path() .. '.part'

  local curl = {
    'curl',
    '-q', -- first, and before anything else: never mind this machine's curlrc
    '--fail', -- a 404 is a failure, not a file full of html
    '--location',
    '--silent',
    '--show-error',
    '--retry',
    '2',
    '--retry-connrefused',
    '--create-dirs',
    '--output',
    part,
    url,
  }

  vim.system(curl, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        os.remove(part)
        return done(
          ('could not fetch %s -- %s'):format(url, vim.trim(res.stderr or ''))
        )
      end

      vim.uv.fs_chmod(part, 493) -- 0755: curl leaves it unrunnable
      local ok, why = vim.uv.fs_rename(part, M.path())
      if not ok then return done('could not install ducktape: ' .. (why or '?')) end

      vim.fn.writefile({ version }, stamp)
      done()
    end)
  end)
end

--- Makes sure there is a binary to run, fetching one if there is not, and says
--- what came of it. Calling this when a binary is already there costs a `stat`
--- and, at most, a `git describe`.
---@param done? fun(err: string?)
function M.ensure(done)
  done = vim.schedule_wrap(done or function() end)

  local built = vim.uv.fs_stat(M.path()) ~= nil
  if built and vim.g.duckument_download == false then return done() end
  if vim.g.duckument_download == false then
    return done('downloading is off -- run `make build` in the plugin directory')
  end

  local stamped = installed()
  -- No stamp means cargo put it there. That build stands.
  if built and stamped == nil then return done() end

  local version = M.version()
  if built and stamped == version then return done() end
  if version == nil then
    if built then return done() end
    return done(
      'no release to fetch: this checkout is not on a tag, so run `make build` in the plugin directory'
    )
  end

  local triple = M.triple()
  if not triple then
    return done(
      ('no ducktape build for %s/%s -- run `make build` in the plugin directory'):format(
        jit.os,
        jit.arch
      )
    )
  end

  fetch(version, triple, done)
end

return M
