# lib.nvim.window

---

## Overview

The `lib.nvim.window` module bundles small, focused helpers for **overlay and
floating windows** — that is, anything that is not a normal file window:
hover popups, pickers, debug panels, transient info windows.

Instead of rewriting the same boilerplate for scratch buffers, close-on-key,
title and positioning in every plugin, you call a small function here and pass
the window ID.

Guiding ideas:

* **one task per function** — small, individually testable building blocks
* **idempotent & defensive** — invalid IDs are a safe no-op (`pcall`,
  `nvim_win_is_valid`), never a crash
* **buffer-local** — keymaps and autocmds only affect the target window
* **composable** — `make_scratch` builds on `nice_quit`; nothing is
  implemented twice

---

## Module structure

```
lib.nvim.window/
├── init.lua                 -- aggregator + attach() constructor
├── make_scratch.lua         -- scratch buffer + float in one call
├── nice_quit.lua            -- q / <Esc> to close (normal mode)
├── set_title.lua            -- set / clear a float title
├── printable_title.lua      -- (internal) a title with control characters spelled out
├── close_on_focus_lost.lua  -- auto-close on focus loss
├── center.lua               -- re-center a float
├── open_named_scratch.lua   -- named, de-duplicated scratch split
├── open_scratch_split.lua   -- fresh (non-de-duplicated) scratch split
├── tag.lua                  -- find windows by an arbitrary string tag
├── matches.lua              -- named, per-window ledger over matchadd/matchdelete
├── focus_helpers.lua        -- keep a log view scrolled to bottom / force focus
├── find_usable.lua          -- find a normal, non-floating, non-sidebar window
├── find_by_filetype.lua     -- find the first open window showing a given filetype
└── @types/                  -- LuaLS types
```

The entry point is `require("lib.nvim.window")`. Individual functions can also be
loaded directly (tree-shake friendly, recommended in plugin code):

```lua
local make_scratch = require("lib.nvim.window.make_scratch")
```

---

## Two consumption styles

**1) Free functions** — pass the window ID every time:

```lua
local window = require("lib.nvim.window")
local winid, bufnr = window.make_scratch({ lines = { "Hello" }, title = "Info" })
window.nice_quit(winid)
window.center(winid)
```

**2) Constructor (`attach`)** — a bound handle, **dot-call** (no `self`):

```lua
local window = require("lib.nvim.window")
local w = window.attach(winid)
w.nice_quit()
w.set_title("New title")
w.center()
```

`attach` is pure sugar: each method delegates with a pre-bound `winid` to the
free function. The free functions remain the single source of truth.

---

## Functions

### `make_scratch(opts?) -> winid, bufnr`

Creates an unlisted **scratch buffer** (`nofile`, `bufhidden=wipe`, no swapfile)
in a **centered float** and returns `winid, bufnr` (`nil, nil` on error — the
buffer is then cleaned up again).

```lua
local winid, bufnr = window.make_scratch({
  lines     = { "Line 1", "Line 2" },
  title     = "Hover",
  nice_quit = true,        -- q / <Esc> close immediately
  filetype  = "markdown",
})
```

