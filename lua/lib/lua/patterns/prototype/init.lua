---@module 'lib.lua.patterns.prototype'
--- Prototype: create objects by cloning a template instead of building them from scratch.
---
--- Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.
---
--- `clone(overrides)` returns an independent deep copy of the template with `overrides` merged on top
--- (nested tables merge, other values replace). `deepcopy` handles cycles and keeps metatables (shared, not copied): that is why it is not
--- `lib.lua.tables.deep_copy`, which drops them and would turn class instances into plain tables.
---
--- ```lua
--- local prototype = require("lib.lua.patterns.prototype")
--- local base = prototype.new({ width = 80, theme = { fg = "white", bg = "black" } })
--- local dark = base:clone({ theme = { bg = "blue" } }) --> width 80, fg white, bg blue
--- ```

require("lib.lua.patterns.prototype.@types")

local M = {}

---Deep copy with cycle protection; metatables are shared, not copied.
---@param v any
---@param seen table|nil
---@return any
function M.deepcopy(v, seen)
  if type(v) ~= "table" then
    return v
  end
  seen = seen or {}
  if seen[v] then
    return seen[v]
  end
  local out = {}
  seen[v] = out
  for k, x in pairs(v) do
    out[M.deepcopy(k, seen)] = M.deepcopy(x, seen)
  end
  return setmetatable(out, getmetatable(v))
end

local function merge(into, from)
  for k, v in pairs(from) do
    -- rawget: an __index on the copy's metatable must not hand out a table shared with other objects
    local base = rawget(into, k)
    if type(v) == "table" and type(base) == "table" then
      -- copy before merging: the nested table may be aliased elsewhere in the copy
      local own = M.deepcopy(base)
      into[k] = merge(own, v)
    else
      into[k] = M.deepcopy(v)
    end
  end
  return into
end

---@class Lib.Patterns.Prototype
local P = {}
P.__index = P

---@param template table
---@return Lib.Patterns.Prototype
function M.new(template)
  if type(template) ~= "table" then
    error("prototype.new: template must be a table", 2)
  end
  return setmetatable({ template = M.deepcopy(template) }, P)
end

---@param overrides table|nil
---@return table
function P:clone(overrides)
  local copy = M.deepcopy(self.template)
  if overrides then
    merge(copy, overrides)
  end
  return copy
end

return M
