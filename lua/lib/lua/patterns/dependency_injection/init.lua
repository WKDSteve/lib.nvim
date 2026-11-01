---@module 'lib.lua.patterns.dependency_injection'
--- Dependency injection: hand collaborators in instead of requiring them inside, so tests can swap them.
---
--- A small container: `provide(name, factory)` registers how to build something (`factory(container)`
--- may resolve other names), `value(name, v)` registers a ready value. `resolve(name)` builds on first
--- use and caches (singleton), `provide(..., { transient = true })` builds every time. Cycles raise.
--- `child()` makes an overlay that falls back to the parent, handy for a test or a per-project scope.
---
--- ```lua
--- local di = require("lib.lua.patterns.dependency_injection")
--- local c = di.new()
--- c:value("config", { root = "." })
--- c:provide("scanner", function(c) return make_scanner(c:resolve("config")) end)
--- c:resolve("scanner")
---
--- local test = c:child()
--- test:value("config", { root = "/tmp" }) -- only the child sees this
--- ```
---
--- Often a plain `opts` parameter (`opts.scanner or require("my.scanner")`) is all the injection needed;
--- use the container when one setup wires many parts together.

require("lib.lua.patterns.dependency_injection.@types")

local M = {}

---@class Lib.Patterns.Container
local K = {}
K.__index = K

---@param parent Lib.Patterns.Container|nil
---@return Lib.Patterns.Container
function M.new(parent)
  return setmetatable({ entries = {}, cache = {}, built = {}, parent = parent, resolving = {} }, K)
end

---@param name string
---@param factory fun(c: Lib.Patterns.Container): any
---@param opts { transient: boolean|nil }|nil
---@return Lib.Patterns.Container
function K:provide(name, factory, opts)
  if name == nil or name ~= name then
    error("dependency_injection.provide: name must not be nil or NaN", 2)
  end
  if type(factory) ~= "function" then
    error("dependency_injection.provide: factory must be a function", 2)
  end
  self.entries[name] = { factory = factory, transient = opts and opts.transient or false }
  self.cache[name] = nil
  self.built[name] = nil
  return self
end

---@param name string
---@param value any
---@return Lib.Patterns.Container
function K:value(name, value)
  if name == nil or name ~= name then
    error("dependency_injection.value: name must not be nil or NaN", 2)
  end
  self.entries[name] = { value = value, is_value = true }
  self.cache[name] = nil
  self.built[name] = nil
  return self
end

---@param name string
---@return boolean
function K:has(name)
  return self.entries[name] ~= nil or (self.parent ~= nil and self.parent:has(name))
end

---@param name string
---@return any
function K:resolve(name)
  local entry = self.entries[name]
  if not entry then
    if self.parent then
      return self.parent:resolve(name)
    end
    error(("dependency_injection: nothing provided for %q"):format(tostring(name)), 2)
  end
  if entry.is_value then
    return entry.value
  end
  if not entry.transient and self.built[name] then
    return self.cache[name]
  end
  if self.resolving[name] then
    error(("dependency_injection: cycle while resolving %q"):format(name), 2)
  end
  self.resolving[name] = true
  local ok, built = pcall(entry.factory, self)
  self.resolving[name] = nil
  if not ok then
    error(built, 0)
  end
  if not entry.transient then
    self.cache[name] = built
    self.built[name] = true
  end
  return built
end

---An overlay container; unknown names fall back to this one.
---@return Lib.Patterns.Container
function K:child()
  return M.new(self)
end

return M