| Option        | Type                                  | Default      | Meaning                                                |
| ------------- | ------------------------------------- | ------------ | ------------------------------------------------------ |
| `lines`       | `string[]`                            | `{}`         | initial content                                        |
| `width`       | `number`                              | content      | strictly between 0 and 1 = fraction of `vim.o.columns`, larger = cells (so `1` is one cell, `2` two); not given (or a fraction rounding to zero cells) = derived from content, falling back to 60 whenever that derived width is 2 cells or less (no content, or content that renders at zero display width); clamped to editor |
| `height`      | `number`                              | line count   | strictly between 0 and 1 = fraction of `vim.o.lines`, larger = cells (so `1` is one row, what a prompt wants); not given (or a fraction rounding to zero cells) = the line count; clamped to editor |
| `relative`    | `"editor"\|"cursor"\|"win"`           | `"editor"`   | anchor of the float                                    |
| `row` / `col` | `integer`                             | centered     | explicit position (otherwise editor-centered)          |
| `border`      | `string\|string[]`                    | `"rounded"`  | border style                                           |
| `title`       | `string`                              | –            | title (only visible with a border); control characters in it are spelled out (`^[`), never drawn raw |
| `title_pos`   | `"left"\|"center"\|"right"`           | –            | title position                                         |
| `footer`      | `string`                              | –            | footer on the bottom edge of the border, spelled out like `title`; left out without a border (`"none"`, `""`) |
| `footer_pos`  | `"left"\|"center"\|"right"`           | –            | footer position                                        |
| `focusable`   | `boolean`                             | `true`       | focusable                                              |
| `enter`       | `boolean`                             | `true`       | focus the new window immediately                       |
| `zindex`      | `integer`                             | –            | stacking order                                         |
| `filetype`    | `string`                              | –            | buffer `filetype`                                      |
| `modifiable`  | `boolean`                             | `false`      | keep the buffer writable (otherwise read-only)         |
| `nice_quit`   | `boolean\|NiceQuitOpts`               | `false`      | wire up `q`/`<Esc>` closing directly                   |
| `wo`          | `table<string, any>`                  | –            | window-local option overrides                          |
| `bo`          | `table<string, any>`                  | –            | buffer-local option overrides                          |

Overlay defaults for the window (`number=false`, `relativenumber=false`,
`signcolumn=no`, `wrap=false`, `cursorline=false`, `style=minimal`) can be
overridden via `opts.wo`. The content is set, **then** the buffer is locked to
`nomodifiable` (unless `modifiable = true`).

---

### `nice_quit(winid, opts?) -> boolean`

Binds `q` and `<Esc>` **buffer-local, normal mode only** to closing the window.

```lua
window.nice_quit(winid)
window.nice_quit(winid, { keys = { "q" }, force = true })
```

| Option  | Type       | Default            | Meaning                                   |
| ------- | ---------- | ------------------ | ----------------------------------------- |
| `keys`  | `string[]` | `{ "q", "<Esc>" }` | normal-mode keys to close                 |
| `force` | `boolean`  | `false`            | discard unsaved changes                   |

**Why normal mode only?** This gives the natural "double escape" for free: the
first `<Esc>` leaves insert/terminal mode (Vim default), the second `<Esc>` —
now in normal mode — closes the window. In insert/terminal mode nothing is
mapped, so TUI programs (fzf, lazygit …) still receive Escape themselves. The
keymaps use `nowait`, so no `timeoutlen` delay occurs. The last window of the
tabpage is never closed.

---

### `set_title(winid, title, opts?) -> boolean`

Sets (or clears with `nil`) the title of a **floating window**. On non-floats a
safe no-op.

```lua
window.set_title(winid, "New title", { pos = "center" })
window.set_title(winid, nil)   -- remove title
```

> **Note:** Neovim stores and shows a float title only if the float has a
> **border**. Without a border the title has no effect (a debug hint is emitted).

> **Note:** a title is text a caller may have built from typed or pasted input
> (a file name, a command line). Neovim draws a plain-string title cell by cell,
> control characters included, and the TUI writes those to the terminal as they
> are (an ESC ] 0 ; ... BEL sets the terminal's window title). `set_title` and
> `make_scratch` therefore spell them out the way Neovim shows them in a buffer
> (`^[`, `^G`, `^I`, `<9b>`); an ordinary title is passed through untouched.

---

### `close_on_focus_lost(winid, opts?) -> augroup | nil`

Registers a one-shot, buffer-local autocmd that closes the window as soon as
focus leaves it — the typical hover/popup dismiss. Returns the **augroup id**,
with which it can be canceled again via `nvim_del_augroup_by_id`.

```lua
local grp = window.close_on_focus_lost(winid)
-- cancel later if needed:
vim.api.nvim_del_augroup_by_id(grp)
```

