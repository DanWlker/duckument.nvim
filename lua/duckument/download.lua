--- Getting hold of the `ducktape` binary, the way blink.cmp gets hold of its own:
--- built here by `make build`, or -- when this checkout sits exactly on a release
--- tag -- fetched from that release and stamped with the version it came from.
---
--- A binary with no stamp beside it was built from source, and is left alone
--- whatever github has: somebody ran cargo on this working copy, and their build
--- is the one they meant to run.
---
--- Everything below is asynchronous. Nothing here blocks the editor, including
--- the `git describe` -- the query that found the binary missing has already been
--- turned down, and the next one will find it there.

local download = {}

--- The knobs, gathered in one place. blink.cmp reads these off its own config
--- table; this plugin has no `setup()`, so they are globals.
---@return { download: boolean, force_version: string?, force_system_triple: string?, repo: string }
local function config()
  return {
    download = vim.g.duckument_download ~= false,
    force_version = vim.g.duckument_version,
    force_system_triple = vim.g.duckument_triple,
    repo = vim.g.duckument_repo or 'DanWlker/duckument.nvim',
  }
end

--- Rust target triples, by what luajit calls this machine. Only the pairs the
--- release workflow actually builds are here: a triple with no asset behind it
--- would turn a plain "unsupported" into a 404. `tests/download_spec.lua` holds
--- the two to that agreement.
download.system_triples = {
  mac = {
    arm = 'aarch64-apple-darwin',
    x64 = 'x86_64-apple-darwin',
  },
  windows = {
    arm = 'aarch64-pc-windows-msvc',
    x64 = 'x86_64-pc-windows-msvc',
  },
  linux = {
    arm = function(libc) return 'aarch64-unknown-linux-' .. libc end,
    x64 = function(libc) return 'x86_64-unknown-linux-' .. libc end,
  },
}

--- What an executable is called on this machine.
---@return string
function download.get_binary_extension()
  return jit.os:lower() == 'windows' and '.exe' or ''
end

--- <root>/lua/duckument/download.lua -> <root>
local root_dir =
  vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))

-- Beside whatever cargo would have built, so a downloaded binary and a built one
-- are found by the same lookup and `make build` overwrites the download.
local release_dir = vim.fs.joinpath(root_dir, 'src', 'target', 'release')

download.binary_path =
  vim.fs.joinpath(release_dir, 'ducktape' .. download.get_binary_extension())
local version_path = vim.fs.joinpath(release_dir, 'ducktape.version')

--- @param callback fun(err: string | nil)
function download.ensure_downloaded(callback)
  callback = vim.schedule_wrap(callback or function() end)

  download.is_downloaded(function(downloaded)
    -- Told never to fetch: whatever is on disk is the whole answer.
    if not config().download then
      if downloaded then return callback() end
      return callback(
        'downloading is off -- run `make build` in the plugin directory'
      )
    end

    download.get_target_version(function(version_err, target_version)
      if version_err then return callback(version_err) end

      download.get_downloaded_version(function(_, version)
        -- Built from source -- no stamp beside it -- and that build stands.
        if downloaded and version == nil then return callback() end

        -- Between tags, so there is no release this checkout matches.
        if not target_version then
          if downloaded then return callback() end
          return callback(
            'no release to fetch: this checkout is not on a tag, so run `make build` in the plugin directory'
          )
        end

        -- Already fetched, and the right one.
        if downloaded and version == target_version then return callback() end

        download.from_github(target_version, function(download_err)
          if download_err then return callback(download_err) end
          download.set_downloaded_version(target_version, callback)
        end)
      end)
    end)
  end)
end

--- @param cb fun(downloaded: boolean)
function download.is_downloaded(cb)
  -- Answered on the main loop, as every step below is: the callbacks these
  -- chain into reach for `vim.fn`, which a fast event context forbids.
  cb = vim.schedule_wrap(cb)
  vim.uv.fs_stat(download.binary_path, function(err) cb(not err) end)
end

--- The release to be running: the one asked for, or the tag this checkout sits
--- exactly on. Nil when it sits between tags and has nothing to match.
--- @param cb fun(err: string | nil, version: string | nil)
function download.get_target_version(cb)
  local forced = config().force_version
  if forced then
    return vim.schedule(function() cb(nil, forced) end)
  end
  download.get_git_tag(cb)
end

--- @param cb fun(err: string | nil, tag: string | nil)
function download.get_git_tag(cb)
  cb = vim.schedule_wrap(cb)

  -- No repository at all -- installed from a tarball, say -- is the same answer
  -- as a commit no tag points at: nothing to match, so nothing to fetch.
  local repo_dir = vim.fs.root(root_dir, '.git')
  if not repo_dir then return cb() end

  vim.system({
    'git',
    '--git-dir',
    vim.fs.joinpath(repo_dir, '.git'),
    '--work-tree',
    repo_dir,
    'describe',
    '--tags',
    '--exact-match',
  }, { text = true }, function(out)
    -- 128 is what `--exact-match` says when no tag points here.
    if out.code == 128 then return cb() end
    if out.code ~= 0 then
      return cb(
        'while getting the git tag, git exited with '
          .. out.code
          .. ': '
          .. vim.trim(out.stderr or '')
      )
    end

    local tag = vim.trim(vim.split(out.stdout or '', '\n')[1] or '')
    return cb(nil, tag ~= '' and tag or nil)
  end)
