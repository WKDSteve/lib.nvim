-- TESTS/git_refs_spec.lua — lib.nvim.git.refs starts one git process
--
-- `refs` used to run one `git for-each-ref` per group (heads, remotes, tags):
-- three synchronous starts on the first <Tab> of a revision completion. It
-- now asks once with all three patterns and splits the date-sorted list by
-- group. Pinned against a real fixture repository: the answer equals the old
-- three-process listing (computed here the old way), ties included, and
-- exactly one process starts.

return function(H)
  local git = require("lib.nvim.git")
  local dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
  local F = dofile(dir .. "git_fixture.lua")(H)

  local repo = F.init("-refs-one")
  local c1 = F.commit(repo, "one", { when = 1700000000 })
  F.git(repo, { "tag", "v1" })
  F.git(repo, { "branch", "old" })
  -- Same commit, same date: ties sorted by refname, in every group.
  F.git(repo, { "branch", "a-tie" })
  F.git(repo, { "branch", "z-tie" })
  F.commit(repo, "two", { when = 1700001000 })
  F.git(repo, { "tag", "-a", "v2", "-m", "annotated" }, { env = F.when(1700002000) })
  F.git(repo, { "update-ref", "refs/remotes/origin/main", "HEAD" })
  F.git(repo, { "update-ref", "refs/remotes/origin/dev", c1 })
  F.git(repo, { "update-ref", "refs/remotes/upstream/main", c1 })
  -- A tag named like a branch: deduplicated, the branch (first group) stays.
  F.git(repo, { "tag", "old", c1 })
  -- A ref outside the three groups never appears.
  F.git(repo, { "update-ref", "refs/notes/commits", c1 })

  --- The old implementation: one process per group, strip=2.
  ---@param opts? table
  local function old_refs(opts)
    opts = opts or {}
    local out, seen = {}, {}
    for _, g in ipairs({
      { opts.branches ~= false, "refs/heads/" },
      { opts.remotes ~= false, "refs/remotes/" },
      { opts.tags ~= false, "refs/tags/" },
    }) do
      if g[1] then
        local raw = F.git(
          repo,
          { "for-each-ref", "--sort=-creatordate", "--format=%(refname:strip=2)", g[2] }
        )
        for line in raw:gmatch("[^\r\n]+") do
          if not seen[line] then
            seen[line] = true
            out[#out + 1] = line
          end
        end
      end
    end
    return out
  end

  --- `fn` with every `vim.system` start counted.
  ---@return integer starts
  ---@return any result
  local function counted(fn)
    local n = 0
    local real = vim.system
    local result
    H.with_patched(vim, "system", function(argv, ...)
      if argv[1] == "git" then
        n = n + 1
      end
      return real(argv, ...)
    end, function()
      result = fn()
    end)
    return n, result
  end

  for _, opts in ipairs({
    {},
    { remotes = false },
    { branches = false },
    { tags = false },
    { branches = false, remotes = false },
    { branches = false, tags = false },
  }) do
    local starts, got = counted(function()
      return git.refs(repo, opts)
    end)
    local label = vim.inspect(opts, { newline = "", indent = "" })
    H.eq(
      table.concat(got, ","),
      table.concat(old_refs(opts), ","),
      "same answer as before " .. label
    )
    H.eq(starts, 1, "one git process " .. label)
  end

  local all = git.refs(repo)
  H.eq(
    table.concat(all, ","),
    "main,a-tie,old,z-tie,origin/main,origin/dev,upstream/main,v2,v1",
    "heads, then remotes, then tags; newest first, ties by name, deduplicated"
  )
  H.eq(table.concat(git.refs(repo, { limit = 3 }), ","), "main,a-tie,old", "limit")

  local none_starts, none = counted(function()
    return git.refs(repo, { branches = false, remotes = false, tags = false })
  end)
  H.eq(#none, 0, "no group: empty")
  H.eq(none_starts, 0, "no group: no process")

  -- ------------------------------------------------------------ refs_async

  --- `git.refs_async` driven to its answer. Inside the call `vim.system`
  --- hands out jobs whose `wait()` throws: the async form must never block.
  ---@return { refs: string[], err: string|nil, calls: integer, inline: boolean, waited?: boolean }
  local function async_refs(d, opts, git_cmd)
    local got = { calls = 0, inline = false }
    local returned = false
    local real = vim.system
    H.with_patched(vim, "system", function(argv, o, cb)
      local job = real(argv, o, cb)
      return setmetatable({
        wait = function()
          got.waited = true
          error("refs_async waited for git")
        end,
      }, { __index = job })
    end, function()
      git.refs_async(d, opts, function(refs, err)
        got.calls = got.calls + 1
        got.refs, got.err = refs, err
        got.inline = not returned
      end, git_cmd)
    end)
    returned = true
    vim.wait(10000, function()
      return got.calls > 0
    end, 5)
    vim.wait(30)
    return got
  end

  for _, opts in ipairs({
    {},
    { remotes = false },
    { branches = false },
    { tags = false },
    { branches = false, tags = false },
    { limit = 3 },
    { limit = 5, branches = false },
  }) do
    local label = vim.inspect(opts, { newline = "", indent = "" })
    local got = async_refs(repo, opts)
    H.eq(got.waited, nil, "refs_async never waits for git " .. label)
    H.eq(got.calls, 1, "refs_async answers once " .. label)
    H.eq(got.inline, false, "refs_async answers scheduled, not inline " .. label)
    H.eq(got.err, nil, "refs_async: no error " .. label)
    H.eq(
      table.concat(got.refs or {}, ","),
      table.concat(git.refs(repo, opts), ","),
      "refs_async: the same list as refs " .. label
    )
  end

  do
    local starts = counted(function()
      async_refs(repo, {})
    end)
    H.eq(starts, 1, "refs_async: one git process")
  end

  do
    local none_got
    local none_async_starts = counted(function()
      none_got = async_refs(repo, { branches = false, remotes = false, tags = false })
    end)
    H.eq(none_async_starts, 0, "refs_async no group: no process")
    H.eq(none_got.calls, 1, "refs_async no group: still answers")
    H.eq(none_got.inline, false, "refs_async no group: answers scheduled")
    H.eq(#none_got.refs, 0, "refs_async no group: empty list")
  end

  do -- git cannot be started: an empty list and a reason, scheduled
    local got = async_refs(repo, {}, "lib-nvim-no-such-git-binary")
    H.eq(got.calls, 1, "refs_async start failure: answers once")
    H.eq(got.inline, false, "refs_async start failure: answers scheduled")
    H.eq(#got.refs, 0, "refs_async start failure: empty list")
    H.ok(type(got.err) == "string" and got.err ~= "", "refs_async start failure: names the reason")
  end

  do -- outside a repository: empty, with git's reason
    local outside = vim.fn.tempname()
    vim.fn.mkdir(outside, "p")
    local got = async_refs(outside, {})
    H.eq(#got.refs, 0, "refs_async outside a repo: empty list like refs")
    H.ok(type(got.err) == "string", "refs_async outside a repo: git's reason")
    vim.fn.delete(outside, "rf")
  end

  do -- stop() before the answer: on_done never runs
    local calls = 0
    local handle = git.refs_async(repo, {}, function()
      calls = calls + 1
    end)
    handle.stop()
    vim.wait(500)
    H.eq(calls, 0, "refs_async: stop() drops the answer")
    handle.stop()
    local none_handle = git.refs_async(
      repo,
      { branches = false, remotes = false, tags = false },
      function()
        calls = calls + 1
      end
    )
    none_handle.stop()
    vim.wait(50)
    H.eq(calls, 0, "refs_async: stop() also drops the no-group answer")
  end

  F.cleanup()
end