| Option   | Type       | Default                      | Meaning                          |
| -------- | ---------- | ---------------------------- | -------------------------------- |
| `events` | `string[]` | `{ "WinLeave", "BufLeave" }` | events that count as focus loss  |
| `force`  | `boolean`  | `true`                       | discard unsaved changes          |

The autocmd is `once = true` (cleans itself up) and closes via `vim.schedule`,
since closing directly from within `WinLeave` would be unsafe.

---

### `center(winid) -> boolean`

Re-centers an existing float on the editor (from the current width/height and
editor size). No-op on non-floats and invalid IDs.

```lua
window.center(winid)
```

---

### `open_scratch_split(lines?, opts?) -> bufnr, winid`

Opens a fresh scratch buffer (`nofile`, `bufhidden=wipe`, no swapfile) in a
plain **split** — every call opens its own window, with no de-duplication by
name. Use this for report/audit-style output where a second invocation should
produce its own buffer rather than silently overwrite a previous run.
Complements `make_scratch` (floats) and `open_named_scratch` (named,
de-duplicated split).

```lua
local bufnr, winid = window.open_scratch_split(report_lines, {
  filetype = "my-plugin-report",
})
```

| Option       | Type                                  | Default    | Meaning                                              |
| ------------ | -------------------------------------- | ---------- | ----------------------------------------------------- |
| `filetype`   | `string`                              | –          | buffer `filetype`                                     |
| `split`      | `"above"\|"below"\|"left"\|"right"`   | –          | split direction; unset honors 'splitbelow'/'splitright' |
| `modifiable` | `boolean`                             | `false`    | keep the buffer writable (otherwise read-only)         |

---

### `open_named_scratch(name, lines?, opts?) -> bufnr, winid`

Find-or-create a **named** scratch buffer shown in a split. Unlike
`open_scratch_split`, a second call with the same `name` reuses the existing
buffer/window instead of piling up duplicates — the right choice for a log
viewer or list view that should stay a single, stable window.

```lua
local bufnr, winid = window.open_named_scratch("MyPlugin://log", lines, {
  filetype = "myplugin-log",
  split = "below",
})
```

| Option       | Type                                  | Default    | Meaning                                              |
| ------------ | -------------------------------------- | ---------- | ----------------------------------------------------- |
| `filetype`   | `string`                              | –          | buffer `filetype`                                     |
| `split`      | `"above"\|"below"\|"left"\|"right"`   | `"below"`  | split direction, only used when opening for the first time |
| `size`       | `integer`                             | –          | width (left/right) or height (above/below) of a fresh split |
| `modifiable` | `boolean`                             | `true`     | keep the buffer writable                              |

If a window already shows the named buffer (in any tab), that window is
focused instead of opening a new split.

The name is matched **exactly**, as Neovim itself compares buffer names
(`bufexists()`): `log://x.log` never picks up the buffer of `log://x.log.1`,
and `*`, `?`, `[`, `%`, `#` in a name are plain characters, not wildcards.
A plain name (without `scheme://`) is stored as an absolute path below the
cwd, like any `nvim_buf_set_name`. An empty name raises.

---

### `is_usable_window(winid) -> boolean` / `target_window(opts?) -> winid|nil`

Find a normal content window to act on — not floating, not a sidebar
(`filetype` in a small deny-list: `neo-tree`, `NvimTree`, etc.), not a
special buffer type.

```lua
window.is_usable_window(vim.api.nvim_get_current_win())  -- boolean

local winid = window.target_window()                              -- any tab
local winid = window.target_window({ current_tab_only = true })   -- this tab only
```

`target_window` prefers the current window if it's usable, otherwise scans
for the first usable one.

---

### Focus helpers — `ensure_bottom`, `make_focusable`, `force_focus`, `reveal_at_bottom`

For log/output-style windows that should stay scrolled to the latest line and
be reachable even when opened as a non-focusable float:

```lua
window.ensure_bottom(winid)      -- scroll winid's cursor to its buffer's last line
                                   -- (retries if winid isn't valid yet)
window.make_focusable(winid)     -- flip a floating window's `focusable` config to true
window.force_focus(winid)        -- make_focusable + nvim_set_current_win
window.reveal_at_bottom(winid)   -- force_focus + ensure_bottom
```

