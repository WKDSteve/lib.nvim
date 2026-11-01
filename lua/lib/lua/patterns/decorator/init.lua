---@module 'lib.lua.patterns.decorator'
--- Decorator: add behaviour around a function without changing its callers.
---
--- Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.
---
--- A decorator is `function(fn) -> fn`. `wrap(fn, d1, d2, ...)` applies them so that the first listed is
--- the outermost. Ready-made ones: `before`, `after`, `guard`, `timed`.
---
--- ```lua
--- local decorator = require("lib.lua.patterns.decorator")
--- local save = decorator.wrap(write_file,
---   decorator.guard(function(path) return path ~= "" end, function() return nil, "empty path" end),
---   decorator.before(function(path) log("saving " .. path) end)
--- )
--- ```

require("lib.lua.patterns.decorator.@types")

local M = {}

local varargs = require("lib.lua.functions.varargs")
local pack, unpack = varargs.pack, varargs.unpack

---`wrap(fn, d1, d2)` == `d1(d2(fn))`.
---@param fn function
---@param ... fun(fn: function): function
---@return function
function M.wrap(fn, ...)
  if type(fn) ~= "function" then
    error("decorator.wrap: fn must be a function", 2)
  end
  -- select("#") and not #/ipairs: a nil among the decorators (a decorator variable that was never set) must be
  -- reported, not silently end the list
  local n = select("#", ...)
  for i = n, 1, -1 do
    local d = select(i, ...)
    if type(d) ~= "function" then
      error(("decorator.wrap: decorator %d must be a function"):format(i), 2)
    end
  end
  for i = n, 1, -1 do
    fn = (select(i, ...))(fn)
  end
  return fn
end

---Run `hook(...)` before the call (its return value is ignored).
---@param hook function
---@return fun(fn: function): function
function M.before(hook)
  if type(hook) ~= "function" then
    error("decorator.before: hook must be a function", 2)
  end
  return function(fn)
    return function(...)
      hook(...)
      return fn(...)
    end
  end
end

---Run `hook(results_table, ...)` after the call; the original results are returned unchanged.
---@param hook function
---@return fun(fn: function): function
function M.after(hook)
  if type(hook) ~= "function" then
    error("decorator.after: hook must be a function", 2)
  end
  return function(fn)
    return function(...)
      local out = pack(fn(...))
      hook(out, ...)
      return unpack(out, 1, out.n)
    end
  end
end

---Only call `fn` when `predicate(...)` is truthy; otherwise return `otherwise(...)` (default: nothing).
---@param predicate function
---@param otherwise function|nil
---@return fun(fn: function): function
function M.guard(predicate, otherwise)
  if type(predicate) ~= "function" then
    error("decorator.guard: predicate must be a function", 2)
  end
  if otherwise ~= nil and type(otherwise) ~= "function" then
    error("decorator.guard: otherwise must be a function or nil", 2)
  end
  return function(fn)
    return function(...)
      if predicate(...) then
        return fn(...)
      end
      if otherwise then
        return otherwise(...)
      end
    end
  end
end

---Report the duration of each call in milliseconds to `sink(ms, ...)`. The clock is injectable.
---@param sink function
---@param clock (fun(): number)|nil  # seconds, default `os.clock`
---@return fun(fn: function): function
function M.timed(sink, clock)
  if type(sink) ~= "function" then
    error("decorator.timed: sink must be a function", 2)
  end
  clock = clock or os.clock
  return function(fn)
    return function(...)
      local t0 = clock()
      local out = pack(pcall(fn, ...))
      -- a failing sink must never replace the result or the original error
      pcall(sink, (clock() - t0) * 1000, ...)
      if not out[1] then
        error(out[2], 0)
      end
      return unpack(out, 2, out.n)
    end
  end
end

return M
