# `lib.lua.patterns.reducer`

> Pattern: Reducer / MVU (Elm architecture) · Group: modern · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.

State = reduce(state, action): one function decides every change; a store dispatches actions and notifies subscribers.

## The pattern in one paragraph

All state changes go through one pure-ish function, so the state is predictable, changes can be logged and replayed, and the UI renders from state only. `store(reduce, initial)` keeps the state; `dispatch` returns `ok, state` (a raising reducer leaves the state unchanged); subscribers get `(new, old, action)` only when the state changed by reference. `combine({ slice = reducer })` builds a reducer from slice reducers.

## Usage

```lua
local reducer = require("lib.lua.patterns.reducer")

local store = reducer.store(function(state, action)
  if action.type == "add" then
    local next_state = { unpack(state) }
    next_state[#next_state + 1] = action.item
    return next_state
  end
  return state
end, {})
local off = store:subscribe(function(new) render(new) end)
store:dispatch({ type = "add", item = "x" })
```

## API

| Function | Does |
| --- | --- |
| `store(reduce, initial)` | `s:state()`, `s:dispatch(action)`, `s:subscribe(fn)` (returns unsubscribe) |
| `combine(slices)` | reducer for `{ slice = state }`; returns the same table when no slice changed |

Subscribers are kept in a [`lib.lua.listeners`](../../listeners/README.md) list: a subscriber that was unsubscribed by an earlier one during the same dispatch is skipped, one added meanwhile is not called by it.

## When it helps / when it does not (Lua view)

- **Helps when:** UI state has many writers (keymaps, async results, timers) and bugs come from unclear update order.
- **Does not help when:** state has one writer; assigning a field is simpler. Immutable updates copy tables, which costs for large state.
- **Cheaper alternative in Lua:** a state table with a few setter functions that call `render()`.

## Related

- `lib.lua.patterns.state_machine`, `lib.lua.patterns.event_bus`, `lib.nvim.store`. The Index lists `testing.nvim` `state.lua` as a hand-written state store.

## Tests

`TESTS/patterns_reducer_spec.lua`: dispatch, notifications, unchanged state, raising reducer and subscriber, combine.
