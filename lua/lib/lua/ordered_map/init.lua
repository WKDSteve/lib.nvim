---@module 'lib.lua.ordered_map'
--- A key -> value map that remembers the order its keys were first put in. Pure Lua, no `vim`.
---
--- The shared core under `lib.nvim.registry` and `lib.lua.patterns.repository` (`memory()`), which both
--- need "one entry per key, answered in registration order, never `pairs()` order". `delete` is O(1): it
--- leaves a hole in the order list, and the holes are squeezed out once they are half of it, never while
--- an `each` walk is running (a callback may delete entries, also the one being visited).
---
--- ```lua
--- local map = require("lib.lua.ordered_map").new()
--- map:put("b", 1)
--- map:put("a", 2)
--- map:put("b", 3)          -- replaces the value, keeps the position
--- map:keys()               --> { "b", "a" }
--- map:delete("b")          --> true
--- map:each(function(key, value) print(key, value) end)
--- ```

local M = {}

---@class Lib.Lua.OrderedMap
---@field order any[]    # internal: keys in order; `false` marks a deleted slot
---@field pos table      # internal: key -> index in `order`
---@field data table     # internal
---@field live integer   # internal
---@field dead integer   # internal
---@field walking integer # internal: running `each` walks
local O = {}
O.__index = O

---@return Lib.Lua.OrderedMap
function M.new()
  return setmetatable({ order = {}, pos = {}, data = {}, live = 0, dead = 0, walking = 0 }, O)
end

---@param self Lib.Lua.OrderedMap
local function compact(self)
  if self.walking > 0 then
    return
  end
  local order, pos = self.order, self.pos
  local j = 0
  for k = 1, #order do
    local key = order[k]
    if key ~= false then
      j = j + 1
      order[j] = key
      pos[key] = j
    end
  end
  for k = j + 1, #order do
    order[k] = nil
  end
  self.dead = 0
end

---Put `value` under `key`. An existing key keeps its position. Neither may be nil, the key not NaN.
---@param key any
---@param value any
function O:put(key, value)
  if key == nil or key ~= key then
    error("ordered_map.put: key must not be nil or NaN", 2)
  end
  if value == nil then
    error("ordered_map.put: value must not be nil (use delete)", 2)
  end
  if self.data[key] == nil then
    local order = self.order
    order[#order + 1] = key
    self.pos[key] = #order
    self.live = self.live + 1
  end
  self.data[key] = value
end

---@param key any
---@return any|nil
function O:get(key)
  return self.data[key]
end

---@param key any
---@return boolean
function O:has(key)
  return self.data[key] ~= nil
end

---Remove one entry. Returns whether there was one.
---@param key any
---@return boolean
function O:delete(key)
  if key == nil or key ~= key or self.data[key] == nil then
    return false
  end
  self.data[key] = nil
  self.order[self.pos[key]] = false
  self.pos[key] = nil
  self.live = self.live - 1
  self.dead = self.dead + 1
  if self.dead * 2 > #self.order then
    compact(self)
  end
  return true
end

---@return integer
function O:count()
  return self.live
end

---Visit the entries in order; `fn(key, value)` returning a truthy value stops the walk. Entries put
---during the walk are not visited, entries deleted during it are skipped.
---@param fn fun(key: any, value: any): any
function O:each(fn)
  local order, data = self.order, self.data
  local n = #order
  self.walking = self.walking + 1
  local ok, err = pcall(function()
    for k = 1, n do
      local key = order[k]
      if key ~= false and key ~= nil then
        local value = data[key]
        if value ~= nil and fn(key, value) then
          return
        end
      end
    end
  end)
  self.walking = self.walking - 1
  if self.dead * 2 > #self.order then
    compact(self)
  end
  if not ok then
    error(err, 0)
  end
end

---The keys in order (a fresh list).
---@return any[]
function O:keys()
  local out = {}
  for _, key in ipairs(self.order) do
    if key ~= false then
      out[#out + 1] = key
    end
  end
  return out
end

---Drop every entry.
function O:clear()
  for k = 1, #self.order do
    local key = self.order[k]
    if key ~= false then
      self.data[key] = nil
    end
  end
  self.order, self.pos = {}, {}
  self.live, self.dead = 0, 0
end

return M
