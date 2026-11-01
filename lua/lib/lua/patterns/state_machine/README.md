# `lib.lua.patterns.state_machine`

> Pattern: State Machine (table-driven cousin of State) · Group: modern · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.

Declared states and transitions with optional guards, actions and enter/exit hooks.

## The pattern in one paragraph

Instead of scattering `if mode == "running" and event == "stop"` through the code, the allowed transitions are data: `from` (a state, a list, or `"*"`), `event`, `to`, optional `guard` and `action`. Invalid events return `false, reason` and leave the state alone, so illegal states are unreachable by construction.

## Usage

```lua
local state_machine = require("lib.lua.patterns.state_machine")

local sm = state_machine.new({
  initial = "idle",
  transitions = {
    { from = "idle", event = "start", to = "running" },
    { from = "running", event = "stop", to = "idle", guard = function(ctx) return not ctx.locked end },
    { from = "*", event = "reset", to = "idle" },
  },
  on_enter = { running = function(from, event) print("running") end },
})
sm:fire("start") --> true, "running"
sm:can("start")  --> false
```

## API

| Function | Does |
| --- | --- |
| `new(spec)` | `initial`, `transitions`, `on_enter`, `on_exit`, `ctx`; unknown states in hooks raise |
| `sm:fire(event, ...)` | `true, new_state` or `false, reason`; order: exit, action, switch, change listeners, enter (a raising action leaves the state unchanged, an `on_exit` that already ran is not undone) |
| `sm:can(event)` / `sm:is(s)` / `sm:state()` | inspect |
| `sm:on_change(fn)` | subscribe `fn(new, old, event)`, returns unsubscribe |

Listeners live in a [`lib.lua.listeners`](../../listeners/README.md) list: one unsubscribed by an earlier listener during the same change is skipped, one added meanwhile is not called by it.

## When it helps / when it does not (Lua view)

- **Helps when:** a lifecycle has four or more states with rules about what may follow what (test-run phases, a markdown block parser, connection handling).
- **Does not help when:** there are two states; a boolean is enough.
- **Cheaper alternative in Lua:** a `state` string plus a table `{ idle = { start = "running" } }`.

## Related

- Strategy / State (behaviour per state), `lib.nvim.async` (flows with waiting), Command.

## Tests

`TESTS/patterns_state_machine_spec.lua`: transitions, guard, hook order, wildcard, unknown event, subscription, construction errors.
