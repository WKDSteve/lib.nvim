---@module 'lib.lua.patterns.strategy'
--- Strategy: interchangeable algorithms behind one call, chosen by name.
---
--- Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.
---
--- In Lua a strategy is a function in a table. This module adds what the bare table lacks: a current
--- selection, a fallback, a listing, and a clear error for an unknown name.
---
--- ```lua
--- local strategy = require("lib.lua.patterns.strategy")
--- local render = strategy.new({
---   plain = function(item) return item.name end,
---   long = function(item) return item.name .. " (" .. item.path .. ")" end,
--- }, { default = "plain" })
--- render:run({ name = "a", path = "/x" })        -- current strategy
--- render:use("long")
--- render:call("plain", { name = "a" })           -- one-off, current unchanged
--- ```

require("lib.lua.patterns.strategy.@types")

local M = {}

---@class Lib.Patterns.Strategy
local S = {}
S.__index = S

---@param strategies table<string, function>
---@param opts { default: string|nil }|nil
---@return Lib.Patterns.Strategy
function M.new(strategies, opts)
  local self = setmetatable({ strategies = {}, current = nil }, S)
  for name, fn in pairs(strategies or {}) do
    self:register(name, fn)
  end
  if opts and opts.default then
    self:use(opts.default)
  end
  return self
end

---@param name string
---@param fn function
---@return Lib.Patterns.Strategy
function S:register(name, fn)
  if type(fn) ~= "function" then
    error("strategy.register: strategy must be a function", 2)
  end
  self.strategies[name] = fn
  return self
end

---Select the current strategy.
---@param name string
---@return Lib.Patterns.Strategy
function S:use(name)
  if not self.strategies[name] then
    error(("strategy: unknown strategy %q"):format(tostring(name)), 2)
  end
  self.current = name
  return self
end

---@return string|nil
function S:selected()
  return self.current
end

---Run the current strategy.
---@param ... any
---@return any
function S:run(...)
  if not self.current then
    error("strategy: no strategy selected (use() or opts.default)", 2)
  end
  return self.strategies[self.current](...)
end

---Run a named strategy once; the current selection is unchanged.
---@param name string
---@param ... any
---@return any
function S:call(name, ...)
  local fn = self.strategies[name]
  if not fn then
    error(("strategy: unknown strategy %q"):format(tostring(name)), 2)
  end
  return fn(...)
end

---@return string[]
function S:names()
  local out = {}
  for name in pairs(self.strategies) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

return M
