# `lib.lua.patterns.mediator`

> Pattern: Mediator · Group: behavioral · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.

Components talk to one coordinator by name instead of holding references to each other.

## The pattern in one paragraph

Each component registers a `handle(from, message, ...)` function. Others reach it through `send(from, to, ...)` (returns the target's result) or `broadcast(from, ...)` (everyone except the sender, in registration order; a raising component does not stop the rest). Removing or replacing a component touches no other component.

## Usage

```lua
local m = require("lib.lua.patterns.mediator").new()
m:register("tree", { handle = function(from, msg, path) ... end })
m:register("preview", { handle = function(from, msg, path) show(path) end })
m:send("tree", "preview", "show", "a.md")
m:broadcast("tree", "closed")
```

## API

| Function | Does |
| --- | --- |
| `new()` | empty mediator |
| `m:register(name, component)` / `m:unregister(name)` / `m:names()` | manage |
| `m:send(from, to, message, ...)` | result of the target; unknown target raises |
| `m:broadcast(from, message, ...)` | `reached, errors` |

## When it helps / when it does not (Lua view)

- **Helps when:** several UI parts (tree, preview, statusline) must react to each other and direct requires would create cycles.
- **Does not help when:** only two parts talk, or the traffic is one-way notification: use `lib.lua.patterns.event_bus`. A mediator knows the participants; an event bus does not.
- **Cheaper alternative in Lua:** a shared state table with callbacks, or `User` autocmds across plugins.

## Related

- `lib.lua.patterns.event_bus`, `lib.nvim.bindings.autocmd.dispatcher`, Observer.

## Tests

`TESTS/patterns_mediator_spec.lua`: send, broadcast order and sender exclusion, error isolation, unregister, replacement.
