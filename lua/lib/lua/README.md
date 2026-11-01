# `lib.lua`

Namespace aggregator for the editor-independent Lua helpers.

Every submodule under `lib.lua.*` avoids the `vim` API entirely, so it works
(and can be unit-tested) outside Neovim too — plain Lua or LuaJIT. This
`init.lua` itself does no work beyond dispatch: it returns a table with a
metatable `__index` that lazily `require`s and caches `lib.lua.<key>` the
first time each key is accessed.

## Usage

```lua
local Lua = require("lib.lua")

Lua.tables    -- == require("lib.lua.tables"), loaded (and cached) on first access
Lua.strings   -- == require("lib.lua.strings")
Lua.json      -- == require("lib.lua.json")
```

Direct requiring of a submodule remains possible and is more
tree-shake-friendly — nothing about the submodules depends on going through
this aggregator:

```lua
local tables = require("lib.lua.tables")
```

## Submodules

| Submodule | What |
| --- | --- |
| `lib.lua.functions` | tiny functional/meta helpers (`noop`, `identity`, `const`, …) |
| `lib.lua.json` | pure-Lua JSON encode + a `string[]`-coercion decode namespace |
| `lib.lua.strings` | string helpers: trim/split/case/pad/UTF-8/encoding/distance/… |
| `lib.lua.tables` | array/dict/set/safe-mutation table helpers |
| `lib.lua.diff` | see [`diff/README.md`](diff/README.md) |
| `lib.lua.dump` | see [`dump/README.md`](dump/README.md) |
| `lib.lua.error` | see [`error/README.md`](error/README.md) |
| `lib.lua.lazy` | see [`lazy/README.md`](lazy/README.md) |
| `lib.lua.listeners` | see [`listeners/README.md`](listeners/README.md) |
| `lib.lua.memo` | see [`memo/README.md`](memo/README.md) |
| `lib.lua.numeral` | see [`numeral/README.md`](numeral/README.md) |
| `lib.lua.scoring` | see [`scoring/README.md`](scoring/README.md) |
| `lib.lua.range` | see [`range/README.md`](range/README.md) |
| `lib.lua.uuid` | see [`uuid/README.md`](uuid/README.md) |
| `lib.lua.yaml` | see [`yaml/README.md`](yaml/README.md) |
| `lib.lua.time` | time helpers (no README yet) |

`functions`, `json`, `strings` and `tables` are documented in their own
directories' READMEs alongside this one.
