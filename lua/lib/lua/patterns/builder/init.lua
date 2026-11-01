---@module 'lib.lua.patterns.builder'
--- Builder: collect options step by step, validate once in `build()`.
---
--- The field schema declares defaults, required fields and validators. Every field also gets a fluent
--- setter named like the field (`b:name("x")`), besides the generic `b:set(name, v)`.
---
--- ```lua
--- local builder = require("lib.lua.patterns.builder")
--- local new_cmd = builder.new({
---   name = { required = true },
---   nargs = { default = 0, validate = function(v) return type(v) == "number" end },
--- })
--- local cmd, err = new_cmd():name("Foo"):nargs(1):build()
--- ```

require("lib.lua.patterns.builder.@types")

local M = {}

local RESERVED = { set = true, build = true, get = true, _schema = true, _values = true }

---@class Lib.Patterns.Builder
local B = {}

B.__index = function(self, key)
  local own = rawget(B, key)
  if own then
    return own
  end
  local schema = rawget(self, "_schema")
  if schema and schema[key] then
    return function(b, value)
      return b:set(key, value)
    end
  end
  return nil
end

---@param self Lib.Patterns.Builder
---@param name string
---@param value any
---@return Lib.Patterns.Builder
function B:set(name, value)
  if not self._schema[name] then
    error(("builder: unknown field %q"):format(tostring(name)), 2)
  end
  self._values[name] = value
  return self
end

---@param name string
---@return any
function B:get(name)
  local v = self._values[name]
  if v == nil then
    v = self._schema[name] and self._schema[name].default
  end
  return v
end

---Validate and produce the product. Returns `product` or `nil, err`.
---@return table|nil
---@return string|nil err
function B:build()
  local out = {}
  for name, spec in pairs(self._schema) do
    local v = self:get(name)
    if v == nil and spec.required then
      return nil, ("missing required field %q"):format(name)
    end
    if v ~= nil and spec.validate then
      -- a validator that raises is a rejected value, not a crash of the caller
      local vok, valid = pcall(spec.validate, v)
      if not vok then
        return nil, ("validator of field %q raised: %s"):format(name, tostring(valid))
      end
      if not valid then
        return nil, ("invalid value for field %q"):format(name)
      end
    end
    out[name] = v
  end
  return out
end

---Returns a constructor function: each call yields a fresh builder.
---@param schema table<string, Lib.Patterns.Builder.Field>
---@return fun(): Lib.Patterns.Builder
function M.new(schema)
  if type(schema) ~= "table" then
    error("builder.new: schema must be a table", 2)
  end
  -- own copy: changing the schema afterwards must not bypass the checks of build()
  local own = {}
  for name, spec in pairs(schema) do
    if RESERVED[name] then
      error(("builder.new: field name %q is reserved"):format(name), 2)
    end
    if type(spec) ~= "table" then
      error(("builder.new: field %q must be a table"):format(tostring(name)), 2)
    end
    local field = {}
    for k, v in pairs(spec) do
      field[k] = v
    end
    own[name] = field
  end
  schema = own
  return function()
    return setmetatable({ _schema = schema, _values = {} }, B)
  end
end

return M
