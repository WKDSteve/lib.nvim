---@meta
---@module 'lib.lua.patterns.iterator.@types'

---@alias Lib.Patterns.Iterator.Reducer fun(acc: any, v: any): any

---@class Lib.Patterns.Iterator
---@field next_fn fun(): any
---@field buffer any
---@field has_buffer boolean
---@field next fun(self: Lib.Patterns.Iterator): any
---@field peek fun(self: Lib.Patterns.Iterator): any
---@field has_next fun(self: Lib.Patterns.Iterator): boolean
---@field map fun(self: Lib.Patterns.Iterator, fn: fun(v: any): any): Lib.Patterns.Iterator
---@field filter fun(self: Lib.Patterns.Iterator, pred: fun(v: any): boolean): Lib.Patterns.Iterator
---@field take fun(self: Lib.Patterns.Iterator, n: integer): Lib.Patterns.Iterator
---@field drop fun(self: Lib.Patterns.Iterator, n: integer): Lib.Patterns.Iterator
---@field collect fun(self: Lib.Patterns.Iterator): any[]
---@field each fun(self: Lib.Patterns.Iterator, fn: fun(v: any))
---@field reduce fun(self: Lib.Patterns.Iterator, fn: Lib.Patterns.Iterator.Reducer, init: any): any
---@field iter fun(self: Lib.Patterns.Iterator): fun(): any
