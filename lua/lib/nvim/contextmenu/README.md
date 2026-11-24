# `lib.nvim.contextmenu`

> **One implementation, here.** This module is the only copy of the context
> menu. [`ui.nvim`](https://github.com/WKDSteve/ui.nvim)'s
> `require("ui.contextmenu")` is a re-export of it (like `ui.kit.*`, which
> re-exports `lib.nvim.ui.kit.*`), so both names share one module and one
> state, including `set_enabled`/`is_enabled` (`ui.setup({ menu = false })`).
> The ecosystem's consumer plugins keep requiring `ui.contextmenu`; code that
> cannot depend on `ui.nvim` requires `lib.nvim.contextmenu` directly.

Building blocks for [nvzone/menu](https://github.com/nvzone/menu)-shaped
context-menu entries: a self-gating item builder (`entry`/`group`/`submenu`),
a renderer (`open`), and a mouse-trigger binder (`bind_buffer`).

Two renderers draw the same item tables:

| `renderer` | draws with | notes |
|---|---|---|
| `"auto"` (default) | nvzone/menu if installed, else the kit | nothing changes for an existing setup |
| `"nvzone"` | [nvzone/menu](https://github.com/nvzone/menu) | side-by-side fly-outs; falls back to the kit (one notify) when not installed |
| `"kit"` | `lib.nvim.ui.kit.menu` | no third-party dependency, kit theming, drill-down fly-outs |

```lua
require("lib.nvim.contextmenu").setup({ renderer = "kit" })
```

The dependency stays soft either way: `menu` is only `require()`d when a menu
actually opens, and a missing install degrades to the kit, never to an error.

### `native_popup`

Neovim ships its own built-in right-click menu (`:h popup-menu`), which pops
up under the editor's default `'mousemodel'` (`popup_setpos`) wherever a click
lands on no active `<RightMouse>` mapping at all — a blank line past a tree's
last node, a spot no contributor's own menu covers, insert mode, and so on.
From the user's chair that reads as "a different context menu sometimes
appears", indistinguishable at a glance from this module's own menu
degrading to something else.

`setup()` turns it off by default (sets `'mousemodel' = "extend"`) — opt-out,
not opt-in, so a host that never mentions the option still gets the sane
default with nothing to remember to configure:

```lua
require("lib.nvim.contextmenu").setup({})                        -- native popup off (the default)
require("lib.nvim.contextmenu").setup({ native_popup = true })   -- keep vanilla Neovim's PopUp menu
```

## Two integration shapes

**"Owns its buffer"** — a plugin-created UI (a tree, a dashboard, a
list-view). The plugin ships both an item builder and its own trigger,
bound directly on the buffer it creates. Live reference: `filetree.nvim`
(`lua/filetree/integrations/menu.lua` +
`lua/filetree/features/ui/context_menu/init.lua`).

```lua
-- integrations/menu.lua
local contextmenu = require("lib.nvim.contextmenu")
local nerd = require("lib.nvim.ui.nerd_font")

function M.items()
  local out = {}
  contextmenu.group(out,
    contextmenu.heading("MyPlugin"),
    contextmenu.entry(feature("x") ~= nil, "Do X", do_x, "<leader>x", {
      icon = nerd.glyph("F0AD", "*"),
    }),
    contextmenu.entry(feature("y") ~= nil, "Do Y", do_y, nil, {
      icon = nerd.glyph("F0EB", "*"),
    })
  )
  return out
end

function M.submenu(label)
  local items = M.items()
  if #items == 0 then return nil end
  return contextmenu.submenu(label or "MyPlugin", items, {
    icon = nerd.glyph("F1B2", "*"),
  })
end
```

> **Put the glyph in `icon`, never in the label.** The kit renderer draws
> icons as a column of their own, so an entry with one lines up with an entry
> without. A glyph inside `label` is just text: it indents that row past every
> other, and it makes `"  Do X"` — two spaces where a glyph was meant to be —
> indistinguishable from a working entry. That exact bug shipped twice in this
> ecosystem before the column existed.

```lua
-- features/ui/context_menu/init.lua, wherever the plugin's own buffer is created
local contextmenu = require("lib.nvim.contextmenu")
local items_mod = require("myplugin.integrations.menu")

contextmenu.bind_buffer(bufnr, items_mod.items, {
  desc = "MyPlugin: right-click context menu",
})
```

**"Contributes only"** — the plugin's actions apply to ordinary
filetype-scoped or condition-scoped buffers it doesn't own. It ships only
`integrations/menu.lua` (`items`/`submenu`), with **no trigger code and no
`nvzone/menu` dependency at all** — a host (typically the user's own
RightMouse dispatcher) composes `submenu(...)` into its own menu when the
relevant condition holds. Live reference: `markdown.nvim`
(`lua/markdown/integrations/menu.lua`, composed by the user's
`config/menu/mappings.lua`).

## Functions

```lua
local contextmenu = require("lib.nvim.contextmenu")

contextmenu.setup({ renderer = "auto", native_popup = false })  -- renderer: "auto"|"kit"|"nvzone"; native_popup: true keeps Neovim's own PopUp menu (default: off)
contextmenu.renderer()                         -- the configured value
contextmenu.entry(available, label, fn, rtxt, opts)  -- {name,rtxt,cmd,icon,hl} or nil; opts = { icon, icon_hl, hl }
contextmenu.heading(title)                     -- group heading marker; pass it first to `group`
contextmenu.group(out, entry, entry, nil, entry)  -- varargs; appends non-nil items, separator between groups
contextmenu.submenu(label, items, opts)        -- {name=label, items=items} or nil if items is empty
contextmenu.open(items, opts)                  -- draw with the active renderer; `items` may be a "menus.<name>" string
contextmenu.bind_buffer(bufnr, get_items, opts) -- buffer-local <RightMouse>, opens via `open`
```

See `@types/init.lua` for full field documentation (`Lib.ContextMenu.Item`,
`Lib.ContextMenu.BindOpts`).

## Design notes

- `group` takes varargs, not a table: `{ entry(...), nil, entry(...) }` loses
  everything past the first gap under `ipairs`/`#` (a table with holes has no
  defined length in Lua), silently dropping later entries whenever an
  earlier one in the same group gates off. Varargs don't have that problem —
  `select('#', ...)` counts every position, nil or not.
- `entry`/`group`/`submenu` never touch `nvzone/menu` — they build a plain
  data structure. Only `bind_buffer` (and, for "contributes only" plugins, the
  host composing the menu) ever calls `require("menu")`, so a plugin can call
  `entry`/`group`/`submenu` unconditionally regardless of whether nvzone/menu
  is installed.
- `heading` is a marker passed **into** `group`, not a `title` parameter on
  it, so gating reaches it: a section whose every entry is unavailable drops
  its title along with itself, rather than leaving a heading standing over
  nothing. `group` also skips its usual separator when a heading is present —
  the heading already starts the new section.
- The kit renderer draws a named group as a titled frame (`group_style`
  defaults to `"box"`; `"header"` and `"plain"` are the quieter variants). A
  menu that names no section keeps the divider look it always had — which is
  why grouping cost the existing consumers nothing.
- `bind_buffer` resolves the renderer at trigger time, not at bind time — safe
  to call from a plugin's setup path regardless of what is installed.
- Consumers never call a renderer themselves. `entry`/`group`/`submenu` build
  plain data; `open` is the single place either renderer is reached from.
  That is what makes the renderer swappable at all — the two live consumers
  (`filetree.nvim`, `github_stats.nvim`) needed no change for the kit
  renderer to exist.

### The kit renderer, and a claim that was wrong

An earlier version of this file argued that `lib.nvim.ui.kit.menu` was **not
a fit**, because it is cursor-anchored and "doesn't give nvzone/menu's
`{ mouse = true }` pointer positioning that `<RightMouse>` needs". That was
wrong on the fact it rested on: `relative = "mouse"` is a plain
`nvim_open_win` value, and the kit's surface has always passed `relative`
straight through. Nothing had to be computed; the option simply had not been
tried. What the kit renderer genuinely needed was smaller and elsewhere —
separators the cursor steps over (a `selectable = false` rich item in
`ui.kit.chooser`), a right-aligned `rtxt` column, and nesting.

The visual gap that was left after the swap closed later, and only one item
of it was refused. Rows carry a pad column at each edge, dividers are
indented and stop short of the right edge, the block cursor is hidden while
the menu is open, a single left click picks, and a click or focus change
elsewhere dismisses it. What was **not** copied is nvzone/menu's darker
window background: that is a base46 group, so taking it would tie the menu
to NvChad. A menu that should stand out more belongs in a kit preset, not in
`ui.kit.menu`.

One real behavioural difference remains, and it is a design choice rather
than a gap: nvzone/menu opens a nested fly-out in a **second window** beside
the parent, while the kit **drills down** in place, with `<BS>` walking back
up. A single-instance chooser is what gives the kit its themed selection and
its one-window lifecycle; opening a second one to imitate the fly-out would
trade that away for the visual.
