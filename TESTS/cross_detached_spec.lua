-- TESTS/cross_detached_spec.lua -- lib.nvim.cross.detached: the register of detached processes.
--
-- A real child (a headless Neovim that sleeps) stands in for the detached process, and a short-lived one for the
-- owner that is gone. The register file is redirected to a scratch directory so the user's own is never touched.

return function(H)
  local eq, ok = H.eq, H.ok
  local detached = require("lib.nvim.cross.detached")
  local run = require("lib.nvim.cross.run")
  local uv = vim.uv or vim.loop
  local spec_dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

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

    -- start_time: what tells a reused pid from the registered process
    local own_start = detached.start_time(uv.os_getpid())
    ok(type(own_start) == "number", "start_time: this process has one: " .. tostring(own_start))
    ok(
      own_start <= os.time() + detached.START_TOLERANCE and own_start > os.time() - 86400,
      "start_time: ...a recent one in seconds since the epoch: " .. tostring(own_start)
    )
    eq(detached.start_time(0), nil, "start_time: pid 0 has none")
    eq(detached.start_time("x"), nil, "start_time: a string has none")

    -- start_time with the same C functions already declared by someone else in the process, as testing.nvim's
    -- testing.child.winproc does (its own FILETIME struct): the full suite loads it through
    -- notify_popup_fallback_spec, and then every start time read nil and list() came back empty. A child Neovim
    -- so the foreign declarations come first whatever this suite loaded before.
    local root = vim.fs.normalize(vim.fn.fnamemodify(spec_dir .. "..", ":p")):gsub("/$", "")
    local probe = vim.fn.tempname() .. "_foreign_cdef.lua"
    local pf = assert(io.open(probe, "wb"))
    pf:write(table.concat({
      'local ffi = require("ffi")',
      'pcall(ffi.cdef, "struct spec_foreign_ft { uint32_t a; uint32_t b; };")',
      'pcall(ffi.cdef, "void *OpenProcess(uint32_t a, int i, uint32_t p);")',
      'pcall(ffi.cdef, "int CloseHandle(void *h);")',
      'pcall(ffi.cdef, "int GetProcessTimes(void *h, struct spec_foreign_ft *c, struct spec_foreign_ft *e,'
        .. ' struct spec_foreign_ft *k, struct spec_foreign_ft *u);")',
      'pcall(ffi.cdef, "int sysconf(long n);")',
      "vim.opt.rtp:append(" .. string.format("%q", root) .. ")",
      'local state = vim.fn.tempname() .. "_detached_probe"',
      "vim.fn.stdpath = function() return state end",
      'local d = require("lib.nvim.cross.detached")',
      "local pid = (vim.uv or vim.loop).os_getpid()",
      "local st = d.start_time(pid)",
      'd.track(pid, { name = "probe" })',
      'io.stdout:write(tostring(st), " ", #d.list(), "\\n")',
      'vim.fn.delete(state, "rf")',
    }, "\n"))
    pf:close()
    local res = vim
      .system({ vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", probe }, {
        text = true,
      })
      :wait(30000)
    vim.fn.delete(probe)
    local probe_start, probe_listed = (res.stdout or ""):match("(%S+) (%d+)")
    ok(
      tonumber(probe_start) ~= nil,
      "start_time: still read when the C functions were declared elsewhere first: "
        .. vim.inspect({ code = res.code, stdout = res.stdout, stderr = res.stderr })
    )
    eq(probe_listed, "1", "list: ...and a tracked process is listed then")

    ---Rewrite the register file's entries in place.
    local function rewrite(fn)
      local doc = vim.json.decode(slurp(path))
      fn(doc.entries)
      local fw = assert(io.open(path, "wb"))
      fw:write(vim.json.encode(doc))
      fw:close()
    end

    local reused = sleeper()
    local reused_start = detached.start_time(reused)
    ok(
      type(reused_start) == "number" and reused_start >= own_start - detached.START_TOLERANCE,
      "start_time: a child started after us: " .. tostring(reused_start)
    )
    detached.track(reused, { name = "reused" })
    local recorded = vim.json.decode(slurp(path)).entries[1].proc_start
    ok(
      type(recorded) == "number" and math.abs(recorded - reused_start) < 0.01,
      "track: records the start time: " .. tostring(recorded)
    )

    -- a reused pid: a live process under the pid, but not the one that started when the entry says
    rewrite(function(es)
      es[1].proc_start = es[1].proc_start - 3600
    end)
    eq(#detached.list(), 0, "list: a pid whose start time differs is not listed")
    eq(#vim.json.decode(slurp(path)).entries, 0, "list: ...and drops out of the register")
    detached.track(reused, { name = "reused" })
    rewrite(function(es)
      es[1].proc_start = es[1].proc_start - 3600
    end)
    local refused_reuse, why_reuse = detached.kill(reused)
    eq(refused_reuse, false, "kill: a pid whose start time differs is refused")
    ok(tostring(why_reuse):find("start time", 1, true) ~= nil, "kill: ...and says why")
    ok(detached.is_alive(reused), "kill: ...and the process still runs")

    -- an entry from before the check: no start time, nothing to verify against
    for _, way in ipairs({ "list", "kill" }) do
      detached.track(reused, { name = "legacy" })
      rewrite(function(es)
        es[1].proc_start = nil
        es[1].owner_start = nil
      end)
      if way == "list" then
        eq(#detached.list(), 0, "list: an entry without a start time is not listed")
      else
        eq(detached.kill(reused), false, "kill: an entry without a start time is refused")
      end
      ok(detached.is_alive(reused), way .. ": ...and the process still runs")
    end

    -- the genuine entry is found
    detached.track(reused, { name = "reused" })
    local genuine = detached.list()
    eq(#genuine, 1, "list: the registered process with its start time is listed")
    eq(genuine[1].pid, reused, "list: ...under its pid")
    eq(genuine[1].orphan, false, "list: ...and we, its owner, run")

    -- a reused owner pid: a live process under the owner's pid that started at another time leaves an orphan
    rewrite(function(es)
      es[1].owner_start = es[1].owner_start - 3600
    end)
    local orphaned = detached.list({ orphans = true })
    eq(#orphaned, 1, "list: an owner pid with another start time counts as gone")
    eq(orphaned[1].orphan, true, "list: ...the process is an orphan")
    detached.untrack(reused)

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
    -- by name, not by count: "spec-quick" above may still run or have ended meanwhile, which changes the count
    -- (seen on macOS, where list() asks `ps` per entry and takes long enough for it to end in between)
    local fake_entries = vim.tbl_filter(function(e)
      return e.name == "spec-fake"
    end, vim.json.decode(slurp(path)).entries)
    eq(#fake_entries, 0, "run_detached: no pid, nothing registered")
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
