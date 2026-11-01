---@meta
---@module 'lib.lua.listeners.@types'

---@class Lib.Lua.Listeners.Opts
---@field on_empty? fun(list: Lib.Lua.Listeners.List) # called once the last live value is gone, never while an `each` walks the list

---@class Lib.Lua.Listeners
---@field new fun(opts?: Lib.Lua.Listeners.Opts): Lib.Lua.Listeners.List

---@class Lib.Lua.Listeners.List
---@field add fun(self: Lib.Lua.Listeners.List, value: any): fun() # returns an idempotent remove function
---@field remove fun(self: Lib.Lua.Listeners.List, value: any): boolean # removes the first live equal value
---@field each fun(self: Lib.Lua.Listeners.List, fn: fun(value: any))
---@field values fun(self: Lib.Lua.Listeners.List): any[]
---@field count fun(self: Lib.Lua.Listeners.List): integer
---@field clear fun(self: Lib.Lua.Listeners.List)
