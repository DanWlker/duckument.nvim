-- Getting hold of the binary: where it goes, which build is wanted for this
-- machine, and the agreement between that answer and what the release workflow
-- actually publishes. Nothing here goes near the network.

local download = require('duckument.download')

--- Runs one of the callback-taking functions and hands back what it reported,
--- or fails waiting. Everything in this module answers asynchronously.
---@param fn fun(cb: fun(...))
---@return ... the arguments the callback was given
local function wait_for(fn)
  local answer, called = nil, false
  fn(function(...)
    answer, called = vim.F.pack_len(...), true
  end)
  assert.is_true(vim.wait(10000, function() return called end, 10), 'never answered')
  return vim.F.unpack_len(answer)
end

--- Every triple the table can name, glibc and musl both.
---@return string[]
local function all_triples()
  local named = {}
  for _, by_arch in pairs(download.system_triples) do
    for _, triple in pairs(by_arch) do
      if type(triple) == 'function' then
        table.insert(named, triple('gnu'))
        table.insert(named, triple('musl'))
      else
        table.insert(named, triple)
      end
    end
  end
  table.sort(named)
  return named
end

describe('where the binary goes', function()
  it(
    'sits where cargo would have put it',
    function()
      assert.is_truthy(
        download.binary_path:match('src/target/release/ducktape%.?e?x?e?$')
      )
    end
  )

  it(
    'is an absolute path, so it needs no runtimepath lookup',
    function() assert.equals(1, vim.fn.isabsolutepath(download.binary_path)) end
  )
end)

describe('which build is wanted', function()
  after_each(function()
    vim.g.duckument_triple = nil
    vim.g.duckument_version = nil
    vim.g.duckument_download = nil
  end)

  it('names a triple for the machine running the tests', function()
    -- Whatever this is, it has to be one the workflow builds.
    assert.is_truthy(
      vim.tbl_contains(all_triples(), download.get_system_triple_sync())
    )
  end)

  it(
    'answers the same asked either way round',
    function()
      assert.equals(
        download.get_system_triple_sync(),
        wait_for(download.get_system_triple)
      )
    end
  )

  it('takes the triple it is given', function()
    vim.g.duckument_triple = 'made-up-triple'
    assert.equals('made-up-triple', download.get_system_triple_sync())
    assert.equals('made-up-triple', wait_for(download.get_system_triple))
  end)

  it('takes the release it is given', function()
    vim.g.duckument_version = 'v9.9.9'
    local err, version = wait_for(download.get_target_version)
    assert.is_nil(err)
    assert.equals('v9.9.9', version)
  end)

  it('has no release to fetch when the checkout is not on a tag', function()
    -- The suite runs from a working copy, which is the point: a checkout
    -- between tags matches no release and is expected to build its own.
    local git =
      { 'git', '-C', vim.fn.getcwd(), 'describe', '--tags', '--exact-match' }
    if vim.system(git, { text = true }):wait().code == 0 then return end

    local err, version = wait_for(download.get_git_tag)
    assert.is_nil(err) -- being between tags is an answer, not a failure
    assert.is_nil(version)
  end)
end)

describe('the triples and the release workflow', function()
  local workflow =
    table.concat(vim.fn.readfile('.github/workflows/release.yml'), '\n')

  it('agree, so no supported machine is sent after a missing asset', function()
    for _, triple in ipairs(all_triples()) do
      assert.is_truthy(
        workflow:find('target: ' .. triple, 1, true),
        triple .. ' is offered to users but never built'
      )
    end
  end)

  it('agree the other way, so nothing is built that nobody asks for', function()
    local named = all_triples()
    for target in workflow:gmatch('target: ([%w_%-%.]+)') do
      assert.is_truthy(
        vim.tbl_contains(named, target),
        target .. ' is built but no machine ever asks for it'
      )
    end
  end)
end)

describe('a binary that is already there', function()
  after_each(function() vim.g.duckument_download = nil end)

  it('is found', function()
    if not vim.uv.fs_stat(download.binary_path) then return end
    assert.is_true(wait_for(download.is_downloaded))
  end)

  it('is left alone when it was built from source', function()
    if not vim.uv.fs_stat(download.binary_path) then return end
    -- No version stamp beside it: cargo put it there, and it stands. (The
    -- parentheses matter -- gsub also returns a count, which fs_stat would
    -- otherwise take for a callback.)
    local stamp = (download.binary_path:gsub('ducktape$', 'ducktape.version'))
    if vim.uv.fs_stat(stamp) then return end

    -- Reading the stamp fails, which is exactly how "built here" is told
    -- apart from "fetched from a release".
    local _, version = wait_for(download.get_downloaded_version)
    assert.is_nil(version)

    assert.is_nil(wait_for(download.ensure_downloaded))
  end)

  it('is enough on its own when downloading is off', function()
    if not vim.uv.fs_stat(download.binary_path) then return end
    vim.g.duckument_download = false
    assert.is_nil(wait_for(download.ensure_downloaded))
  end)
end)

describe('no binary and no way to get one', function()
  after_each(function() vim.g.duckument_download = nil end)

  it(
    'says to build, rather than reaching for a release that is not there',
    function()
      if vim.uv.fs_stat(download.binary_path) then return end
      vim.g.duckument_download = false
      assert.is_truthy(wait_for(download.ensure_downloaded):match('make build'))
    end
  )
end)
