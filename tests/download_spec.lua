-- Getting hold of the binary: where it goes, which build is wanted for this
-- machine, and the agreement between that answer and what the release workflow
-- actually publishes. Nothing here goes near the network.

local download = require('duckument.download')

--- Runs `download.ensure` and returns what it reported, or fails waiting.
---@return string? err
local function ensure()
  local err, called = nil, false
  download.ensure(function(why)
    err, called = why, true
  end)
  assert.is_true(
    vim.wait(10000, function() return called end, 10),
    'ensure never answered'
  )
  return err
end

--- Every triple the table can name, glibc and musl both.
---@return string[]
local function all_triples()
  local named = {}
  for _, by_arch in pairs(download.triples) do
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
        download.path():match('src/target/release/ducktape%.?e?x?e?$')
      )
    end
  )

  it(
    'is an absolute path, so it needs no runtimepath lookup',
    function() assert.equals(1, vim.fn.isabsolutepath(download.path())) end
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
    assert.is_truthy(vim.tbl_contains(all_triples(), download.triple()))
  end)

  it('takes the triple it is given', function()
    vim.g.duckument_triple = 'made-up-triple'
    assert.equals('made-up-triple', download.triple())
  end)

  it('takes the release it is given', function()
    vim.g.duckument_version = 'v9.9.9'
    assert.equals('v9.9.9', download.version())
  end)

  it('has no release to fetch when the checkout is not on a tag', function()
    -- The suite runs from a working copy, which is the point: a checkout
    -- between tags matches no release and is expected to build its own.
    local git =
      { 'git', '-C', vim.fn.getcwd(), 'describe', '--tags', '--exact-match' }
    if vim.system(git, { text = true }):wait().code == 0 then return end
    assert.is_nil(download.version())
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

  it('is left alone when it was built from source', function()
    if not vim.uv.fs_stat(download.path()) then return end
    -- No version stamp beside it: cargo put it there, and it stands. (The
    -- parentheses matter -- gsub also returns a count, which fs_stat would
    -- otherwise take for a callback.)
    local stamp = (download.path():gsub('ducktape$', 'ducktape.version'))
    if vim.uv.fs_stat(stamp) then return end
    assert.is_nil(ensure())
  end)

  it('is enough on its own when downloading is off', function()
    if not vim.uv.fs_stat(download.path()) then return end
    vim.g.duckument_download = false
    assert.is_nil(ensure())
  end)
end)

describe('no binary and no way to get one', function()
  it(
    'says to build, rather than reaching for a release that is not there',
    function()
      if vim.uv.fs_stat(download.path()) then return end
      vim.g.duckument_download = false
      assert.is_truthy(ensure():match('make build'))
    end
  )
end)
