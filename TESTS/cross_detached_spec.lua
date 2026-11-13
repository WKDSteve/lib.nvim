-- TESTS/cross_detached_spec.lua -- lib.nvim.cross.detached: the register of detached processes.
--
-- A real child (a headless Neovim that sleeps) stands in for the detached process, and a short-lived one for the
-- owner that is gone. The register file is redirected to a scratch directory so the user's own is never touched.

return function(H)
  local eq, ok = H.eq, H.ok
  local detached = require("lib.nvim.cross.detached")
  local run = require("lib.nvim.cross.run")
  local uv = vim.uv or vim.loop

  ---A file's content, with the handle closed again (Windows will not rename over a file that is still open).
  local function slurp(p)
    local f = assert(io.open(p, "rb"))
    local text = f:read("*a")
    f:close()
    return text
  end

  local state = vim.fn.tempname() .. "_detached_state"
  vim.fn.mkdir(state, "p")
  local real_stdpath = vim.fn.stdpath
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.stdpath = function(what)
    if what == "state" then
      return state
    end
    return real_stdpath(what)
  end

  ---A child that lives for a while; killed at the end whatever the spec did.
  local children = {}
  local function sleeper()
    local obj = vim.system(
      { vim.v.progpath, "--headless", "-u", "NONE", "-c", "sleep 60", "-c", "qa!" },
      { detach = vim.fn.has("win32") == 0 }
    )
    children[#children + 1] = obj
    vim.wait(100)
    return obj.pid
  end
  local function gone(pid)
    return vim.wait(8000, function()
      return not detached.is_alive(pid)
    end, 50)
  end

  ---Force the jobstart path of run_detached and answer every jobstart with `id`; undone by unstub_jobstart.
  local WIN = "lib.nvim.cross.platform.is_windows"
  local real_is_windows, real_jobstart
  local function stub_jobstart(id)
    real_is_windows, real_jobstart = package.loaded[WIN], vim.fn.jobstart
    package.loaded[WIN] = function()
      return true
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.jobstart = function()
      return id
    end
  end
  local function unstub_jobstart()
    if real_jobstart then
      package.loaded[WIN], vim.fn.jobstart = real_is_windows, real_jobstart
      real_is_windows, real_jobstart = nil, nil
    end
  end

  local function body()
    -- is_alive
    ok(detached.is_alive(uv.os_getpid()), "is_alive: this process")
    ok(not detached.is_alive(0), "is_alive: pid 0 is nothing")
    ok(not detached.is_alive(-5), "is_alive: a negative pid is nothing")
    ok(not detached.is_alive("x"), "is_alive: a string is nothing")

    -- a dead owner: a process that ended
    local owner = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-c", "qa!" })
    local dead_pid = owner.pid
    ok(owner:wait().code == 0, "the short-lived owner ran")
    ok(not detached.is_alive(dead_pid), "...and is gone")

    -- track / list
    local child = sleeper()
    ok(detached.is_alive(child), "the child runs")
    ok(detached.track(child, { name = "spec-sleeper", cmd = "nvim sleep" }), "track records it")
    local listed = detached.list()
    eq(#listed, 1, "list: one process")
    eq(listed[1].pid, child, "list: its pid")
    eq(listed[1].name, "spec-sleeper", "list: its name")
    eq(listed[1].orphan, false, "list: our own child is not an orphan (we are its owner and alive)")
    eq(#detached.list({ orphans = true }), 0, "list: no orphans yet")

    -- an orphan: the same process, owned by a dead Neovim
    local path = detached.path()
    local data = vim.json.decode(slurp(path))
    data.entries[1].owner = dead_pid
    local w = assert(io.open(path, "wb"))
    w:write(vim.json.encode(data))
    w:close()
    local orphans = detached.list({ orphans = true })
    eq(#orphans, 1, "list: a process whose owner is gone is an orphan")
    eq(orphans[1].orphan, true, "list: flagged as such")

    -- kill refuses what is not registered
    local other = sleeper()
    local refused, why = detached.kill(other)
    eq(refused, false, "kill: an unregistered pid is refused")
    ok(tostring(why):find("not in the register", 1, true) ~= nil, "kill: ...and says why")
    ok(detached.is_alive(other), "kill: ...and it is still running")

    -- kill_orphans asks per orphan; a no kills nothing
    local asked = 0
    eq(
      detached.kill_orphans(function()
        asked = asked + 1
        return false
      end),
      0,
      "kill_orphans: a no kills nothing"
    )
    eq(asked, 1, "kill_orphans: asked once")
    ok(detached.is_alive(child), "kill_orphans: ...the orphan still runs")

    eq(
      detached.kill_orphans(function(e)
        return e.pid == child
      end),
      1,
      "kill_orphans: a yes kills it"
    )
    ok(gone(child), "kill_orphans: the process is gone")
    eq(#detached.list(), 0, "kill_orphans: ...and it left the register")

    -- a process that died on its own drops out of the register on list
    local mortal = sleeper()
    detached.track(mortal, { name = "mortal" })
    for _, c in ipairs(children) do
      if c.pid == mortal then
        c:kill(9)
      end
    end
    ok(gone(mortal), "the mortal process ended")
    eq(#detached.list(), 0, "list: a dead process is not listed")
    eq(#vim.json.decode(slurp(path)).entries, 0, "list: ...and was dropped from the file")

    -- old entries are forgotten, not listed
    local old = sleeper()
    detached.track(old, { name = "old" })
    local d = vim.json.decode(slurp(path))
    d.entries[1].started = os.time() - (detached.MAX_AGE_DAYS + 1) * 86400
    local w2 = assert(io.open(path, "wb"))
    w2:write(vim.json.encode(d))
    w2:close()
    eq(
      #detached.list(),
      0,
      "list: an entry past MAX_AGE_DAYS is not trusted (the pid may be reused)"
    )

    -- untrack
    local t = sleeper()
    detached.track(t, { name = "t" })
    ok(detached.untrack(t), "untrack: removes it")
    ok(not detached.untrack(t), "untrack: a second time finds nothing")

    -- run_detached records only when asked
    local before = #detached.list()
    ok(
      run.run_detached({ vim.v.progpath, "--headless", "-u", "NONE", "-c", "sleep 15", "-c", "qa!" })
    )
    vim.wait(200)
    eq(#detached.list(), before, "run_detached: nothing is registered unless asked")
    ok(
      run.run_detached(
        { vim.v.progpath, "--headless", "-u", "NONE", "-c", "sleep 60", "-c", "qa!" },
        { track = "spec-run" }
      )
    )
    vim.wait(200)
    local tracked = detached.list()
    eq(#tracked, before + 1, "run_detached: { track = name } registers it")
    local entry = tracked[#tracked]
    eq(entry.name, "spec-run", "run_detached: under that name")
    ok(entry.cmd:find("sleep 60", 1, true) ~= nil, "run_detached: with its command line")
    ok(detached.kill(entry.pid), "kill: a registered process ends")
    ok(gone(entry.pid), "kill: ...and is gone")

    -- run_detached on a process that exits at once: launching it never raises, tracked or not
    local quick = { vim.v.progpath, "--headless", "-u", "NONE", "-c", "qa!" }
    eq(run.run_detached(quick), true, "run_detached: a process that exits at once")
    eq(
      run.run_detached(quick, { track = "spec-quick" }),
      true,
      "run_detached: ...also when tracked"
    )

    -- the jobstart path (Windows/WSL) with a jobstart that answers a fake id, as callers' specs stub it
    -- (filetree.nvim TESTS/gaps.lua): no live channel stands behind the id, so jobpid() raises E900. That
    -- must neither abort an untracked launch (which never needs the pid) nor a tracked one.
    local FAKE_JOB = 4242
    local before_fake = #detached.list()
    stub_jobstart(FAKE_JOB)
    local untracked_ok, untracked = pcall(run.run_detached, { "fake-gui.exe" })
    eq(untracked_ok, true, "run_detached: a fake job id does not raise: " .. tostring(untracked))
    eq(untracked, true, "run_detached: ...and the launch counts as done")
    local tracked_ok, tracked_res = pcall(
      run.run_detached,
      { "fake-gui.exe" },
      { track = "spec-fake" }
    )
    eq(
      tracked_ok,
      true,
      "run_detached: tracked, a fake job id does not raise: " .. tostring(tracked_res)
    )
    eq(tracked_res, true, "run_detached: ...and the launch counts as done")
    unstub_jobstart()
    eq(#detached.list(), before_fake, "run_detached: no pid, nothing registered")
  end

  local finished, err = pcall(body)
  unstub_jobstart()
  vim.fn.stdpath = real_stdpath
  for _, c in ipairs(children) do
    pcall(function()
      c:kill(9)
    end)
  end
  vim.fn.delete(state, "rf")
  if not finished then
    error(err, 0)
  end
end
