---@module 'lib.lua.patterns.iterator'
--- Iterator: walk a sequence without exposing how it is stored, lazily and chainable.
---
--- An iterator wraps a `next()` function that returns the next value or `nil` at the end (so the values
--- themselves cannot be `nil`). `map`, `filter`, `take`, `drop` are lazy; `collect`, `each`, `reduce`
--- consume. `iter()` gives a function usable in a generic `for`.
---
--- ```lua
--- local iterator = require("lib.lua.patterns.iterator")
--- local firsts = iterator.of({ 1, 2, 3, 4, 5, 6 }):filter(function(x) return x % 2 == 0 end):map(function(x) return x * x end):take(2):collect()
--- --> { 4, 16 }
--- for v in iterator.range(1, 3):iter() do print(v) end
--- ```

require("lib.lua.patterns.iterator.@types")

local M = {}

---@class Lib.Patterns.Iterator
local I = {}
I.__index = I

---Wrap a `next()` function (returns the next value, `nil` at the end).
---@param next_fn fun(): any
---@return Lib.Patterns.Iterator
function M.from_fn(next_fn)
  if type(next_fn) ~= "function" then
    error("iterator.from_fn: next_fn must be a function", 2)
  end
  return setmetatable({ next_fn = next_fn, buffer = nil, has_buffer = false }, I)
end

---Iterate a list.
---@param list any[]
---@return Lib.Patterns.Iterator
function M.of(list)
  local i = 0
  return M.from_fn(function()
    i = i + 1
    return list[i]
  end)
end

---Numbers from `first` to `last` (inclusive) in steps of `step` (default 1).
---@param first number
---@param last number
---@param step number|nil
---@return Lib.Patterns.Iterator
function M.range(first, last, step)
  step = step or 1
  for _, v in ipairs({ first, last, step }) do
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
      error("iterator.range: first, last and step must be finite numbers", 2)
    end
  end
  if step == 0 then
    error("iterator.range: step must not be 0", 2)
  end
  -- the number of values is fixed up front and each value is first + i * step: summing a float step
  -- drifts (0.1 + 0.1 + 0.1 ~= 0.3) and at 2^53 `cur + 1 == cur` would never end
  local count = math.floor((last - first) / step + 1e-9) + 1
  local i = -1
  return M.from_fn(function()
    i = i + 1
    if i >= count then
      return nil
    end
    return first + i * step
  end)
end

---@param n any
---@param name string
---@return integer
local function count_arg(n, name)
  if type(n) ~= "number" or n ~= n then
    error(("iterator.%s: n must be a number"):format(name), 3)
  end
  if n < 0 then
    return 0
  end
  return math.floor(n)
end

---The next value or `nil`.
---@return any
function I:next()
  if self.has_buffer then
    local v = self.buffer
    self.buffer, self.has_buffer = nil, false
    return v
  end
  return self.next_fn()
end

---Look at the next value without consuming it.
---@return any
function I:peek()
  if not self.has_buffer then
    self.buffer = self.next_fn()
    self.has_buffer = true
  end
  return self.buffer
end

---@return boolean
function I:has_next()
  return self:peek() ~= nil
end

---@param fn fun(v: any): any
---@return Lib.Patterns.Iterator
function I:map(fn)
  if type(fn) ~= "function" then
    error("iterator.map: fn must be a function", 2)
  end
  return M.from_fn(function()
    local v = self:next()
    if v == nil then
      return nil
    end
    return fn(v)
  end)
end

---@param pred fun(v: any): boolean
---@return Lib.Patterns.Iterator
function I:filter(pred)
  if type(pred) ~= "function" then
    error("iterator.filter: pred must be a function", 2)
  end
  return M.from_fn(function()
    while true do
      local v = self:next()
      if v == nil then
        return nil
      end
      if pred(v) then
        return v
      end
    end
  end)
end

---@param n integer
---@return Lib.Patterns.Iterator
function I:take(n)
  n = count_arg(n, "take")
  local taken = 0
  return M.from_fn(function()
    if taken >= n then
      return nil
    end
    taken = taken + 1
    return self:next()
  end)
end

---@param n integer
---@return Lib.Patterns.Iterator
function I:drop(n)
  n = count_arg(n, "drop")
  local dropped = false
  return M.from_fn(function()
    if not dropped then
      dropped = true
      for _ = 1, n do
        if self:next() == nil then
          return nil
        end
      end
    end
    return self:next()
  end)
end

---@return any[]
function I:collect()
  local out = {}
  for v in self:iter() do
    out[#out + 1] = v
  end
  return out
end

---@param fn fun(v: any)
function I:each(fn)
  for v in self:iter() do
    fn(v)
  end
end

---@param fn fun(acc: any, v: any): any
---@param init any
---@return any
function I:reduce(fn, init)
  local acc = init
  for v in self:iter() do
    acc = fn(acc, v)
  end
  return acc
end

---Function for a generic `for`.
---@return fun(): any
function I:iter()
  return function()
    return self:next()
  end
end

return M
