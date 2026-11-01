-- TESTS/debounce_spec.lua — lib.nvim.debounce: the latest call wins after the quiet period,
-- cancel() really cancels (also a run that is already queued on the main loop), and the timer
-- is released once it has fired. Real timers, waited on with vim.wait.

return function(H)
  local eq, ok = H.eq, H.ok
  local debounce = require("lib.nvim.debounce")

  -- A burst delivers once, with the arguments of the last call.
  do
    local got = {}
    local d = debounce.new(function(a, b)
      got[#got + 1] = a .. ":" .. tostring(b)
    end, 30)
    d.call("x", 1)
    d.call("y", 2)
    d.call("z", nil)
    eq(#got, 0, "nothing runs while the burst goes on")
    vim.wait(1000, function()
      return #got > 0
    end, 5)
    vim.wait(100)
    eq(#got, 1, "one run for the whole burst")
    eq(got[1], "z:nil", "...with the most recent arguments")

    -- the handle is reusable after it fired
    d.call("again", 0)
    vim.wait(1000, function()
      return #got > 1
    end, 5)
    eq(got[2], "again:0", "a call after the run fires again")
  end

  -- cancel() before the timer fires.
  do
    local n = 0
    local d = debounce.new(function()
      n = n + 1
    end, 30)
    d.call()
    d.cancel()
    vim.wait(150)
    eq(n, 0, "cancel() stops a pending run")
    d.cancel()
    d.call()
    vim.wait(1000, function()
      return n > 0
    end, 5)
    eq(n, 1, "...and the handle still works afterwards (cancel is repeatable)")
  end

  -- A run already queued on the main loop (timer fired, vim.schedule not run yet).
  do
    local real_schedule = vim.schedule
    local queued = {}
    vim.schedule = function(f)
      queued[#queued + 1] = f
    end

    local n = 0
    local d = debounce.new(function()
      n = n + 1
    end, 10)

    d.call()
    vim.wait(500, function()
      return #queued > 0
    end, 5)
    ok(#queued == 1, "the fired timer queued its run")
    d.cancel()
    queued[1]()
    eq(n, 0, "cancel() drops a run that is already queued")

    queued = {}
    d.call()
    vim.wait(500, function()
      return #queued > 0
    end, 5)
    d.call() -- a newer call supersedes the queued run
    queued[1]()
    eq(n, 0, "a newer call drops the older queued run")

    vim.wait(500, function()
      return #queued > 1
    end, 5)
    queued[2]()
    vim.schedule = real_schedule
    eq(n, 1, "...and only the newest call's run is delivered")
  end

  -- No timer handle stays open after the run (libuv idle handles are not free).
  do
    local uv = vim.uv or vim.loop
    local function timers()
      local c = 0
      uv.walk(function(h)
        if h:get_type() == "timer" and not h:is_closing() then
          c = c + 1
        end
      end)
      return c
    end
    local before = timers()
    local fired = false
    local d = debounce.new(function()
      fired = true
    end, 10)
    d.call()
    vim.wait(1000, function()
      return fired
    end, 5)
    vim.wait(50)
    eq(timers() <= before, true, "the timer is released after it fired")
  end
end
