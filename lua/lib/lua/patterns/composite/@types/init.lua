---@meta
---@module 'lib.lua.patterns.composite.@types'

---@class Lib.Patterns.Composite
---@field items any # a lib.lua.listeners list (this check does not see its type)
---@field is_composite boolean
---@field add fun(self: Lib.Patterns.Composite, child: table): Lib.Patterns.Composite
---@field remove fun(self: Lib.Patterns.Composite, child: table): boolean
---@field size fun(self: Lib.Patterns.Composite): integer
---@field call fun(self: Lib.Patterns.Composite, method: string, ...: any): any[], any[]
