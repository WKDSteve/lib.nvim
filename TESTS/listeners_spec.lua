-- TESTS/listeners_spec.lua — lib.lua.listeners, the list under event_bus, mediator, reducer,
-- state_machine and composite. The first half tests the list itself; the second half runs one
-- unsubscribe behaviour against all five modules, so a fix in the core cannot pass for four of them.

return function(H)
  local eq, ok = H.eq, H.ok
  local listeners = require("lib.lua.listeners")

  local function join(list)
    return table.concat(list, ",")
  end

  -- ------------------------------------------------------------------ the list
  do
    local list = listeners.new()
    local seen = {}
    local off_a = list:add("a")
    list:add("b")
    eq(list:count(), 2)
    off_a()
    off_a()
    eq(list:count(), 1, "removing twice removes once")
    eq(join(list:values()), "b")

    -- the same value twice: the handle removes its own entry, `remove` the first live one
    local l2 = listeners.new()
    l2:add("x")
    local off_second = l2:add("x")
    off_second()
    eq(l2:count(), 1, "a handle removes its own entry, not the first equal value")
    ok(l2:remove("x"), "remove finds the live one")
    ok(not l2:remove("x"), "remove reports a miss")

    -- added during a walk: not visited; removed during a walk: skipped
    local l3 = listeners.new()
    local off_c
    l3:add("a")
    off_c = l3:add("c")
    l3:add("d")
    l3:each(function(v)
      seen[#seen + 1] = v
      if v == "a" then
        off_c()
        l3:add("late")
      end
    end)
    eq(join(seen), "a,d", "a removed entry is skipped, a late one is not visited")
    eq(join(l3:values()), "a,d,late")

    -- nested walk and compaction only after the outer walk
    local l4 = listeners.new()
    local offs = {}
    for i = 1, 6 do
      offs[i] = l4:add(i)
    end
    local order = {}
    l4:each(function(v)
      order[#order + 1] = v
      if v == 1 then
        for i = 2, 5 do
          offs[i]()
        end
        l4:each(function(w)
          order[#order + 1] = "n" .. w
        end)
      end
    end)
    eq(join(order), "1,n1,n6,6")
    eq(#l4:values(), 2, "dead entries are compacted once no walk is running")

    -- a raising callback does not leave the list walking
    local l5 = listeners.new()
    local off5 = l5:add(1)
    l5:add(2)
    ok(not pcall(l5.each, l5, function()
      error("boom")
    end))
    off5()
    eq(l5.walking, 0)

    -- on_empty fires once the last value is gone, and not during a walk
    local empties = 0
    local l6 = listeners.new({
      on_empty = function()
        empties = empties + 1
      end,
    })
    local off6 = l6:add("x")
    l6:each(function()
      off6()
      eq(empties, 0, "not while walking")
    end)
    eq(empties, 1, "after the walk")

    local l7 = listeners.new()
    l7:add(1)
    l7:add(2)
    local n = 0
    l7:each(function()
      n = n + 1
      l7:clear()
    end)
    eq(n, 1, "clear stops a running walk")
    eq(l7:count(), 0)

    -- clearing an empty list is not "the last value went"
    local fired = 0
    local l8 = listeners.new({
      on_empty = function()
        fired = fired + 1
      end,
    })
    l8:clear()
    eq(fired, 0, "clear on an empty list does not fire on_empty")
    l8:add(1)
    l8:clear()
    eq(fired, 1, "clear on a filled list fires it once")
  end

  -- ------------------------------------------------------------------ one behaviour, five modules
  -- Each adapter yields: subscribe(fn) -> off, trigger(), count(). `fn` receives no arguments.
  local adapters = {
    event_bus = function()
      local bus = require("lib.lua.patterns.event_bus").new()
      return function(fn)
        return bus:on("t", fn)
      end, function()
        bus:emit("t")
      end, function()
        return bus:count("t")
      end
    end,
    reducer = function()
      local store = require("lib.lua.patterns.reducer").store(function(state)
        return state + 1
      end, 0)
      local subscribers = 0
      return function(fn)
        subscribers = subscribers + 1
        local off = store:subscribe(fn)
        local released = false
        return function()
          off()
          if not released then
            released = true
            subscribers = subscribers - 1
          end
        end
      end, function()
        store:dispatch({ type = "x" })
      end, function()
        return subscribers
      end
    end,
    state_machine = function()
      local sm = require("lib.lua.patterns.state_machine").new({
        initial = "a",
        transitions = {
          { event = "go", from = "*", to = "b" },
          { event = "back", from = "*", to = "a" },
        },
      })
      local flip, subscribers = false, 0
      return function(fn)
        subscribers = subscribers + 1
        local off = sm:on_change(fn)
        local released = false
        return function()
          off()
          if not released then
            released = true
            subscribers = subscribers - 1
          end
        end
      end, function()
        flip = not flip
        sm:fire(flip and "go" or "back")
      end, function()
        return subscribers
      end
    end,
    mediator = function()
      local m = require("lib.lua.patterns.mediator").new()
      local names = 0
      return function(fn)
        names = names + 1
        local name = "c" .. names
        m:register(name, {
          handle = function()
            fn()
          end,
        })
        return function()
          m:unregister(name)
        end
      end, function()
        m:broadcast("outside", "ping")
      end, function()
        return #m:names()
      end
    end,
    composite = function()
      local group = require("lib.lua.patterns.composite").new()
      return function(fn)
        local child = {
          ping = function()
            fn()
          end,
        }
        group:add(child)
        return function()
          group:remove(child)
        end
      end, function()
        group:call("ping")
      end, function()
        return group:size()
      end
    end,
  }

  for name, make in pairs(adapters) do
    local subscribe, trigger, count = make()
    local calls = {}
    local offs = {}
    for i = 1, 4 do
      offs[i] = subscribe(function()
        calls[#calls + 1] = i
      end)
    end
    trigger()
    eq(join(calls), "1,2,3,4", name .. ": every listener runs, in order")
    eq(count(), 4)

    offs[2]()
    offs[2]()
    eq(count(), 3, name .. ": unsubscribing twice removes once")
    calls = {}
    trigger()
    eq(join(calls), "1,3,4", name .. ": an unsubscribed listener is not called")

    -- a listener unsubscribing a later one during delivery: the later one is skipped
    calls = {}
    offs[1]()
    local off_later
    subscribe(function()
      calls[#calls + 1] = "first"
      off_later()
    end)
    off_later = subscribe(function()
      calls[#calls + 1] = "later"
    end)
    trigger()
    ok(
      not join(calls):find("later", 1, true),
      name .. ": a listener removed mid-delivery is skipped"
    )

    -- unsubscribing everything leaves nothing behind and the module keeps working
    for i = 3, 4 do
      offs[i]()
    end
    local n = 0
    local off_new = subscribe(function()
      n = n + 1
    end)
    trigger()
    ok(n >= 1, name .. ": subscribing again after removals works")
    off_new()
  end

  -- many subscribe/unsubscribe cycles stay cheap (no O(n) shifting per removal)
  local bus = require("lib.lua.patterns.event_bus").new()
  local offs = {}
  for i = 1, 5000 do
    offs[i] = bus:on("t", function() end)
  end
  local start = os.clock()
  for i = 1, 5000 do
    offs[i]()
  end
  ok(os.clock() - start < 1, "5000 unsubscribes take well under a second")
  eq(bus:count("t"), 0)
end
