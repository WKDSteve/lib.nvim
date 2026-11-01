---@module 'lib.lua.patterns.chain_of_responsibility'
--- Chain of responsibility: an ordered list of handlers; the first one that claims the request ends the
--- chain.
---
--- Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.
---
--- A handler is `fn(request, ...) -> handled, result`. Returning a falsy `handled` passes the request on.
--- A handler that raises counts as "not handled"; the error is collected, the chain continues.
---
--- ```lua
--- local chain = require("lib.lua.patterns.chain_of_responsibility").new()
--- chain:add("lua", function(path) if path:match("%.lua$") then return true, "lua file" end end)
--- chain:add("any", function(path) return true, "other" end)
--- chain:handle("a.lua") --> true, "lua file", "lua", {}
--- ```

require("lib.lua.patterns.chain_of_responsibility.@types")

local M = {}

---@class Lib.Patterns.Chain
local C = {}
C.__index = C

---@return Lib.Patterns.Chain
function M.new()
  return setmetatable({ handlers = {}, index = {}, handling = 0 }, C)
end

---The handler list a mutation may change. While a `handle` is walking the list it keeps its own
---reference, so a mutation made by a handler works on a copy (handle itself never copies).
---@param self Lib.Patterns.Chain
---@return table[]
local function writable(self)
  if self.handling > 0 then
    local copy = {}
    for i, h in ipairs(self.handlers) do
      copy[i] = h
    end
    self.handlers = copy
  end
  return self.handlers
end

---Append a handler; `opts.first = true` puts it at the front. A handler with the same name is replaced.
---@param name string
---@param fn fun(request: any, ...): boolean|nil, any
---@param opts { first: boolean|nil }|nil
---@return Lib.Patterns.Chain
function C:add(name, fn, opts)
  if type(fn) ~= "function" then
    error("chain_of_responsibility.add: handler must be a function", 2)
  end
  if self.index[name] then
    self:remove(name)
  end
  local handlers = writable(self)
  local entry = { name = name, fn = fn }
  if opts and opts.first then
    table.insert(handlers, 1, entry)
  else
    handlers[#handlers + 1] = entry
  end
  self.index[name] = true
  return self
end

---@param name string
---@return boolean
function C:remove(name)
  if not self.index[name] then
    return false
  end
  local handlers = writable(self)
  for i, h in ipairs(handlers) do
    if h.name == name then
      table.remove(handlers, i)
      self.index[name] = nil
      return true
    end
  end
  return false
end

---@return string[]
function C:names()
  local out = {}
  for i, h in ipairs(self.handlers) do
    out[i] = h.name
  end
  return out
end

---Offer the request to the handlers in order.
---@param request any
---@param ... any
---@return boolean handled
---@return any result
---@return string|nil handler_name
---@return any[] errors
function C:handle(request, ...)
  local errors
  -- no copy: the list this call walks is never mutated in place while handling > 0 (see writable)
  local handlers = self.handlers
  self.handling = self.handling + 1
  for i = 1, #handlers do
    local h = handlers[i]
    local ok, handled, result = pcall(h.fn, request, ...)
    if not ok then
      errors = errors or {}
      errors[#errors + 1] = handled == nil and "nil error" or handled
    elseif handled then
      self.handling = self.handling - 1
      return true, result, h.name, errors or {}
    end
  end
  self.handling = self.handling - 1
  return false, nil, nil, errors or {}
end

return M
