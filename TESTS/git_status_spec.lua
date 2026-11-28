-- TESTS/git_status_spec.lua — lib.nvim.git: `opts.dir`, the `-z` status parser
-- and `status_porcelain_async`.
--
-- The regression this exists for: `git status --porcelain` without `-z`
-- C-quotes any path containing a space or a non-ASCII byte, so the old parser
-- returned `"a b.txt"` (with the quotes) and `"\303\274.txt"` (octal escapes)
-- as map keys -- paths that do not exist on disk. Every assertion about a
-- fixture path below therefore also checks the key against the real
-- filesystem, not just against the string a fixture was written with.
--
-- Fixtures are real throwaway repositories (real `git merge` for the conflict
-- case), not string mocks: a parser tested only against strings cannot notice
-- that git stopped producing them.

return function(H)
  local git = require("lib.nvim.git")
  local is_windows = vim.fn.has("win32") == 1

  local created = {} ---@type string[]

  local function tmpdir(suffix)
    local dir = vim.fn.tempname() .. suffix
    vim.fn.mkdir(dir, "p")
    created[#created + 1] = dir
    return dir
  end

  --- Run git against `dir`; a fixture step that fails is a test failure, never
  --- a silent skip (a spec that quietly passes without its fixture is worse
  --- than one that fails).
  ---@param dir string
  ---@param args string[]
  ---@param allow_fail? boolean
  ---@return string stdout
  ---@return integer code
  local function git_run(dir, args, allow_fail)
    local argv = {
      "git",
      "-c",
      "user.name=lib-nvim-spec",
      "-c",
      "user.email=spec@example.invalid",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "core.autocrlf=false",
      "-C",
      dir,
    }
    vim.list_extend(argv, args)
    local res = vim.system(argv, { text = true }):wait()
    if not allow_fail then
      H.ok(
        res.code == 0,
        ("fixture: git %s failed (%d): %s"):format(table.concat(args, " "), res.code, res.stderr)
      )
    end
    return vim.trim(res.stdout or ""), res.code
  end

  local function write(dir, rel, lines)
    local path = dir .. "/" .. rel
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    H.eq(vim.fn.writefile(lines or { "x" }, path), 0, "fixture: could not write " .. rel)
  end

  --- Paths from git use forward slashes and may differ in case / 8.3 naming
  --- from what `tempname()` returned on Windows.
  local function same_path(a, b)
    a = vim.fs.normalize(vim.uv.fs_realpath(a) or a)
    b = vim.fs.normalize(vim.uv.fs_realpath(b) or b)
    if is_windows then
      return a:lower() == b:lower()
    end
    return a == b
  end

  local function exists(dir, rel)
    return vim.uv.fs_stat(dir .. "/" .. rel) ~= nil
  end

  local function wait_for(pred)
    vim.wait(5000, pred, 10)
    return pred()
  end

  -- ── parse_status: pure ───────────────────────────────────────────────
  local nul = "\0"
  local parsed = git.parse_status(table.concat({
    "?? a b.txt",
    " M plain.txt",
    "R  new name.txt",
    "old name.txt",
    "UU conflict.txt",
    "!! ignored.log",
    " R worktree new.txt",
    "worktree old.txt",
    "C  copy.txt",
    "orig.txt",
    "?? weird -> name.txt",
    "", -- trailing NUL, exactly as git terminates the last entry
  }, nul))

  H.eq(parsed["a b.txt"].code, "??", "parse_status: a path with a space is keyed raw, unquoted")
  H.eq(parsed["plain.txt"].code, " M", "parse_status: ordinary worktree modification")
  H.eq(parsed["plain.txt"].orig_path, nil, "parse_status: ordinary entries have no orig_path")
  H.eq(parsed["new name.txt"].code, "R ", "parse_status: staged rename is keyed by the NEW path")
  H.eq(
    parsed["new name.txt"].orig_path,
    "old name.txt",
    "parse_status: -z puts the destination first, the source second"
  )
  H.eq(parsed["old name.txt"], nil, "parse_status: the rename source is not a key of its own")
  H.eq(parsed["conflict.txt"].code, "UU", "parse_status: unmerged code is preserved")
  H.eq(parsed["ignored.log"].code, "!!", "parse_status: ignored code is preserved")
  H.eq(parsed["worktree new.txt"].orig_path, "worktree old.txt", "parse_status: R in the Y column")
  H.eq(parsed["copy.txt"].orig_path, "orig.txt", "parse_status: copies carry a source path too")
  H.ok(
    parsed["weird -> name.txt"] ~= nil,
    "parse_status: a path that contains ' -> ' is not mistaken for a rename"
  )
  H.eq(vim.tbl_count(parsed), 8, "parse_status: exactly one key per entry, sources excluded")

  H.eq(vim.tbl_count(git.parse_status("")), 0, "parse_status: empty input is an empty map")
  H.eq(vim.tbl_count(git.parse_status(nil)), 0, "parse_status: nil is an empty map, not an error")
  H.eq(
    vim.tbl_count(git.parse_status("x" .. nul .. "ab" .. nul)),
    0,
    "parse_status: malformed short fields are skipped, not misread"
  )

  -- ── a real repository: quoting, nesting, renames ─────────────────────
  local repo = tmpdir("-git-status-repo")
  git_run(repo, { "init", "-q", "-b", "main" })
  write(repo, "a b.txt")
  write(repo, "ü.txt")
  write(repo, "plain.txt")
  write(repo, "sub dir/nested file.txt")

  local untracked = git.status_porcelain({ dir = repo })
  H.ok(untracked ~= nil, "status_porcelain: a repo yields a map")
  H.eq(vim.tbl_count(untracked), 4, "status_porcelain: -u lists untracked files individually")
  for _, rel in ipairs({ "a b.txt", "ü.txt", "plain.txt", "sub dir/nested file.txt" }) do
    H.ok(untracked[rel] ~= nil, "status_porcelain: key is the exact path (" .. rel .. ")")
    H.eq(untracked[rel].code, "??", "status_porcelain: untracked code for " .. rel)
    H.ok(exists(repo, rel), "status_porcelain: the key names a file that exists on disk: " .. rel)
  end

  -- Clean tree first (nothing dirty), then dirty it again.
  git_run(repo, { "add", "-A" })
  git_run(repo, { "commit", "-q", "-m", "initial" })
  H.eq(git.is_dirty({ dir = repo }), false, "is_dirty({dir}): a freshly committed tree is clean")
  local clean = git.status_porcelain({ dir = repo })
  H.ok(clean ~= nil, "status_porcelain: a clean tree is a map, not nil")
  H.eq(vim.tbl_count(clean), 0, "status_porcelain: ...and an empty one")

  -- Read-only queries must not take index.lock or rewrite the index: an
  -- automatic refresh that overlaps the user's own `git commit` would
  -- otherwise make that commit fail with "index.lock exists". Same-content
  -- rewrite = an index entry whose stat data is stale, which is exactly what
  -- a plain `git status` opportunistically refreshes (and writes) the index
  -- for. (The short wait only guarantees a distinct mtime, it awaits nothing.)
  do
    local index_path = repo .. "/.git/index"
    vim.wait(50)
    write(repo, "plain.txt")
    local before = vim.uv.fs_stat(index_path)
    git.is_dirty({ dir = repo })
    git.status_porcelain({ dir = repo })
    local after = vim.uv.fs_stat(index_path)
    H.ok(
      before.mtime.sec == after.mtime.sec
        and before.mtime.nsec == after.mtime.nsec
        and before.size == after.size,
      "status_porcelain/is_dirty: read-only, the index file is left untouched"
    )
  end

  git_run(repo, { "mv", "a b.txt", "c d.txt" })
  git_run(repo, { "mv", "ü.txt", "ö.txt" })
  write(repo, "plain.txt", { "changed" })
  write(repo, "sub dir/nested file.txt", { "changed" })
  local changed = git.status_porcelain({ dir = repo })
  H.eq(changed["c d.txt"].code, "R ", "status_porcelain: a staged rename, new path with a space")
  H.eq(changed["c d.txt"].orig_path, "a b.txt", "status_porcelain: ...its source path is exact too")
  H.eq(changed["ö.txt"].orig_path, "ü.txt", "status_porcelain: rename between non-ASCII names")
  H.ok(exists(repo, "ö.txt"), "status_porcelain: the non-ASCII rename target exists on disk")
  H.eq(changed["plain.txt"].code, " M", "status_porcelain: worktree modification")
  H.eq(changed["ü.txt"], nil, "status_porcelain: a rename source is not a key")
  H.eq(git.is_dirty({ dir = repo }), true, "is_dirty({dir}): a modified tree is dirty")

  -- Paths are repo-root relative even when git is started in a subdirectory.
  local from_sub = git.status_porcelain({ dir = repo .. "/sub dir" })
  H.ok(
    from_sub["sub dir/nested file.txt"] ~= nil,
    "status_porcelain: paths stay repo-root relative when started from a subdirectory"
  )

  -- ── opts.dir targets another repo than the cwd ───────────────────────
  local cwd_status = git.status_porcelain()
  H.ok(cwd_status ~= nil, "status_porcelain: no opts still reads the cwd (this checkout)")
  H.eq(cwd_status["c d.txt"], nil, "status_porcelain: ...and does not see the fixture repo")
  H.ok(
    vim.deep_equal(git.status_porcelain({}), cwd_status),
    "status_porcelain: an empty opts table is the cwd form"
  )

  local here = vim.fn.getcwd()
  H.ok(
    same_path(git.repo_root() or "", git.repo_root({ dir = here }) or ""),
    "repo_root: the no-opts form equals {dir = cwd}"
  )
  H.ok(
    same_path(git.repo_root({ dir = repo .. "/sub dir" }) or "", repo),
    "repo_root({dir}): resolves the root of the TARGET repo from a subdirectory"
  )

  -- ── the other functions that gained opts.dir ─────────────────────────
  H.eq(git.in_git_repo({ dir = repo }), true, "in_git_repo({dir}): inside the fixture repo")
  local not_repo = tmpdir("-not-a-repo")
  H.eq(git.in_git_repo({ dir = not_repo }), false, "in_git_repo({dir}): a plain directory")
  H.eq(
    git.in_git_repo({ dir = not_repo .. "-gone" }),
    false,
    "in_git_repo({dir}): a nonexistent directory is false, not an error"
  )
  H.eq(git.repo_root({ dir = not_repo }), nil, "repo_root({dir}): nil outside a repo")
  H.eq(
    git.is_detached_head({ dir = not_repo }),
    false,
    "is_detached_head({dir}): a non-repo has no HEAD to be detached"
  )

  -- The pre-`opts` calling convention (git_cmd first) must fail loudly: a
  -- string here used to select the git binary, and ignoring it silently would
  -- run the default `git` instead.
  for name, call in pairs({
    current_branch = function()
      return git.current_branch("some-git")
    end,
    status_porcelain = function()
      return git.status_porcelain("some-git")
    end,
    is_tracked = function()
      return git.is_tracked("plain.txt", "some-git")
    end,
  }) do
    local ok_call, call_err = pcall(call)
    H.eq(ok_call, false, name .. ": a string where opts belongs raises")
    H.ok(
      tostring(call_err):find("opts", 1, true) ~= nil,
      name .. ": ...and the message names the parameter"
    )
  end

  H.eq(git.current_branch({ dir = repo }), "main", "current_branch({dir})")
  H.eq(git.is_detached_head({ dir = repo }), false, "is_detached_head({dir}): on a branch")
  local head = git_run(repo, { "rev-parse", "--short", "HEAD" })
  H.eq(git.head_short_hash({ dir = repo }), head, "head_short_hash({dir})")

  H.eq(git.is_tracked("plain.txt", { dir = repo }), true, "is_tracked: relative to opts.dir")
  H.eq(
    git.is_tracked("sub dir/nested file.txt", { dir = repo }),
    true,
    "is_tracked: a path with a space"
  )
  H.eq(git.is_tracked("nope.txt", { dir = repo }), false, "is_tracked: an unknown path")

  -- upstream / ahead_behind need a remote: a local bare repo is enough.
  H.eq(git.upstream({ dir = repo }), nil, "upstream({dir}): nil before a remote exists")
  local ahead0, behind0 = git.ahead_behind({ dir = repo })
  H.ok(ahead0 == false and behind0 == false, "ahead_behind({dir}): false/false without an upstream")

  git_run(repo, { "add", "-A" })
  git_run(repo, { "commit", "-q", "-m", "second" })
  local bare = tmpdir("-bare-remote")
  git_run(bare, { "init", "-q", "--bare", "-b", "main" })
  git_run(repo, { "remote", "add", "origin", bare })
  git_run(repo, { "push", "-q", "-u", "origin", "main" })
  H.eq(git.upstream({ dir = repo }), "origin/main", "upstream({dir}): the tracked remote branch")
  local in_sync_a, in_sync_b = git.ahead_behind({ dir = repo })
  H.ok(
    in_sync_a == false and in_sync_b == false,
    "ahead_behind({dir}): in sync right after the push"
  )
  write(repo, "extra.txt")
  git_run(repo, { "add", "-A" })
  git_run(repo, { "commit", "-q", "-m", "local only" })
  local ahead, behind = git.ahead_behind({ dir = repo })
  H.ok(ahead == true and behind == false, "ahead_behind({dir}): one local commit is ahead")

  git_run(repo, { "checkout", "-q", "--detach" })
  H.eq(git.current_branch({ dir = repo }), nil, "current_branch({dir}): nil when detached")
  H.eq(git.is_detached_head({ dir = repo }), true, "is_detached_head({dir}): detached")

  -- ── a real merge conflict ────────────────────────────────────────────
  local merge = tmpdir("-git-status-merge")
  git_run(merge, { "init", "-q", "-b", "main" })
  write(merge, "my file.txt", { "base" })
  git_run(merge, { "add", "-A" })
  git_run(merge, { "commit", "-q", "-m", "base" })
  git_run(merge, { "checkout", "-q", "-b", "other" })
  write(merge, "my file.txt", { "theirs" })
  git_run(merge, { "commit", "-q", "-am", "theirs" })
  git_run(merge, { "checkout", "-q", "main" })
  write(merge, "my file.txt", { "ours" })
  git_run(merge, { "commit", "-q", "-am", "ours" })
  local _, merge_code = git_run(merge, { "merge", "other" }, true)
  H.ok(merge_code ~= 0, "fixture: the merge must conflict, or this test proves nothing")

  local conflicted = git.status_porcelain({ dir = merge })
  H.ok(conflicted["my file.txt"] ~= nil, "status_porcelain: a conflicted path with a space")
  H.eq(conflicted["my file.txt"].code, "UU", "status_porcelain: both-modified conflict is UU")

  -- ── opts.ignored ──────────────────────────────────────────────────────
  do
    local ig = tmpdir("-git-status-ignored")
    git_run(ig, { "init", "-q", "-b", "main" })
    write(ig, ".gitignore", { "ignored dir/", "*.log" })
    write(ig, "kept.txt")
    write(ig, "debug.log")
    vim.fn.mkdir(ig .. "/ignored dir", "p")
    write(ig, "ignored dir/inside.txt")

    local plain = git.status_porcelain({ dir = ig })
    H.ok(plain ~= nil, "status_porcelain: ignored fixture yields a map")
    H.eq(
      plain["debug.log"],
      nil,
      "status_porcelain: without opts.ignored, an ignored file is absent"
    )
    H.eq(
      plain["ignored dir/inside.txt"],
      nil,
      "status_porcelain: without opts.ignored, an ignored directory's content is absent"
    )
    H.ok(plain["kept.txt"] ~= nil, "status_porcelain: a tracked-candidate file is still listed")

    local with_ignored = git.status_porcelain({ dir = ig, ignored = true })
    H.ok(with_ignored ~= nil, "status_porcelain({ignored=true}): still yields a map")
    H.eq(
      with_ignored["debug.log"] and with_ignored["debug.log"].code,
      "!!",
      "status_porcelain({ignored=true}): an ignored file is listed with code !!"
    )
    H.eq(
      with_ignored["ignored dir/inside.txt"] and with_ignored["ignored dir/inside.txt"].code,
      "!!",
      "status_porcelain({ignored=true}): an ignored directory reports its content, with a space in the dir name"
    )

    local done, async_map = false, nil
    git.status_porcelain_async({ dir = ig, ignored = true }, function(map)
      done, async_map = true, map
    end)
    H.ok(
      wait_for(function()
        return done
      end),
      "status_porcelain_async({ignored=true}): on_done fires"
    )
    H.ok(
      vim.deep_equal(async_map, with_ignored),
      "status_porcelain_async({ignored=true}): same map as the synchronous call"
    )
  end

  -- ── failure shape ────────────────────────────────────────────────────
  local none, err = git.status_porcelain({ dir = not_repo })
  H.eq(none, nil, "status_porcelain: outside a repo is nil, not an empty map")
  H.ok(
    type(err) == "string" and #err > 0 and err ~= "git status failed",
    "status_porcelain: ...and says why with git's reason, not the generic text, got "
      .. tostring(err)
  )
  local ok_call, gone = pcall(git.status_porcelain, { dir = not_repo .. "-gone" })
  H.ok(ok_call and gone == nil, "status_porcelain: a nonexistent directory does not raise")

  -- A git that cannot even be spawned reports why, not a generic message.
  local no_bin, no_bin_err =
    git.status_porcelain({ dir = repo }, "definitely-not-a-git-binary-lib-nvim-spec")
  H.eq(no_bin, nil, "status_porcelain: an unspawnable git is nil")
  H.ok(
    type(no_bin_err) == "string" and no_bin_err ~= "git status failed",
    "status_porcelain: ...with the spawn failure as the error, not the generic fallback"
  )

  -- ── async ────────────────────────────────────────────────────────────
  do
    local done, amap, aerr = false, nil, nil
    git.status_porcelain_async({ dir = merge }, function(map, e)
      done, amap, aerr = true, map, e
    end)
    H.ok(
      wait_for(function()
        return done
      end),
      "status_porcelain_async: on_done fires"
    )
    H.eq(aerr, nil, "status_porcelain_async: no error for a repo")
    H.ok(
      vim.deep_equal(amap, conflicted),
      "status_porcelain_async: same map as the synchronous call"
    )
  end

  do
    local done, amap, aerr = false, "unset", nil
    git.status_porcelain_async({ dir = not_repo }, function(map, e)
      done, amap, aerr = true, map, e
    end)
    H.ok(
      wait_for(function()
        return done
      end),
      "status_porcelain_async: on_done fires on failure too"
    )
    H.eq(amap, nil, "status_porcelain_async: outside a repo is nil")
    H.ok(
      type(aerr) == "string" and #aerr > 0 and aerr ~= "git status failed",
      "status_porcelain_async: ...with git's reason, not the generic text, got " .. tostring(aerr)
    )
  end

  do
    -- opts may be nil: the callback-first form a caller with no dir uses.
    local done = false
    git.status_porcelain_async(nil, function()
      done = true
    end)
    H.ok(
      wait_for(function()
        return done
      end),
      "status_porcelain_async: opts = nil reads the cwd"
    )
  end

  -- Best-effort cleanup; on Windows a just-used .git can hold read-only files,
  -- and a leftover temp directory is not a test failure.
  for _, dir in ipairs(created) do
    pcall(vim.fn.delete, dir, "rf")
  end
end
