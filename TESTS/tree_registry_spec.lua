-- TESTS/tree_registry_spec.lua — lib.nvim.tree.registry: sources, decorators and actions of a tree view,
-- registered without a reader.

return function(H)
  local eq, ok = H.eq, H.ok
  local registry = require("lib.nvim.tree.registry")

  ---@param fn function
  ---@return boolean raised
  ---@return string msg
  local function raises(fn)
    local good, err = pcall(fn)
    return not good, tostring(err)
  end

  local function noop() end
  local function source(name)
    return {
      name = name,
      root = function()
        return { id = name, label = name }
      end,
    }
  end
  local function decorator(name)
    return {
      name = name,
      get = noop,
      subscribe = function()
        return noop
      end,
    }
  end
  local function names(kind)
    local out = {}
    for i, entry in ipairs(registry.list(kind)) do
      out[i] = entry.name
    end
    return table.concat(out, ",")
  end

  registry.reset()
  H.after_spec(registry.reset)

  -- three separate lists, each in registration order
  registry.source(source("tests"))
  registry.source(source("alpha"))
  registry.decorator(decorator("git"))
  registry.action({ name = "tests.run", run = noop })
  eq(names("source"), "tests,alpha", "sources: registration order")
  eq(names("decorator"), "git", "decorators are their own list")
  eq(names("action"), "tests.run", "actions are their own list")
  eq(registry.get("source", "alpha").name, "alpha", "get")
  eq(registry.get("source", "git"), nil, "get: a decorator's name is no source")

  -- list() answers a copy of the list
  local copy = registry.list("source")
  table.remove(copy, 1)
  eq(names("source"), "tests,alpha", "list: changing the answer leaves the registry alone")

  -- what an entry must carry
  local raised, msg = raises(function()
    registry.source({ name = "x" })
  end)
  ok(raised and msg:find("root%(%)") ~= nil, "source without root() is refused: " .. msg)
  ok(msg:find("tree_registry_spec", 1, true) ~= nil, "the error names the caller: " .. msg)
  raised, msg = raises(function()
    registry.decorator({ name = "x", get = noop })
  end)
  ok(
    raised and msg:find("subscribe%(%)") ~= nil,
    "decorator without subscribe() is refused: " .. msg
  )
  raised = raises(function()
    registry.action({ name = "x" })
  end)
  ok(raised, "action without run() is refused")
  raised, msg = raises(function()
    registry.source({ root = noop })
  end)
  ok(raised, "an entry without a name is refused: " .. msg)
  raised = raises(function()
    registry.source({ name = "", root = noop })
  end)
  ok(raised, "an empty name is refused")
  raised = raises(function()
    registry.source("tests")
  end)
  ok(raised, "an entry that is no table is refused")
  eq(names("source"), "tests,alpha", "a refused entry is not listed")
  raised, msg = raises(function()
    registry.list("sources")
  end)
  ok(raised and msg:find("unknown kind") ~= nil, "list: an unknown kind raises: " .. msg)

  -- the change feed
  local events = {}
  local stop = registry.subscribe(function(ev)
    events[#events + 1] = ("%s:%s:%s:%s"):format(
      ev.kind,
      ev.name,
      ev.entry and "set" or "gone",
      ev.replaced and "replaced" or "new"
    )
  end)
  local first = source("late")
  local remove_first = registry.source(first)
  eq(events[1], "source:late:set:new", "subscribe: a late registration")

  -- the same name again replaces the entry and keeps its place
  registry.source(source("zz"))
  local second = source("late")
  local remove_second = registry.source(second)
  eq(events[3], "source:late:set:replaced", "subscribe: a replacement says so")
  eq(names("source"), "tests,alpha,late,zz", "a replacement keeps the position")
  ok(registry.get("source", "late") == second, "the later entry wins")

  -- the unregister of a replaced entry must not remove the entry that replaced it
  eq(remove_first(), false, "unregister of a replaced entry answers false")
  ok(registry.get("source", "late") == second, "... and leaves the newer entry")
  eq(#events, 3, "... and reports nothing")
  eq(remove_second(), true, "unregister removes its own entry")
  eq(registry.get("source", "late"), nil, "the entry is gone")
  eq(events[4], "source:late:gone:new", "subscribe: a removal has no entry")
  eq(remove_second(), false, "a second unregister is a no-op")

  -- after unsubscribe nothing arrives
  stop()
  registry.source(source("quiet"))
  eq(#events, 4, "unsubscribe: no more events")

  -- a subscriber that raises fails neither the registration nor the other subscribers
  local reached = false
  local said = {}
  local notify = require("lib.nvim.notify")
  H.with_patched(notify, "create", function()
    return {
      error = function(text)
        said[#said + 1] = text
      end,
    }
  end, function()
    registry.subscribe(function()
      error("boom")
    end)
    registry.subscribe(function()
      reached = true
    end)
    local registered = pcall(registry.decorator, decorator("after_boom"))
    ok(registered, "a raising subscriber does not fail the registration")
  end)
  ok(reached, "the subscriber after a raising one is still told")
  ok(registry.get("decorator", "after_boom") ~= nil, "the entry is registered")
  ok(
    #said == 1 and said[1]:find("boom", 1, true) ~= nil,
    "the failure is reported once: " .. tostring(said[1])
  )

  raised = raises(function()
    registry.subscribe("nope")
  end)
  ok(raised, "subscribe needs a function")

  -- reset: empty lists, no subscribers
  registry.reset()
  eq(
    #registry.list("source") + #registry.list("decorator") + #registry.list("action"),
    0,
    "reset empties the lists"
  )
  reached = false
  registry.source(source("fresh"))
  eq(reached, false, "reset drops the subscribers")

  -- pure: no editor API in the module (a registration must be possible before any UI exists)
  local path = vim.api.nvim_get_runtime_file("lua/lib/nvim/tree/registry/init.lua", false)[1]
  local text = table.concat(H.read_lines(path), "\n")
  for _, needle in ipairs({ "vim%.api", "vim%.fn", "vim%.cmd" }) do
    eq(text:find(needle), nil, "no " .. needle .. " in the registry")
  end
end