end

--- @param tag string
--- @param cb fun(err: string | nil)
function download.from_github(tag, cb)
  cb = vim.schedule_wrap(cb)

  if vim.fn.executable('curl') ~= 1 then
    return cb('curl is needed to fetch ducktape')
  end

  download.get_system_triple(function(system_triple)
    if not system_triple then
      return cb(
        ('no ducktape build for %s/%s -- run `make build` in the plugin directory'):format(
          jit.os,
          jit.arch
        )
      )
    end

    local url = 'https://github.com/'
      .. config().repo
      .. '/releases/download/'
      .. tag
      .. '/ducktape-'
      .. system_triple
      .. download.get_binary_extension()

    -- Downloaded beside itself and moved into place at the end, so a fetch cut
    -- off half way through never leaves a runnable binary behind.
    local part = download.binary_path .. '.part'

    vim.system({
      'curl',
      '-q', -- first, and before anything else: never mind this machine's curlrc
      '--fail', -- a 404 is a failure, not a file full of html
      '--location', -- follow redirects
      '--silent', -- no progress meter
      '--show-error', -- but do say what went wrong
      '--retry', -- (two words: `--retry=2` is not a spelling every curl takes)
      '2',
      '--retry-connrefused',
      '--create-dirs',
      '--output',
      part,
      url,
    }, { text = true }, function(out)
      if out.code ~= 0 then
        os.remove(part)
        return cb(
          ('could not fetch %s -- %s'):format(url, vim.trim(out.stderr or ''))
        )
      end

      vim.uv.fs_chmod(part, 493) -- 0755: curl leaves it unrunnable
      local ok, why = vim.uv.fs_rename(part, download.binary_path)
      if not ok then
        os.remove(part)
        return cb('could not install ducktape: ' .. (why or '?'))
      end
      cb()
    end)
  end)
end

--- The release the binary sitting there came from, if it came from one at all.
--- @param cb fun(err: string | nil, last_version: string | nil)
function download.get_downloaded_version(cb)
  cb = vim.schedule_wrap(cb)
  vim.uv.fs_open(version_path, 'r', 438, function(open_err, fd)
    if open_err or fd == nil then return cb(open_err or 'Unknown error') end

    -- Read by the file's own size rather than a fixed count, so a tag longer
    -- than the guess is not silently truncated into a version that matches
    -- nothing and re-downloads forever.
    vim.uv.fs_fstat(fd, function(stat_err, stat)
      if stat_err or stat == nil then
        vim.uv.fs_close(fd, function() end)
        return cb(stat_err or 'Unknown error')
      end

      vim.uv.fs_read(fd, stat.size, 0, function(read_err, data)
        vim.uv.fs_close(fd, function() end)
        if read_err or data == nil then return cb(read_err or 'Unknown error') end

        local version = vim.trim(data)
        return cb(nil, version ~= '' and version or nil)
      end)
    end)
  end)
end

--- @param version string
--- @param cb fun(err: string | nil)
function download.set_downloaded_version(version, cb)
  cb = vim.schedule_wrap(cb)
  vim.uv.fs_open(version_path, 'w', 420, function(open_err, fd)
    if open_err or fd == nil then return cb(open_err or 'Unknown error') end
    vim.uv.fs_write(fd, version, 0, function(write_err)
      vim.uv.fs_close(fd, function() end)
      return cb(write_err)
    end)
  end)
end

--- @return string os, string | nil arch
function download.get_system_info()
  local os = jit.os:lower()
  if os == 'osx' then os = 'mac' end

  local arch = jit.arch:lower()
  arch = (arch:match('arm') or arch:match('aarch64')) and 'arm'
    or arch:match('x64') and 'x64'
    or nil

  return os, arch
end

--- @param cb fun(triple: string | nil)
function download.get_system_triple(cb)
  cb = vim.schedule_wrap(cb)

  local forced = config().force_system_triple
  if forced then return cb(forced) end

  local os, arch = download.get_system_info()
  local triples = download.system_triples[os] or {}

  if os ~= 'linux' then return cb(triples[arch]) end

  -- Nothing is published for android, and a linux binary is not a substitute.
  if vim.fn.has('android') == 1 then return cb(nil) end

  vim.uv.fs_stat('/etc/alpine-release', function(err, is_alpine)
    -- The musl build is for the distributions that have no glibc to link
    -- against; everywhere else the gnu one is the better neighbour.
    local libc = (not err and is_alpine) and 'musl' or 'gnu'
    local triple = triples[arch]
    return cb(type(triple) == 'function' and triple(libc) or triple)
  end)
end

--- @return string | nil
function download.get_system_triple_sync()
  local forced = config().force_system_triple
  if forced then return forced end

  local os, arch = download.get_system_info()
  local triples = download.system_triples[os] or {}

  if os ~= 'linux' then return triples[arch] end
  if vim.fn.has('android') == 1 then return nil end

  local ok, is_alpine = pcall(vim.uv.fs_stat, '/etc/alpine-release')
  local libc = (ok and is_alpine) and 'musl' or 'gnu'
  local triple = triples[arch]
  return type(triple) == 'function' and triple(libc) or triple
end

return download
