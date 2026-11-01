---@module 'lib.lua.patterns.reducer'
--- Reducer / MVU: state = reduce(state, action). All changes go through one function, so the state is
--- predictable and every change can be logged, tested and replayed.
---
--- Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.
---
--- `reducer.store(reduce, initial)` keeps the state. `dispatch(action)` computes the next state; a
--- reducer that raises leaves the state unchanged (the error is returned). Subscribers get
--- `(new, old, action)` only when the state actually changed (`~=`), so return the same table when
--- nothing changed. `reducer.combine({ slice = reducer })` builds a reducer for a state made of slices.
---
--- ```lua
--- local reducer = require("lib.lua.patterns.reducer")
--- local store = reducer.store(function(state, action)
---   if action.type == "add" then return vim.list_extend({ unpack(state) }, { action.item }) end
---   return state
--- end, {})
--- local off = store:subscribe(function(new) render(new) end)
--- store:dispatch({ type = "add", item = "x" })
--- ```

require("lib.lua.patterns.reducer.@types")

local listeners = require("lib.lua.listeners")

local M = {}

---@class Lib.Patterns.ReducerStore
local S = {}
S.__index = S

---@param reduce fun(state: any, action: table): any
---@param initial any
---@return Lib.Patterns.ReducerStore
function M.store(reduce, initial)
  if type(reduce) ~= "function" then
    error("reducer.store: reduce must be a function", 2)
  end
  return setmetatable({ reduce = reduce, current = initial, listeners = listeners.new() }, S)
end

---@return any
function S:state()
  return self.current
end

---Apply an action. Returns `true, new_state` or `false, err` (state unchanged).
---@param action table
---@return boolean ok
---@return any state_or_err
function S:dispatch(action)
  local ok, new = pcall(self.reduce, self.current, action)
  if not ok then
    return false, new
  end
  local old = self.current
  self.current = new
  if new ~= old then
    self.listeners:each(function(l)
      pcall(l, new, old, action)
    end)
  end
  return true, new
end

---@param fn fun(new: any, old: any, action: table)
---@return fun() unsubscribe
function S:subscribe(fn)
  if type(fn) ~= "function" then
    error("reducer.subscribe: listener must be a function", 2)
  end
  return self.listeners:add(fn)
end

---Combine slice reducers: the state is a table `{ slice = state }`. A slice reducer that returns the same
---value leaves the whole state table unchanged.
---@param slices table<string, fun(state: any, action: table): any>
---@return fun(state: table|nil, action: table): table
function M.combine(slices)
  return function(state, action)
    state = state or {}
    local changed, next_state = false, {}
    for name, reduce in pairs(slices) do
      local before = state[name]
      local after = reduce(before, action)
      next_state[name] = after
      if after ~= before then
        changed = true
      end
    end
    return changed and next_state or state
  end
end

return M
