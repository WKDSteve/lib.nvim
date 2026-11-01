# `lib.lua.patterns.event_bus`

> Pattern: Event Bus (publish/subscribe) · Group: modern · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.

Named topics, `on` returns the unsubscribe function, `"*"` hears everything, a failing listener does not stop the others.

## The pattern in one paragraph

Publishers and subscribers know only topic names, not each other. Here the bus is a plain table of listener lists; `emit` calls them in subscription order under `pcall` and returns how many ran and which errors occurred.

## Usage

```lua
local event_bus = require("lib.lua.patterns.event_bus")

local bus = event_bus.new()
local off = bus:on("saved", function(path) print(path) end)
bus:on("*", function(topic, ...) print("any:", topic) end)
bus:emit("saved", "a.lua") --> 2, {}
off()
```

## API

| Function | Does |
| --- | --- |
| `new()` | an empty bus |
| `b:on(topic, fn)` / `b:once(topic, fn)` | subscribe; return unsubscribe |
| `b:emit(topic, ...)` | `called, errors`; a listener unsubscribed during the emit (also by a nested emit) is skipped; `"*"` listeners always get `(topic, ...)` |
| `b:count(topic)` / `b:clear(topic?)` | inspect / drop |

## When it helps / when it does not (Lua view)

- **Helps when:** several independent parts react to the same happening and must not know each other (a plugin core announcing `saved`, `loaded`).
- **Does not help when:** exactly one party listens; call it directly. Hidden coupling through topic strings is the price.
- **Cheaper alternative in Lua:** a callback list, or a Neovim `User` autocmd when the listener may live in another plugin. For priorities and vetoable events use `lib.nvim.hooks`.

## Related

- `lib.nvim.hooks` (the editor-aware, prioritised variant), Observer, Mediator.

## Tests

`TESTS/patterns_event_bus_spec.lua`: delivery, error isolation, unsubscribe, once, wildcard, unsubscribe during emit, clear.
