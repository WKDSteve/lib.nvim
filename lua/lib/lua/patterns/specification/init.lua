---@module 'lib.lua.patterns.specification'
--- Specification: rules as composable predicates.
---
--- Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.
---
--- ```lua
--- local spec = require("lib.lua.patterns.specification")
--- local is_lua = spec.new(function(f) return f:match("%.lua$") ~= nil end)
--- local is_test = spec.new(function(f) return f:match("_spec%.lua$") ~= nil end)
--- local wanted = is_lua:and_(is_test:not_())
--- wanted:is_satisfied_by("a.lua") --> true
--- wanted("a_spec.lua")            --> false (a specification is also callable)
--- ```

require("lib.lua.patterns.specification.@types")

local M = {}

---@class Lib.Patterns.Specification
local S = {}
S.__index = S
S.__call = function(self, candidate)
  return self.check(candidate)
end

---@param fn fun(candidate: any): boolean
---@return Lib.Patterns.Specification
function M.new(fn)
  if type(fn) ~= "function" then
    error("specification.new: fn must be a function", 2)
  end
  return setmetatable({
    check = function(candidate)
      return fn(candidate) and true or false
    end,
  }, S)
end

---@param candidate any
---@return boolean
function S:is_satisfied_by(candidate)
  return self.check(candidate)
end

---@param other Lib.Patterns.Specification
---@return Lib.Patterns.Specification
function S:and_(other)
  local a, b = self.check, other.check
  return M.new(function(c)
    return a(c) and b(c)
  end)
end

---@param other Lib.Patterns.Specification
---@return Lib.Patterns.Specification
function S:or_(other)
  local a, b = self.check, other.check
  return M.new(function(c)
    return a(c) or b(c)
  end)
end

---@return Lib.Patterns.Specification
function S:not_()
  local a = self.check
  return M.new(function(c)
    return not a(c)
  end)
end

---All of the specifications (an empty list is satisfied by everything).
---@param list Lib.Patterns.Specification[]
---@return Lib.Patterns.Specification
function M.all(list)
  return M.new(function(c)
    for _, s in ipairs(list) do
      if not s.check(c) then
        return false
      end
    end
    return true
  end)
end

---Any of the specifications (an empty list is satisfied by nothing).
---@param list Lib.Patterns.Specification[]
---@return Lib.Patterns.Specification
function M.any(list)
  return M.new(function(c)
    for _, s in ipairs(list) do
      if s.check(c) then
        return true
      end
    end
    return false
  end)
end

return M
