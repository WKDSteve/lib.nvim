# `lib.lua.patterns.specification`

> Pattern: Specification · Group: modern · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.

Rules as composable predicates: `and_`, `or_`, `not_`, `all`, `any`; a specification is also callable.

## The pattern in one paragraph

A business rule becomes an object with one question, `is_satisfied_by(candidate)`, and rules combine into bigger rules without a growing `if a and (b or not c)` expression. Here a specification wraps a predicate function and returns a boolean.

## Usage

```lua
local spec = require("lib.lua.patterns.specification")

local is_lua = spec.new(function(f) return f:match("%.lua$") ~= nil end)
local is_test = spec.new(function(f) return f:match("_spec%.lua$") ~= nil end)
local wanted = is_lua:and_(is_test:not_())

wanted:is_satisfied_by("a.lua") --> true
wanted("a_spec.lua")            --> false
```

## API

| Function | Does |
| --- | --- |
| `new(fn)` | wrap a predicate (result coerced to boolean) |
| `s:is_satisfied_by(x)` / `s(x)` | evaluate |
| `s:and_(o)` / `s:or_(o)` / `s:not_()` | combine (new specification) |
| `all(list)` / `any(list)` | n-ary; empty `all` is true, empty `any` is false |

## When it helps / when it does not (Lua view)

- **Helps when:** the same rule parts are recombined in several places (file filters, picker predicates, validation), or rules are built from configuration.
- **Does not help when:** one fixed condition is used once; a plain `function(x) return a(x) and not b(x) end` is clearer.
- **Cheaper alternative in Lua:** plain predicate functions plus a small `all`/`any` helper.

## Related

- Strategy (a rule is a strategy that answers yes/no), Chain of Responsibility (ordered handlers).

## Tests

`TESTS/patterns_specification_spec.lua`: base, and/or/not, n-ary edge cases, boolean coercion.
