# `lib.lua.patterns.middleware`

> Pattern: Middleware / Pipeline · Group: modern · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.

An ordered list of stages `fn(ctx, next)`; a stage may change `ctx`, call `next()`, or stop the chain.

## The pattern in one paragraph

Each stage wraps the rest of the chain: it can act before and after `next()`, replace the result, or short-circuit by not calling it. The innermost step is the optional `final(ctx)`. It is Chain of Responsibility with the ability to wrap, as used by HTTP servers and command pipelines.

## Usage

```lua
local middleware = require("lib.lua.patterns.middleware")

local chain = middleware.new()
chain:use(function(ctx, next)
  local t0 = os.clock()
  local r = next()
  ctx.seconds = os.clock() - t0
  return r
end)
chain:use(function(ctx, next)
  if not ctx.path then return nil, "no path" end
  return next()
end)

chain:run({ path = "a.lua" }, function(ctx) return ctx.path end) --> "a.lua"
```

## API

| Function | Does |
| --- | --- |
| `new()` | empty chain |
| `chain:use(stage)` | append a stage, returns the chain |
| `chain:run(ctx, final)` | run; returns what the stages return; `next()` twice raises |

## When it helps / when it does not (Lua view)

- **Helps when:** several independent concerns (timing, validation, logging, caching) wrap one operation and must be reorderable.
- **Does not help when:** the steps always run in one fixed order without wrapping; a function calling three functions is simpler.
- **Cheaper alternative in Lua:** a list of functions run in a loop, if no stage needs to wrap or stop the rest.

## Related

- `lib.nvim.bindings.autocmd.dispatcher` (keyed handler fan-out), Chain of Responsibility, Decorator.

## Tests

`TESTS/patterns_middleware_spec.lua`: nesting order, return value, stop, empty chain, double `next`.
