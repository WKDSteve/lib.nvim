---@module 'lib.lua.patterns.abstract_factory'
--- Abstract factory: families of constructors that always come as a matching set.
---
--- A family is a table `product -> constructor`. The factory insists that every family provides the same
--- products, so code written against one family works with any other (one theme = icons + borders +
--- highlights, one backend = reader + writer).
---
--- ```lua
--- local abstract_factory = require("lib.lua.patterns.abstract_factory")
--- local ui = abstract_factory.new({
---   ascii = { border = function() return "+-+" end, icon = function() return "*" end },
---   nerd = { border = function() return "╭─╮" end, icon = function() return "" end },
--- })
--- ui:create("ascii", "icon") --> "*"
--- ui:family("nerd").border()
--- ```
---
--- Status: idea pool. Few call sites need a *set* of constructors to vary together; a single
--- `factory_method` table or a plain config table usually suffices.

require("lib.lua.patterns.abstract_factory.@types")

local M = {}

---@class Lib.Patterns.AbstractFactory
local A = {}
A.__index = A

---@param families table<string, table<string, function>>
---@return Lib.Patterns.AbstractFactory
function M.new(families)
  if type(families) ~= "table" then
    error("abstract_factory.new: families must be a table", 2)
  end
  -- own copy: changing the table afterwards must not bypass the checks below
  local own = {}
  for name, fam in pairs(families) do
    if type(fam) ~= "table" then
      error(("abstract_factory.new: family %q must be a table"):format(tostring(name)), 2)
    end
    local products_of = {}
    for product, ctor in pairs(fam) do
      products_of[product] = ctor
    end
    own[name] = products_of
  end
  families = own
  local products
  for name, fam in pairs(families) do
    local keys = {}
    for product, ctor in pairs(fam) do
      if type(ctor) ~= "function" then
        error(("abstract_factory.new: %s.%s must be a function"):format(name, product), 2)
      end
      keys[#keys + 1] = product
    end
    table.sort(keys)
    -- length-prefixed join: product names containing "," cannot make two different sets look equal
    local parts = {}
    for i, k in ipairs(keys) do
      parts[i] = #k .. ":" .. k
    end
    local sig = table.concat(parts, ",")
    if products == nil then
      products = sig
    elseif products ~= sig then
      error(
        ("abstract_factory.new: family %q provides {%s}, expected {%s}"):format(name, sig, products),
        2
      )
    end
  end
  return setmetatable({ families = families }, A)
end

---@return string[]
function A:names()
  local out = {}
  for name in pairs(self.families) do
    out[#out + 1] = name
  end
  table.sort(out)
  return out
end

---@param name string
---@return table<string, function>
function A:family(name)
  local fam = self.families[name]
  if not fam then
    error(("abstract_factory: unknown family %q"):format(tostring(name)), 2)
  end
  return fam
end

---@param name string
---@param product string
---@param ... any
---@return any
function A:create(name, product, ...)
  local ctor = self:family(name)[product]
  if not ctor then
    error(("abstract_factory: family %q has no product %q"):format(name, tostring(product)), 2)
  end
  return ctor(...)
end

return M
