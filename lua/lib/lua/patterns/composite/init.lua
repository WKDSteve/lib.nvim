---@module 'lib.lua.patterns.composite'
--- Composite: treat a group like one element. A call made on the group is made on every child and the
--- results come back as a list; groups can contain groups.
---
--- ```lua
--- local composite = require("lib.lua.patterns.composite")
--- local all = composite.new({ statusline_a, statusline_b })
--- all:call("refresh")                 --> { ra, rb }
--- all:add(composite.new({ c, d }))    -- a group inside a group
--- all:call("refresh")                 --> { ra, rb, { rc, rd } }
--- ```
---
--- A child is any table whose method is looked up by name; a child without that method is skipped.

require("lib.lua.patterns.composite.@types")

local listeners = require("lib.lua.listeners")
local varargs = require("lib.lua.functions.varargs")
local pack, unpack = varargs.pack, varargs.unpack

local M = {}

---@class Lib.Patterns.Composite
local C = {}
C.__index = C

---@param children table[]|nil
---@return Lib.Patterns.Composite
function M.new(children)
  local items = listeners.new()
  for _, child in ipairs(children or {}) do
    items:add(child)
  end
  return setmetatable({ items = items, is_composite = true }, C)
end

---@param child table
---@return Lib.Patterns.Composite
function C:add(child)
  if type(child) ~= "table" then
    error("composite.add: child must be a table", 2)
  end
  self.items:add(child)
  return self
end

---@param child table
---@return boolean
function C:remove(child)
  return self.items:remove(child)
end

---@return integer
function C:size()
  return self.items:count()
end

---Call `method` on every child. Errors in one child do not stop the others; they are returned.
---@param method string
---@param ... any
---@return any[] results # one entry per child that has the method (a nested group yields a list)
---@return any[] errors
function C:call(method, ...)
  local results, errors = {}, {}
  local args = pack(...)
  -- a child may add or remove children (itself included) while being called: the walk covers the
  -- children present when it started and skips the ones removed meanwhile
  self.items:each(function(child)
    local group = type(child) == "table" and child.is_composite
    if group or (type(child) == "table" and type(child[method]) == "function") then
      local ok, res, child_errors
      if group then
        ok, res, child_errors = pcall(child.call, child, method, unpack(args, 1, args.n))
      else
        ok, res = pcall(child[method], child, unpack(args, 1, args.n))
      end
      if ok then
        results[#results + 1] = res
        for _, e in ipairs(child_errors or {}) do
          errors[#errors + 1] = e
        end
      else
        errors[#errors + 1] = res
      end
    end
  end)
  return results, errors
end

return M
