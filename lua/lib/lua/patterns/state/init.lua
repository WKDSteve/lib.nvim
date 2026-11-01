---@module 'lib.lua.patterns.state'
--- State (GoF): an object whose behaviour changes with its current state; each state is a table of
--- methods.
---
--- `state.new({ states = {...}, initial = "..." })` returns an object. Calling `obj:method(...)` runs
--- `states[current].method(obj, ...)`; `obj:set_state(name)` switches (running `exit` of the old and
--- `enter` of the new state). A method the current state does not have raises, unless the state table has
--- a `default` function.
---
--- ```lua
--- local state = require("lib.lua.patterns.state")
--- local door = state.new({
---   initial = "closed",
---   states = {
---     closed = { open = function(self) self:set_state("open") end },
---     open = { close = function(self) self:set_state("closed") end, enter = function() print("open!") end },
---   },
--- })
--- door:open()
--- door:close()
--- ```
---
--- Compare `state_machine`: that one is driven by named events and declared transitions; this one is
--- about behaviour per state. For two or three states a `mode` string and an `if` is simpler.

require("lib.lua.patterns.state.@types")

local M = {}

local OBJ = {}

-- one dispatcher per method name some state defines, shared by all objects (it only needs obj and key)
local dispatchers = {}

---@param key any
---@return function
local function make_dispatcher(key)
  return function(obj, ...)
    local st = obj._states[obj._current]
    local fn = st[key] or st.default
    if not fn then
      error(("state: %q is not available in state %q"):format(tostring(key), obj._current), 2)
    end
    return fn(obj, ...)
  end
end

OBJ.__index = function(self, key)
  local own = rawget(OBJ, key)
  if own then
    return own
  end
  local methods = self._methods
  if methods[key] then
    local d = dispatchers[key]
    if not d then
      d = make_dispatcher(key)
      dispatchers[key] = d
    end
    return d
  end
  -- not a method of any state: a state with `default` answers every name, but such a name must not grow the
  -- shared cache (an arbitrary key is not bounded); without `default` it is simply not there
  if methods.default then
    return make_dispatcher(key)
  end
  return nil
end

---@param name string
function OBJ:set_state(name)
  local new = self._states[name]
  if not new then
    error(("state: unknown state %q"):format(tostring(name)), 2)
  end
  local old = self._states[self._current]
  local from = self._current
  if old and old.exit then
    old.exit(self, name)
  end
  self._current = name
  if new.enter then
    new.enter(self, from)
  end
end

---@return string
function OBJ:current_state()
  return self._current
end

---@param name string
---@return boolean
function OBJ:is_state(name)
  return self._current == name
end

---@param spec { states: table<string, table<string, function>>, initial: string, fields: table|nil }
---@return table
function M.new(spec)
  if type(spec) ~= "table" or type(spec.states) ~= "table" or not spec.states[spec.initial] then
    error("state.new: spec.states and a known spec.initial are required", 2)
  end
  local methods = {}
  for _, def in pairs(spec.states) do
    for method in pairs(def) do
      methods[method] = true
      if method == "set_state" or method == "current_state" or method == "is_state" then
        error(
          ("state.new: %q is a built-in method and cannot be defined by a state"):format(method),
          2
        )
      end
    end
  end
  local obj =
    setmetatable({ _states = spec.states, _current = spec.initial, _methods = methods }, OBJ)
  for k, v in pairs(spec.fields or {}) do
    if k == "_states" or k == "_current" or k == "_methods" then
      error(("state.new: field %q is reserved"):format(k), 2)
    end
    rawset(obj, k, v)
  end
  local init = spec.states[spec.initial]
  if init.enter then
    init.enter(obj, nil)
  end
  return obj
end

return M
