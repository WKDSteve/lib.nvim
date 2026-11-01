# `lib.lua.listeners`

An ordered list of listeners (or any values) that stays correct while it is
changed during a walk. Pure Lua, no `vim`. It is the shared core under the
pattern modules that keep subscribers: `event_bus`, `mediator`, `reducer`,
`state_machine` and `composite`, so unsubscribing is written, tested and fixed in
one place.

```lua
local listeners = require("lib.lua.listeners")
local list = listeners.new()

local off = list:add(function(x) print(x) end)  -- returns an idempotent remove function
list:each(function(fn) fn(1) end)               -- walks the live entries in order
off()
```

## Behaviour

- **O(1) removal.** `off()` only marks the entry. Marked entries are dropped in
  one pass once more than half of the list is dead, and never while a walk runs.
- **Safe during a walk.** `each` covers the entries present when it started,
  skips the ones removed meanwhile (also by a nested `each`) and does not visit
  the ones added meanwhile.
- **The handle owns its entry.** Adding the same value twice and calling the
  second handle removes the second entry. `list:remove(value)` removes the first
  live equal value instead (what `composite:remove(child)` needs).
- **A raising callback** propagates after the list is released, so it is never
  left "walking".
- **`opts.on_empty(list)`** runs once the last live value is gone and no walk is
  running (`event_bus` drops the empty topic with it).
- `values()` copies the live values, `count()` counts them, `clear()` drops all
  of them and stops a running walk.

## Who uses it

`lib.lua.patterns.event_bus`, `mediator`, `reducer`, `state_machine`,
`composite`. Delivery to a listener that was unsubscribed by an earlier listener
in the same delivery is skipped in all of them. Tests: `TESTS/listeners_spec.lua`
(the list, plus one unsubscribe behaviour run against all five modules).
