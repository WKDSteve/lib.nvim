# `lib.lua.patterns.object_pool`

> Pattern: Object Pool · Group: modern · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.
> Status: use sparingly. In Lua most objects are cheap tables; measure before pooling.

`acquire()` hands out a free object or creates one; `release(obj)` resets it and keeps it for the next caller.

## The pattern in one paragraph

Creating some objects is expensive (timers, scratch buffers, parsers with large state). A pool keeps a bounded number of idle ones and recycles them. The pool resets an object on release, so no caller sees leftovers of the previous user.

## Usage

```lua
local object_pool = require("lib.lua.patterns.object_pool")

local pool = object_pool.new({
  create = function() return {} end,
  reset = function(t) for k in pairs(t) do t[k] = nil end end,
  destroy = function(t) end, -- close handles here
  max = 8,
})
pool:with(function(scratch) scratch.x = 1 end)
```

## API

| Function | Does |
| --- | --- |
| `new(opts)` | `create` (required), `reset`, `destroy`, `max` idle (16) |
| `p:acquire()` / `p:release(obj)` | take / return; overflow and failed resets are destroyed |
| `p:with(fn)` | acquire, run, always release, re-raise errors |
| `p:clear()` / `p:stats()` | destroy idle objects / `{ idle, created, reused }` |

## When it helps / when it does not (Lua view)

- **Helps when:** object creation shows up in a profile (libuv handles, large preallocated tables) and calls are frequent.
- **Does not help when:** the object is a small table; the garbage collector is faster than the pool bookkeeping. This module may bring no benefit; it is kept as a reference.
- **Cheaper alternative in Lua:** one reused module-level scratch table, cleared per call.

## Related

- Flyweight (share instead of recycle), `lib.lua.memo` (cache results, not objects).

## Tests

`TESTS/patterns_object_pool_spec.lua`: reuse and reset, max idle, `with` and errors, clear, failing reset.
