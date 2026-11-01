---@meta
---@module 'lib.lua.patterns.dependency_injection.@types'

---@alias Lib.Patterns.Container.Factory fun(c: Lib.Patterns.Container): any

---@class Lib.Patterns.Container
---@field entries table<string, table>
---@field cache table<string, any>
---@field built table<string, boolean>
---@field parent Lib.Patterns.Container|nil
---@field resolving table<string, boolean>
---@field provide fun(self: Lib.Patterns.Container, name: string, factory: Lib.Patterns.Container.Factory, opts: { transient: boolean|nil }|nil): Lib.Patterns.Container
---@field value fun(self: Lib.Patterns.Container, name: string, value: any): Lib.Patterns.Container
---@field has fun(self: Lib.Patterns.Container, name: string): boolean
---@field resolve fun(self: Lib.Patterns.Container, name: string): any
---@field child fun(self: Lib.Patterns.Container): Lib.Patterns.Container
