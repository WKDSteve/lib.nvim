---@module 'lib.lua.listeners'
--- An ordered list of listeners (or any values) that is safe to change while it is walked: the shared
--- core under `event_bus`, `mediator`, `reducer`, `state_machine` and `composite`.
---
--- `add(value)` returns a remove function; removing only marks the entry (O(1)). `each(fn)` walks the
--- entries that existed when it started, skips the ones removed meanwhile (also by a nested `each`) and
--- never sees the ones added meanwhile. Marked entries are dropped in one pass once more than half of
--- the list is dead, and never while a walk is running. Pure Lua, no `vim`.
---
--- ```lua
--- local list = require("lib.lua.listeners").new()
--- local off = list:add(function(x) print(x) end)
--- list:each(function(fn) fn(1) end)
--- off()
--- ```

require("lib.lua.listeners.@types")

local M = {}

---@class Lib.Lua.Listeners.List
local L = {}
L.__index = L

---@param opts? Lib.Lua.Listeners.Opts
---@return Lib.Lua.Listeners.List
function M.new(opts)
  return setmetatable({
    items = {},
    live = 0,
    dead = 0,
    walking = 0,
    on_empty = opts and opts.on_empty or nil,
  }, L)
end

---@param self Lib.Lua.Listeners.List
local function compact(self)
  if self.walking > 0 then
    return
  end
  if self.live == 0 then
    self.items, self.dead = {}, 0
    if self.on_empty then
      self.on_empty(self)
    end
    return
  end
  local items = self.items
  local n = #items
  if self.dead * 2 > n then
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
    self.dead = 0
  end
end

---@param self Lib.Lua.Listeners.List
---@param entry table
local function drop(self, entry)
  if entry.removed then
    return false
  end
  entry.removed = true
  self.live = self.live - 1
  self.dead = self.dead + 1
  compact(self)
  return true
end

---@param value any
---@return fun() remove
function L:add(value)
  local entry = { value = value }
  self.items[#self.items + 1] = entry
  self.live = self.live + 1
  return function()
    drop(self, entry)
  end
end

---Remove the first live entry holding `value` (raw equality).
---@param value any
---@return boolean removed
function L:remove(value)
  for _, e in ipairs(self.items) do
    if not e.removed and e.value == value then
      return drop(self, e)
    end
  end
  return false
end

---Call `fn(value)` for every live entry in order. An error of `fn` propagates after the list is
---released, so a raising callback never leaves it "walking".
---@param fn fun(value: any)
function L:each(fn)
  local items = self.items
  local n = #items
  self.walking = self.walking + 1
  local ok, err = pcall(function()
    for i = 1, n do
      local e = items[i]
      if e and not e.removed then
        fn(e.value)
      end
    end
  end)
  self.walking = self.walking - 1
  if self.dead > 0 then
    compact(self)
  end
  if not ok then
    error(err, 0)
  end
end

---A copy of the live values, in order.
---@return any[]
function L:values()
  local out = {}
  for _, e in ipairs(self.items) do
    if not e.removed then
      out[#out + 1] = e.value
    end
  end
  return out
end

---@return integer
function L:count()
  return self.live
end

---Drop every entry; a running `each` stops calling them.
function L:clear()
  if #self.items == 0 then
    return
  end
  for _, e in ipairs(self.items) do
    e.removed = true
  end
  self.live, self.dead = 0, #self.items
  compact(self)
end

return M
