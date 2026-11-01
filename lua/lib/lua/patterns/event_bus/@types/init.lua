---@meta
---@module 'lib.lua.patterns.event_bus.@types'

---@class Lib.Patterns.EventBus
---@field topics table<string, any> # lib.lua.listeners lists
---@field on fun(self: Lib.Patterns.EventBus, topic: string, fn: function): fun()
---@field once fun(self: Lib.Patterns.EventBus, topic: string, fn: function): fun()
---@field emit fun(self: Lib.Patterns.EventBus, topic: string, ...: any): integer, any[]
---@field count fun(self: Lib.Patterns.EventBus, topic: string): integer
---@field clear fun(self: Lib.Patterns.EventBus, topic: string|nil)
