# `lib.lua.patterns.state`

> Pattern: State (GoF) · Group: behavioral · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.

An object whose methods come from its current state; each state is a table of functions.

## The pattern in one paragraph

Behaviour depends on a mode, and each mode owns its methods instead of one object testing `if self.mode == ...` everywhere. `obj:method(...)` runs `states[current].method(obj, ...)`; `set_state` switches with `exit`/`enter` hooks; a state may define `default` for unlisted methods. A method the state lacks raises and names the state. Note: reading a key no state defines returns `nil`, unless some state has a `default`; then every key reads as a method that goes to `default`.

## Usage

```lua
local state = require("lib.lua.patterns.state")

local door = state.new({
  initial = "closed",
  fields = { opened = 0 },
  states = {
    closed = { open = function(self) self.opened = self.opened + 1; self:set_state("open") end },
    open = { close = function(self) self:set_state("closed") end },
  },
})
door:open(); door:close()
```

## API

| Function | Does |
| --- | --- |
| `new(spec)` | `states`, `initial`, optional `fields` (raw fields on the object) |
| `obj:set_state(name)` / `obj:current_state()` / `obj:is_state(name)` | switch / inspect |
| state table keys `enter(self, from)`, `exit(self, to)`, `default(self, ...)` | hooks |

## When it helps / when it does not (Lua view)

- **Helps when:** several operations behave differently per mode (editing/viewing, connected/disconnected) and the `if mode` checks spread over many functions.
- **Does not help when:** there are two states or one operation; a boolean and an `if` is simpler. For rules about which event may follow which, use `lib.lua.patterns.state_machine`.
- **Cheaper alternative in Lua:** a table `handlers[mode]` looked up at the call site.

## Related

- `lib.lua.patterns.state_machine` (event/transition driven), Strategy (the choice is made by the caller, here by the object itself).

## Tests

`TESTS/patterns_state_spec.lua`: dispatch to the state, hooks order, default, missing method, unknown state.
