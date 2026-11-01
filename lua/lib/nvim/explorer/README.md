# `lib.nvim.explorer`

> Pattern: Adapter + Registry (`lib.nvim.registry`) · Stage: `reuse` (a domain module, not a `patterns/` entry)

File-explorer adapters. One registry answers three questions for neo-tree, NvimTree, netrw and oil, and for
any explorer a plugin registers from outside: **which explorer owns this buffer**, **which path is under the
cursor**, **how do I make it re-read the disk**. Plugins that today each carry their own `filetype` ladder
(`fileops.nvim` `ops/file.lua`, `pdfport.nvim` `integrations/init.lua`, `open.nvim` `context.lua`) ask here
instead.

Namespace: `lib.nvim.explorer`, not `lib.nvim.patterns.explorer`. It is domain code with four real adapters
built in, not a reusable pattern skeleton. It is also not `lib.nvim.tree` (a pure tree data structure) and not
`lib.nvim.neotree` (neo-tree node internals): this module only detects, reads a path and reloads.

## Usage

```lua
local explorer = require("lib.nvim.explorer")

explorer.current()          --> "oil"  (adapter name of the current buffer, nil if it is no explorer)
explorer.current_path()     --> "C:/proj/src/a.lua" | nil
explorer.reload_all()       --> { "nvim-tree" }  (adapters that reloaded without error)

-- an explorer the library does not know
explorer.register({
  name = "mytree",
  filetypes = { "mytree" },            -- or detect = function(buf) return ... end
  module = "mytree",                    -- reload only runs once this module is loaded
  current_path = function(buf) return require("mytree").cursor_path() end,
  reload = function() require("mytree").refresh() end,
})
```

## API

| Function | Does |
| --- | --- |
| `register(adapter)` | add an adapter; the same `name` replaces it and keeps its position |
| `unregister(name)` | remove one; `false` if there was none |
| `adapters()` | all adapters, in registration order (a fresh list) |
| `detect(buf?)` | the adapter that owns `buf` (default: current buffer), or `nil` |
| `current(buf?)` | its name, or `nil` |
| `current_path(buf?)` | the path under the cursor of a window showing `buf` (read in that window), or `nil` |
| `reload_all()` | reload every adapter whose `module` is loaded; returns the names that succeeded |
| `reset()` | back to the four built-ins (tests) |

Adapter fields: `name` (required), `filetypes` **or** `detect(buf)` (one is required), `module?`,
`current_path?(buf)`, `reload?()`.

Built in, in this order: `neo-tree`, `nvim-tree`, `netrw`, `oil`. netrw has no `reload`: it re-reads a
directory whenever its buffer is entered. The `oil` reload is the `refresh` action and only runs from an oil buffer (it acts on the current buffer and may ask about unsaved edits; elsewhere oil watches the disk itself).

## When it helps / when it does not (Lua view)

- **Helps when:** a plugin has to treat "the file under the cursor in whatever explorer is open" or "refresh
  every open tree after a file operation" the same for all explorers, and would otherwise grow a second
  `if ft == "neo-tree" ... elseif ft == "NvimTree" ...` ladder.
- **Does not help when:** the plugin works with exactly one explorer and uses its API directly (richer than
  path and reload), or it needs explorer features beyond that (marks, selection, expand state): those stay
  in the explorer-specific module (`lib.nvim.neotree.node`).
- **Cheaper alternative in Lua:** a three-line `filetype` check when only the detection is needed.

## Soft by design

Missing plugins are the normal case. A built-in adapter recognises its buffer by `filetype` alone, so a
buffer of an explorer that is not installed answers `current() == "oil"` and `current_path() == nil`,
never an error. Every adapter call runs under `pcall`: a raising `current_path` answers `nil`, a raising
`reload` is skipped and the next adapter still runs (`LUA-05`: soft dependencies).

## Related

- `lib.nvim.registry` (the mechanism), `lib.lua.patterns.adapter` (the pattern), `lib.nvim.neotree.node`
  (neo-tree specifics), `lib.nvim.tree` (tree data).
- Adoption (own follow-up tasks): `fileops.nvim` (`reload_explorers`, which already has its own adapter list),
  `pdfport.nvim` (`current_pdf_path`), then `open.nvim` `context.lua`, `debugging.nvim`, `my.nvim`.

## Tests

`TESTS/explorer_spec.lua` — the four built-ins by fake modules (no plugin installed), missing-plugin
answers, registration from outside, `detect` instead of `filetypes`, replace/unregister/reset, failure
isolation, the module gate of `reload_all`.
