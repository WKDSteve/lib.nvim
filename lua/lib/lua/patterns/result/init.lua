---@module 'lib.lua.patterns.result'
--- Result: errors as values. A result is either `{ ok = true, value = v }` or `{ ok = false, err = e }`.
---
--- Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.
---
--- Lua already returns `value, err` pairs; this module wraps such a pair into a value that can be passed
--- around, mapped and chained without an `if err then return nil, err end` after every call.
---
--- ```lua
--- local result = require("lib.lua.patterns.result")
--- local r = result.from_pcall(vim.json.decode, text)
---   :map(function(t) return t.name end)
--- print(r:unwrap_or("unnamed"))
--- ```

require("lib.lua.patterns.result.@types")

local M = {}

---@class Lib.Patterns.Result
local R = {}
R.__index = R

---@param v any
---@return Lib.Patterns.Result
function M.ok(v)
  return setmetatable({ ok = true, value = v }, R)
end

---@param e any
---@return Lib.Patterns.Result
function M.err(e)
  return setmetatable({ ok = false, err = e }, R)
end

---Wrap a Lua `value, err` pair: a non-nil `err` is an error, anything else is ok.
---@param value any
---@param err any
---@return Lib.Patterns.Result
function M.from_pair(value, err)
  if err ~= nil then
    return M.err(err)
  end
  return M.ok(value)
end

---Call `fn(...)` under `pcall`; a throw becomes an error result.
---@param fn function
---@param ... any
---@return Lib.Patterns.Result
function M.from_pcall(fn, ...)
  local ok, v = pcall(fn, ...)
  if ok then
    return M.ok(v)
  end
  return M.err(v)
end

---@param r any
---@return boolean
function M.is_result(r)
  return getmetatable(r) == R
end

---@return boolean
function R:is_ok()
  return self.ok
end

---Apply `fn` to the value of an ok result; an error result passes through.
---@param fn fun(v: any): any
---@return Lib.Patterns.Result
function R:map(fn)
  if not self.ok then
    return self
  end
  return M.from_pcall(fn, self.value)
end

---Apply `fn` to the error of an error result; an ok result passes through.
---@param fn fun(e: any): any
---@return Lib.Patterns.Result
function R:map_err(fn)
  if self.ok then
    return self
  end
  -- like `map`: a throw in `fn` becomes the error of the result, it does not escape
  local _, mapped = pcall(fn, self.err)
  return M.err(mapped)
end

---Chain a step that itself returns a result. A non-result return value is an error (a bug in `fn`).
---@param fn fun(v: any): Lib.Patterns.Result
---@return Lib.Patterns.Result
function R:and_then(fn)
  if not self.ok then
    return self
  end
  local ok, next_r = pcall(fn, self.value)
  if not ok then
    return M.err(next_r)
  end
  if not M.is_result(next_r) then
    return M.err("and_then: callback did not return a result")
  end
  return next_r
end

---@param default any
---@return any
function R:unwrap_or(default)
  if self.ok then
    return self.value
  end
  return default
end

---The value of an ok result; raises the error of an error result.
---@return any
function R:unwrap()
  if self.ok then
    return self.value
  end
  error(self.err, 2)
end

---Back to the Lua convention: `value, nil` or `nil, err`.
---@return any, any
function R:to_pair()
  if self.ok then
    return self.value, nil
  end
  return nil, self.err
end

return M
