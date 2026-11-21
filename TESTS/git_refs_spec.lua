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

  F.cleanup()
end
