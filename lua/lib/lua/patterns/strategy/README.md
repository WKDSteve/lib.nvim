# `lib.lua.patterns.strategy`

> Pattern: Strategy · Group: behavioral · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.

Interchangeable algorithms chosen by name, with a current selection, a listing and clear errors.

## The pattern in one paragraph

In Lua a strategy is a function in a table. This module adds what the bare table lacks: a current selection (`use`/`run`), a one-off call that leaves the selection alone, `names()`, and an error that names an unknown strategy instead of "attempt to call a nil value".

## Usage

```lua
local strategy = require("lib.lua.patterns.strategy")

local render = strategy.new({
  plain = function(item) return item.name end,
  long = function(item) return item.name .. " (" .. item.path .. ")" end,
}, { default = "plain" })
render:run(item)
render:use("long")
render:call("plain", item)
```

## API

| Function | Does |
| --- | --- |
| `new(strategies, opts)` | `opts.default` selects one |
| `s:register(name, fn)` / `s:use(name)` / `s:selected()` / `s:names()` | manage |
| `s:run(...)` / `s:call(name, ...)` | current / one-off |

## When it helps / when it does not (Lua view)

- **Helps when:** the algorithm is a user setting or changes at runtime (pickers, renderers, backends) and callers need a clear error for a bad name.
- **Does not help when:** the choice is made once at the call site; `handlers[kind](...)` is enough.
- **Cheaper alternative in Lua:** a function table and `handlers[name] or handlers.default`.

## Related

- `lib.lua.patterns.factory_method` (builds objects instead of running code), `lib.nvim.registry` (self-registering), `lib.strategies` (how the `lib` aggregator resolves).

## Tests

`TESTS/patterns_strategy_spec.lua`: default, use/run/call, register, unknown names, no selection.
