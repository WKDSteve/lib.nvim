# `lib.lua.patterns.decorator`

> Pattern: Decorator · Group: structural · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.

Add behaviour around a function without changing its callers: `wrap`, `before`, `after`, `guard`, `timed`.

## The pattern in one paragraph

A decorator is a function that takes a function and returns a function with the same call shape. Decorators stack; `wrap(fn, d1, d2)` makes `d1` the outermost. In Lua this is just closures, no wrapper class needed.

## Usage

```lua
local decorator = require("lib.lua.patterns.decorator")

local save = decorator.wrap(write_file,
  decorator.guard(function(path) return path ~= "" end, function() return nil, "empty path" end),
  decorator.before(function(path) log("saving " .. path) end),
  decorator.timed(function(ms, path) log(path, ms) end)
)
```

## API

| Function | Does |
| --- | --- |
| `wrap(fn, ...)` | apply decorators, first listed outermost |
| `before(hook)` / `after(hook)` | run a hook before / after (after gets the result list and the arguments) |
| `guard(pred, otherwise)` | call only if `pred(...)`, else `otherwise(...)` |
| `timed(sink, clock)` | report milliseconds and arguments; errors are re-raised |

## When it helps / when it does not (Lua view)

- **Helps when:** cross-cutting behaviour (timing, logging, guards, caching) must be added to several functions without editing them.
- **Does not help when:** one function needs one extra line; edit it. Stacks of decorators make stack traces harder to read.
- **Cheaper alternative in Lua:** a local wrapper function.

## Related

- `lib.strategies.telemetry_wrap` (instrumenting a whole module), `lib.lua.memo` (a caching decorator), `lib.lua.patterns.middleware`.

## Tests

`TESTS/patterns_decorator_spec.lua`: order, before/after, guard, timed with an injected clock, error path, empty wrap.
