-- TESTS/lock_spec.lua — lib.nvim.cross.fs.lock
--
-- A real sharing violation cannot be provoked from inside this process:
-- libuv opens files with FILE_SHARE_DELETE, so nothing we can open here
-- would block our own rename. Holding one from a second process would make
-- the suite slow, Windows-only and dependent on a spawned helper staying
-- alive. So the *probe* is tested against real files (it is pure libuv and
-- fully deterministic), and the holder lookup is tested for its contract:
-- platform gating, parsing, and never leaving the file parked aside.

return function(H)
  local eq, ok = H.eq, H.ok

  local lock = require("lib.nvim.cross.fs.lock")
  local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = dir .. "/"

  ---@param path string
  ---@param text string
  local function write_file(path, text)
    vim.fn.writefile({ text }, path)
  end

  -- ------------------------------------------------------------- M.probe

  -- An unlocked file probes clean AND survives unchanged: the probe renames
  -- it aside, so a bug here would silently park the user's file under
  -- ".libnvim-lockprobe" — the one failure mode this module must never have.
  do
    local path = dir .. "unlocked.txt"
    write_file(path, "payload")

    local pok, perr = lock.probe(path)
    eq(pok, true, "probe: an unlocked file is renameable")
    eq(perr, nil, "probe: no error for an unlocked file")
    eq(vim.fn.filereadable(path), 1, "probe: file is restored under its original name")
    eq(vim.fn.filereadable(path .. ".libnvim-lockprobe"), 0, "probe: no probe artifact left behind")
    eq(table.concat(vim.fn.readfile(path), "\n"), "payload", "probe: content untouched")
  end

  -- A missing file is a failure, not a crash, and reports libuv's own code.
  do
    local pok, perr = lock.probe(dir .. "does_not_exist.txt")
    eq(pok, false, "probe: a missing file cannot be renamed")
    ok(tostring(perr):match("^ENOENT") ~= nil, "probe: surfaces the libuv code: " .. tostring(perr))
  end

  -- ---------------------------------------------------------- M.supported

  eq(lock.supported(), is_windows, "supported() tracks the platform")

  -- ----------------------------------------------------------- M.who / report

  -- Off Windows the lookup must fail loudly rather than pretend nothing holds
  -- the file — "no holders" and "cannot tell" are different answers.
  if not is_windows then
    local called, got_holders, got_err = false, nil, nil
    lock.who(dir .. "unlocked.txt", function(h, e)
      called, got_holders, got_err = true, h, e
    end)
    eq(called, true, "who: calls back synchronously when unsupported")
    eq(got_holders, nil, "who: no holder list off Windows")
    ok(got_err ~= nil, "who: reports why the lookup is unavailable")
  else
    -- On Windows the query is a real PowerShell round-trip. An unlocked file
    -- must come back with an empty list (not an error), which also proves the
    -- "NO_HOLDER" sentinel is understood.
    local path = dir .. "unlocked.txt"
    local done, holders, werr = false, nil, nil
    lock.who(path, function(h, e)
      holders, werr, done = h, e, true
    end)
    -- Wait on the callback, not on a clock: a cold PowerShell on a loaded CI
    -- runner has needed far longer than the desktop's second or two (the
    -- lookup flaked at 20 s). `who` kills the process and answers with an
    -- error at its own 60 s timeout, so 90 s only ever expires when the
    -- callback truly never comes -- which still fails this spec.
    vim.wait(90000, function()
      return done
    end, 20)
    eq(done, true, "who: the lookup calls back within the timeout")
    eq(werr, nil, "who: an unlocked file is not an error: " .. tostring(werr))
    ok(type(holders) == "table" and #holders == 0, "who: an unlocked file has no holders")

    -- The lookup runs in its own folder: started from Neovim's cwd it held
    -- that folder (on Windows a cwd is a handle), which is the case folder a
    -- caller has just failed to move, and blocked the user's next try.
    do
      local seen
      H.with_patched(vim, "system", function(_, opts, on_exit)
        seen = opts
        on_exit({ code = 0, stdout = "NO_HOLDER", stderr = "" })
        return {}
      end, function()
        lock.who(path, function() end)
      end)
      ok(type(seen) == "table" and type(seen.cwd) == "string", "who: the lookup gets a cwd")
      ok(
        vim.fs.normalize(seen.cwd):lower() ~= vim.fs.normalize(vim.fn.getcwd()):lower(),
        "who: the lookup does not run in Neovim's cwd: " .. tostring(seen and seen.cwd)
      )
    end

    -- The timeout is the lookup's own: a lookup that cannot finish in time is
    -- answered with an error rather than never.
    local tdone, tholders, terr = false, nil, nil
    lock.who(path, function(h, e)
      tholders, terr, tdone = h, e, true
    end, { timeout = 1 })
    vim.wait(90000, function()
      return tdone
    end, 20)
    eq(tdone, true, "who: a timed-out lookup still calls back")
    eq(tholders, nil, "who: a timed-out lookup has no holder list")
    ok(
      tostring(terr):find("timed out", 1, true) ~= nil,
      "who: the error says it timed out: " .. tostring(terr)
    )
  end

  -- report() stitches probe + holders into one block regardless of platform.
  do
    local path = dir .. "unlocked.txt"
    local lines, done = nil, false
    lock.report(path, function(l)
      lines, done = l, true
    end)
    vim.wait(90000, function()
      return done
    end, 20)
    eq(done, true, "report: calls back")
    local text = table.concat(lines or {}, "\n")
    ok(text:find("rename probe:", 1, true) ~= nil, "report: includes the probe section")
    ok(text:find(path, 1, true) ~= nil, "report: names the path")
    if is_windows then
      ok(text:find("handle holders", 1, true) ~= nil, "report: includes the holder section")
    end
  end

  -- The probe must not disturb an open uv handle on an unrelated file, i.e.
  -- it acts on exactly the path it was given.
  do
    local neighbour = dir .. "neighbour.txt"
    write_file(neighbour, "keep")
    local target = dir .. "target.txt"
    write_file(target, "move me")
    lock.probe(target)
    eq(vim.fn.filereadable(neighbour), 1, "probe: leaves neighbouring files alone")
    eq(table.concat(vim.fn.readfile(neighbour), "\n"), "keep", "probe: neighbour content untouched")
  end
end
