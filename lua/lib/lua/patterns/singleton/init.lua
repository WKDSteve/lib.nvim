---@module 'lib.lua.patterns.singleton'
--- Singleton: exactly one instance, created on first use.
---
--- Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.
---
--- In Lua a module table already is a singleton (`local M = {}`), which is what you want in nearly every
--- case. This module covers the rest: an instance that must be created lazily (it is expensive, or needs
--- the editor to be ready) and that tests must be able to throw away.
---
--- ```lua
--- local singleton = require("lib.lua.patterns.singleton")
--- local cache = singleton.new(function() return load_index() end)
--- cache:get()          -- creates on first call, then returns the same object
--- cache:reset()        -- tests: the next get() creates again
--- ```

require("lib.lua.patterns.singleton.@types")

local M = {}

---@class Lib.Patterns.Singleton
local S = {}
S.__index = S

---@param factory fun(): any
---@return Lib.Patterns.Singleton
function M.new(factory)
  if type(factory) ~= "function" then
    error("singleton.new: factory must be a function", 2)
  end
  return setmetatable({ factory = factory, created = false, instance = nil, creating = false }, S)
end

---@return any
function S:get()
  if not self.created then
    if self.creating then
      error("singleton: factory is re-entrant (get() called while creating)", 2)
    end
    self.creating = true
    local ok, inst = pcall(self.factory)
    self.creating = false
    if not ok then
      error(inst, 0)
    end
    self.instance = inst
    self.created = true
  end
  return self.instance
end

---@return boolean
function S:is_created()
  return self.created
end

---Forget the instance; the next `get()` calls the factory again.
function S:reset()
  self.instance = nil
  self.created = false
end

return M
