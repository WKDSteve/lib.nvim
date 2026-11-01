---@module 'lib.lua.patterns.unit_of_work'
--- Unit of work: collect changes to a repository and apply them together; if one fails, take back what was
--- already applied.
---
--- `add(id, value)`, `change(id, value)` and `remove(id)` only queue. `commit()` applies the queue in
--- order against a store with `get/put/delete` (see `lib.lua.patterns.repository`). A failing step reverts
--- the applied ones in reverse order, using the values saved just before each step. `rollback()` throws the
--- queue away.
---
--- ```lua
--- local repository = require("lib.lua.patterns.repository")
--- local unit_of_work = require("lib.lua.patterns.unit_of_work")
--- local store = repository.memory()
--- local uow = unit_of_work.new(store)
--- uow:add("a", 1); uow:change("b", 2); uow:remove("c")
--- local ok, err = uow:commit()
--- ```
---
--- Status: idea pool. Real atomicity needs the store to support it; this only restores values the unit of
--- work itself wrote. Plain sequential writes are enough when a half-applied state does not matter.

require("lib.lua.patterns.unit_of_work.@types")

local M = {}

---@class Lib.Patterns.UnitOfWork
local U = {}
U.__index = U

---@param store Lib.Patterns.Store
---@return Lib.Patterns.UnitOfWork
function M.new(store)
  for _, name in ipairs({ "get", "put", "delete" }) do
    if type(store[name]) ~= "function" then
      error(("unit_of_work.new: store lacks %q"):format(name), 2)
    end
  end
  return setmetatable({ store = store, queue = {} }, U)
end

---@param id any
---@param value any
---@return Lib.Patterns.UnitOfWork
function U:add(id, value)
  if id == nil or id ~= id then
    error("unit_of_work.add: id must not be nil or NaN", 2)
  end
  if value == nil then
    error("unit_of_work.add: value must not be nil (use remove)", 2)
  end
  self.queue[#self.queue + 1] = { kind = "put", id = id, value = value }
  return self
end

---@param id any
---@param value any
---@return Lib.Patterns.UnitOfWork
function U:change(id, value)
  return self:add(id, value)
end

---@param id any
---@return Lib.Patterns.UnitOfWork
function U:remove(id)
  if id == nil or id ~= id then
    error("unit_of_work.remove: id must not be nil or NaN", 2)
  end
  self.queue[#self.queue + 1] = { kind = "delete", id = id }
  return self
end

---@return integer
function U:pending()
  return #self.queue
end

---Drop the queued changes.
function U:rollback()
  self.queue = {}
end

---Apply the queue. Returns `true`, or `false, err, step_index` after reverting what was applied.
---@return boolean ok
---@return any err
---@return integer|nil failed_step
function U:commit()
  local applied = {}
  for i, op in ipairs(self.queue) do
    local gok, before = pcall(self.store.get, op.id)
    local ok, err
    if not gok then
      ok, err = false, before
    elseif op.kind == "put" then
      ok, err = pcall(self.store.put, op.id, op.value)
    else
      ok, err = pcall(self.store.delete, op.id)
    end
    if not ok then
      for j = #applied, 1, -1 do
        local done = applied[j]
        if done.before == nil then
          pcall(self.store.delete, done.id)
        else
          pcall(self.store.put, done.id, done.before)
        end
      end
      self.queue = {}
      return false, err, i
    end
    applied[#applied + 1] = { id = op.id, before = before }
  end
  self.queue = {}
  return true
end

return M
