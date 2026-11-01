# `lib.lua.patterns.adapter`

> Pattern: Adapter · Group: structural · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.

Give a foreign object the interface the caller expects; missing methods raise at construction.

## The pattern in one paragraph

A caller needs `refresh()` and `current_path()`, the library at hand offers something different. The adapter exposes exactly the wanted methods and translates: a mapping entry is either the adaptee's method name (forwarded) or a function `(adaptee, ...)` for real translation.

## Usage

```lua
local adapter = require("lib.lua.patterns.adapter")

local explorer = adapter.new({ "refresh", "current_path" }, nvim_tree_api, {
  refresh = function(api) api.tree.reload() end,
  current_path = "get_node_path",
})
explorer.refresh()
```

## API

| Function | Does |
| --- | --- |
| `new(interface, adaptee, map)` | table with exactly the `interface` methods; a method that cannot be provided raises immediately |

## When it helps / when it does not (Lua view)

- **Helps when:** several backends (neo-tree, nvim-tree, oil, netrw) must answer the same few questions, or you want the failure for a missing method at setup, not at first call.
- **Does not help when:** one backend only; call it directly.
- **Cheaper alternative in Lua:** a small table of functions per backend, selected by name. Combine with `lib.nvim.registry` to register adapters from the outside.

## Related

- `lib.nvim.registry`, Strategy, Facade. The Index lists duplicated explorer detection in `fileops.nvim`, `pdfport.nvim` and `open.nvim`.

## Tests

`TESTS/patterns_adapter_spec.lua`: function mapping, name mapping, fallback to same name, exposed surface, construction errors.
