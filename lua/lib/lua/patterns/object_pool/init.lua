---@module 'lib.lua.patterns.object_pool'
--- Object pool: reuse expensive objects (scratch tables, timers, buffers) instead of creating and
--- dropping them. `acquire()` hands out a free object or creates one, `release(obj)` resets it and keeps
--- it for the next caller, up to `max` idle objects.
---
--- Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.
---
--- ```lua
--- local pool = require("lib.lua.patterns.object_pool").new({
---   create = function() return {} end,
---   reset = function(t) for k in pairs(t) do t[k] = nil end end,
---   max = 8,
--- })
--- pool:with(function(t) t.x = 1 end)
--- ```
---
--- Worth it only for objects that are costly to create. Lua tables are cheap; measure first.

require("lib.lua.patterns.object_pool.@types")

local M = {}

---Release `obj`, then return the results of the protected call or re-raise its error.
local function finish_with(self, obj, ok, ...)
  self:release(obj)
  if not ok then
    error((...), 0)
  end
  return ...
end

---@class Lib.Patterns.ObjectPool
local P = {}
P.__index = P

---@param opts Lib.Patterns.ObjectPool.Opts
---@return Lib.Patterns.ObjectPool
function M.new(opts)
  if type(opts) ~= "table" or type(opts.create) ~= "function" then
    error("object_pool.new: opts.create (function) is required", 2)
  end
  local max = opts.max
  if max == nil then
    max = 16
  end
  if type(max) ~= "number" or max ~= max or max < 0 then
    error("object_pool.new: opts.max must be a number >= 0", 2)
  end
  return setmetatable({
    create = opts.create,
    reset = opts.reset,
    destroy = opts.destroy,
    max = math.floor(max),
    idle = {},
    is_idle = {},
    created = 0,
    reused = 0,
  }, P)
end

---@return any
function P:acquire()
  local obj = table.remove(self.idle)
  if obj ~= nil then
    self.is_idle[obj] = nil
    self.reused = self.reused + 1
    return obj
  end
  local fresh = self.create()
  self.created = self.created + 1
  return fresh
end

---Return an object. It is reset and kept if there is room, otherwise destroyed.
---@param obj any
function P:release(obj)
  if obj == nil or self.is_idle[obj] then
    -- nil, or an object that is already idle: handing it out twice would alias two users
    return
  end
  if #self.idle >= self.max then
    if self.destroy then
      pcall(self.destroy, obj)
    end
    return
  end
  if self.reset then
    local ok = pcall(self.reset, obj)
    if not ok then
      if self.destroy then
        pcall(self.destroy, obj)
      end
      return
    end
  end
  self.idle[#self.idle + 1] = obj
  self.is_idle[obj] = true
end

---Acquire, run `fn(obj)`, release even if `fn` raises (the error is re-raised after the release).
---@param fn fun(obj: any): ...
---@return ...
function P:with(fn)
  local obj = self:acquire()
  return finish_with(self, obj, pcall(fn, obj))
end

---Destroy every idle object.
function P:clear()
  if self.destroy then
    for _, obj in ipairs(self.idle) do
      pcall(self.destroy, obj)
    end
  end
  self.idle = {}
  self.is_idle = {}
end

---@return { idle: integer, created: integer, reused: integer }
function P:stats()
  return { idle = #self.idle, created = self.created, reused = self.reused }
end

return M
