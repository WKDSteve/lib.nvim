# `lib.nvim.registry`

A generic registry: **who is responsible for X**, self-registration, deterministic order, `reset()` for
tests. One entry per language / verb / backend / renderer: a key maps to a value, entries register
themselves (a backend module calls `register` when it is required), lookups answer in **registration
order** (never `pairs()` order, so a scan or a generated doc is the same on every run), and a test can
start from an empty one.

Extracted from `docmap.nvim`'s `lang_registry` and `lib.nvim.bindings.usercmd.composer.registry`
(which now sits on it). Domain rules stay with the owner: which backend claims a file name, a scan-scoped
filter, a handshake report. This holds the entries.

## Usage

```lua
local registry = require("lib.nvim.registry")

local langs = registry.new({
  name = "lang",
  validate = function(key, backend)
    return type(backend.is_source) == "function", "a backend needs is_source()"
  end,
  -- runs once, before the first read: the one place that names the backend modules
  loader = function()
    require("my.lang.lua")
    require("my.lang.python")
  end,
})

-- in my/lang/lua.lua, as a side effect of being required:
langs:register("lua", { is_source = function(f) return f:match("%.lua$") ~= nil end })

langs:get("lua")
langs:find(function(key, backend) return backend.is_source("a.lua") end) --> "lua", backend
langs:keys()    --> { "lua", "python" }   (registration order)
langs:reset()   -- tests: empty; the loader runs again before the next read
```

## API

| Call | Meaning |
|---|---|
| `registry.new(opts?)` | `name` (for messages), `validate(key, value) -> ok, reason`, `loader()`, `on_duplicate` = `"replace"` (default) / `"keep"` / `"error"`. |
| `r:register(key, value)` | Add (chainable). A nil key or value, or a refused `validate`, raises. A duplicate follows `on_duplicate`; `"replace"` keeps the position. |
| `r:unregister(key)` | Remove one entry; returns whether there was one. A later `register` of it goes last. |
| `r:get(key)`, `r:has(key)`, `r:count()` | Lookups. |
| `r:keys()`, `r:all(pred?)`, `r:entries()` | Fresh lists in registration order; `entries()` gives `{ key, value }` pairs. |
| `r:find(pred)` | `key, value` of the first entry (registration order) `pred(key, value)` accepts: who is responsible. |
| `r:reset()` | Drop everything; the loader runs again before the next read. |

The entries and their registration order are kept by [`lib.lua.ordered_map`](../../lua/ordered_map/README.md) (O(1) `unregister`, no array shifting; a predicate of `all`/`find` may unregister entries while the walk runs).

## The loader

`loader` runs **once**, before the first read (`get`, `has`, `count`, `keys`, `all`, `entries`, `find`);
`register` alone does not trigger it. It is marked as run *before* it is called, so a loader that registers
by calling back into the registry (the usual shape: a backend module requires the registry and registers
itself) does not recurse. After `reset()` it runs again, so the known entries come back on the next read;
entries registered by hand are gone. A loader that **throws** is not marked as run: the error reaches
the reading call, and the next read runs it again (what it registered before throwing stays, so a
half-filled registry is never served silently; that run registers those keys again, which `on_duplicate = "error"`
does not count as a duplicate, once per key; any other collision still raises). `unregister` runs the loader first too, so a known entry
can be removed before anything read the registry.
