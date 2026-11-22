-- TESTS/async_all_spec.lua — lib.nvim.async.all, InFlight, keyed LatestWins
--
-- Tasks are completed by hand (their `done` callbacks are collected and called
-- from the spec body), so every ordering is exact; nothing here starts a
-- process or touches the network.

return function(H)
  local eq, ok = H.eq, H.ok
  local async = require("lib.nvim.async")

  local function wait_for(pred)
    vim.wait(5000, pred, 5)
    return pred()
  end

  -- ------------------------------------------------------------ all

  do -- every task starts at once, one answer in task order
    local dones, started = {}, 0
    local tasks = {}
    for i = 1, 3 do
      tasks[i] = function(done)
        started = started + 1
        dones[i] = done
      end
    end
    local calls, got = 0, nil
    async.all(tasks, function(results, errors, stopped)
      calls = calls + 1
      got = { results = results, errors = errors, stopped = stopped }
    end)
    eq(started, 3, "all: every task is started at once, not one after another")
    dones[3]("c")
    dones[1]("a")
    vim.wait(20)
    eq(calls, 0, "all: no answer while a task is still out")
    dones[2](nil, "boom")
    ok(
      wait_for(function()
        return calls == 1
      end),
      "all: one answer once the last task is back"
    )
    eq(got.results[1], "a", "all: results[i] belongs to tasks[i]")
    eq(got.results[3], "c", "all: results keep task order, not finish order")
    eq(got.errors[2], "boom", "all: errors[i] belongs to tasks[i]")
    eq(got.stopped, false, "all: a completed run is not stopped")
    dones[1]("again")
    vim.wait(20)
    eq(calls, 1, "all: a second done of a task does not answer twice")
  end

  do -- a task that answers at once must not finish the run before the last task started
    local started = 0
    local got
    async.all({
      function(done)
        started = started + 1
        done(1)
      end,
      function(done)
        started = started + 1
        done(2)
      end,
    }, function(results)
      got = { results = results, started = started }
    end)
    ok(
      wait_for(function()
        return got ~= nil
      end),
      "all: synchronous answers still finish the run"
    )
    eq(got.started, 2, "all: the answer comes only after the last task started")
    eq(got.results[2], 2, "all: both synchronous results are kept")
  end

  do -- the answer is scheduled, never inline in the caller
    local inline = true
    local answered = false
    async.all({
      function(done)
        done("x")
      end,
    }, function()
      answered = true
      ok(not inline, "all: on_done never runs inside the call to all")
    end)
    inline = false
    ok(
      wait_for(function()
        return answered
      end),
      "all: a one-task run answers"
    )
  end

  do -- empty list still answers (asynchronously)
    local got
    async.all({}, function(results, _, stopped)
      got = { n = #results, stopped = stopped }
    end)
    ok(
      wait_for(function()
        return got ~= nil
      end),
      "all: an empty list still answers"
    )
    eq(got.n, 0, "all: an empty list answers with no results")
  end

  do -- stop() kills what is in flight, answers once as stopped, drops late answers
    local killed, dones = 0, {}
    local function task(i)
      return function(done)
        dones[i] = done
        return {
          stop = function()
            killed = killed + 1
          end,
        }
      end
    end
    local calls, got = 0, nil
    local handle = async.all({ task(1), task(2) }, function(results, _, stopped)
      calls = calls + 1
      got = { results = results, stopped = stopped }
    end)
    dones[1]("early")
    handle.stop()
    dones[2]("late")
    ok(
      wait_for(function()
        return calls == 1
      end),
      "all: stop() answers once"
    )
    eq(got.stopped, true, "all: stop() answers as stopped")
    eq(got.results[1], "early", "all: what finished before stop() is kept")
    eq(got.results[2], nil, "all: a late answer after stop() is dropped")
    eq(killed, 1, "all: stop() kills only the task still in flight")
    handle.stop()
    vim.wait(20)
    eq(calls, 1, "all: a second stop() is a no-op")
  end

  do -- a task that throws counts as finished with that error
    local got
    async.all({
      function()
        error("kaputt", 0)
      end,
      function(done)
        done("fine")
      end,
    }, function(results, errors)
      got = { results = results, errors = errors }
    end)
    ok(
      wait_for(function()
        return got ~= nil
      end),
      "all: a throwing task does not stall the run"
    )
    eq(got.errors[1], "kaputt", "all: the thrown error is that task's error")
    eq(got.results[2], "fine", "all: the other task's result is kept")
  end

  do
    ok(not pcall(async.all, "x", function() end), "all: rejects a non-list")
    ok(not pcall(async.all, {}, nil), "all: rejects a missing on_done")
  end

  -- ------------------------------------------------------------ InFlight

  do
    local flight = async.in_flight()
    eq(flight:idle(), true, "InFlight: a fresh counter is idle")
    local a = flight:track(function() end)
    local b = flight:track()
    eq(flight:count(), 2, "InFlight: track() counts one piece of work each")
    a()
    a()
    eq(flight:count(), 1, "InFlight: a second call of the same wrapper is ignored")
    b()
    eq(flight:idle(), true, "InFlight: idle once every tracked callback ran")
  end

  do -- work started from inside a callback counts before the first is uncounted
    local flight = async.in_flight()
    local seen_idle = nil
    local inner
    local outer = flight:track(function()
      -- before the next piece starts: the running callback itself still counts
      seen_idle = flight:idle()
      inner = flight:track(function() end)
    end)
    outer()
    eq(seen_idle, false, "InFlight: inside the callback the count still includes it")
    eq(flight:idle(), false, "InFlight: a chained piece keeps the counter busy")
    inner()
    eq(flight:idle(), true, "InFlight: idle once the whole chain is done")
  end

  do -- a throwing callback still uncounts, and its error reaches the caller
    local flight = async.in_flight()
    local cb = flight:track(function()
      error("inner", 0)
    end)
    local okc, err = pcall(cb)
    ok(not okc and err == "inner", "InFlight: the callback's error is raised to the caller")
    eq(flight:idle(), true, "InFlight: a throwing callback is uncounted anyway")
  end

  do -- the return value passes through the wrapper
    local flight = async.in_flight()
    local cb = flight:track(function(x)
      return x + 1, "two"
    end)
    local r1, r2 = cb(41)
    eq(r1, 42, "InFlight: the wrapper returns the callback's first value")
    eq(r2, "two", "InFlight: and the rest")
  end

  do -- all + in_flight: busy until on_done returned, not only until the last task answered
    local flight = async.in_flight()
    local done1
    local idle_in_done
    async.all({
      function(done)
        done1 = done
      end,
    }, function()
      idle_in_done = flight:idle()
    end, { in_flight = flight })
    eq(flight:idle(), false, "all+in_flight: busy right after the call")
    done1("x")
    eq(flight:idle(), false, "all+in_flight: still busy while on_done is only scheduled")
    ok(
      wait_for(function()
        return flight:idle()
      end),
      "all+in_flight: idle after on_done"
    )
    eq(idle_in_done, false, "all+in_flight: inside on_done the run still counts")
  end

  do -- all + in_flight + stop()
    local flight = async.in_flight()
    local handle = async.all({
      function() end,
    }, function() end, { in_flight = flight })
    handle.stop()
    ok(
      wait_for(function()
        return flight:idle()
      end),
      "all+in_flight: a stopped run is uncounted too"
    )
  end

  -- ------------------------------------------------------------ keyed LatestWins

  do
    local gate = async.latest_wins()
    local s1 = gate:begin("status")
    local b1 = gate:begin("browse")
    eq(gate:is_current(s1, "status"), true, "LatestWins key: a key's token is current")
    eq(gate:is_current(b1, "browse"), true, "LatestWins key: another key does not supersede it")
    local s2 = gate:begin("status")
    eq(gate:is_current(s1, "status"), false, "LatestWins key: a newer token of the key supersedes")
    eq(
      gate:is_current(s2, "status"),
      true,
      "LatestWins key: the newest token of the key is current"
    )
    eq(gate:is_current(b1, "browse"), true, "LatestWins key: the other key is untouched")
    local plain = gate:begin()
    eq(gate:is_current(plain), true, "LatestWins key: the keyless token is separate")
    eq(gate:is_current(s2, "status"), true, "LatestWins key: a keyless begin() leaves keys alone")
  end

  do
    local gate = async.latest_wins()
    local v1 = gate:ticket("lazygit")
    local other = gate:ticket("browse")
    eq(v1(), true, "LatestWins ticket: valid right after drawing it")
    local v2 = gate:ticket("lazygit")
    eq(v1(), false, "LatestWins ticket: a newer ticket of the key makes the old one invalid")
    eq(v2(), true, "LatestWins ticket: the newer ticket is valid")
    eq(other(), true, "LatestWins ticket: a ticket of another key stays valid")
    local p1 = gate:ticket()
    local p2 = gate:ticket()
    ok(not p1() and p2(), "LatestWins ticket: keyless tickets supersede each other")
  end
end
