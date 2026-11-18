# `lib.nvim.fs.helper`

The client of the file helper: `filetree-helper`, a small read-only program (Rust) that filetree.nvim
builds and releases. It lists the files below a folder with the ignore rules of ripgrep, adds up the
size of a folder and watches a folder tree, also on Linux. One process per Neovim serves every plugin;
most callers want `lib.nvim.fs.fast`, which falls back to `fd`, `rg` and Lua without it.

## Which program

The mode decides, first match wins:

1. `configure(mode)` (specs, or after installing the program during a session)
2. the provider a plugin set with `set_mode_provider(fn)` (filetree.nvim hands over `native.fs.helper`)
3. `vim.g.lib_fs_helper`
4. `"auto"`

`"auto"` uses `default_path()`, `stdpath("data") .. "/filetree-helper/filetree-helper[.exe]"`, where
`require("filetree.native.fs.helper").build()` puts it; never on a machine with
`NVIM_MACHINE_ROLE=workstation` (nothing native runs there before the EDR check). `false` uses none; a
path uses exactly that program.

## Usage

```lua
local helper = require("lib.nvim.fs.helper")

local gen = helper.request("walk", root, function(kind, payload)
  -- "files" (a batch), "done" ({ ok, files, ms }), "error" (text), "lost" (the helper ended)
  return kind == "files" -- true: more answers wanted
end, { hidden = false, max_depth = 3 })
helper.drop(gen, "cancel")
```

Methods: `walk` (with options, protocol 3), `size`, `watch` (then `tell(gen, "follow", dir)`,
`drop(gen, "unwatch")`). The protocol is described at the top of `helper/src/main.rs` in filetree.nvim.
The helper is started with `FILETREE_HELPER_SINK=lib.nvim.fs.helper` and answers through
`require('lib.nvim.fs.helper').on(kind, gen, payload)`, the only thing it can make the editor do.

A helper that ends or cannot start is not started again in the session: every open request gets
`"lost"`, and the user is told once. `state()` and `health(ok, info, warn)` say what is going on.
