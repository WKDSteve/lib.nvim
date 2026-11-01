# `lib.lua.functions`

Tiny, allocation-free functional/meta helpers — defaults, placeholders and
adapters for APIs and control flow. All are side-effect free except `raise`.

The module itself is a thin re-export: `init.lua` lazily requires
`lib.lua.functions.meta` (via `lib.lua.lazy`) and copies its six functions
onto `M`; `pack`/`unpack` come from the dependency-free `lib.lua.functions.varargs`.

## Usage

```lua
local fn = require("lib.lua.functions")

fn.noop()                    --> nil, does nothing
fn.identity(42)               --> 42
fn.always_true()              --> true
fn.always_false()             --> false

local get_five = fn.const(5)
get_five()                    --> 5

local ok, err = pcall(fn.raise, "boom")
-- ok == false, err == "boom" (error level 0: no position info prepended)
```

| Function | Behavior |
| --- | --- |
| `noop()` | Does nothing, returns `nil`. Useful as a default callback or an intentional empty branch. |
| `identity(v)` | Returns `v` unchanged. Default mapper in pipelines. |
| `always_true()` | Always returns `true`. Default filter/guard. |
| `always_false()` | Always returns `false`. Disabling predicate/sentinel. |
| `const(value)` | Returns a closure that always yields `value` — a lazy default or dependency-injection stub. |
| `pack(...)` | `{ ..., n = <count> }`; LuaJIT has no `table.pack`, and `n` is what keeps embedded and trailing `nil`s. Also `require("lib.lua.functions.varargs")` (no dependencies, safe to load from low-level modules). |
| `unpack(list, i, j)` | `table.unpack` or the LuaJIT global `unpack`; pass the count: `unpack(t, 1, t.n)`. |
| `raise(err)` | Always calls `error(err, 0)` — passthrough error helper (level `0` suppresses the usual "file:line:" prefix). |
