# `lib.lua.ordered_map`

A key -> value map that remembers the order its keys were first put in. Pure
Lua, no `vim`. It is the shared core under [`lib.nvim.registry`](../../nvim/registry/README.md)
and `lib.lua.patterns.repository` (`memory()`): both are "one entry per key,
answered in registration order, never `pairs()` order", and `registry` needs
`vim` while `repository` must not, so neither can sit on the other.

```lua
local map = require("lib.lua.ordered_map").new()
map:put("b", 1)
map:put("a", 2)
map:put("b", 3)          -- replaces the value, keeps the position
map:keys()               --> { "b", "a" }
map:delete("b")          --> true
map:each(function(key, value) print(key, value) end)
```

## Behaviour

- `put(key, value)`: neither may be `nil`, the key not `NaN`. A key that is
  already there keeps its position; one that was deleted comes back at the end.
- `delete(key)` is O(1): it leaves a hole in the order list, squeezed out once
  the holes are half of it, and never while an `each` walk is running.
- `each(fn)`: `fn(key, value)` returning a truthy value stops the walk. Entries
  deleted during it are skipped (also the one being visited), entries put during
  it are not visited, and a raising callback releases the walk.
- `get`, `has`, `count`, `keys` (a fresh list), `clear`.

Tests: `TESTS/ordered_map_spec.lua` (basics plus a differential run against a
plain array model).
