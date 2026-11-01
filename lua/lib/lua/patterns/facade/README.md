# `lib.lua.patterns.facade`

> Pattern: Facade · Group: structural · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.

One small module API in front of several submodules, loaded lazily from an explicit entry list.

## The pattern in one paragraph

Users see one tidy surface; the submodules behind it stay private and are not even loaded until first use. Entries are a module path, `"module:function"` or a function. `names()` and `loaded()` make the surface checkable in tests.

## Usage

```lua
local facade = require("lib.lua.patterns.facade")

return facade.new({
  parse = "my.parser:parse",
  render = "my.render:render",
  config = "my.config",
  version = function() return "1.0" end,
})
```

## API

| Function | Does |
| --- | --- |
| `new(spec)` | table with the entries as keys; `names` and `loaded` are reserved |
| `api.names()` / `api.loaded()` | declared / already resolved entries |

## When it helps / when it does not (Lua view)

- **Helps when:** a plugin's `init.lua` re-exports a dozen functions from submodules and startup time matters.
- **Does not help when:** the module is small; a plain `local M = {}` with the functions is the facade already.
- **Cheaper alternative in Lua:** `lib.lua.lazy` for single modules, or the `lib` aggregator.

## Related

- `lib.strategies.eager` / `lazy` / `metatable` (how the `lib` aggregator resolves), `lib.lua.lazy`.

## Tests

`TESTS/patterns_facade_spec.lua`: lazy loading, entry kinds, caching, names/loaded, reserved names (uses `package.preload`).
