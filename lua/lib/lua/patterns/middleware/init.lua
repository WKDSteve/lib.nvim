---@module 'lib.lua.patterns.middleware'
--- Middleware: an ordered list of stages, each `fn(ctx, next)`. A stage may change `ctx`, call `next()`
--- to continue, or return without calling it to stop the chain. The innermost step is the optional
--- `final(ctx)`.
---
--- Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.
---
--- ```lua
--- local middleware = require("lib.lua.patterns.middleware")
--- local chain = middleware.new()
--- chain:use(function(ctx, next) ctx.t0 = os.clock(); local r = next(); ctx.dt = os.clock() - ctx.t0; return r end)
--- chain:use(function(ctx, next) if not ctx.path then return nil, "no path" end return next() end)
--- chain:run({ path = "a.lua" }, function(ctx) return ctx.path end) --> "a.lua"
--- ```

require("lib.lua.patterns.middleware.@types")

local M = {}

---@class Lib.Patterns.Middleware
local C = {}
C.__index = C

---@return Lib.Patterns.Middleware
function M.new()
  return setmetatable({ stages = {} }, C)
end

---Append a stage. Returns the chain for chaining.
---@param stage fun(ctx: table, next: fun(): ...): ...
---@return Lib.Patterns.Middleware
function C:use(stage)
  if type(stage) ~= "function" then
    error("middleware.use: stage must be a function", 2)
  end
  self.stages[#self.stages + 1] = stage
  return self
end

---Run the chain. Returns whatever the stages return. A stage calling `next()` twice raises.
---@param ctx table
---@param final fun(ctx: table): ...|nil
---@return ...
function C:run(ctx, final)
  local stages = self.stages
  local n = #stages
  local function dispatch(i)
    local called = false
    return function()
      if called then
        error("middleware: next() called more than once", 2)
      end
      called = true
      if i > n then
        if final then
          return final(ctx)
        end
        return
      end
      return stages[i](ctx, dispatch(i + 1))
    end
  end
  return dispatch(1)()
end

return M
