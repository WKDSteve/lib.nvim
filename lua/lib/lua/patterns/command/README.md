# `lib.lua.patterns.command`

> Pattern: Command · Group: behavioral · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.

An action as data with `run` and `undo`, and a history with undo and redo.

## The pattern in one paragraph

A command bundles an operation and the means to take it back. `run` returns whatever `undo` needs (the old value, a snapshot). The history executes commands, keeps bounded undo and redo stacks, and clears redo when a new command runs. This is the editing-history side of Command; routing `:Command <sub>` is `lib.nvim.bindings.usercmd.composer`.

## Usage

```lua
local command = require("lib.lua.patterns.command")

local h = command.history({ limit = 100 })
local set_title = {
  name = "set title",
  run = function(doc, title) local old = doc.title; doc.title = title; return old end,
  undo = function(old, doc) doc.title = old end,
}
h:run(set_title, doc, "New")
h:undo()
h:redo()
```

## API

| Function | Does |
| --- | --- |
| `history(opts)` | `opts.limit` (100) |
| `h:run(cmd, ...)` | execute, record, clear redo; a raising `run` records nothing |
| `h:undo()` / `h:redo()` | return the command name, or `nil` when empty |
| `h:can_undo()` / `h:can_redo()` / `h:names()` / `h:clear()` | inspect |

## When it helps / when it does not (Lua view)

- **Helps when:** users must be able to take back several kinds of changes (rename, move, bulk replace) through one mechanism.
- **Does not help when:** Neovim's own undo tree already covers buffer edits, or the operation cannot be reversed cheaply.
- **Cheaper alternative in Lua:** a stack of `{ undo = function() ... end }` closures.

## Related

- `lib.nvim.checkpoint` / `lib.nvim.ui.kit.history` (snapshot-based, Memento), `lib.nvim.bindings.usercmd.composer`.

## Tests

`TESTS/patterns_command_spec.lua`: undo/redo, limit, redo clearing, failing run, arguments with nil holes.
