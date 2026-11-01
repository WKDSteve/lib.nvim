---@meta
---@module 'lib.lua.patterns.repository.@types'

---Visits the entries in order; `fn` returning true stops the walk.
---@alias Lib.Patterns.Store.Each fun(fn: fun(id: any, value: any): boolean|nil)

---@alias Lib.Patterns.Store.Count fun(): integer

---@class Lib.Patterns.Store
---@field get fun(id: any): any
---@field put fun(id: any, value: any)
---@field delete fun(id: any)
---@field all fun(): { id: any, value: any }[]
---@field each Lib.Patterns.Store.Each|nil # Optional: `repository` uses it to stop early.
---@field count Lib.Patterns.Store.Count|nil # Optional: number of entries without building the list.

---@class Lib.Patterns.Repository
---@field store Lib.Patterns.Store
---@field get fun(self: Lib.Patterns.Repository, id: any): any
---@field save fun(self: Lib.Patterns.Repository, id: any, value: any)
---@field remove fun(self: Lib.Patterns.Repository, id: any)
---@field all fun(self: Lib.Patterns.Repository): { id: any, value: any }[]
---@field find fun(self: Lib.Patterns.Repository, predicate: fun(value: any, id: any): boolean): { id: any, value: any }|nil
---@field filter fun(self: Lib.Patterns.Repository, predicate: fun(value: any, id: any): boolean): { id: any, value: any }[]
---@field count fun(self: Lib.Patterns.Repository): integer
