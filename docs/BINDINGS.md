# lib.nvim — Binding Cheatsheet

Every user command and autocommand `lib.nvim` installs. This file is
documentation only; the source of truth is `lua/lib/nvim_usrcmds/`
(`usrcmds.lua`, `autocmds.lua`, `actions.lua`). A change there must be
reflected here.

`lib.nvim` is a library, not a feature plugin, so its binding surface is
deliberately small and every part of it is opt-in.

## Table of content

  - [Keymaps](#keymaps)
  - [User commands](#user-commands)
  - [Autocommands](#autocommands)
  - [Switching things off](#switching-things-off)

---

## Keymaps

**None global.** A library that other plugins depend on has no business
claiming a key on their behalf, so `lua/lib/nvim_usrcmds/` has no
`keymaps.lua` at all — the one deliberate gap in the three-module `bindings/`
split every plugin here uses.

`lib.nvim.bindings.keymap` is a wrapper *for callers* around `vim.keymap.set`; it binds
nothing itself. Every actual `vim.keymap.set` call in the tree is buffer-local
to a window this library opened itself, closed again with the window:

| key | buffer | desc |
| --- | --- | --- |
| `q` | UI-kit preview surface (`ui/kit/preview.lua`) | Close the preview |
| `q` | notify history (`notify/popup.lua`'s `show_history()`) | Close the history buffer |
| `<C-s>` | notify history (`notify/popup.lua`'s `show_history()`) | Toggle collapsed/full entries — same effect as `popup.toggle_full()` |

## User commands

Two surfaces over the same actions, deliberately: the flat commands predate the
verb and are kept for muscle memory; the verb is the composer-built one with
`<Tab>` completion at every level. Both dispatch into
`lib.nvim_usrcmds.actions`, so they cannot drift apart.

### Flat

| command | option | desc |
| --- | --- | --- |
| `:CwdHere` | `cwd_here` | Set the local cwd to the directory of the current buffer |
| `:PowershellProfile` | `powershell_profile` | Open the active PowerShell profile in Neovim |

`powershell_profile` defaults to `vim.fn.has("win32") == 1` — the command does
not exist on other platforms unless you ask for it.

### `:Lib`

Built with `lib.nvim.bindings.usercmd.composer`, which dogfoods the module it ships. The
route list mirrors which features are enabled, so the verb never advertises an
action the flat set would also omit.

| command | desc |
| --- | --- |
| `:Lib helptags` | Regenerate all helptags now |
| `:Lib cwd-here` | `lcd` to the current buffer's directory |
| `:Lib ps-profile` | Open the active PowerShell profile |
| `:Lib deps show [{plugin}]` | List a plugin's declared external tools, why each matters, and what is missing |
| `:Lib deps status` | Every declared tool across every plugin, and what's missing here |
| `:Lib deps install [{plugin}]` | Offer to install missing external tools — one plugin's, or every plugin's (asks first) |
| `:Lib deps project [{action}]` | Scan this directory's files and show which treesitter parsers and tools are missing for them (`refresh`: scan again; `install`: ask once, then install) |
| `:Lib deps reset-first-run [{plugin}]` | Forget that a plugin's (or every plugin's) first-run popup was already shown |
| `:Lib notify last` | Show the last delivered message in full, in a read-only viewer |
| `:Lib notify history [{source}]` | Open the notify history (optionally filtered by source) |
| `:Lib notify dismiss` | Close every visible notification toast (the history stays) |
| `:Lib notify clear [{source}]` | Clear the notify history (optionally by source) |

`{plugin}` completes from the `DEPS_PLUGIN` argument type — the set of plugins
that declare a dependency spec, computed at completion time.

The `deps` routes live under `:Lib deps …` rather than a separate `:LibDeps`
command on purpose: a second top-level name for a subordinate feature is
exactly the `:VerbFeatureA`/`:VerbFeatureB` shape the composer exists to
replace. The `notify` routes (`lib.nvim.notify.popup.routes()`) follow the
same pattern and, unlike `deps`, are always merged in — no `o.notify` flag —
since notify history management is core lib.nvim, not an opt-in feature.

Every route here is a command and none is a keymap, which is why this
namespace has no keymaps module at all: a library its dependents load has no
business claiming a key on their behalf. A feature that genuinely wants a
keystroke borrows one for as long as its window is on screen and hands back
whatever it shadowed — the pattern
[hover.nvim](https://github.com/WKDSteve/hover.nvim) uses for `q`/`<Esc>`,
and the exception that proves the rule.

The generated table is also kept at
[`BINDINGS/Usercmds.md`](BINDINGS/Usercmds.md).

## Autocommands

One, in the augroup `LibNvimUsrCmdsHelptags`:

| event | pattern | option | desc |
| --- | --- | --- | --- |
| `User` | `LazyInstall`, `LazyUpdate`, `LazySync` | `helptags` | Regenerate helptags after lazy.nvim installs or updates plugins |

Two things about it are the result of fixing a bug rather than a first draft,
and both are worth knowing before touching it:

- **It hangs off those three `User` patterns, not `LazyDone`.** `LazyDone`
  fires on *every* start, and `helptags ALL` walks every installed plugin's
  `doc/` directory and rewrites its tags file unconditionally — nothing about
  it is incremental, so the second run in a session costs exactly as much as
  the first. Help files only change when a plugin is installed or updated, and
  those are the events above. `:Lib helptags` covers the case where something
  changed outside lazy's knowledge.
- **The augroup is named and created with `clear = true`.** It used to have no
  group, and `setup()` is called again on every config reload: each call added
  another `User` autocmd for the same three patterns, so a `:Lazy sync` after
  two reloads ran `helptags ALL` three times. At the ~229 ms that costs with a
  hundred-plus plugins, that is visible. A named group makes re-registration
  idempotent by construction.

## Switching things off

Everything is a flag on `setup()`, and each is independent:

```lua
require("lib.nvim_usrcmds").setup({
  helptags           = true,   -- the autocommand + :Lib helptags
  cwd_here           = true,   -- :CwdHere + :Lib cwd-here
  powershell_profile = vim.fn.has("win32") == 1,
  lib_verb           = true,   -- the :Lib verb itself
  deps               = true,   -- the :Lib deps … routes
})
```

Setting `lib_verb = false` drops the verb but keeps the flat commands; setting
an individual feature to `false` drops it from both surfaces at once.
