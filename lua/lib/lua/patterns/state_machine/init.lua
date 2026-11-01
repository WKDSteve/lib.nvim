---@module 'lib.lua.patterns.state_machine'
--- State machine: declared states and transitions with optional guards and actions.
---
--- Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.
---
--- ```lua
--- local sm = require("lib.lua.patterns.state_machine").new({
---   initial = "idle",
---   transitions = {
---     { from = "idle", event = "start", to = "running" },
---     { from = "running", event = "stop", to = "idle", guard = function(ctx) return not ctx.locked end },
---   },
---   on_enter = { running = function(from, event) print("now running") end },
--- })
--- sm:fire("start")   --> true, "running"
--- sm:can("start")    --> false
--- ```
---
--- `from` may be a list of states or `"*"` (any). Unknown events and failed guards return
--- `false, reason` instead of raising, so the caller decides.

require("lib.lua.patterns.state_machine.@types")

local listeners = require("lib.lua.listeners")

local M = {}

---@param from string|string[]
---@return string[]
local function from_list(from)
  if type(from) == "table" then
    return from
  end
  return { from }
end

---@class Lib.Patterns.StateMachine
local SM = {}
SM.__index = SM

---@param spec Lib.Patterns.StateMachine.Spec
---@return Lib.Patterns.StateMachine
function M.new(spec)
  if type(spec) ~= "table" or type(spec.initial) ~= "string" then
    error("state_machine.new: spec.initial (string) is required", 2)
  end
  local known = { [spec.initial] = true }
  for i, t in ipairs(spec.transitions or {}) do
    if type(t.event) ~= "string" or type(t.to) ~= "string" then
      error(("state_machine.new: transition %d needs string event and to"):format(i), 2)
    end
    known[t.to] = true
    local from = from_list(t.from)
    for _, f in ipairs(from) do
      if f ~= "*" then
        known[f] = true
      end
    end
  end
  for name in pairs(spec.on_enter or {}) do
    if not known[name] then
      error(("state_machine.new: on_enter names unknown state %q"):format(name), 2)
    end
  end
  for name in pairs(spec.on_exit or {}) do
    if not known[name] then
      error(("state_machine.new: on_exit names unknown state %q"):format(name), 2)
    end
  end
  return setmetatable({
    spec = spec,
    current = spec.initial,
    ctx = spec.ctx or {},
    listeners = listeners.new(),
  }, SM)
end

---@return string
function SM:state()
  return self.current
end

---@param s string
---@return boolean
function SM:is(s)
  return self.current == s
end

---@param self Lib.Patterns.StateMachine
---@param event string
---@return table|nil transition
---@return string|nil reason
local function find(self, event)
  local seen_event, guard_rejected = false, false
  for _, t in ipairs(self.spec.transitions or {}) do
    if t.event == event then
      seen_event = true
      local from = from_list(t.from)
      for _, f in ipairs(from) do
        if f == "*" or f == self.current then
          if not t.guard or t.guard(self.ctx, self.current, event) then
            return t
          end
          -- keep looking: a later transition for the same event may have a guard that passes
          guard_rejected = true
          break
        end
      end
    end
  end
  if guard_rejected then
    return nil, "guard rejected"
  end
  return nil,
    seen_event and ("event %q not allowed in state %q"):format(event, self.current)
      or ("unknown event %q"):format(event)
end

---Whether `event` would be accepted now.
---@param event string
---@return boolean
function SM:can(event)
  return find(self, event) ~= nil
end

---Fire an event. Returns `true, new_state` or `false, reason`.
---Order: `on_exit` of the old state, the transition `action`, the state switches, change listeners,
---`on_enter` of the new state. A hook or action that raises propagates; the state only switches after
---the action returned, but an `on_exit` that already ran is not undone.
---@param event string
---@param ... any # passed to the transition action
---@return boolean ok
---@return string reason_or_state
function SM:fire(event, ...)
  local t, reason = find(self, event)
  if not t then
    return false, reason or "rejected"
  end
  local from, to = self.current, t.to
  local exit = (self.spec.on_exit or {})[from]
  if exit then
    exit(to, event, self.ctx)
  end
  if t.action then
    t.action(self.ctx, from, to, ...)
  end
  if self.current ~= from then
    error(
      "state_machine: the state changed during the transition (fire() inside on_exit or an action is not allowed, use on_enter)",
      2
    )
  end
  self.current = to
  -- listeners run before on_enter, so a fire() made inside on_enter reports its change after this one
  self.listeners:each(function(l)
    pcall(l, to, from, event)
  end)
  local enter = (self.spec.on_enter or {})[to]
  if enter then
    enter(from, event, self.ctx)
  end
  return true, to
end

---Subscribe to every state change. Returns the unsubscribe function.
---@param fn fun(new: string, old: string, event: string)
---@return fun()
function SM:on_change(fn)
  if type(fn) ~= "function" then
    error("state_machine.on_change: listener must be a function", 2)
  end
  return self.listeners:add(fn)
end

return M
