---@meta
---@module 'lib.lua.patterns.state_machine.@types'

---@class Lib.Patterns.StateMachine.Transition
---@field from string|string[]                # A state, a list of states, or `"*"`.
---@field event string
---@field to string
---@field guard (fun(ctx: table, from: string, event: string): boolean)|nil
---@field action (fun(ctx: table, from: string, to: string, ...: any))|nil

---@class Lib.Patterns.StateMachine.Spec
---@field initial string
---@field transitions Lib.Patterns.StateMachine.Transition[]|nil
---@field on_enter table<string, fun(from: string, event: string, ctx: table)>|nil
---@field on_exit table<string, fun(to: string, event: string, ctx: table)>|nil
---@field ctx table|nil                       # Shared context handed to guards and actions.

---@class Lib.Patterns.StateMachine
---@field spec Lib.Patterns.StateMachine.Spec
---@field current string
---@field ctx table
---@field listeners any # a lib.lua.listeners list (this check does not see its type)
---@field state fun(self: Lib.Patterns.StateMachine): string
---@field is fun(self: Lib.Patterns.StateMachine, s: string): boolean
---@field can fun(self: Lib.Patterns.StateMachine, event: string): boolean
---@field fire fun(self: Lib.Patterns.StateMachine, event: string, ...: any): boolean, string
---@field on_change fun(self: Lib.Patterns.StateMachine, fn: fun(new: string, old: string, event: string)): fun()
