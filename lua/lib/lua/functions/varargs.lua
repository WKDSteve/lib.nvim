---@module 'lib.lua.functions.varargs'
--- `pack` and `unpack` that work on Neovim's LuaJIT.
---
--- LuaJIT (Lua 5.1) has neither `table.pack` nor `table.unpack`: it provides the global `unpack` and no
--- `pack` at all. This module is the one place that knows that, so callers do not repeat the shim and its
--- diagnostic suppression. It requires nothing, so any module (also `lib.lua.error`) can load it.
---
--- ```lua
--- local varargs = require("lib.lua.functions.varargs")
--- local packed = varargs.pack(f())               --> { n = <count>, ... } (trailing nils survive)
--- return varargs.unpack(packed, 1, packed.n)
--- ```

local M = {}

---`{ ..., n = <count> }`: `n` is what lets embedded and trailing `nil`s survive the round trip (`#` and
---`ipairs` cannot, see rules-vault `ERR-63`).
---@param ... any
---@return { n: integer, [integer]: any }
function M.pack(...)
  return { n = select("#", ...), ... }
end

---`table.unpack` where it exists, else the global `unpack`. Pass the count: `unpack(t, 1, t.n)`.
---@type fun(list: table, i?: integer, j?: integer): ...
---@diagnostic disable-next-line: deprecated
M.unpack = table.unpack or unpack

return M
