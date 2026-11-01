---@module 'lib.lua.error'
--- Structured-error + safe-call-with-traceback convention, pure Lua.
---
--- `M.new` builds a plain table describing an error (`kind`, `message`,
--- optional `data`) tagged with a `__lib_error` marker field so `M.is` can
--- recognize it. `M.safe_call` wraps a function call in `xpcall` with
--- `debug.traceback` as the message handler, returning `true, ...` on
--- success (all of `fn`'s return values preserved) or
--- `false, <structured error>` on failure.

local M = {}

---Build a structured error table.
---@nodiscard
---@param kind string
---@param message string
---@param data any? Optional extra context
---@return LibErrorValue err `{ kind, message, data, __lib_error = true }`
function M.new(kind, message, data)
  assert(type(kind) == "string", "kind must be a string")
  assert(type(message) == "string", "message must be a string")

  return {
    kind = kind,
    message = message,
    data = data,
    __lib_error = true,
  }
end

---True iff `value` is a table produced by `M.new`.
---@nodiscard
---@param value any
---@return boolean
function M.is(value)
  return type(value) == "table" and value.__lib_error == true
end

-- LuaJIT has no `table.pack`/`table.unpack`; the shim lives in one place.
-- `n` is what makes embedded `nil`s survive the round-trip.
local varargs = require("lib.lua.functions.varargs")
local pack_fn, unpack_fn = varargs.pack, varargs.unpack

-- Marker for the wrapper `traceback_handler` builds around a non-string error
-- value, so `safe_call` can tell it from a plain traceback string.
local RAW = {}

---@internal
--- `xpcall` message handler. A string error keeps the old behaviour (message
--- plus traceback in one string). Anything else (`error({ code = 7 })`,
--- `error(42)`, `error(nil)`) is not touched by `debug.traceback` -- it hands
--- the value back unchanged, which used to make `M.new` assert and `safe_call`
--- itself throw. Such a value is wrapped together with its traceback instead.
---@param err any
---@return string|table
local function traceback_handler(err)
  if type(err) == "string" then
    return debug.traceback(err, 2)
  end
  local shown_ok, shown = pcall(tostring, err)
  local label = shown_ok and shown or ("<" .. type(err) .. ">")
  return { [RAW] = true, value = err, traceback = debug.traceback(label, 2) }
end

---Call `fn(...)` guarded by `xpcall`, capturing a full traceback on failure.
---
---Correctly forwards multiple return values (and embedded `nil`s), so
---callers can do: `local ok, a, b, c = M.safe_call(fn, ...)`.
---
---A non-string error value (a table thrown with `error({ ... })`, a number,
---`nil`) is kept as-is in the structured error's `data` field, and `message`
---holds its `tostring` plus the traceback; a string error leaves `data` nil.
---@param fn function
---@param ... any Arguments forwarded to `fn`
---@return boolean ok
---@return any ... On success: all return values of `fn`. On failure: a single `LibErrorValue` (`kind = "runtime_error"`, `message` = traceback string, `data` = the original error value when it was not a string).
function M.safe_call(fn, ...)
  local args = pack_fn(...)

  local outcome = pack_fn(xpcall(function()
    return fn(unpack_fn(args, 1, args.n))
  end, traceback_handler))

  local ok = outcome[1]
  if not ok then
    local caught = outcome[2]
    if type(caught) == "table" and caught[RAW] then
      return false, M.new("runtime_error", caught.traceback, caught.value)
    end
    return false, M.new("runtime_error", caught)
  end

  return true, unpack_fn(outcome, 2, outcome.n)
end

---@type LibError
return M
