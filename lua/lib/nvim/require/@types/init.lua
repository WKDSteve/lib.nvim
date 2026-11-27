---@meta
---@module 'lib.nvim.require.@types'

---@class Lib.Require
---@field safe fun(name: string): boolean, any
---@field dir fun(dir: string, calls?: string|string[]|""): nil
---@field lazy fun(module_name: string): fun(): table
---@field installed fun(mod: string, opts?: { repo?: string }): boolean

return {}
