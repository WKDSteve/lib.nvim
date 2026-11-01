# `lib.lua.patterns.result`

> Pattern: Result · Group: modern · Stage: `impl`

Errors as values: a result is `{ ok = true, value }` or `{ ok = false, err }`, with `map`, `map_err`, `and_then`, `unwrap_or`, `unwrap`, `to_pair`.

## The pattern in one paragraph

Instead of raising or returning `nil, err` that every caller must test, a fallible step returns a value that carries success or failure and can be passed on, transformed and chained. In Lua the native form is the `value, err` pair; this module wraps that pair so several steps compose without repeating `if err then return nil, err end`.

## Usage

```lua
local result = require("lib.lua.patterns.result")

local name = result.from_pcall(vim.json.decode, text)
  :map(function(t) return t.name end)
  :unwrap_or("unnamed")

local r = result.ok(2):and_then(function(v) return result.ok(v + 1) end)
local value, err = r:to_pair() --> 3, nil
```

## API

| Function | Does |
| --- | --- |
| `ok(v)` / `err(e)` | construct |
| `from_pair(value, err)` | a non-nil `err` is an error |
| `from_pcall(fn, ...)` | a throw becomes an error result |
| `is_result(x)` | true only for results made here |
| `r:map(fn)` / `r:map_err(fn)` | transform value / error (a throw in `fn` becomes the error of the result, in both) |
| `r:and_then(fn)` | chain a step that returns a result; a non-result return is an error |
| `r:unwrap_or(d)` / `r:unwrap()` | value or default / value or raise |
| `r:to_pair()` | back to `value, nil` or `nil, err` |

## When it helps / when it does not (Lua view)

- **Helps when:** a pipeline of three or more fallible steps would otherwise repeat the error check after each one, or when a failure must be stored or passed to a callback as data.
- **Does not help when:** a single call returns `value, err` and the caller handles it right there; the native pair is shorter and what the rest of lib.nvim returns.
- **Cheaper alternative in Lua:** `value, err` pairs and `lib.lua.error.safe_call`.

## Related

- `lib.lua.error` (structured errors, `safe_call`): the result's `err` can be such an error.
- Seen in the author's plugins as the `ok, err` return convention (e.g. `filetree.nvim` `registry.register`).

## Tests

`TESTS/patterns_result_spec.lua`: construction, map/map_err/and_then short-circuiting, unwrap, pair conversion, throw capture.
