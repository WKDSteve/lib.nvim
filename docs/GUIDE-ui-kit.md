# `lib.nvim.ui.kit` — User Guide

> **The kit's code lives in lib.nvim** (`lua/lib/nvim/ui/kit/`, since
> 2026-10-28); `ui.nvim`'s `ui.kit.*` are re-exports of the same tables, so
> `require("lib.nvim.ui.kit")` and `require("ui.kit")` are interchangeable.
> Features and fixes are made here.

A themed, composable UI toolkit for Neovim plugins. Pick a preset once and every
popup is visually coordinated; or override colors/borders per call. Everything
is cross-platform (pure `nvim_open_win` + highlights).

- Vimhelp: `:help lib.nvim-kit`
- **Live playground:** `:KitPreview` after `kit.setup()`, or `kit.preview()` at any
  time (see [§6](#6-live-preview-playground))

## Contents
1. [Getting the module](#1-getting-the-module)
2. [Quick start](#2-quick-start)
3. [Themes & presets](#3-themes--presets)
4. [Components](#4-components)
5. [Layouts & templates](#5-layouts--templates)
6. [Live preview playground](#6-live-preview-playground)
7. [Highlight groups](#7-highlight-groups)

---

## 1. Getting the module

```lua
local kit = require("lib.nvim.ui.kit")
-- or via the aggregator:  require("lib").kit
```

Optionally configure once (registers presets and installs `:KitPreview`):

```lua
require("lib.nvim.ui.kit").setup({
  default = "rounded",          -- active preset when a call passes no theme
  presets = {                   -- your own named presets
    myplugin = { border = "double", hl = { accent = "WarningMsg" } },
  },
})
```

## 2. Quick start

```lua
kit.note({ title = "Saved", message = "Wrote 3 files", timeout = 2000 })
kit.toast({ message = "background job done" })
kit.select({ selection = { "one", "two", "three" }, on_select = function(item, i) end })
kit.confirm({ question = "Delete 3 files?", on_answer = function(yes) end })
kit.input({ prompt = "New name", default = "x", on_submit = function(text) end })
```

Every component also works through the one front door, `kit.popup{ type = … }`:

```lua
kit.popup({ type = "select", selection = { "a", "b" }, on_select = fn })
```

## 3. Themes & presets

A **theme** is a table of tokens (border, padding, zindex, title position, and
semantic highlight groups). Built-in **presets** differ mainly in border:

| Preset      | Border | Look |
| ----------- | ------ | ---- |
| `minimal`   | none   | subdued (selection→`Visual`, accents muted) |
| `rounded`   | rounded (default) | base palette |
| `solid`     | single | `Statement` accents, bold `Title` |
| `double`    | double | `Special` border, `WarningMsg` accents |
| `ascii`     | ASCII glyphs | `Comment` border, `Identifier` accents |
| `dock_left` | glyph-less left edge | for a panel docked against the screen's left edge |
| `menu`      | rounded | coloured frame and title (`Function`); `kit.menu`'s default |
| `hacker`    | ASCII glyphs | fixed green-on-black palette, does not follow the colorscheme |

Presets differ in border **and** in which standard highlight groups they link
to, so they look distinct under any colorscheme — no colors are hardcoded, so
everything stays theme-adaptive.

Anywhere a component takes a `theme`, you can pass:

```lua
kit.note({ message = "…", theme = "double" })                       -- a preset name
kit.note({ message = "…", theme = { hl = { accent = "WarningMsg" } } }) -- an override table
kit.note({ message = "…" })                                          -- nil → active default
```

Highlights **link to standard groups** by default (`NormalFloat`, `FloatBorder`,
`FloatTitle`, `PmenuSel`, `Special`, `Comment`, `DiagnosticError`, …), so the look
is correct in any colorscheme. Override any of the semantic keys:
`normal`, `border`, `title`, `selection`, `accent`, `muted`, `error`, `flash`,
`hover`, and the status tokens `ok`, `warn`, `info`, `dim`.

**Status tokens.** A list whose rows have a state (test results, tasks, health)
uses the groups `KitOk`, `KitWarn`, `KitInfo` and `KitDim` rather than groups of
its own. They link to `DiagnosticOk`, `DiagnosticWarn`, `DiagnosticInfo` and
`Comment`, and a preset or an override table sets them like any other key. The
global groups follow the active default: `kit.setup()` defines them, so a list in a
plain split or a statusline is coloured before any kit surface opens, and a new
`default` recolours them at once (a surface opened with its own `theme` sets them to
that theme until the next one):

```lua
kit.setup({
  default = "mine",
  presets = { mine = { hl = { ok = "String", warn = { fg = "#e0af68" } } } },
})
vim.api.nvim_buf_set_extmark(buf, ns, row, 0, { line_hl_group = "KitDim" }) -- a skipped row
```

## 4. Components

| Type       | What it is | Sketch |
| ---------- | ---------- | ------ |
| `note`     | centered title + message float; optional `timeout` auto-dismiss | ↓ |
| `viewer`   | read-only info panel; auto-sized to content; closes on `q`/`<Esc>` or when focus leaves it | |
| `toast`    | ephemeral top-right message; stacks; never steals focus | ↓ |
| `input`    | single-line insert-mode prompt (`<CR>` submit, `<Esc>` cancel) | |
| `live_input` | `input` plus debounced `on_change(query)` as the user types | |
| `form`     | sequential multi-field prompt, chained into one keyed result table | |
| `select`   | native themed list chooser (`j`/`k`, `<CR>`, `<Tab>` marks in multi) | |
| `prompt`   | ask: `answer_type = "confirm"` (yes/no → boolean) or `"text"` | |
| `confirm`  | horizontal-button dialog (`h`/`l` move, `<CR>` confirm, click confirms) | ↓ |
| `menu`     | cursor-anchored action list (`{ label, action }`) | |
| `picker`   | interactive prompt + results + preview (see §5) | ↓ |
| `compare`  | pick two items out of one picker, view them side by side (see §5) | |
| `sidebar`  | themed split panel on the left, right or bottom (`kit.sidebar.open`, not a `popup` type) | ↓ |
| `progress` | passthrough to [`lib.nvim.progress`](../lua/lib/nvim/progress/README.md) | |

**note** — `kit.note({ title, message, timeout? })`


**toast** — `kit.toast({ message, timeout? })`


**confirm** — `kit.confirm({ question, choices?, on_answer })`. Default
`Yes`/`No` yields a boolean; a custom `choices` list yields the chosen string
(cancel → `nil`). `h`/`l`/arrows move focus, `<CR>` confirms, `<Esc>`/`q`
cancels. Without `default` (index or label) the safe button starts focused, so a stray `<CR>`
never confirms a destructive action: `No` of the Yes/No pair, else the first button labelled
No/Cancel (also `Nein`/`Abbrechen`), else the first button (a menu-like list has no safer one).
Behaviour change: before, the first button was always focused. One key picks a button directly: `y`/`n` for Yes/No, else the first
free letter of the label (`Cancel`, `Close`, `Copy` → `c`, `o`, `p`), else its
digit; the key is underlined in the button (see the kit README for the rules). A left click on a button focuses and confirms it directly (needs
`mouse=a`); clicking blank space in the dialog is a no-op, not a cancel.


```lua
kit.confirm({ question = "Pick", choices = { "Keep", "Discard", "Cancel" },
              on_answer = function(choice) end })
```

**sidebar** — `kit.sidebar.open({ name, position?, size?, title?, lines?, theme? })`.
A split instead of a float: fixed width (or height at the bottom), the theme through
`winhighlight`, one sidebar per position (a newer one hides the older and brings it
back when it closes), `hide`/`show`/`toggle`, and `kit.sidebar.close_all()` as the one
cleanup. Details in the [kit README](../lua/lib/nvim/ui/kit/README.md#sidebar-themed-split-panel).

```
┌──────────┬───────────────────────────┐
│ Tests    │                           │
│ ✓ a_spec │   code window             │
│ ✗ b_spec │                           │
│          │                           │
└──────────┴───────────────────────────┘
```

## 5. Layouts & templates

The **layout engine** turns a declarative region spec into aligned
`nvim_open_win` geometry for several coordinated floats — "windows that line up
perfectly", no gaps, recomputed on resize.

### The classic picker — the layout looks like this

`kit.layout.template("picker", …)` gives you a prompt (full width, top), a
result list (bottom-left, 40%) and a preview (bottom-right, 60%):


```lua
-- Mount the template as-is, then fill the slots yourself:
local g = kit.layout.template("picker", { theme = "rounded" })
g.slots.results:set_lines(matches)
g.slots.preview:set_lines(preview_lines)
g.close()   -- closes every slot
```

### Custom arrangements

Compute geometry directly (pure, unit-testable) and mount it:

```lua
local geo = kit.layout.compute({
  width = 0.8, height = 0.8, gap = 0,
  rows = {
    { name = "prompt", height = 3 },                       -- fixed 3 rows
    { cols = {
        { name = "results", width = 0.4 },                 -- 40%
        { name = "preview", width = 0.6 },                 -- 60%
    }},
  },
})
-- geo.slots.prompt / .results / .preview → { row, col, width, height, relative }
```

Sizing per region: a fraction (`0.4` of the parent axis), a fixed integer
(`height = 3`), or `nil` (take the remainder). Copy `kit.layout.templates.picker.spec`
and tweak it, or write your own.

### Interactive picker (Telescope-style)

`kit.picker` makes the picker template live — an insert-mode prompt drives the
results:

```lua
local p = kit.picker({
  on_change = function(query) p.set_results(compute_matches(query)) end, -- debounced
  on_submit = function(idx, text) open(text) end,                        -- <CR>
})
-- <C-n>/<C-p> or arrows move the selection; <Esc> closes.
```

### Compare two items (pick two, view side by side)

`kit.compare` is a picker for picking *two* things: search, mark one
(`<M-c>` or `<CR>`), search again, `<CR>` a second time to view both at once.

```lua
kit.compare({
  items = scanned_files,
  render = function(item, surface) surface:set_lines(read_lines(item)) end,
  on_close = function(a, b) end, -- b is nil if the pick was aborted
})
```

`render(item, surface)` is the only rendering contract, so it isn't limited
to text: images.nvim's `:Image compare` draws a terminal-overlay image into
`surface.winid`s screen coordinates instead of setting buffer lines. See
`docs/EXAMPLES/kit-compare.lua` for the three-state flow
(SEARCH → MARKED → COMPARE) in full.

## 6. Live preview playground

Not sure how a theme will look? Run (after `require("lib.nvim.ui.kit").setup()`):

```vim
:KitPreview
```

(or `require("lib.nvim.ui.kit").preview()`, which needs no setup). It opens a new tab split in two:

```
┌─────────────────────────┬──────────────────────────────┐
│ config (edit me)        │ preview (updates as you type) │
│                         │                               │
│ return {                │  Theme preview — border=double│
│   border = "double",    │  ╔══ note ══════════════════╗ │
│   hl = {                │  ║ A themed message float.   ║ │
│     accent = "…",       │  ╚═══════════════════════════╝ │
│   },                    │  ╔══ select ════════════════╗ │
│ }                       │  ║ selected item (current)   ║ │  ← KitSelection
│                         │  ║ marked item (multi)       ║ │  ← KitAccent
│                         │  … [ Yes ] «No» [ Cancel ] … │ │
└─────────────────────────┴──────────────────────────────┘
```

Edit the left buffer (a preset name or an override table); the right pane
re-renders instantly with your theme's borders and `KitSelection` / `KitAccent`
/ `KitTitle` / `KitMuted` colors. A quick-reference of presets and `hl` keys
sits **below** the return value in the config buffer.

- **`<Tab>`** cycles the five border presets (`minimal` → `rounded` → `solid` →
  `double` → `ascii`); `dock_left`, `menu` and `hacker` are not in the cycle.
- **`<S-Tab>`** cycles installed **nvim colorschemes** and applies them live —
  because the kit's highlights link to standard groups, the whole preview
  restyles under each colorscheme. Your original scheme is restored on close.

Note: the `hl.*` keys (`title`, `selection`, `accent`, …) are **highlight-group
links**, not text — e.g. `hl.title = "ErrorMsg"` recolors titles. A broken
config shows an error instead of throwing. Press `q` to close.

`:KitPreview` is registered by `require("lib.nvim.ui.kit").setup()`; loading the
kit alone registers nothing, and `kit.preview()` registers it on the way.

## 7. Highlight groups

The kit materializes these global groups from the active default theme (link targets
in parens); override them per theme via the `hl` keys. A window opened with another theme
remaps them to groups of its own in `winhighlight`, so naming `KitOk` in an extmark paints the
window's colour:

| Group          | Default link       | Used for               |
| -------------- | ------------------ | ---------------------- |
| `KitNormal`    | `NormalFloat`      | body / background      |
| `KitBorder`    | `FloatBorder`      | borders                |
| `KitTitle`     | `FloatTitle`       | titles                 |
| `KitSelection` | `PmenuSel`         | current item / focused button |
| `KitAccent`    | `Special`          | marked items, accents  |
| `KitMuted`     | `Comment`          | hints / secondary text |
| `KitError`     | `DiagnosticError`  | errors                 |
| `KitFlash`     | `IncSearch`        | the row a pick just landed on |
| `KitHover`     | `Visual`           | the row under the mouse pointer |
| `KitOk`        | `DiagnosticOk`     | status: passed / healthy |
| `KitWarn`      | `DiagnosticWarn`   | status: needs a look   |
| `KitInfo`      | `DiagnosticInfo`   | status: neutral information |
| `KitDim`       | `Comment`          | status: skipped / inactive |
| `KitHotkey`    | `{ underline = true }` | the key that picks a dialog button |
