---@module 'lib.lua.patterns.event_bus'
--- Event bus: publish/subscribe on named topics, without the editor.
---
--- A listener that raises does not stop the others: errors are collected and returned by `emit`.
--- `on()` returns the unsubscribe function. The topic `"*"` receives every event as `(topic, ...)`.
---
--- ```lua
--- local bus = require("lib.lua.patterns.event_bus").new()
--- local off = bus:on("saved", function(path) print(path) end)
--- bus:emit("saved", "a.lua") --> 1, {}   (listeners called, errors)
--- off()
--- ```
---
--- For editor-aware needs (priorities, vetoable events) use `lib.nvim.hooks`.

require("lib.lua.patterns.event_bus.@types")

local M = {}

---@class Lib.Patterns.EventBus
local B = {}
B.__index = B

---@return Lib.Patterns.EventBus
function M.new()
  return setmetatable({ topics = {} }, B)
end

-- A topic holds { items, live, dead, emitting }. Unsubscribing only marks the entry (O(1)); the dead
-- entries are removed in one pass when more than half of the list is dead, and never while an emit is
-- walking the list. A topic without listeners is dropped, so one-shot topics (per-request ids) leave
-- nothing behind.
---@param self Lib.Patterns.EventBus
---@param topic string
---@param list table
local function compact(self, topic, list)
  if list.emitting > 0 then
    return
  end
  if list.live == 0 then
    if self.topics[topic] == list then
      self.topics[topic] = nil
    end
    list.items, list.dead = {}, 0
    return
  end
  local items = list.items
  local n = #items
  if list.dead * 2 > n then
    local j = 0
    for k = 1, n do
      local e = items[k]
      if not e.removed then
        j = j + 1
        items[j] = e
      end
    end
    for k = j + 1, n do
      items[k] = nil
    end
    list.dead = 0
  end
end

---@param topic string
---@param fn function
---@return fun() unsubscribe
function B:on(topic, fn)
  if topic == nil or topic ~= topic then
    error("event_bus.on: topic must not be nil or NaN", 2)
  end
  if type(fn) ~= "function" then
    error("event_bus.on: listener must be a function", 2)
  end
  local list = self.topics[topic]
  if not list then
    list = { items = {}, live = 0, dead = 0, emitting = 0 }
    self.topics[topic] = list
  end
  local entry = { fn = fn }
  list.items[#list.items + 1] = entry
  list.live = list.live + 1
  return function()
    if entry.removed then
      return
    end
    entry.removed = true
    list.live = list.live - 1
    list.dead = list.dead + 1
    compact(self, topic, list)
  end
end

---Subscribe for one event only.
---@param topic string
---@param fn function
---@return fun() unsubscribe
function B:once(topic, fn)
  if type(fn) ~= "function" then
    error("event_bus.once: listener must be a function", 2)
  end
  local off
  off = self:on(topic, function(...)
    off()
    return fn(...)
  end)
  return off
end

---Call every listener of `topic` (then of `"*"`) in subscription order. Listeners added during the
---emit are not called by it; listeners removed during it (also by a nested emit) are skipped.
---@param topic string
---@param ... any
---@return integer called
---@return any[] errors
function B:emit(topic, ...)
  local called, errors = 0, {}
  local function run(list_topic, list, with_topic, ...)
    if not list then
      return
    end
    local items = list.items
    local n = #items
    list.emitting = list.emitting + 1
    for i = 1, n do
      local e = items[i]
      if e and not e.removed then
        called = called + 1
        local ok, err
        if with_topic then
          ok, err = pcall(e.fn, topic, ...)
        else
          ok, err = pcall(e.fn, ...)
        end
        if not ok then
          errors[#errors + 1] = err == nil and "nil error" or err
        end
      end
    end
    list.emitting = list.emitting - 1
    if list.dead > 0 then
      compact(self, list_topic, list)
    end
  end
  run(topic, self.topics[topic], topic == "*", ...)
  if topic ~= "*" then
    run("*", self.topics["*"], true, ...)
  end
  return called, errors
end

---Number of listeners on `topic`.
---@param topic string
---@return integer
function B:count(topic)
  local list = self.topics[topic]
  return list and list.live or 0
end

---Drop the listeners of one topic, or of all topics.
---@param topic string|nil
function B:clear(topic)
  -- mark the entries removed so a running emit stops calling them
  for name, list in pairs(self.topics) do
    if topic == nil or name == topic then
      for _, e in ipairs(list.items) do
        e.removed = true
      end
      list.live = 0
    end
  end
  if topic then
    self.topics[topic] = nil
  else
    self.topics = {}
  end
end

return M
