# `lib.lua.patterns.iterator`

> Pattern: Iterator · Group: behavioral · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.

Walk a sequence without exposing its storage: lazy `map`, `filter`, `take`, `drop`; `collect`, `each`, `reduce`; `peek`.

## The pattern in one paragraph

An iterator wraps a `next()` function that returns the next value or `nil` at the end (so values cannot be `nil`). Transformations are lazy: nothing is computed until a consumer pulls. `iter()` gives a function for the generic `for`.

## Usage

```lua
local iterator = require("lib.lua.patterns.iterator")

local squares = iterator.range(1, 20)
  :filter(function(x) return x % 2 == 0 end)
  :map(function(x) return x * x end)
  :take(3)
  :collect() --> { 4, 16, 36 }
for v in iterator.of({ "a", "b" }):iter() do print(v) end
```

## API

| Function | Does |
| --- | --- |
| `of(list)` / `range(first, last, step)` / `from_fn(next_fn)` | construct |
| `it:next()` / `it:peek()` / `it:has_next()` | pull |
| `it:map(fn)` / `it:filter(pred)` / `it:take(n)` / `it:drop(n)` | lazy transforms |
| `it:collect()` / `it:each(fn)` / `it:reduce(fn, init)` / `it:iter()` | consume |

## When it helps / when it does not (Lua view)

- **Helps when:** a pipeline over a large or unbounded source (a directory walk, lines of a file) should stop early without building intermediate lists.
- **Does not help when:** the data is a small list; `vim.iter` (Neovim 0.10+) already provides this on the editor side, and `for ... ipairs` is enough for plain loops. This module is for code that must stay editor-independent.
- **Cheaper alternative in Lua:** `vim.iter(list):filter(...):map(...):totable()`.

## Related

- `lib.nvim.fs.collect_recursive` (walker with an async variant), Composite, Visitor (`walk`).

## Tests

`TESTS/patterns_iterator_spec.lua`: constructors, negative step, chain, laziness (call count), peek, reduce, `for` use.