---

### `best_target_window(opts?) -> winid|nil`

The window to put text into, by a fixed chain: `opts.source_win` (where the action came from) -> the
alternate window (`:wincmd p`) -> the first usable window. Every step must be `is_usable_window` and, unless
`writable = false`, hold a normal, modifiable buffer. `current_tab_only = true` limits the last step.

```lua
local win = window.best_target_window({ source_win = state.source_win })
if win then
  vim.api.nvim_win_call(win, function() vim.api.nvim_put({ alias }, "c", true, true) end)
end
```

Unlike `insertion_window` (current window, else the previous one) it knows an explicit origin window, which
a float or picker stores when it opens.

### `matches.new() -> ledger`

A window-local match ledger: `window -> { name -> match id }`, so highlights made with `matchadd()` are
addressed by name and the caller never keeps match ids. Each plugin makes its own ledger.

```lua
local ledger = require("lib.nvim.window.matches").new()
ledger:add(win, "cursorword", "Search", [[\<foo\>]], { priority = 5 }) --> match id | nil, err
ledger:add(win, "cursorword", "Search", [[\<bar\>]])  -- same name: replaces (a bad pattern keeps the old one)
ledger:add_pos(win, "line", "Search", { { 3, 1, 4 } })  -- matchaddpos
ledger:has(win, "cursorword")   --> boolean (a match deleted elsewhere counts as gone)
ledger:list(win)                --> { cursorword = <id>, ... }
ledger:remove(win, "cursorword")--> boolean
ledger:clear(win)               --> count removed;  ledger:clear_all()
```

Closed windows are forgotten, never an error; matches of others in the same window are left alone.

Note: a window's matches stay with that window. Neovim does not copy them into the window a `:split` creates
(checked on 0.12; `TESTS/window_matches_spec.lua` pins it), so the new window has none and
`ledger:list(new_win)` is empty. A match wanted in the split is added again for it (e.g. on `WinNew`).

### `find_by_filetype(filetype) -> winid|false`

First open window whose buffer has the given `filetype`, or `false` if none
exists. Generic replacement for filetree-manager-specific lookups (Neo-tree's
`"neo-tree"`, nvim-tree's `"NvimTree"`, etc.) — pass the filetype you care
about instead of hardcoding one.

```lua
local winid = window.find_by_filetype("neo-tree")
```

---

### `tag` — find windows by an arbitrary string tag

Small namespace for identifying a window later without keeping your own
registry (a registry can go stale when a window closes through a path you
never observed). Uses the same `vim.w[win].custom_tag` convention as
`lib.nvim.buf_win_tab.capture`'s `tag` option, so windows tagged by either can
be found by the other.

```lua
window.tag.set(winid, "my-plugin://report")
local found = window.tag.find("my-plugin://report")  -- nil if not open / closed
local t = window.tag.get(winid)                        -- read it back
```

`find` only matches live, real content windows (not hidden or degenerate
floats with width/height <= 1).

---

### `attach(winid) -> Handle`

Creates a handle bound to `winid`. All of the above functions that take `winid`
as the first parameter are available as methods (dot-call):

```lua
local w = window.attach(winid)
w.set_title("Title")
w.nice_quit()
w.center()
w.close_on_focus_lost()
```

---

## Typical flow

```lua
local window = require("lib.nvim.window")

local winid, bufnr = window.make_scratch({
  lines     = vim.split(help_text, "\n"),
  title     = " Help ",
  title_pos = "center",
  filetype  = "markdown",
  nice_quit = true,            -- q / <Esc> close
})

window.close_on_focus_lost(winid)  -- also closes when clicking away
```

---

## Notes

* Float-specific functions (`set_title`, `center`) have no classic-Vim
  equivalent — floating windows are a Neovim-only concept.
* All functions are defensive: invalid window IDs return a safe value
  (`false` / `nil`) plus a debug `notify`, instead of throwing.
