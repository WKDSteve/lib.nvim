# `lib.nvim.fs.fast`

Fast file listings for every plugin: a deep list, the size of a folder and a recursive watch, each
behind one call, with the fastest means this machine has.

| Work | Tiers, in order |
| --- | --- |
| `list(root, opts, on_batch, on_done)` | the file helper (`lib.nvim.fs.helper`), `fd`, `rg --files`, a Lua walk |
| `size(dir, on_done)` | the file helper, a Lua walk (everything counted, as `du`) |
| `watch(root, opts, on_change)` | the file helper, one recursive libuv handle (Windows, macOS), one libuv handle per folder (Linux) |

Measured on the same trees: helper 11-42 ms, `fd` 197-336 ms (the process start through a scoop
shim), Lua 75-475 ms (`lib.nvim/NOTES/2026-11-17_schnelle-dateilisten-recherche.md` in the tasks vault).

## Usage

```lua
local fast = require("lib.nvim.fs.fast")

-- streamed and cancellable; paths are absolute, `/`-separated, drive letter upper case
local cancel = fast.list(root, { hidden = false, exclude = { "*.min.js" } }, function(paths)
  -- a batch, on the main loop
end, function(ok)
  -- once, after the last batch; false: the tool failed, an option was wrong, the walk hit its limit
end)

-- everything at once
fast.list_all(root, { ignore = "names" }, function(paths, ok) end)

fast.size(dir, function(bytes, files, tier) end)   -- nil, nil when the folder cannot be read

local w = fast.watch(root, {}, function(dirs) end) -- the folders in which something changed
w.stop()
```

## Options of a listing

The switches of `fd`; `.git` is never entered, whatever they say.

| Option | Default | Meaning |
| --- | --- | --- |
| `hidden` | `true` | list and enter dot entries |
| `ignore` | `"gitignore"` | `"gitignore"`: what `.gitignore`, `.ignore` and the global excludes name (inside a repository); `"names"`: no ignore file, the folders named in `names`; `"none"`: nothing |
| `names` | `lib.nvim.fs.ignore.list.basenames` | the folder names for `ignore = "names"` |
| `no_ignore` | `false` | `true` is `ignore = "none"` unless `ignore` is given |
| `follow` | `false` | follow links to folders (each real folder once) |
| `exclude` | `{}` | globs as `fd --exclude`: without `/` they match a name at any depth |
| `max_depth` | none | `1` = the files directly in the root |
| `skip` | none | Lua walk with `"gitignore"` only: `fun(name, is_dir)`, replaces `names` |

The Lua walk cannot read `.gitignore`; for `"gitignore"` it leaves out the folders of `names` (or what
`skip` says) instead, the nearest thing it has. A link to a file (or a broken link) is listed as a
file; a link to a folder is neither listed nor followed unless `follow` is set. `rg` cannot list a link
without following it: on a machine with `rg` and no `fd` links are not found.

## Notes

- A helper that ends during a listing hands it to the next tier, which leaves out what the helper had
  handed over already; during a watch libuv takes over and the root is reported once, so the caller
  reads everything again.
- `fd` and `rg` are started as the program itself, not through a scoop shim (`resolve`): a shim costs
  40 to 70 ms per start, and ending it leaves the program running. `running()` counts the tools that
  have not ended.
- The per-folder watch (Linux without helper) watches at most `max_watches` folders (default
  `MAX_WATCHES`, 4000) and adds a folder that appears.
