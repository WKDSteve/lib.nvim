---@module 'lib.lua.functions'
--- Aggregator for lib.lua's higher-order function helpers (noop, identity,
--- const, raise, etc.), lazily delegating to lib.lua.functions.meta.
---@see lib.lua.functions.meta
---@see lib.lua.functions.varargs

local lazy = require("lib.lua.lazy")
---@type Lib.Functions.Meta
local meta = lazy.require("lib.lua.functions.meta")

local M = {}

M.noop = meta.noop
M.identity = meta.identity
M.always_true = meta.always_true
M.always_false = meta.always_false
M.const = meta.const
M.raise = meta.raise

local varargs = lazy.require("lib.lua.functions.varargs")
M.pack = varargs.pack
M.unpack = varargs.unpack

---@type Lib.Functions
return M
