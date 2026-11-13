# `lib.nvim.tree.registry`

Where plugins announce what they add to a tree view. Three ordered lists and a
change feed:

| Kind | What it is | Must carry |
|---|---|---|
| `source` | supplies the nodes of one view | `name`, `root()` |
| `decorator` | badges on nodes, looked up by path or id | `name`, `get()`, `subscribe()` |
| `action` | something to do with the node under the cursor or the selection | `name`, `run()` |

```lua
local registry = require("lib.nvim.tree.registry")

local remove = registry.decorator({
  name = "tests",
  slot = "badge",
  roll_up = "worst",
  get = function(path) return cache[path] end,                 -- a lookup, no I/O
  subscribe = function(emit) return store.subscribe(emit) end, -- returns unsubscribe
  all = function() return cache end,                           -- optional: every key with a badge
})

registry.list("decorator")           -- entries in registration order
registry.get("decorator", "tests")
local stop = registry.subscribe(function(ev) end)  -- { kind, name, entry?, replaced? }
remove()                             -- true; false when the entry was replaced or removed already
```

## Why it lives here and not in the tree plugin

A plugin registers when it is loaded. Nothing is loaded in return, and no
reader has to exist: filetree.nvim's own tree reads the lists when it opens a
view and follows `subscribe` for entries that arrive later. So a plugin needs
no "is the tree installed?" check, never waits for another plugin to load, and
keeps lib.nvim as its only dependency for this.

A user of filetree.nvim does not call this module: `require("filetree").source`
/ `.decorator` / `.action` and its `setup()` options write into the same lists.
The direct way is for plugins that must not make a plugin manager load
filetree.nvim just because they required one of its modules.

## Rules

- A second registration under the same name **replaces** the first and keeps
  its position; the event says `replaced = true`. The unregister function of
  the replaced entry then answers `false` and removes nothing.
- The module checks only what keeps the lists sane (a name, the functions in
  the table above). What an entry means (when `root` is called, how a badge is
  drawn, where an action applies) is the reader's contract; the field names are
  in `@types/init.lua`.
- `subscribe` does not replay earlier registrations: read `list()` first.
- A subscriber that raises does not fail the registration and does not stop
  the other subscribers; the failure is reported through `lib.nvim.notify`.
- No `vim.api`, `vim.fn` or `vim.cmd` call: registering works before any UI
  exists.
- `reset()` empties everything, for tests.
