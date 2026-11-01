---@module 'lib.lua.patterns.factory_method'
--- Factory method: `create(kind, ...)` picks the constructor from a table instead of an if/elseif chain.
---
--- ```lua
--- local factory_method = require("lib.lua.patterns.factory_method")
--- local make = factory_method.new({
---   md = function(path) return { kind = "md", path = path } end,
---   pdf = function(path) return { kind = "pdf", path = path } end,
--- }, { default = function(path) return { kind = "raw", path = path } end })
--- make:create("pdf", "a.pdf")
--- make:register("png", function(path) return { kind = "png", path = path } end)
--- ```

require("lib.lua.patterns.factory_method.@types")

local M = {}

---@class Lib.Patterns.FactoryMethod
local F = {}
F.__index = F

---@param ctors table<string, function>|nil
---@param opts { default: function|nil }|nil
---@return Lib.Patterns.FactoryMethod
function M.new(ctors, opts)
  if opts and opts.default ~= nil and type(opts.default) ~= "function" then
    error("factory_method.new: opts.default must be a function", 2)
  end
  local self = setmetatable({ ctors = {}, order = {}, default = opts and opts.default }, F)
  for kind, ctor in pairs(ctors or {}) do
    self:register(kind, ctor)
  end
  table.sort(self.order)
  return self
end

---@param kind string
---@param ctor function
---@return Lib.Patterns.FactoryMethod
function F:register(kind, ctor)
  if type(ctor) ~= "function" then
    error("factory_method.register: ctor must be a function", 2)
  end
  if type(kind) ~= "string" then
    error("factory_method.register: kind must be a string", 2)
  end
  if not self.ctors[kind] then
    self.order[#self.order + 1] = kind
  end
  self.ctors[kind] = ctor
  return self
end

---Build an instance of `kind`; an unknown kind uses `default` or raises.
---@param kind string
---@param ... any
---@return any
function F:create(kind, ...)
  local ctor = self.ctors[kind] or self.default
  if not ctor then
    error(("factory_method: unknown kind %q"):format(tostring(kind)), 2)
  end
  return ctor(...)
end

---@return string[]
function F:kinds()
  local out = {}
  for i, k in ipairs(self.order) do
    out[i] = k
  end
  return out
end

return M
