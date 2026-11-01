---@module 'lib.lua.patterns.repository'
--- Repository: hide storage behind a collection-like API.
---
--- A repository sits on a store with four primitives: `get(id)`, `put(id, value)`, `delete(id)` and
--- `all()` (a list of `{ id, value }` entries, in a stable order). Code works with `get`, `save`, `remove`,
--- `find(predicate)`, `count()`; where the data lives (a table, a JSON file, `lib.nvim.store`) is the
--- store's business. `repository.memory()` is an in-memory store for tests and small cases.
---
--- ```lua
--- local repository = require("lib.lua.patterns.repository")
--- local users = repository.new(repository.memory())
--- users:save("u1", { name = "Ada" })
--- users:find(function(u) return u.name == "Ada" end) --> { id = "u1", value = {...} }
--- ```
---
--- Status: idea pool. Worth it when the storage is likely to change or must be faked in tests; for one
--- JSON file a pair of read/write functions is simpler.

require("lib.lua.patterns.repository.@types")

local ordered_map = require("lib.lua.ordered_map")

local M = {}

---An in-memory store.
---@return Lib.Patterns.Store
function M.memory()
  -- the order bookkeeping (O(1) delete, holes squeezed out) is `lib.lua.ordered_map`'s
  local map = ordered_map.new()
  return {
    get = function(id)
      return map:get(id)
    end,
    count = function()
      return map:count()
    end,
    each = function(fn)
      map:each(fn)
    end,
    put = function(id, value)
      if id == nil or id ~= id then
        error("repository.memory: id must not be nil or NaN", 2)
      end
      if value == nil then
        error("repository.memory: value must not be nil (use delete)", 2)
      end
      map:put(id, value)
    end,
    delete = function(id)
      map:delete(id)
    end,
    all = function()
      local out = {}
      map:each(function(id, value)
        out[#out + 1] = { id = id, value = value }
      end)
      return out
    end,
  }
end

---@class Lib.Patterns.Repository
local R = {}
R.__index = R

---@param store Lib.Patterns.Store
---@return Lib.Patterns.Repository
function M.new(store)
  for _, name in ipairs({ "get", "put", "delete", "all" }) do
    if type(store[name]) ~= "function" then
      error(("repository.new: store lacks %q"):format(name), 2)
    end
  end
  return setmetatable({ store = store }, R)
end

---@param id any
---@return any
function R:get(id)
  return self.store.get(id)
end

---@param id any
---@param value any
function R:save(id, value)
  if value == nil then
    error("repository.save: value must not be nil (use remove)", 2)
  end
  self.store.put(id, value)
end

---@param id any
function R:remove(id)
  self.store.delete(id)
end

---@return { id: any, value: any }[]
function R:all()
  return self.store.all()
end

---First entry whose value satisfies `predicate`.
---@param predicate fun(value: any, id: any): boolean
---@return { id: any, value: any }|nil
function R:find(predicate)
  local store = self.store
  if store.each then
    local found
    store.each(function(id, value)
      if predicate(value, id) then
        found = { id = id, value = value }
        return true
      end
    end)
    return found
  end
  for _, e in ipairs(store.all()) do
    if predicate(e.value, e.id) then
      return e
    end
  end
  return nil
end

---All entries whose value satisfies `predicate`.
---@param predicate fun(value: any, id: any): boolean
---@return { id: any, value: any }[]
function R:filter(predicate)
  local out = {}
  local store = self.store
  if store.each then
    store.each(function(id, value)
      if predicate(value, id) then
        out[#out + 1] = { id = id, value = value }
      end
    end)
    return out
  end
  for _, e in ipairs(store.all()) do
    if predicate(e.value, e.id) then
      out[#out + 1] = e
    end
  end
  return out
end

---@return integer
function R:count()
  if self.store.count then
    return self.store.count()
  end
  return #self.store.all()
end

return M
