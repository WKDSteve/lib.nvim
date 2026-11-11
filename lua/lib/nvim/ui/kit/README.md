# `lib.nvim.ui.kit`

> **The kit's code lives here** (since 2026-10-28). `ui.nvim`'s `ui.kit.*`
> modules are one-line re-exports of `lib.nvim.ui.kit.*` (the same tables), so
> features and fixes land in this directory. `ui.nvim` keeps the kit's user guide
> (`lua/ui/kit/README.md`), its own `@types` copy and most kit specs; keep this
> README, `@types` and those in step.
>
> History: from 2026-09-14 to 2026-10-28 `ui.nvim` held the canonical copy and
> this one was frozen; moving the code back here ended the duplication (and the
> drift spec that compared the two).

A themed, composable UI toolkit. Pick a preset once and every popup is visually
coordinated, or override colors/borders per call. Built in layers on top of
[`lib.nvim.window`](../../window) (`make_scratch`, `nice_quit`) and
[`lib.nvim.ui.hl`](../hl) — nothing shells out, so it is cross-platform.

> **New here?** Read the [User Guide](../../../../../docs/GUIDE-ui-kit.md)
> (with layout sketches), run **`:KitPreview`** for a live theme playground
> (registered by `kit.setup()`; `kit.preview()` works without it),
> or see [docs/EXAMPLES](../../../../../docs/EXAMPLES) for one scenario per
> component (`kit-note.lua`, `kit-viewer.lua`, `kit-toast.lua`,
> `kit-input.lua`, `kit-live-input.lua`, `kit-form.lua`, `kit-select.lua`,
> `kit-prompt.lua`, `kit-confirm.lua`, `kit-menu.lua`, `kit-picker.lua`,
> `kit-layout.lua`, `kit-sync.lua` (deprecated), `kit-async.lua`).

> **Phases 1–2** (this release): theme/preset engine + `surface` primitive +
> components `note`, `toast`, `input`, `select` (delegates to hover_select) and
> `prompt` (confirm/text). The layout engine, templates, native select chooser
> and button-confirm follow.

## Themes & presets

A theme is a token table (border, padding, zindex, title_pos, dims, `hl`).
Built-in presets differ mainly in border strength:

| Preset      | Border    |
| ----------- | --------- |
| `minimal`   | none      |
| `rounded`   | rounded (default) |
| `solid`     | single    |
| `double`    | double    |
| `ascii`     | ASCII glyphs (terminals without good Unicode) |
| `menu`      | rounded, but with a **coloured** frame (`Function`) — `kit.menu`'s default |

Highlights link to standard groups (`NormalFloat` / `FloatBorder` /
`FloatTitle` / `PmenuSel` / …), so the default look is correct in any
colorscheme.

**Status tokens.** A list whose rows have a state (test results, tasks, health) uses
the groups `KitOk`, `KitWarn`, `KitInfo` and `KitDim` rather than groups of its own.
They link to `DiagnosticOk`, `DiagnosticWarn`, `DiagnosticInfo` and `Comment`, and a
preset or an override table sets them like any other token (`hl = { ok = "String" }`,
or a highlight spec). These global groups follow the active default: `setup()` defines
them (a list in a plain split or a statusline needs no kit surface to have opened), a
new `default` recolours them at once, and `:colorscheme` defines them again.

**Per window.** A surface with its own `theme` leaves the global groups alone and remaps them
in its window (`KitOk:KitOk_3` in `winhighlight`): an extmark, virtual text or a winbar item
naming `KitOk` paints that theme's colour, and a toast in the default theme recolours neither
the globals nor a list that is already open. The target of a `winhighlight` entry is not
remapped again, so an entry a component adds itself names the scoped group:
`theme.window_groups(resolved).selection`, or `theme.scoped_group(winid, "KitSelection")` when
only the window is at hand. A split that writes `winhighlight` itself merges
`theme.role_remaps(resolved)`.

**Hotkey token.** `KitHotkey` (token `hotkey`, default `{ underline = true }`, no colour) marks
the key that picks a `kit.confirm` button. It is drawn over the letter's `KitAccent`, so it
composes with any colour and the underline stays visible on the focused button; an override table
adds to it (`hl = { hotkey = { bold = true } }`).

```lua
require("lib.nvim.ui.kit").setup({
  default = "rounded",
  presets = {
    myproject = { border = "double", hl = { title = "Title" } },
  },
})
```

A theme argument (anywhere one is accepted) is a preset name, a partial override
table (deep-merged over the active default), or `nil`.

## Surface

One themed float + a lifecycle handle:

```lua
local kit = require("lib.nvim.ui.kit")
local s = kit.surface.open({ lines = { "hi" }, theme = "double", title = "X" })
s:set_lines({ "new", "content" })
s:set_title("Y")
s:focus()
s:on_close(function() end)
s:close()
```

`open(opts)` accepts `lines`, `theme`, `title`, `title_pos`, `width`, `height`,
`relative`, `row`, `col`, `zindex`, `enter`, `focusable`, `nice_quit`,
`filetype`, `modifiable`, `wo`, `bo`. Returns the handle, or `nil` on failure.
The window is `winfixbuf` unless `wo.winfixbuf = false`: a surface lives and dies
with its one buffer, so `<C-o>`, `:bnext` or `:e` in it fail with E1513 instead of
swapping the user's file in and wiping the component's buffer from under it.

