# `lib.nvim.require`

Safe and extended `require` utilities: a `pcall`-wrapped require, a
directory-batch loader with lifecycle-function dispatch, and a lazy-require
closure factory, and a check whether a plugin is installed that does not load it.

## `M.safe(name)`

```lua
local ok, mod_or_err = require("lib.nvim.require").safe("some.module")
if not ok then
  -- mod_or_err is the pcall error message
end
```

Returns `false, "invalid module name"` if `name` isn't a string; otherwise
`pcall(require, name)` and passes the result straight through.

## `M.dir(dir, calls)`

```lua
require("lib.nvim.require").dir("myplugin.modules")           -- calls setup({}) on each
require("lib.nvim.require").dir("myplugin.modules", "apply")  -- calls apply() on each
require("lib.nvim.require").dir("myplugin.modules", { "init", "start" })
require("lib.nvim.require").dir("myplugin.modules", "")       -- require only, call nothing
```

Non-recursively `require`s every `*.lua` file directly inside
`vim.fn.stdpath("config") .. "/lua/<dir>"` (module name derived as
`<dir>.<filename_without_extension>`), then optionally dispatches a lifecycle
function on each loaded module table:

* `calls == nil` (default) — call `mod.setup({})` if present.
* `calls` a string — call exactly that function name (empty string `""` means
  call nothing at all, require only).
* `calls` a `string[]` — call each listed name, in order.

Only functions that actually exist and are callable are invoked. `init.lua`
is always skipped (avoids double-loading aggregators), and **the calling
module itself is skipped** — resolved via `debug.getinfo(2, "S")` against the
caller's own source path, to prevent the classic `lua/lib/func.lua ->
require_dir("lib")` infinite-recursion trap where `lib.func` would otherwise
re-require itself. Every `require` and every dispatched call is wrapped in
`pcall`; failures are reported via `require("lib.nvim.notify")` (tagged
`[lib.nvim.require]`) rather than aborting the batch. If the directory does
not exist, or contains no `.lua` files, a warning saying which of the two it
is is emitted and the function returns. The listing goes through
`vim.fs.dir`, which reads a path — not `vim.fn.glob`, which reads a pattern
and would list nothing for a config directory spelled with `~` (an 8.3 short
name), `[`, `*` or `?`.

Note: this reads `dir` relative to the **user's Neovim config** directory
(`stdpath("config")`), not relative to lib.nvim's own `lua/` tree — it is a
helper for consumers of lib.nvim to batch-load their own plugin's modules.

## `M.lazy(module_name)`

```lua
local get_heavy = require("lib.nvim.require").lazy("myplugin.heavy_module")
-- ... later, on first actual use:
get_heavy().do_thing()
```

Returns a closure that `require`s `module_name` on first call and caches the
result for every call after that — a minimal alternative to
`lib.lua.lazy` for a single module.

## `M.installed(mod, opts)`

```lua
local there = require("lib.nvim.require").installed("filetree", { repo = "filetree.nvim" })
```

Whether a plugin's main module is installed, answered without loading the
plugin where possible. Under lazy.nvim a plain `require` of a plugin that is
not loaded yet loads it (its `config` included), so asking that way would load
every plugin asked about. The order:

1. `package.loaded[mod]`: already loaded.
2. lazy.nvim's registry, only when lazy.nvim is already loaded: the plugin
   listed as `opts.repo` with an existing directory, or any listed plugin whose
   directory ships `lua/<mod>`. Plugins with `cond = false` do not count. The
   plugin stays unloaded.
3. `runtimepath`: `lua/<mod>.lua` or `lua/<mod>/init.lua` (other plugin
   managers, dev checkouts, everything lazy.nvim has loaded).
4. `require` last, for modules only a loader knows (`package.preload`).

`lib.nvim.contextmenu.catalog.available` and `lib.nvim.crossfeature.installed`
ask this.
