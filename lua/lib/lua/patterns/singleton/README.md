# `lib.lua.patterns.singleton`

> Pattern: Singleton · Group: creational · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.
> Status: rarely needed. In Lua a module table already is a singleton.

A lazily created single instance with `get()`, `is_created()` and `reset()` (for tests).

## The pattern in one paragraph

Exactly one instance exists and everyone gets the same one. `local M = {}` in a module file does that for free. This module only adds what the module table lacks: creation on first use (the instance is expensive or needs the editor ready), detection of a factory that calls `get()` again while creating, and `reset()` so tests can throw the instance away.

## Usage

```lua
local singleton = require("lib.lua.patterns.singleton")

local index = singleton.new(function() return build_index() end)
index:get() -- creates on first call, then always the same object
index:reset() -- tests: the next get() creates again
```

## API

| Function | Does |
| --- | --- |
| `new(factory)` | factory runs on the first `get()` |
| `s:get()` | the instance; a failing factory raises and is retried on the next `get()` |
| `s:is_created()` / `s:reset()` | inspect / forget |

## When it helps / when it does not (Lua view)

- **Helps when:** the shared instance is costly or order-dependent to create and tests need a clean slate.
- **Does not help when:** the state is cheap; a module-level table is shorter and equally global. Singletons are global state: they hide dependencies and make tests order-dependent. Prefer passing the instance in (dependency injection).
- **Cheaper alternative in Lua:** `local state = nil; local function get() state = state or make(); return state end`.

## Related

- `lib.lua.lazy` (lazy module loading), `lib.lua.patterns.object_pool`.

## Tests

`TESTS/patterns_singleton_spec.lua`: lazy creation, identity, reset, failing factory, re-entrancy.
