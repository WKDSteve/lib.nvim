# `lib.lua.patterns.chain_of_responsibility`

> Pattern: Chain of Responsibility · Group: behavioral · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.

An ordered list of named handlers; the first one that claims the request ends the chain.

## The pattern in one paragraph

The sender does not know which handler will deal with a request. Each handler either claims it (`return true, result`) or passes it on. A handler that raises counts as "not handled"; its error is collected and the chain continues.

## Usage

```lua
local chain = require("lib.lua.patterns.chain_of_responsibility").new()
chain:add("lua", function(path) if path:match("%.lua$") then return true, "lua file" end end)
chain:add("any", function() return true, "other" end)
chain:handle("a.lua") --> true, "lua file", "lua", {}
```

## API

| Function | Does |
| --- | --- |
| `new()` | empty chain |
| `c:add(name, fn, opts)` | append (`opts.first = true`: prepend); same name replaces and moves to the end |
| `c:remove(name)` / `c:names()` | manage / list |
| `c:handle(request, ...)` | `handled, result, handler_name, errors`; iterates a snapshot, so handlers added or removed during `handle` take effect for the next request |

## When it helps / when it does not (Lua view)

- **Helps when:** handlers come from different places (plugins, features) and the order matters (resolvers, link openers, fallbacks).
- **Does not help when:** the set is fixed; an `if/elseif` ladder is shorter. If you need to run all handlers, use `lib.lua.patterns.event_bus`.
- **Cheaper alternative in Lua:** a list of functions in a `for` loop that returns on the first hit.

## Related

- `lib.nvim.bindings.autocmd.dispatcher`, `lib.lua.patterns.middleware` (wrapping instead of claiming), Strategy. The Index lists `gopath.nvim` `resolve.lua` as a hand-written chain.

## Tests

`TESTS/patterns_chain_of_responsibility_spec.lua`: claim order, catch-all, first/replace/remove, raising handler, argument passing.
