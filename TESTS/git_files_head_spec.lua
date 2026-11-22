-- TESTS/git_files_head_spec.lua — git.files ref_sha / head_sha / upstream,
-- git.head_hash_fast / git.ahead_behind_fast
--
-- The commit of HEAD and of its upstream read from `.git` instead of a git
-- process. Pinned on real fixture repositories: every answer compared with
-- git's own (`rev-parse`), every `vim.system` start counted. What the files
-- cannot answer the way git would says `unsure`, and the `*_fast` wrappers
-- then ask git.
--
-- HOME / XDG_CONFIG_HOME point at an empty directory and the GIT_* variables
-- are unset for the whole spec, so the runner's global config cannot change
-- what is measured.

return function(H)
  local git = require("lib.nvim.git")
  local files = require("lib.nvim.git.files")
  local dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
  local F = dofile(dir .. "git_fixture.lua")(H)

  ---`fn` with every `vim.system` start counted.
  ---@return integer starts
  ---@return any ...
  local function counted(fn)
    local n = 0
    local real = vim.system
    local out
    H.with_patched(vim, "system", function(...)
      n = n + 1
      return real(...)
    end, function()
      out = { fn() }
    end)
    return n, unpack(out)
  end

  ---Deep comparison (H.eq compares tables by identity).
  local function same(got, want, msg)
    H.ok(
      vim.deep_equal(got, want),
      msg .. ": got " .. vim.inspect(got) .. ", want " .. vim.inspect(want)
    )
  end

  local home = F.tmpdir("-home")
  local env = {
    { "HOME", home },
    { "USERPROFILE", home },
    { "XDG_CONFIG_HOME", home .. "/xdg" },
    { "GIT_DIR", nil },
    { "GIT_WORK_TREE", nil },
    { "GIT_COMMON_DIR", nil },
    { "GIT_CONFIG", nil },
    { "GIT_CONFIG_GLOBAL", nil },
    { "GIT_CONFIG_COUNT", nil },
    { "GIT_CONFIG_PARAMETERS", nil },
  }
  local saved = {}
  for _, e in ipairs(env) do
    saved[e[1]] = vim.env[e[1]]
    vim.env[e[1]] = e[2]
  end

  local ok, err = pcall(function()
    -- ── a clone with an upstream ──────────────────────────────────────────
    local origin = F.init("-head-origin")
    local c1 = F.commit(origin, "one", { when = 1700000000 })
    local work = F.tmpdir("-head-work")
    F.git(work, { "clone", "-q", origin, "." })

    local head, unsure = files.head(work)
    H.eq(unsure, nil, "clone: head is sure")
    H.eq(head and head.sha, c1, "clone: head.sha is git's HEAD")
    H.eq(head and head.branch, "main", "clone: head.branch")
    H.eq(files.head_sha(work), F.git(work, { "rev-parse", "HEAD" }), "head_sha == rev-parse HEAD")

    local pair, punsure = files.upstream(work)
    H.eq(punsure, nil, "clone: upstream is sure")
    H.eq(pair and pair.head, c1, "upstream: head")
    H.eq(pair and pair.upstream, F.git(work, { "rev-parse", "@{u}" }), "upstream == rev-parse @{u}")

    -- the wrappers: no process when the files answer
    local n_hash, hash = counted(function()
      return git.head_hash_fast({ dir = work })
    end)
    H.eq(hash, c1, "head_hash_fast: git's answer")
    H.eq(n_hash, 0, "head_hash_fast: no process")
    local n_ab, ahead, behind = counted(function()
      return git.ahead_behind_fast({ dir = work })
    end)
    same({ ahead, behind }, { false, false }, "ahead_behind_fast: in sync")
    H.eq(n_ab, 0, "ahead_behind_fast: same sha, no process")

    -- ahead: a local commit; the answer comes from git, and equals git's
    F.commit(work, "two", { when = 1700001000 })
    local n_ahead, a2, b2 = counted(function()
      return git.ahead_behind_fast({ dir = work })
    end)
    local ga, gb = git.ahead_behind({ dir = work })
    same({ a2, b2 }, { ga, gb }, "ahead_behind_fast: ahead, the same as ahead_behind")
    same({ a2, b2 }, { true, false }, "ahead_behind_fast: ahead")
    H.ok(n_ahead >= 1, "ahead_behind_fast: different shas ask git")

    -- packed refs: the loose file goes, the answer stays
    F.git(work, { "pack-refs", "--all" })
    H.eq(vim.fn.filereadable(work .. "/.git/refs/heads/main"), 0, "fixture: main is packed")
    H.eq(files.head_sha(work), F.git(work, { "rev-parse", "HEAD" }), "packed: head_sha")
    pair = files.upstream(work)
    H.eq(pair and pair.upstream, F.git(work, { "rev-parse", "@{u}" }), "packed: upstream")

    -- a loose ref wins over packed-refs, as in git
    local c3 = F.commit(work, "three", { when = 1700002000 })
    H.eq(files.head_sha(work), c3, "loose ref over packed-refs")

    -- a symbolic ref is followed
    local info = assert(files.find(work))
    F.git(work, { "symbolic-ref", "refs/heads/alias", "refs/heads/main" })
    H.eq(files.ref_sha(info, "refs/heads/alias"), c3, "ref_sha follows a symbolic ref")
    same(
      { files.ref_sha(info, "refs/heads/nope") },
      {},
      "ref_sha: a missing ref is nil, not unsure"
    )
    H.eq(select(2, files.ref_sha(info, "refs/heads/../x")), true, "ref_sha: `..` is unsure")

    -- detached HEAD: the sha, no branch, no upstream
    F.git(work, { "checkout", "-q", "--detach", c1 })
    head = files.head(work)
    H.eq(head and head.sha, c1, "detached: head.sha")
    H.eq(head and head.branch, nil, "detached: no branch")
    same({ files.upstream(work) }, {}, "detached: no upstream, not unsure")
    local n_det, da, db = counted(function()
      return git.ahead_behind_fast({ dir = work })
    end)
    same({ da, db }, { git.ahead_behind({ dir = work }) }, "detached: same as ahead_behind")
    H.eq(n_det, 0, "detached: no process")
    F.git(work, { "checkout", "-q", "main" })

    -- a branch without an upstream in this config: unsure (the global config may name one)
    F.git(work, { "checkout", "-q", "-b", "side" })
    H.eq(select(2, files.upstream(work)), true, "no upstream configured: unsure")
    local n_side, sa, sb = counted(function()
      return git.ahead_behind_fast({ dir = work })
    end)
    same({ sa, sb }, { git.ahead_behind({ dir = work }) }, "unsure: answer from git")
    H.ok(n_side >= 1, "unsure: asks git")

    -- a local upstream (remote = .)
    F.git(work, { "branch", "--set-upstream-to=main" })
    pair = files.upstream(work)
    H.eq(pair and pair.upstream, F.git(work, { "rev-parse", "@{u}" }), "remote = .: upstream")
    F.git(work, { "checkout", "-q", "main" })

    -- a fetch refspec of its own: unsure
    F.git(work, { "config", "remote.origin.fetch", "+refs/heads/main:refs/remotes/origin/main" })
    H.eq(select(2, files.upstream(work)), true, "own fetch refspec: unsure")
    F.git(work, { "config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*" })

    -- unborn branch: nil, not unsure; head_hash_fast like git
    local fresh = F.init("-head-unborn")
    head, unsure = files.head(fresh)
    H.eq(unsure, nil, "unborn: sure")
    H.eq(head and head.sha, nil, "unborn: no sha")
    local n_unborn, unborn_hash = counted(function()
      return git.head_hash_fast({ dir = fresh })
    end)
    H.eq(unborn_hash, git.head_hash({ dir = fresh }), "unborn: head_hash_fast like head_hash")
    H.eq(n_unborn, 0, "unborn: no process")

    -- a linked worktree: HEAD in its own git dir, refs in the common one
    local linked = F.tmpdir("-head-linked")
    vim.fn.delete(linked, "rf")
    F.git(work, { "worktree", "add", "-q", "-b", "wt", linked, c1 })
    H.eq(files.head_sha(linked), F.git(linked, { "rev-parse", "HEAD" }), "worktree: head_sha")
    H.eq(files.head(linked).branch, "wt", "worktree: branch")

    -- not a repository
    local plain = F.tmpdir("-head-plain")
    same({ files.head(plain) }, {}, "no repository: nil, not unsure")
    H.eq(git.head_hash_fast({ dir = plain }), git.head_hash({ dir = plain }), "no repo: like git")

    -- the environment points git elsewhere: unsure, the wrapper asks git
    vim.env.GIT_DIR = origin .. "/.git"
    H.eq(select(2, files.head(work)), true, "GIT_DIR: unsure")
    local n_env, env_hash = counted(function()
      return git.head_hash_fast({ dir = work })
    end)
    H.eq(env_hash, git.head_hash({ dir = work }), "GIT_DIR: the wrapper answers like git")
    H.ok(n_env >= 1, "GIT_DIR: asks git")
    vim.env.GIT_DIR = nil

    -- a reftable repository (git 2.45+): unsure
    local rt = F.tmpdir("-head-reftable")
    local _, code = F.git(rt, { "init", "-q", "--ref-format=reftable" }, { allow_fail = true })
    if code == 0 then
      F.commit(rt, "rt")
      H.eq(select(2, files.head(rt)), true, "reftable: unsure")
      H.eq(git.head_hash_fast({ dir = rt }), git.head_hash({ dir = rt }), "reftable: like git")
    else
      print("n/a  this git has no reftable (git < 2.45)")
    end

    -- ── the config reader on its own ─────────────────────────────────────
    local function cs(t, sec, sub)
      return { files.config_section(t, sec, sub) }
    end
    H.eq(
      cs('[branch "main"]\n  Remote = origin\n', "branch", "main")[1].remote,
      "origin",
      "key case"
    )
    H.eq(cs('[Branch "main"]\nremote = a\n', "branch", "main")[1].remote, "a", "section case")
    H.eq(cs('[branch "Main"]\nremote = a\n', "branch", "main")[1].remote, nil, "subsection case")
    local twice = cs('[branch "main"]\nremote = a\nremote = b\nmerge = m\n', "branch", "main")
    H.eq(twice[1].remote, nil, "a key given twice is left out")
    H.eq(twice[3].remote, true, "a key given twice is unclear")
    H.eq(twice[1].merge, "m", "a key given twice does not taint the others")
    H.eq(twice[2], false, "a key given twice does not make the section unsure")
    H.eq(cs('[branch "main"]\nremote = a ; note\n', "branch", "main")[1].remote, "a", "comment")
    H.eq(cs("[branch.main]\nremote = a\n", "branch", "main")[2], true, "old form: unsure")
    local quoted = cs('[branch "main"]\nremote = "a"\n', "branch", "main")
    H.eq(quoted[1].remote, nil, "quoted: left out")
    H.eq(quoted[3].remote, true, "quoted: unclear")
    H.eq(cs('[include]\npath = x\n[branch "main"]\n', "branch", "main")[2], true, "include: unsure")
    -- what a clone on Windows writes: the url escaped, the refspec plain
    local win = cs(
      '[remote "origin"]\n\turl = C:\\\\Users\\\\x\\\\repo\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n',
      "remote",
      "origin"
    )
    H.eq(win[2], false, "an escaped url does not make the section unsure")
    H.eq(win[3].url, true, "the escaped url is unclear")
    H.eq(win[1].fetch, "+refs/heads/*:refs/remotes/origin/*", "the refspec next to it is read")
  end)

  for _, e in ipairs(env) do
    vim.env[e[1]] = saved[e[1]]
  end
  F.cleanup()
  if not ok then
    error(err, 0)
  end
end
