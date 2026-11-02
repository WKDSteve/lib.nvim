-- TESTS/mutate_spec.lua — lib.nvim.cross.fs.mutate
--
-- The interesting behavior here (retry on a transient Windows sharing
-- error, escalating backoff, on_retry hooks) can't wait on a *real*
-- EPERM/EACCES/EBUSY lock in a headless test without being slow and
-- flaky. M.retry takes an arbitrary `op` function though, so a lock is
-- simulated by an op that returns a transient-looking error N times
-- before succeeding -- deterministic, and it exercises the exact same
-- retry/backoff/on_retry code path a real Windows sharing violation would.

return function(H)
  local eq, ok = H.eq, H.ok

  local mutate = require("lib.nvim.cross.fs.mutate")

  -- ------------------------------------------------------------ M.retry

  -- Succeeds first try: op called once, no retry machinery engaged.
  do
    local calls = 0
    local result_ok, result_err = mutate.retry(function()
      calls = calls + 1
      return true, nil
    end, { attempts = 3, backoff_ms = 1 })
    eq(result_ok, true, "retry: immediate success reports ok")
    eq(result_err, nil, "retry: immediate success has no error")
    eq(calls, 1, "retry: immediate success calls op exactly once")
  end

  -- Simulated lock: fails with a transient error twice, then succeeds --
  -- the shape of "an AV scanner briefly held the handle, then let go".
  do
    local calls = 0
    local retry_log = {}
    local result_ok, result_err = mutate.retry(function()
      calls = calls + 1
      if calls <= 2 then
        return false, "EBUSY: resource busy or locked"
      end
      return true, nil
    end, {
      attempts = 5,
      backoff_ms = 1,
      on_retry = function(attempt, err)
        retry_log[#retry_log + 1] = { attempt = attempt, err = err }
      end,
    })
    eq(result_ok, true, "retry: succeeds once the simulated lock clears")
    eq(result_err, nil, "retry: no error once it eventually succeeds")
    eq(calls, 3, "retry: stops calling op as soon as it succeeds (2 failures + 1 success)")
    eq(#retry_log, 2, "retry: on_retry fires once per failed attempt, not on the final success")
    eq(retry_log[1].attempt, 1, "retry: on_retry reports the 1-based attempt number")
    eq(retry_log[2].attempt, 2, "retry: on_retry reports each subsequent attempt")
  end

  -- Simulated permanent lock: transient error on every attempt -> gives up
  -- after `attempts`, reporting the last attempt's error.
  do
    local calls = 0
    local result_ok, result_err = mutate.retry(function()
      calls = calls + 1
      return false, ("EPERM: attempt %d"):format(calls)
    end, { attempts = 3, backoff_ms = 1 })
    eq(result_ok, false, "retry: exhausting all attempts reports failure")
    eq(calls, 3, "retry: tries exactly `attempts` times, no more")
    eq(result_err, "EPERM: attempt 3", "retry: reports the FINAL attempt's error, not the first")
  end

  -- A non-transient error (e.g. the path genuinely does not exist) must
  -- not be retried at all -- retrying can't fix "file not found", and
  -- burning `attempts * backoff` on it would just make every ordinary
  -- error slow.
  do
    local calls = 0
    local result_ok, result_err = mutate.retry(function()
      calls = calls + 1
      return false, "ENOENT: no such file or directory"
    end, { attempts = 5, backoff_ms = 1 })
    eq(result_ok, false, "retry: a non-transient error still fails")
    eq(calls, 1, "retry: a non-transient error is NOT retried, even with attempts > 1")
    eq(
      result_err,
      "ENOENT: no such file or directory",
      "retry: the non-transient error passes through unchanged"
    )
  end

  -- on_retry is never called when there's nothing to retry (immediate
  -- success, or a non-transient error on the first try).
  do
    local retry_fired = false
    mutate.retry(function()
      return false, "ENOENT: gone"
    end, {
      attempts = 3,
      backoff_ms = 1,
      on_retry = function()
        retry_fired = true
      end,
    })
    eq(retry_fired, false, "retry: on_retry does not fire for a non-transient error")
  end

  -- `defaults` exists and is a sane baseline the primitives fall back to
  -- when a call site passes no opts at all.
  ok(
    type(mutate.defaults.attempts) == "number" and mutate.defaults.attempts >= 1,
    "defaults.attempts is a positive number"
  )
  ok(
    type(mutate.defaults.backoff_ms) == "number" and mutate.defaults.backoff_ms > 0,
    "defaults.backoff_ms is a positive number"
  )

  -- --------------------------------------------------- real-file smoke tests
  --
  -- The four primitives are thin `retry(function() return uv().fs_x(...) end)`
  -- wrappers; the retry logic above is what's actually load-bearing, but a
  -- quick real-filesystem pass confirms the wiring (right libuv call, right
  -- (ok, err) shape) is intact end to end.

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")

  local src = dir .. "/a.txt"
  local f = assert(io.open(src, "w"))
  f:write("hello")
  f:close()

  local copy_ok = mutate.copy_file(src, dir .. "/b.txt")
  eq(copy_ok, true, "copy_file: copies an existing file")
  local cf = assert(io.open(dir .. "/b.txt", "r"))
  eq(cf:read("*a"), "hello", "copy_file: content matches the source")
  cf:close()

  local rename_ok = mutate.rename_file(dir .. "/b.txt", dir .. "/c.txt")
  eq(rename_ok, true, "rename_file: renames an existing file")
  eq((vim.uv or vim.loop).fs_stat(dir .. "/b.txt"), nil, "rename_file: old path no longer exists")
  ok((vim.uv or vim.loop).fs_stat(dir .. "/c.txt") ~= nil, "rename_file: new path exists")

  local delete_ok = mutate.delete_file(dir .. "/c.txt")
  eq(delete_ok, true, "delete_file: deletes an existing file")
  eq((vim.uv or vim.loop).fs_stat(dir .. "/c.txt"), nil, "delete_file: path is gone")

  local delete_missing_ok, delete_missing_err = mutate.delete_file(dir .. "/does-not-exist.txt")
  eq(delete_missing_ok, false, "delete_file: a missing path fails")
  ok(delete_missing_err ~= nil, "delete_file: a missing path reports an error")

  local nested = dir .. "/x/y/z"
  local mkdirp_ok = mutate.mkdir_p(nested)
  eq(mkdirp_ok, true, "mkdir_p: creates a nested directory tree")
  eq(vim.fn.isdirectory(nested), 1, "mkdir_p: the deepest directory exists")

  local mkdirp_again_ok = mutate.mkdir_p(nested)
  eq(mkdirp_again_ok, true, "mkdir_p: re-creating an already-existing directory is still ok")

  -- A race with another process that makes the same folder: Vim's mkdir loses and raises E739 although the folder
  -- is there. That is the folder that was asked for, so it is ok; a real failure (a file in the way) still is not.
  do
    local raced = dir .. "/raced/inner"
    local real_mkdir = vim.fn.mkdir
    local raced_ok, raced_err
    H.with_patched(vim.fn, "mkdir", function(path)
      vim.fn.delete(path, "rf")
      real_mkdir(path, "p") -- the other process wins
      error("Vim:E739: Cannot create directory " .. path .. ": file already exists")
    end, function()
      raced_ok, raced_err = mutate.mkdir_p(raced)
    end)
    eq(raced_ok, true, "mkdir_p: losing a race for the folder is ok")
    eq(raced_err, nil, "mkdir_p: ... and says nothing")
    eq(vim.fn.isdirectory(raced), 1, "mkdir_p: ... the folder is there")

    -- The race is lost on a PARENT: the other process made `parent`, this call has not made the rest of the chain.
    local parent = dir .. "/raced-parent"
    local deep = parent .. "/a/b"
    vim.fn.delete(parent, "rf")
    local calls = 0
    local parent_ok, parent_err
    H.with_patched(vim.fn, "mkdir", function(path, flags)
      calls = calls + 1
      if calls == 1 then
        real_mkdir(parent, "p")
        error("Vim:E739: Cannot create directory " .. parent .. ": file already exists")
      end
      return real_mkdir(path, flags)
    end, function()
      parent_ok, parent_err = mutate.mkdir_p(deep)
    end)
    eq(parent_ok, true, "mkdir_p: losing a race for a parent is ok, the rest of the chain is made")
    eq(parent_err, nil, "mkdir_p: ... and says nothing")
    eq(vim.fn.isdirectory(deep), 1, "mkdir_p: ... the whole chain is there")

    -- Many processes at once: the race is lost twice in a row, on a different link each time.
    local multi = dir .. "/raced-multi"
    local multi_deep = multi .. "/a/b/c"
    vim.fn.delete(multi, "rf")
    local lost = { multi, multi .. "/a" }
    calls = 0
    local multi_ok, multi_err
    H.with_patched(vim.fn, "mkdir", function(path, flags)
      calls = calls + 1
      local link = lost[calls]
      if link then
        real_mkdir(link, "p")
        error("Vim:E739: Cannot create directory " .. link .. ": file already exists")
      end
      return real_mkdir(path, flags)
    end, function()
      multi_ok, multi_err = mutate.mkdir_p(multi_deep)
    end)
    eq(multi_ok, true, "mkdir_p: losing the race twice on different links is ok")
    eq(multi_err, nil, "mkdir_p: ... and says nothing")
    eq(vim.fn.isdirectory(multi_deep), 1, "mkdir_p: ... the whole chain is there")

    -- No new link since the last try (a permission failure, the chain stays the same): the loop ends at once with
    -- the error instead of trying as often as the path has links.
    local stuck = dir .. "/stuck/a/b/c/d"
    calls = 0
    local stuck_ok, stuck_err
    H.with_patched(vim.fn, "mkdir", function(path)
      calls = calls + 1
      error("Vim:E739: Cannot create directory " .. path .. ": permission denied")
    end, function()
      stuck_ok, stuck_err = mutate.mkdir_p(stuck)
    end)
    eq(stuck_ok, false, "mkdir_p: a chain that does not grow is an error")
    ok(
      tostring(stuck_err):find("permission denied", 1, true),
      "mkdir_p: ... with the reason of the last try"
    )
    eq(calls, 2, "mkdir_p: ... after the first try and one retry, not one per link")

    local blocker = dir .. "/blocker"
    local fh = assert(io.open(blocker, "wb"))
    fh:write("a file")
    fh:close()
    local blocked_ok, blocked_err = mutate.mkdir_p(blocker .. "/below")
    eq(blocked_ok, false, "mkdir_p: a file in the way is still an error")
    ok(blocked_err ~= nil, "mkdir_p: ... with its reason")
  end

  -- ------------------------------------------------------------------- rmdir

  local empty_dir = dir .. "/to-remove"
  vim.fn.mkdir(empty_dir, "p")
  local rmdir_ok = mutate.rmdir(empty_dir)
  eq(rmdir_ok, true, "rmdir: removes an existing empty directory")
  eq(vim.fn.isdirectory(empty_dir), 0, "rmdir: the directory is actually gone")

  local rmdir_missing_ok, rmdir_missing_err = mutate.rmdir(dir .. "/does-not-exist-dir")
  eq(rmdir_missing_ok, false, "rmdir: a missing path fails")
  ok(rmdir_missing_err ~= nil, "rmdir: a missing path reports an error")

  local non_empty_dir = dir .. "/not-empty"
  vim.fn.mkdir(non_empty_dir, "p")
  local nef = assert(io.open(non_empty_dir .. "/x.txt", "w"))
  nef:write("x")
  nef:close()
  local rmdir_nonempty_ok = mutate.rmdir(non_empty_dir)
  eq(rmdir_nonempty_ok, false, "rmdir: a non-empty directory fails (matches plain rmdir semantics)")

  -- ------------------------------------------------------------- symlink/hardlink
  --
  -- Windows symlink creation needs either Developer Mode or an elevated
  -- process (SeCreateSymbolicLinkPrivilege) -- CI/sandboxed runs commonly
  -- have neither. Skip rather than fail on a privilege the test can't grant
  -- itself; the real assertion (right libuv call, right (ok, err) shape) is
  -- still exercised on every POSIX runner and any dev machine with the
  -- privilege.
  local link_src = dir .. "/link_src.txt"
  local lf = assert(io.open(link_src, "w"))
  lf:write("hi")
  lf:close()

  local symlink_ok, symlink_err = mutate.symlink(link_src, dir .. "/link_sym.txt", false)
  if symlink_ok then
    -- Compare separator-insensitively: `link_src` is hand-joined with "/" onto
    -- a tempname() that is already backslashed on Windows, while fs_readlink
    -- hands back the path the OS canonicalized when it wrote the reparse point
    -- (all-backslash). The two spellings name the same file, so the assertion
    -- is about the *target*, not about which slash the platform prefers.
    local unify_slashes = require("lib.nvim.cross.fs.separators.unify_slashes")
    eq(
      unify_slashes(assert((vim.uv or vim.loop).fs_readlink(dir .. "/link_sym.txt"))),
      unify_slashes(link_src),
      "symlink: created link points at the target"
    )
  else
    print("  note symlink() unavailable in this environment, skipping: " .. tostring(symlink_err))
  end

  local hardlink_ok = mutate.hardlink(link_src, dir .. "/link_hard.txt")
  eq(hardlink_ok, true, "hardlink: creates a hard link to an existing file")
  local hf = assert(io.open(dir .. "/link_hard.txt", "r"))
  eq(hf:read("*a"), "hi", "hardlink: content matches the target")
  hf:close()

  local hardlink_missing_ok, hardlink_missing_err =
    mutate.hardlink(dir .. "/does-not-exist.txt", dir .. "/link_hard2.txt")
  eq(hardlink_missing_ok, false, "hardlink: a missing target fails")
  ok(hardlink_missing_err ~= nil, "hardlink: a missing target reports an error")
end
