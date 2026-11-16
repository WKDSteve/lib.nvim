-- TESTS/patterns_throttle_spec.lua — lib.nvim.patterns.throttle
return function(H)
  local eq, ok = H.eq, H.ok
  local throttle = require("lib.nvim.patterns.throttle")
  local uv = vim.uv or vim.loop

  -- Waits below wait for a state, never for a fixed time: under load (parallel suites, BelowNormal
  -- priority) a 40 ms pause can end far later than 40 ms. The generous ceiling only bounds a hang.
  local CEILING = 5000

  -- Records every pause timer the throttle opens (it calls `uv.new_timer()` at call time), so a
  -- spec can wait until the pause is really over: the throttle closes its timer when the pause ends.
  local function track_timers(body)
    local made = {}
    local real = uv.new_timer
    uv.new_timer = function(...)
      local h = real(...)
      made[#made + 1] = h
      return h
    end
    local okb, err = pcall(body, made)
    uv.new_timer = real
    if not okb then
      error(err, 0)
    end
  end

  local function all_closed(made)
    for _, h in ipairs(made) do
      if not h:is_closing() then
        return false
      end
    end
    return true
  end

  -- leading + trailing: first call at once, burst collapses into one trailing call with the latest args
  local seen = {}
  local t = throttle.new(function(x)
    seen[#seen + 1] = x
  end, 40)
  track_timers(function(made)
    t.call(1)
    eq(#seen, 1, "leading: first call runs at once")
    t.call(2)
    t.call(3)
    eq(#seen, 1, "calls during the pause are held")
    ok(
      vim.wait(CEILING, function()
        return #seen >= 2
      end),
      "trailing call ran"
    )
    eq(table.concat(seen, ","), "1,3", "trailing: latest arguments run after the pause")
    -- the trailing call opened a second pause; wait until it has ended (timer closed)
    ok(#made >= 2, "the trailing call opened a pause of its own")
    ok(
      vim.wait(CEILING, function()
        return all_closed(made)
      end),
      "the pause after the trailing call ends"
    )
  end)
  t.call(4)
  eq(seen[#seen], 4, "after a quiet period the next call is leading again")
  t.cancel()

  -- leading only
  local lead = {}
  local l = throttle.new(function(x)
    lead[#lead + 1] = x
  end, 30, { trailing = false })
  l.call("a")
  l.call("b")
  vim.wait(120, function()
    return false
  end)
  eq(table.concat(lead, ","), "a", "trailing=false drops held calls")
  l.cancel()

  -- trailing only
  local trail = {}
  local r = throttle.new(function(x)
    trail[#trail + 1] = x
  end, 30, { leading = false })
  r.call("a")
  r.call("b")
  eq(#trail, 0, "leading=false: nothing at once")
  vim.wait(CEILING, function()
    return #trail >= 1
  end)
  eq(table.concat(trail, ","), "b", "leading=false: latest runs after the pause")
  r.cancel()

  -- cancel and flush
  local fl = {}
  local f = throttle.new(function(x)
    fl[#fl + 1] = x
  end, 1000)
  f.call("x")
  f.call("y")
  f.flush()
  eq(table.concat(fl, ","), "x,y", "flush runs the pending call now")
  f.cancel()

  -- cancel while calls are held inside a pause: they must never run
  local held = {}
  local c = throttle.new(function(x)
    held[#held + 1] = x
  end, 40)
  c.call("lead")
  c.call("held-1")
  c.call("held-2")
  c.cancel()
  vim.wait(150, function()
    return false
  end)
  eq(table.concat(held, ","), "lead", "cancel drops the held calls (only the leading call ran)")
  c.call("again")
  eq(held[#held], "again", "after cancel the next call is leading again")
  vim.wait(150, function()
    return false
  end)
  eq(
    table.concat(held, ","),
    "lead,again",
    "a held call dropped by cancel does not come back after the next pause"
  )
  c.cancel()
  ok(true, "done")
end
