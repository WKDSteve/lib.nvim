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

local listeners = require("lib.lua.listeners")
local varargs = require("lib.lua.functions.varargs")
local pack, unpack = varargs.pack, varargs.unpack

local M = {}

---@class Lib.Patterns.EventBus
local B = {}
B.__index = B

---@return Lib.Patterns.EventBus
function M.new()
  return setmetatable({ topics = {} }, B)
end

-- A topic is a `lib.lua.listeners` list: unsubscribing only marks the entry (O(1)), dead entries are
-- compacted when more than half of the list is dead and never while an emit walks it. A topic without
-- listeners is dropped, so one-shot topics (per-request ids) leave nothing behind.

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
    list = listeners.new({
      on_empty = function(l)
        if self.topics[topic] == l then
          self.topics[topic] = nil
        end
      end,
    })
    self.topics[topic] = list
  end
  return list:add(fn)
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
  local args = pack(...)
  local function run(list, with_topic)
    if not list then
      return
    end
    list:each(function(fn)
      called = called + 1
      local ok, err
      if with_topic then
        ok, err = pcall(fn, topic, unpack(args, 1, args.n))
      else
        ok, err = pcall(fn, unpack(args, 1, args.n))
      end
      if not ok then
        errors[#errors + 1] = err == nil and "nil error" or err
      end
    end)
  end
  run(self.topics[topic], topic == "*")
  if topic ~= "*" then
    run(self.topics["*"], true)
  end
  return called, errors
end

---Number of listeners on `topic`.
---@param topic string
---@return integer
function B:count(topic)
  local list = self.topics[topic]
  return list and list:count() or 0
end

---Drop the listeners of one topic, or of all topics.
---@param topic string|nil
function B:clear(topic)
  -- clearing a list marks its entries removed, so a running emit stops calling them
  for name, list in pairs(self.topics) do
    if topic == nil or name == topic then
      list:clear()
    end
  end
  if topic then
    self.topics[topic] = nil
  else
    self.topics = {}
  end
end

return M
