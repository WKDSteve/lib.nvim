---@module 'lib.lua.patterns.mediator'
--- Mediator: components talk to one coordinator instead of to each other.
---
--- A component is registered under a name with a `handle(from, message, ...)` function. Others reach it
--- through `send(from, to, message, ...)` or `broadcast(from, message, ...)`; no component holds a
--- reference to another.
---
--- ```lua
--- local mediator = require("lib.lua.patterns.mediator")
--- local m = mediator.new()
--- m:register("tree", { handle = function(from, msg, path) if msg == "open" then open_in_tree(path) end end })
--- m:register("preview", { handle = function(from, msg, path) show(path) end })
--- m:send("tree", "preview", "show", "a.md")
--- m:broadcast("tree", "closed")
--- ```

require("lib.lua.patterns.mediator.@types")

local M = {}

---@class Lib.Patterns.Mediator
local D = {}
D.__index = D

---@return Lib.Patterns.Mediator
function M.new()
  return setmetatable({ components = {}, order = {} }, D)
end

---@param name string
---@param component { handle: fun(from: string, message: any, ...): any }
---@return Lib.Patterns.Mediator
function D:register(name, component)
  if name == nil or name ~= name then
    error("mediator.register: name must not be nil or NaN", 2)
  end
  if type(component) ~= "table" or type(component.handle) ~= "function" then
    error("mediator.register: component needs a handle function", 2)
  end
  if not self.components[name] then
    self.order[#self.order + 1] = name
  end
  self.components[name] = component
  return self
end

---@param name string
---@return boolean
function D:unregister(name)
  if not self.components[name] then
    return false
  end
  self.components[name] = nil
  for i, n in ipairs(self.order) do
    if n == name then
      table.remove(self.order, i)
      break
    end
  end
  return true
end

---Deliver to one component and return its result. An unknown target raises.
---@param from string
---@param to string
---@param message any
---@param ... any
---@return any
function D:send(from, to, message, ...)
  local target = self.components[to]
  if not target then
    error(("mediator: no component %q"):format(tostring(to)), 2)
  end
  return target.handle(from, message, ...)
end

---Deliver to every component except the sender, in registration order. A raising component does not
---stop the rest; returns the number reached and the errors.
---@param from string
---@param message any
---@param ... any
---@return integer reached
---@return any[] errors
function D:broadcast(from, message, ...)
  local reached, errors = 0, {}
  local names = {}
  for i, n in ipairs(self.order) do
    names[i] = n
  end
  for _, name in ipairs(names) do
    local comp = self.components[name]
    if name ~= from and comp then
      reached = reached + 1
      local ok, err = pcall(comp.handle, from, message, ...)
      if not ok then
        errors[#errors + 1] = err == nil and "nil error" or err
      end
    end
  end
  return reached, errors
end

---@return string[]
function D:names()
  local out = {}
  for i, n in ipairs(self.order) do
    out[i] = n
  end
  return out
end

return M
