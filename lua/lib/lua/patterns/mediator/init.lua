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

local listeners = require("lib.lua.listeners")
local varargs = require("lib.lua.functions.varargs")
local pack, unpack = varargs.pack, varargs.unpack

local M = {}

---@class Lib.Patterns.Mediator
local D = {}
D.__index = D

---@return Lib.Patterns.Mediator
function M.new()
  return setmetatable({ components = {}, order = listeners.new(), offs = {} }, D)
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
    self.offs[name] = self.order:add(name)
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
  self.offs[name]()
  self.offs[name] = nil
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
  local args = pack(...)
  -- components registered meanwhile are not reached; ones unregistered meanwhile are skipped
  self.order:each(function(name)
    local comp = self.components[name]
    if name ~= from and comp then
      reached = reached + 1
      local ok, err = pcall(comp.handle, from, message, unpack(args, 1, args.n))
      if not ok then
        errors[#errors + 1] = err == nil and "nil error" or err
      end
    end
  end)
  return reached, errors
end

---@return string[]
function D:names()
  return self.order:values()
end

return M