A surface opened with an explicit `enter = true` that is not `modifiable` ends
Insert mode when it opens from it: entering a window keeps the mode, so a read-only
float opened by an Insert-mode mapping (a picker's caller key showing details) would
otherwise type `q` (E21) instead of closing, and need `<Esc>` first. A `modifiable`
surface, one with `enter = false`, and one that leaves `enter` at its default leave
the mode alone -- the default is what a component uses for the helper panes it
passes through on the way to its own prompt (`kit.compare`), where a pending
`:stopinsert` would beat the prompt's `:startinsert`.

`kit.surface.mark_secret(bufnr)` / `kit.surface.is_secret(bufnr?)` set and read
the buffer variable `vim.b.ui_kit_secret` (its name is `kit.surface.SECRET_VAR`): a
buffer a secret is typed into. `kit.input` with `secret = true` and a `kit.sheet`
with a secret field mark theirs (see [Secret input](#secret-input-masked-entry));
anything that records or shows keystrokes as they are typed reads the mark and
leaves that buffer's keys out -- `ui.screenkey` of ui.nvim does, and the name is the
same in ui.nvim's copy of the kit, so one HUD sees the prompts of both.

The `TextChanged` hooks of a prompt -- the re-mask of a secret `kit.input`, the
debounce of `kit.live_input` and of `kit.compare`'s query -- are in no group:
buffer-local autocmds, `record = false`, that go with their buffer when the float
closes. A group shared by every prompt and cleared at each open took the hooks of the
prompt that was already open away (its `on_change` was never called again, a secret
typed after that showed in clear text).

## Sidebar (themed split panel)

`kit.sidebar` is the split counterpart of `kit.surface`: a panel on the left, the right
or the bottom of the tabpage -- a file tree, a test explorer, an output pane. The handle
has the surface methods (`set_lines`, `set_last_line`, `append_lines`, `on_close`,
`focus`, `close`) plus `show`/`hide`.

```lua
local sidebar = require("lib.nvim.ui.kit.sidebar") -- or kit.sidebar
local tree = sidebar.open({
  name = "tests",        -- identity: a second open() with this name shows this sidebar again
  position = "left",     -- "left" (default), "right" or "bottom"
  size = 32,             -- width, or height for "bottom"; 0 < size < 1 is a share of the editor
  title = "Tests",       -- in the window bar, themed with the `title` token
  lines = { "..." },
  theme = "rounded",     -- any kit theme argument
})
tree:hide()              -- off screen, kept (buffer, content, size)
tree:show()              -- back; tree:focus() shows it too
sidebar.toggle({ name = "tests" }) -- name required; hides only a sidebar shown in this tabpage
sidebar.find("tests")    -- its window, found by the buffer variable `ui_kit_sidebar`
sidebar.close_all()      -- the one cleanup: every sidebar, visible or hidden
```

- **Fixed size**: `winfixwidth` (left/right) or `winfixheight` (bottom), so `<C-w>=` and new
  splits leave the panel alone; `winfixbuf`, no numbers, signs or folds (`foldenable` off,
  so the code window's `foldmethod` does not close a tree's children), `cursorline` on.
  `wo` / `bo` override any of it.
- **Theme**: `winhighlight` maps `Normal`, `NormalNC`, `EndOfBuffer` and `SignColumn` to the
  theme's `normal` token, `WinSeparator` to `border`, `WinBar` to `title` and `CursorLine`
  to `KitSelection`. It is set from scratch: a split would otherwise copy the mappings of
  the code window it was made from.
- **One sidebar per slot**: opening (or showing) a sidebar where others are visible in
  the same tabpage hides them all and remembers them. When the newer one is closed or
  hidden, the older ones come back in their own tabpage -- once, two `vim.schedule` ticks
  later, and only if no exclusive sidebar took the slot meanwhile (otherwise they wait
  behind it). Chains work: in A <- B <- C, closing B while it is hidden hands A on to C,
  and showing B by hand keeps A waiting behind C. A sidebar the user shows again by hand
  is no longer brought back by an old record, so a later `hide()` sticks.
  `exclusive = false` shares the slot instead; different positions never displace each
  other.
- **Foreign panels** (Neo-tree, filetree.nvim, any split that is not a kit sidebar) join the same
  exclusivity through `sidebar.register_foreign({ name, position, win, hide, show, exclusive? })`.
  `win()` answers the panel's window while it is on screen; the kit calls `hide()` when a kit sidebar takes its slot
  and `show()` when the displacing sidebar goes away. When the panel appears or disappears by its own doing it says
  so with `handle:shown()` (displaces the kit sidebars at its position, remembered and restored later) and
  `handle:hidden()` (restores them). A hide the kit caused is not reported back as `hidden()`.
  `handle:unregister()` forgets the panel.
- **Per tabpage**: `toggle` hides a sidebar only when it is visible in the current
  tabpage; `show`, `focus` and `open` by name move a sidebar visible in another tabpage
  here (`show` returns false when it is that tabpage's last window).
- **Lifecycle**: `close()`, `:q` on the window or `<C-w>o` close the sidebar for good (its
  buffer is wiped, `on_close` runs once); `hide()` keeps it. What it displaced comes back
  after `close()`, `hide()` and `:q` / `<C-w>c` in the sidebar window itself, but not after
  `:only` / `<C-w>o` from another window (the user asked for one window; show it by hand).
  The tabpage's last window cannot hide; closing it closes that tabpage, or, in the
  last tabpage, leaves the window showing another buffer with the sidebar's window
  options reset. `close_all()` closes everything and restores
  nothing -- call it from a `teardown()` or an error path.

## Components

`kit.popup(opts)` dispatches on `opts.type` (convenience aliases: `kit.note`,
`kit.toast`, `kit.input`, `kit.select`, `kit.prompt`). Not-yet-built types warn
with their planned phase.

```lua
kit.popup({ type = "note",  title = "Saved", message = "Wrote 3 files", timeout = 2000 })
kit.popup({ type = "viewer", title = "Node Info", lines = { "name: foo.lua", "size: 128 B" } })
kit.popup({ type = "toast", message = "background job done" })
kit.popup({ type = "input", prompt = "New name", default = "x", on_submit = function(t) end })
kit.popup({ type = "input", prompt = "Password", secret = true, on_submit = function(pw) end })
kit.popup({ type = "input", prompt = "Path", completion = "file", on_submit = function(p) end })
kit.popup({ type = "live_input", prompt = "Filter", on_change = function(query) end })
kit.popup({ type = "form", fields = { { name = "image", label = "Image", required = true } },
            on_submit = function(values) end })
kit.popup({ type = "sheet", fields = { { name = "image", label = "Image", required = true }, { name = "tag", label = "Tag" } },
            on_submit = function(values) end })
kit.popup({ type = "select", message = "Pick", selection = { "a", "b" }, on_select = function(c, i) end })
kit.popup({ type = "prompt", question = "Delete?", answer_type = "confirm", on_answer = function(yes) end })
```

| Type     | What it is |
| -------- | ---------- |
| `note`   | centered title + message float; optional `timeout` (ms) auto-dismiss |
| `viewer` | read-only info panel; auto-sized to content; closes on q/`<Esc>` OR the moment focus leaves it — the "show some info, dismiss it" float duplicated 6+ times across consumer plugins before this existed |
| `toast`  | ephemeral top-right message; stacks; never steals focus; auto-dismiss |
| `input`  | single-line insert-mode prompt; `<CR>` submits, `<Esc>` cancels; `secret = true` masks it as you type; `completion = "file"` (or any `getcompletion()` type) wires `<Tab>` to the native completion popup |
| `live_input` | like `input`, but also debounces keystrokes into `on_change(query)` as you type — for filter/search boxes |
| `form`   | sequential multi-field prompt — chained `input`s collected into one keyed table; `<Esc>` skips an optional field, aborts on a `required` one; `back = true` adds [back navigation](#form-multi-field) (`<BS>` on an empty field, `<S-Tab>`, a `[← Back] [Skip] [Next ↵]` button row, "(2/5)" in the title) |
| `sheet`  | every field of a form at once in ONE float — a labelled row each, inline validation (`required`, `validate`) shown under the field, `[ Submit ] [ Cancel ]` buttons; see [Sheet](#sheet-every-field-at-once) |
| `select` | native themed list chooser (single/multi; `j`/`k`, `<CR>`, `<Tab>` mark) |
| `prompt` | ask: `answer_type = "confirm"` (yes/no → boolean) or `"text"` |
| `confirm` | button dialog — horizontal buttons, `h`/`l`/arrows move, `<CR>` confirm, `<Esc>` cancel, one key per button picks it directly (`y`/`n`, the first free letter, else its digit; marked in the button), left click confirms a button directly (the button row is `lib.nvim.ui.kit.buttons`, shared with the form's) |
| `menu`    | anchored action list — `{ label, action }` items; picking runs the action. Also renders [`lib.nvim.contextmenu`](../../contextmenu/README.md) tables (`name`/`cmd`, `{ name = "separator" }`, `rtxt`, `icon`, nested `items`) and takes `mouse = true` to anchor at the pointer. A row is a set of **fixed-width columns** measured across the whole level — icon, label, fly-out marker, `rtxt` — so entries line up whichever section they sit in; `icon` is a field, never a prefix on `label`. The marker follows the *label* column rather than the row, so it stays beside the list instead of against the frame, and the hint column keeps the right edge. Named groups (`contextmenu.heading`) are drawn as titled frames (`group_style` = `"box"` \| `"header"` \| `"plain"`; a menu that names nothing keeps the plain divider look). The block cursor is hidden while it is open, one left click picks, and a click or focus change elsewhere dismisses it (`hide_cursor` / `single_click` / `close_on_focus_lost` turn those off). A pick is acknowledged before it is acted on: the row lights up (`KitFlash`) for `flash_ms` (default 100) and the action follows, the way a button shows its press — the delay is the point, since a leaf action closes the menu and a flash painted at that moment would never be seen. A menu dismissed while a row is lit runs nothing (`flash_on_select = false` turns it off). Defaults to the `menu` preset, so the frame is coloured. Drilling into a submenu and walking back swap the list **inside the same window** — no flash, and the menu stays put |
| `progress`| passthrough to [`lib.nvim.progress`](../../progress/README.md) (`:update`/`:finish`/`:cancel`) |
| `compare` | pick two items out of one picker, then view them side by side — see [Compare](#compare-pick-two-view-side-by-side) below |
| `create_on_missing` | a path that does not exist: Create (with its parent directories) / Open in filetree / Cancel — see [Create on missing](#create-on-missing-a-path-that-does-not-exist) below (`kit.create_on_missing(opts)`, not a `popup` type) |

## History stack (back/forward trail, no UI)

`kit.history` is the data structure behind a Back/Forward pair (`<C-o>`/`<C-i>`) in a
view that moves between positions — a browser over modules, a drill-down list. No
window, no keymap: the view keeps its own state table and the history snapshots the
`keys` it names out of it. Generalised from documentation.nvim's browser.

```lua
local history = require("lib.nvim.ui.kit.history") -- or kit.history
local st = { mode = "structure", id = "root", cursor = 1 }
local h = history.new({ state = st, keys = { "mode", "id", "fn", "cursor" }, max = 200 })

h:go(st, { id = "child", fn = "setup" })        -- a move: a new stop
h:go(st, { fn = history.CLEAR })                -- CLEAR removes a field; `fn = nil` would keep it
h:back(st)                                       -- st.fn == "setup" again; false at the start
h:forward(st, vim.v.count1)                      -- counts; a step past either end is refused
h:patch(st, { filter = f })                      -- change state without a stop (needs "filter" in keys to travel along)
```

- The trail holds every position **including the current one**; a new history has one
  entry, so `index()` always addresses a real entry.
- `go(state, changes)` records the position being left (the row the user moved to comes
  back with it), applies `changes`, and makes a stop; a new move drops any forward
  history, like a browser. A move that changes none of the `keys` makes no stop and
  returns `false` (`dedupe = false` turns that off): a Back that visibly does nothing
  reads as a broken history.
- `CLEAR` exists because a patch cannot say "clear" with `nil` — `pairs` never yields a
  nil value, so `{ sha = nil }` is the empty table. `history.apply(t, patch)` is the
  same patch logic on its own.
- `step(state, delta)` / `back` / `forward` write the target entry's `keys` into `state`
  (a key the entry lacks becomes `nil`) and return whether they moved; a `delta`/count
  that is not an integer raises before anything moves. `max` caps the
  trail, oldest first. Also: `push`, `record`, `reset`, `current`, `index`, `len`,
  `can_back`, `can_forward`, `entries`.
- Snapshots are shallow: a table value is shared between state and entries, so treat
  such values as immutable (replace them, do not mutate them).

## Layout engine (Phase 3, partial)

Turn a declarative region spec into aligned `nvim_open_win` geometry for several
coordinated floats — the "three windows that line up perfectly" primitive.

```lua
-- ready-made picker template (prompt / results / preview):
local group = kit.layout.template("picker", { theme = "rounded" })
group.slots.results:set_lines(matches)
group.slots.preview:set_lines(preview_lines)
group.close()               -- closes every slot

-- or compute geometry yourself (pure, no I/O) and mount:
local geo = kit.layout.compute({
  width = 0.8, height = 0.8, gap = 0,
  rows = {
    { name = "prompt", height = 3 },
    { cols = { { name = "results", width = 0.4 }, { name = "preview", width = 0.6 } } },
  },
})
```

### Interactive picker

`kit.picker(opts)` turns the picker template into a working, Telescope-style
picker: an insert-mode prompt drives the results slot.

```lua
local p = kit.picker({
  on_change = function(query)          -- debounced as the user types
    p.set_results(compute_matches(query))
  end,
  on_submit = function(idx, text)      -- <CR> on the highlighted result
    open(text)
  end,
})
-- <C-n>/<C-p> or arrows move the selection; <Esc> closes.
-- p.query() / p.set_results(lines) / p.move(delta) / p.submit() / p.close()
```

#### Item mode (a list of items with marks, highlights and a preview)

With `items` (or `format`) the results slot lists ITEMS instead of plain lines:

```lua
local p = kit.picker({
  items = tasks,
  key = function(t) return t.id end,            -- identity for marks and the cursor (default: the item itself)
  text = function(t) return t.title end,        -- what the prompt's words are matched against (default: item.text)
  format = function(t) return { { t.title, "Title" }, { " " .. t.status, "Comment" } } end,
  preview = function(t, surface) surface:set_lines(read_lines(t.path)) end,   -- follows the cursor item
  selectable = function(t) return not t.heading end,   -- rows that cannot be submitted, marked or rested on (headings)
  keys = { ["<M-d>"] = function(h) finish(h.marked()) end },                 -- lhs -> function(handle), in the prompt
  title = "Tasks", results_width = 0.6,
  on_submit = function(idx, line, item) open(item) end,
  on_close = function() end,
})
-- <Tab> marks and moves down. p.current() / p.marked() / p.set_items(items, { cursor_key?, keep_marks? }) /
-- p.set_title(t) / p.is_closed()
```

The words typed in the prompt filter the list (every word must occur, any case); an empty result stays open.
`set_items` keeps the cursor on its item and the marks of items that are still there.

A caller key may open another window from the prompt (a `kit.viewer` with the current item's
details): that window opens in Normal mode, so `q`/`<Esc>` close it on the first press, and when
the focus comes back to the prompt, Insert mode is back at the column it was left at -- the next
letter goes into the query. That holds for a window that is typed into and closes from Insert
mode as well (a `kit.input`, a nested `kit.picker`): the prompt resumes once the closer has ended
that window's Insert mode, ahead of any key typed after it. A prompt left from Normal mode is
given back in Normal mode.

`kit.picker({ prompt = "plain" })` falls back to a bare
`kit.layout.template("picker")` whose prompt slot you wire yourself.

### Compare (pick two, view side by side)

`kit.compare(opts)` picks two items out of one picker, then shows both full
height, side by side — motivated by images.nvim's "browse, pick two, view
next to each other", but not image-specific: `render(item, surface)` is the
only contract, so a text diff or anything else that can paint into a
`kit.surface` works the same way.

```lua
local handle = kit.compare({
  items = candidates,
  render = function(item, surface)     -- called for the live preview AND
    surface:set_lines(read_lines(item)) -- both COMPARE panes
  end,
  on_compare = function(a, b)          -- fires once, before either COMPARE
    -- both picks known here, before either render() call for COMPARE --
    -- e.g. scale two images relative to each other instead of each to its
    -- own pane
  end,
  on_close = function(a, b) end,       -- b is nil on an aborted pick
})
```

Three states, entered in order: **SEARCH** (prompt + results + a live
preview that follows the selection) → **MARKED** (`mark_key`, default
`<M-c>`, or `<CR>`, freezes the current item; the live preview keeps
following the rest of the search) → **COMPARE** (`<CR>` again: both picks
full-height, side by side; `q`/`<Esc>` on either pane closes the whole
thing). `<CR>` does double duty on purpose — it reads as "confirm whichever
pick this is" rather than needing a second dedicated key.

`kit.chooser` is the low-level native chooser `kit.select` (and `compare`'s
own SEARCH state) delegates to — reach for it directly only when a caller
needs `current_item()`/`current_index()`/`move()` outside of `on_select`,
e.g. extra keymaps that read the highlighted item without submitting or
closing. One active instance at a time, shared with `kit.select`.

### Button-confirm

`kit.confirm(opts)` (or `kit.popup({ type = "prompt", answer_type = "confirm",
layout = "buttons" })`) shows a question with a row of horizontal buttons.

```lua
kit.confirm({ question = "Delete 3 files?", on_answer = function(yes) end })     -- Yes/No -> boolean
kit.confirm({ question = "Pick", choices = { "Keep", "Discard", "Cancel" },
              on_answer = function(choice) end })                               -- custom -> string
```

`h`/`l`/arrows/`<Tab>` move focus (the focused button uses `KitSelection`),
`<CR>` confirms, `<Esc>`/`q` cancels (default → `false`, custom → `nil`).

A long question is wrapped and many or wide buttons are packed into several rows, so the
dialog is never wider than the editor allows and the buttons stay in the window; a label
wider than the window is cut with `…` (the answer is still the full label). A question taller
than the editor is cut to leave the buttons visible.

Options of `kit.confirm` / `kit.ask`:

- `default` -- the button that starts focused (index or label; the first when omitted or unknown).
  With it the order of the buttons is the natural one (action first, cancel last) and `<CR>` still
  lands on the safe answer.
- `choices` as a list of labels, or as a `vim.fn.confirm` string: buttons separated by a newline,
  `&` before the letter that picks the button (`"&Delete\n&Cancel\nRe&name"`). The `&` is not
  drawn, and the answer is the label without it. In a list a `&` is text.
- **Hotkeys.** Every button can be picked with one key, without moving the focus (either case;
  the focus still starts on `default`, and `<CR>` still confirms the focused button). Who gets
  which key is decided in a fixed order, so the same labels always get the same keys:
  1. `y` / `n` go to Yes and No, as in the `more` prompt: the Yes/No default, or the first button
     whose label starts with the word "Yes" / "No" (`"Yes, delete"`, not `"Nope"`).
  2. The `&` letters of a `vim.fn.confirm` string, in button order.
  3. Every other button takes the first letter of its label; when that one is taken, the next free
     letter of the label, left to right. Buttons earlier in the row choose first: `Cancel`, `Close`,
     `Copy` get `c`, `o`, `p`.
  4. The digits 1-9 pick the button at that position (every button, with a letter or without); a
     button labelled with a single digit owns that digit (a `0`..`5` scale after `Skip`). A button
     that still has no key takes the first free digit (1-9, then 0); buttons past the tenth without
     a free letter are reached with `h`/`l` only.

  `h`, `l` and `q` stay navigation and are never a hotkey. The key is marked in the button: its
  letter in the accent colour and underlined (`KitHotkey`; the underline stays on the focused
  button), or, for a button without a free letter (`"?!"`), its digit as a small superscript before
  the `]` (`[ ?!³]`), so the box keeps its size. An `&` letter that is reserved or already taken is
  reported once when the dialog opens, and its button falls back to step 3. Only the button dialog
  has letter keys: a text field (`kit.input`, `kit.form`, `kit.sheet`) keeps every letter for
  typing.
- `<C-c>` cancels like `<Esc>`. So does focus moving elsewhere (a click outside, another plugin
  switching windows); `keep_on_focus_lost = true` keeps the dialog. `kit.ask` keeps it by default:
  a question nobody asked for must not be answered "no" by a window change.
- `kind = "danger" | "warn" | "info"` draws the border and the title in the status colour
  (`KitError`, `KitWarn`, `KitInfo`).
- `legend = true` adds a one-line key legend to the window's winbar.

Every way a dialog ends answers it exactly once: a button, `<Esc>`/`q`, the float
closed from outside (`:q`, `:only`), another dialog replacing it, or
`confirm.close()`. The last three count as a cancel; the answer of an externally
closed float arrives a moment later (scheduled), so an error in `on_answer` is
reported rather than swallowed. `confirm.close()` therefore calls `on_answer`
(`false`/`nil`): do not use it as a silent teardown of a dialog whose answer
handler does something on "no".

**`kit.ask(opts)` — the question that waits its turn and always answers.** `kit.confirm` is
single-instance: opening one closes the open dialog (answering it as cancelled), so a
question raised at a moment the user did not pick (a stream ending minutes after
the command) would drop it with a "no" nobody gave. `kit.ask` waits until no modal kit
dialog is open (a confirm, but also an input, a select or a sheet), then shows its own.
It subscribes to the close once and looks again once a second in case a window went without the close
event (`ASK_RECHECK_MS`); nothing polls faster. The dialog it shows ignores letter and digit hotkeys for half a
second (`ASK_HOTKEY_GRACE_MS`), so keys typed ahead for the editor cannot answer a question nobody saw coming. The wait lasts `max_wait_ms` (default ten
minutes), then `on_answer` gets the cancel value: `false`, or `nil` for a `choices` list,
so "unanswered" is "no" with no second code path. It takes the options of `kit.confirm`
(`choices` included: the answer is the label). If the float cannot open at all it falls
back to `vim.ui.select`. `on_answer` fires at most once, and the optional `abandoned()`
drops a question that is no longer wanted -- when its turn comes, and when its wait runs out (it is then
not answered at all). A question whose dialog cannot be built is answered as cancelled and the error raised. Several waiting questions
are shown in the order they were asked.

```lua
kit.ask({ question = "File the answer?", on_answer = function(yes) end })
```

**`kit.async` — linear code over the callbacks, without blocking.** Start a coroutine with
`kit.async.run(function() ... end)`; inside it `kit.async.confirm / ask / input / form / select`
open the dialog, suspend the coroutine and return the answer when the user gives it, while the editor
keeps running. A dismissed dialog gives what its callback form gives (`false` / `nil`; input and form
return `nil, true`). `kit.async.await(start)` is the building block for anything else. The functions
raise outside a coroutine that `run` started; an error inside it is reported with its traceback.

```lua
kit.async.run(function()
  local name = kit.async.input({ prompt = "Name" })        -- nil when cancelled
  if not name then return end
  if kit.async.confirm({ question = ("Create %s?"):format(name) }) then
    create(name)
  end
end)
```

**Mouse:** a left click on a button focuses *and* confirms it in one action
(needs `:set mouse=a`, as any mouse interaction does). Clicking blank space
inside the dialog is a no-op — it does not cancel, matching the rest of the
kit, where clicking empty space never dismisses a surface. Hit-testing uses
`getmousepos()` against the per-button ranges the focus highlight already
tracks, so the click target is exactly the visible `[ Label ]` box.

The layout, the focus highlight and the hit-test live in
`lib.nvim.ui.kit.buttons` — a small stateless helper (`layout`, `paint`, `hit`,
`wrap`, `row_width`) that the button row under a [`kit.form`](#form-multi-field)
field uses as well, so a click lands on exactly the box that is drawn in both
places.

### Form (multi-field)

`kit.form(opts)` chains `kit.input` prompts field-by-field into one keyed
result table — the "several `vim.fn.input`/`vim.ui.input` calls in a row"
pattern (e.g. sandbox.nvim's Image/Name/Ports/Volumes/Env chain).

```lua
kit.form({
  fields = {
    { name = "image", label = "Image", required = true },  -- <Esc> here aborts the form
    { name = "name", label = "Name" },                       -- <Esc> here skips (keeps default)
    { name = "ports", label = "Ports" },
  },
  on_submit = function(values) end,  -- { image = "...", name = "...", ports = "..." }
  on_cancel = function() end,        -- fires only if a `required` field was <Esc>-ed
})
```

Each field accepts the same options as `kit.input` (`default`, `theme`,
`width`, `relative`, `expand_env`), falling back to `opts.theme`/`opts.width`/
`opts.relative` when omitted.

**Back navigation (`back = true`, opt-in; mirrored from `ui.nvim`).** Off by
default — a form without it is exactly the chain above. With it, `<BS>` on an
**empty** field, `<S-Tab>` or `<C-p>` (or the `[← Back]` button) reopen the
field before with its previous answer as the editable text; a field left
half-typed keeps its text for when the user comes back, so nothing is lost
going back and forth; `<Esc>` keeps its meaning on every field; the first
field has no back; the title reads `Label (2/5)`. A button row sits under the
field — `[← Back]`, `[Skip]` (not on a `required` field) and `[Next ↵]`
(`[Done ↵]` on the last) — a left click presses one, and `<Down>`/`<Tab>` move
the focus onto the row (`h`/`l`/arrows/`<Tab>` move it, `<CR>` presses,
`<Up>`/`k`/`i`/`a` return to the field). A `<BS>` held down stops at the empty
field (a `<BS>` less than 300 ms after the previous one is the key repeating,
not a press); a long answer that scrolls the field sideways keeps the row in
view, and a paste with a newline stays one line. Underneath, `kit.input` takes
`on_back = function(line) end` and `buttons = { { id = "back" | "skip" |
"submit", label = "…" }, … }`. A form that is itself one step of a longer flow
can also pass `on_back = function(values) end`: the first field then has a back
too, which closes the form and hands the answers so far on (neither `on_submit`
nor `on_cancel` fires). The full description is in `ui.nvim`'s
`lua/ui/kit/README.md`.

### Sheet (every field at once)

`kit.sheet(opts)` (or `kit.popup({ type = "sheet", ... })`) is the other shape
of a form: not one prompt per field in a row, but ONE float that shows every
field at once, a row each with its label. Use it when the answers belong
together and the person should see — and be able to fix — all of them before
committing; `kit.form` stays the right tool for a short chain of questions.
Same callbacks (`on_submit(values)` / `on_cancel()`), same keyed result table,
so `kit.async.form`-style code works over it too.

```lua
kit.sheet({
  title = "New case",
  fields = {
    { name = "number", label = "Case number", required = true, live = true,
      validate = function(v)
        if v:match("^%d+$") then return true end
        return false, "digits only"            -- the message shows under the field
      end },
    { name = "area", label = "Area", kind = "select", choices = { "EMEA", "APAC" } },
    { name = "title", label = "Title" },
    { name = "token", label = "Token", secret = true },
  },
  submit_label = "Create", cancel_label = "Abort",     -- default "Submit" / "Cancel"
  on_submit = function(values) end,  -- { number = "...", area = "EMEA", title = "...", token = "..." }
  on_cancel = function() end,
})
```

```text
╭────────────────────────── New case ──────────────────────────╮
│Case number* 12x                                              │
│             ✗ digits only                                    │
│Area         EMEA   ◂ ▸                                       │
│Title        Printer on fire                                  │
│Token        ********                                         │
│                                                              │
│                   [ Create ]  [ Abort ]                      │
╰──────────────────────────────────────────────────────────────╯
```

**Fields.** `{ name, label?, kind?, default?, required?, validate?, live?,
depends_on?, expand_env?, completion?, secret?, mask?, choices? }`:

- `kind = "text"` (default) is an editable line like [`kit.input`](#components):
  `default`, `expand_env`, `completion` and `secret` behave the same. The
  field's row opens in Insert mode.
- `kind = "select"` with `choices` (a list of strings) is a fixed choice shown
  with `◂ ▸`: `h`/`l` (or the arrows) cycle it, `<CR>`/`<Space>` open
  `kit.select` over the choices and a pick moves on to the next field.
  `default` names the choice shown first.

**Validation, next to the field.**

- `required = true` rejects a blank value ("required", or `opts.required_message`).
- `validate(value) -> ok, err` rejects when `ok` is falsy, showing `err`
  ("invalid" without one) as red text (`KitError`) in a line under the field. It
  is not called for an empty optional field, so it never has to handle `""`;
  `value` is what `on_submit` will get (after `expand_env`); a validator that
  raises is a rejection with the error as its message.
- A field is checked when the user **leaves** it and on **submit**. A field that
  shows an error is checked again on every edit, so the message goes away the
  moment the value is right; `live = true` checks a field on every edit from the
  start. `depends_on = "other"` (or a list of names) is for a validity that
  depends on another field — a number that has to be free in the chosen area: the
  field is checked again whenever one of those changes (when it has a value or a
  message showing; a blank, untouched one stays quiet).
- Submit is blocked while any field fails, and the focus jumps to the first
  invalid one. The window is resized to what is shown (a row per message), so
  the sheet grows and shrinks, staying centered.

**Keys** (the same in Insert mode on a text row and in Normal mode elsewhere):

| Key | Does |
| --- | --- |
| `<Tab>` / `<S-Tab>` | next / previous field, then the two buttons, wrapping |
| `<Down>` / `<Up>` (`j` / `k` in Normal mode) | the same without wrapping |
| `<CR>` | next field; on the last field it presses the Submit button; on a select it opens the chooser; on a button it presses it |
| `<Esc>` | cancel the whole sheet, from anywhere |
| left click | focus the field under the pointer (cursor at the click), or press the button (needs `:set mouse=a`) |
| `h` / `l`, `<Space>` | on the button row: move along / press; on a select: cycle / open the chooser |

On a field with `completion`, `<Tab>` is the completion key (as in `kit.input`)
and `<S-Tab>` still goes back unless a popup is open; move on with `<Down>`/`<CR>`.

**Drawn how.** The buffer holds only the values, one per line (then a blank line
and the buttons); the labels are the window's `'statuscolumn'`. So an edit can
never touch a label, the cursor cannot land on one, and a long value wraps under
the value column. The button row is `lib.nvim.ui.kit.buttons`, shared with `kit.confirm`
and the form's. A paste with a newline in it is joined into its row with a
space. `KitAccent` marks the focused field's label, `KitMuted` the others,
`KitError` the messages and the `*` of a required field.

The returned surface has five extra methods, for driving a sheet from code and
from specs: `s:submit()`, `s:cancel()`, `s:focus_field(name | index)`,
`s:validate()` (check every field now so the messages show, without submitting;
returns whether all passed — for a sheet opened with values that may already be
wrong) and `s:state()` (`{ focus = <field name | "submit" | "cancel">, values, errors }`).
Opening options: `focus` (field name or position to start on), `width`
(default 60), `relative` (default `"editor"`), `theme`.

### Live input (debounced on_change)

`kit.live_input(opts)` is `kit.input` plus a debounced `on_change(query)` —
for filter/search boxes that need to refresh a results list or preview on
every keystroke, not just on submit (`kit.picker`'s prompt slot uses the same
debounce timer internally).

```lua
kit.live_input({
  prompt = "Filter",
  debounce = 80,  -- ms after the last keystroke before on_change fires (default 80)
  on_change = function(query) end,   -- fired repeatedly as the user types
  on_submit = function(query) end,   -- <CR>
  on_cancel = function() end,        -- <Esc>
  -- row/col (relative="editor" only) override the default centered
  -- placement, e.g. to anchor the bar to the bottom edge of a host window.
})
```

### Secret input (masked entry)

`kit.input({ secret = true, ... })` masks the input as you type — a
`vim.fn.inputsecret` replacement. Each typed character is concealed behind
`opts.mask` (a string; default `"*"`, which is also what a value that is not a string
and a string nvim cannot show -- a newline, NUL, tab, escape, an invisible character --
becomes) via `conceal`, re-derived from the buffer's actual
content on every edit (paste, backspace, mid-line insert all just work). The
underlying buffer still holds the real text — `on_submit` reads it straight
off the buffer — but it's never echoed on screen, undo is disabled on that
buffer (`undolevels = -1`), and (like every kit scratch buffer) it was never
written to disk in the first place (`swapfile = false`) and is wiped the
moment the float closes. The Insert run that typed it is also what the `.`
register (`:registers`, `<C-r>.`) and the redo buffer keep -- a `.` in any buffer
would type the password there -- so when the prompt closes (submitted, cancelled or
closed from outside; the same goes for a `kit.sheet` with a `secret` field) they are
overwritten with an empty run. A macro being recorded (`q`) still holds the keys it
saw, as it does for `vim.fn.inputsecret`.

The mask only hides the rendering; two things read the buffer without looking at it,
and both are shut for a secret prompt (and for a `kit.sheet` with a `secret` field,
as a whole: its rows are one buffer):

- **Insert-mode completion works on the words of the buffer, which is the secret.**
  `<C-n>`/`<C-p>` listed them in a popup in clear text and inserted the pick unmasked;
  `<C-x><C-n>` and `<C-x><C-p>` did the same, and with `'autocomplete'`
  (Neovim 0.12) the popup came up by itself as one types. In a secret prompt `<C-n>`,
  `<C-p>` and `<C-x>` do nothing (except to move in the popup of the prompt's own
  `completion = ...`, whose `<Tab>` opens it) and `'autocomplete'` is off for the
  buffer. A candidate that is put in from that popup is masked at once (the re-mask
  listens for `TextChangedP` too). A completion *plugin* with its own sources is out of
  reach of this; exclude the prompt's buffer in that plugin's own configuration.
- **A keystroke HUD shows what is typed.** The buffer carries `vim.b.ui_kit_secret =
  true`, which `ui.screenkey` reads: no key typed into a marked buffer reaches its HUD,
  the key that closes the prompt included. (A sheet is marked as soon as one of its
  fields is secret: there is no telling which row a key was meant for, so none of its
  keys are shown.) The rule is the buffer's, not the HUD's: a recorder of your own asks
  `require("lib.nvim.ui.kit.surface").is_secret()` the same way.

```lua
kit.input({
  prompt = "Registry password",
  secret = true,
  on_submit = function(password) end,
})
```

### File-path completion

`kit.input({ completion = "file", ... })` — a `vim.fn.input(..., completion =
"file")` replacement. `<Tab>` completes the last whitespace-delimited
fragment before the cursor via `vim.fn.getcompletion()` and opens Neovim's
real completion popup (`vim.fn.complete()`), so `<C-n>`/`<C-p>` cycle it same
as anywhere else. While the popup is open, `<Tab>`/`<S-Tab>` advance/retreat
the selection instead of re-triggering, and `<CR>` accepts the highlighted
candidate rather than submitting the whole prompt (a second `<CR>` — popup
now closed — submits). `completion` accepts any type name `getcompletion()`
does (`"dir"`, `"shellcmd"`, `"buffer"`, ...), not just `"file"`. A fragment
with a backtick in it is never completed: `getcompletion()` runs the span
between backticks through the shell, and the fragment may be pasted text.

```lua
kit.input({
  prompt = "Path to executable",
  completion = "file",
  on_submit = function(path) end,
})
```

### Create on missing (a path that does not exist)

`kit.create_on_missing({ path = p, on_done = fn })` is the question a plugin asks when the user
wants to open a file that is not there (gopath.nvim's `gf`, a path pasted into images.nvim). A
`kit.confirm` with three buttons:

| Button | Does |
| ------ | ---- |
| `Create` | [`lib.nvim.fs.create_entry`](../../fs/create_entry/README.md) makes the file — or, for a path ending in `/` or `\`, the directory — with every missing parent directory, then opens the file (`:edit`) |
| `Open in filetree` | filetree.nvim shows the deepest directory of the path that does exist (`adapter().open_reveal` with that directory plus a trailing `/`, so a backend that reveals a file shows the directory itself, not its parent); nothing is created |
| `Cancel` | nothing (also `<Esc>`/`q`, or the dialog closed any other way) |

```lua
local kit = require("lib.nvim.ui.kit")
kit.create_on_missing({
  path = "docs/notes/today.md",      -- relative to the cwd, or absolute
  on_done = function(res)            -- exactly once, however the dialog ends
    -- res.action: "created" | "exists" | "filetree" | "cancelled" | "error"
    -- res.path, res.kind ("file"/"directory"), res.err
  end,
})
```

- **filetree.nvim is optional.** The button is offered only when filetree.nvim is loaded *and*
  set up and its adapter can reveal a path; the kit reads `package.loaded["filetree"]` and never
  `require`s it, so asking does not pull a lazy-loaded tree in. `filetree = false` hides the
  button, `filetree = function(dir) ... return true end` offers it with a reveal of your own
  (return `false` for a failure). `require("lib.nvim.ui.kit.create_on_missing").filetree_available()`
  says whether the default would show it.
- `open = false` creates without opening; `open = function(path, kind) end` replaces `:edit`
  (a directory is opened only by such a function).
- A path that **exists** asks nothing: it is opened and reported as `"exists"`.
- A refused name (`create_entry` rejects `\/:*?"<>|` in a segment) or a failed reveal is reported
  with `notify` and as `"error"`; a refused name creates nothing (it is checked before any
  directory is made).
- The question names the missing parent directories, so the user sees that `Create` makes more
  than one entry. The button labels are `M.CREATE`, `M.FILETREE`, `M.CANCEL` on the module — a
  [dialog hook](#dialog-hook-answer-dialogs-in-tests) answers with one of them (or the index).

### Dialog hook (answer dialogs in tests)

`kit.set_dialog_hook(fn)` offers every modal dialog (`confirm`, `ask`, `input`, `select`, `form`, `sheet`) to
`fn(kind, opts)` before it opens. `return true, value` answers it: nothing opens, the caller's callback gets
`value` on the next loop turn (as a real answer does) and the call returns an already closed stand-in surface.
`return false` passes the dialog on. `kit.set_dialog_hook(nil)` removes the hook; without one it costs a table
access. An error the hook raises is raised in the caller.

`value` is what the user would have said: `confirm`/`ask` an index or a label of `choices` (a plain question:
`true`/`false`, or 1 yes / 2 no), `input` the text, `select` an index or an item (a list of them with `multi`),
`form`/`sheet` the keyed table of values; `nil` dismisses. testing.nvim's prompt guard sets this hook for the
case that is open (`h:answer_prompts{ confirm = 2 }`).
