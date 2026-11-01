---@module 'lib.lua.context_manager'
--- Lua's missing try/finally as one small composable primitive, pure Lua
--- (no `vim` API). Built on `lib.lua.error.safe_call` for the actual
--- pcall + multi-return-safe forwarding — this module only adds the
--- "guarantee `release` runs" contract on top.
---
--- No existing module in this codebase has a generic "acquire a scarce
--- resource, guarantee its release" primitive: `lib.nvim.fs.dir_guard`'s
--- `handle.bypass(fn)` is the closest prior art (pcall-wraps a body,
--- unconditionally restores state after), but it is scoped to that one
--- module, not reusable. Not retrofitted onto `dir_guard`/`cache`/`lock`
--- here — they keep their current shape; this is a new primitive for
--- future callers.
---
---```lua
--- local with = require("lib.lua.context_manager").with
---
--- local ok, result_or_err = with(function()
---   return io.open("/tmp/x.txt", "w") -- resource, err
--- end, function(f)
---   f:close() -- release: always runs, even if body errors
--- end, function(f) -- body
---   f:write("hello\n")
---   return "done"
--- end)
---```

local error_mod = require("lib.lua.error")

local varargs = require("lib.lua.functions.varargs")
local pack, unpack = varargs.pack, varargs.unpack

local M = {}

--- Acquire a resource, run `body(resource)` against it, and guarantee
--- `release(resource)` runs afterward — on a normal return *and* on a
--- `body` error. `release` never runs at all if `acquire` itself fails
--- (`resource == nil`): there is nothing to release.
---@param acquire fun(): any, string|nil # Returns `resource, err`; `err` only meaningful when `resource` is `nil`.
---@param release fun(resource: any) # Always called if `acquire` succeeded, regardless of `body`'s outcome.
---@param body fun(resource: any): ...
---@return boolean ok
---@return any ... `body`'s return values on success; `acquire`'s error string, or a structured `LibErrorValue` from a `body` error, on failure.
function M.with(acquire, release, body)
  local resource, acquire_err = acquire()
  if resource == nil then
    return false, acquire_err
  end

  local results = pack(error_mod.safe_call(body, resource))
  release(resource)

  return unpack(results, 1, results.n)
end

---@type Lib.ContextManager
return M
