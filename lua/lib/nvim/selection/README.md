# `lib.nvim.selection`

Reselect a Visual-mode line/char range after a mapping mutates the buffer.

Neovim drops the Visual selection the instant a mapped function returns,
which forces every "act on the selection, then keep it selected" mapping to
hand-roll the same feedkeys dance. `keep_lines`/`keep_chars` do that dance
once: capture the current selection's extent, run the caller's mutation,
then restore an equivalent selection over the (rewritten) same rows or same
byte-column span.

Two shapes are supported, matching the two patterns real callers need:

- **lines** — a linewise (`V`) row range. For actions that rewrite whole
  lines in place but never add or remove any (bullet/checkbox toggles,
  sort/reverse/rotate, indent, ...).
- **chars** — a same-line charwise (`v`) byte-column range. For actions
  that rewrite part of a single line without changing its total length
  (swap-with-neighbor, inline transforms, ...).
- **chars_multiline** — a charwise (`v`) selection spanning more than one
  line. Complements `chars`, which only covers the same-line case.

`gv` is deliberately not used: the `` '< ``/`` '> `` marks it reads are only
set once Visual mode actually *ends*, so calling `gv` from inside a mapping
that is still conceptually "in" Visual mode reselects the *previous*
selection, not the current one. Reselection instead uses an explicit
`<Esc>` followed by pure normal-mode motions — never a `:` command:
entering Visual mode auto-prefixes a typed `:` with `'<,'>`, which would
corrupt any `:call ...` sequence queued mid-selection.

The reselect keys are fed with `nvim_feedkeys(..., "ni")`: no remapping, and
in front of whatever is already queued. In a macro, a `:normal` or a paste the
keys after the mapping are already in the typeahead; they run after the
reselect and act on the reselected range, as they would if the mapping had
been typed by hand.

## Usage

```lua
local selection = require("lib.nvim.selection")

-- A visual-mode ("x") keymap that toggles something on every selected line
-- and should leave the same lines selected afterwards:
vim.keymap.set("x", "<A-->", function()
  local bufnr = vim.api.nvim_get_current_buf()
  selection.keep_lines(function(srow, erow)
    my_toggle_range(bufnr, srow, erow)
  end)
end)
```

```lua
-- A visual-mode keymap that swaps a same-line selection with its right
-- neighbor char, falling back to `gv` when the selection isn't same-line
-- charwise (e.g. linewise or spans multiple lines):
vim.keymap.set("x", "<leader><Right>", function()
  local _, applicable = selection.keep_chars(function(row, scol, ecol)
    my_swap_right(row, scol, ecol)
  end)
  if not applicable then
    vim.api.nvim_feedkeys(vim.keycode("gv"), "ni", false)
  end
end)
```

## Functions

- `lines()` -> `srow, erow` — 0-based inclusive row range of the active
  Visual selection (any submode); reads `line("v")`/`line(".")`, which stay
  live during Visual mode.
- `reselect_lines(srow, erow)` — restore a linewise (`V`) selection over
  `[srow, erow]` (0-based inclusive), once the current mapping returns.
- `keep_lines(fn)` — capture the current row range, run
  `fn(srow, erow)`, then reselect the same rows linewise. Returns `fn`'s
  return value.
- `chars()` -> `row, scol, ecol` — 0-based row and inclusive byte-column
  range of the active selection, if (and only if) it is charwise and
  confined to one line; otherwise `nil`.
- `reselect_chars(row, scol, ecol)` — restore a charwise (`v`) selection
  spanning byte columns `[scol, ecol]` on `row`. Byte columns are converted
  to character offsets first, so multibyte text still lands on the right
  boundary.
- `keep_chars(fn)` -> `ret, applicable` — capture the current same-line
  charwise selection, run `fn(row, scol, ecol)`, then reselect it.
  `applicable` is `false` (and `fn` is not called) when the current
  selection is not a same-line charwise selection — fall back to your own
  handling (e.g. `gv`) in that case.
- `chars_multiline()` -> `srow, scol, erow, ecol` — 0-based row and
  inclusive byte-column bounds of the active selection, if (and only if) it
  is charwise and spans *more than one* line; otherwise `nil`. Complements
  `chars()`. `srow`/`scol` is always the earlier point in the buffer,
  regardless of which end the cursor is on.
- `reselect_chars_multiline(srow, scol, erow, ecol)` — restore a charwise
  (`v`) selection from byte column `scol` on `srow` to byte column `ecol`
  on `erow` (0-based inclusive), covering every full line in between.
- `keep_chars_multiline(fn)` -> `ret, applicable` — capture the current
  multi-line charwise selection, run `fn(srow, scol, erow, ecol)`, then
  reselect it. Only correct when `fn` doesn't shift where the first/last
  line's selected span starts or ends — a mutation that changes that width
  should reselect explicit new bounds itself via
  `reselect_chars_multiline` instead.

See `lua/lib/nvim/selection/@types/init.lua` for exact signatures.
