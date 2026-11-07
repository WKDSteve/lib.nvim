---@module 'lib.nvim.selection'
--- Reselect a Visual-mode line/char range after a mapping mutates the buffer.
---
--- Neovim drops the Visual selection the instant a mapped function returns,
--- which forces every "act on the selection, then keep it selected" mapping
--- to hand-roll the same feedkeys dance. `keep_lines`/`keep_chars` do that
--- dance once: capture the current selection's extent, run the caller's
--- mutation, then restore an equivalent selection over the (rewritten) same
--- rows or same byte-column span.
---
--- Two shapes are supported, matching the two patterns real callers need:
---   - lines: a linewise (`V`) row range — list/transform-style actions that
---     rewrite whole lines in place but never add or remove any.
---   - chars: a same-line charwise (`v`) byte-column range — actions that
---     rewrite part of a single line without changing its total length.
---
--- `chars_multiline` complements `chars` for the one shape it deliberately
--- excludes: a charwise (`v`) selection spanning more than one line. It is a
--- separate function, not a 4-value fallthrough on `chars` itself, so that
--- function's existing same-line, 3-value contract never changes shape under
--- callers that already rely on it.
---
--- `gv` is deliberately not used: the `'<`/`'>` marks it reads are only set
--- once Visual mode actually *ends*, so calling `gv` from inside a mapping
--- that is still conceptually "in" Visual mode reselects the *previous*
--- selection, not the current one. Reselection instead uses an explicit
--- `<Esc>` followed by pure normal-mode motions — never a `:` command:
--- entering Visual mode auto-prefixes a typed `:` with `'<,'>`, which would
--- corrupt any `:call ...` sequence queued mid-selection.

require("lib.nvim.selection.@types")

local M = {}

--- Feed a key sequence without remapping, to run once the current mapping
--- function returns ("n" = no remap, not executed synchronously), in front of
--- whatever is already queued ("i"): the keys after the mapping in a macro,
--- `:normal` or a paste must see the reselected range, as they would if the
--- mapping had been typed by hand.
---@internal
---@param keys string
---@return nil
local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "ni", false)
end

--- 0-based inclusive row range of the current (still-active) Visual
--- selection. Reads `line("v")`/`line(".")`, which stay live during Visual
--- mode — unlike the `'<`/`'>` marks `gv` relies on.
---@return integer srow, integer erow
function M.lines()
  local a, b = vim.fn.line("v") - 1, vim.fn.line(".") - 1
  if a > b then
    a, b = b, a
  end
  return a, b
end

--- Restore a linewise (`V`) selection over `[srow, erow]` (0-based
--- inclusive). Queued to run once the current mapping returns.
---@param srow integer
---@param erow integer
---@return nil
function M.reselect_lines(srow, erow)
  feed(string.format("<Esc>%dGV%dG", srow + 1, erow + 1))
end

--- Capture the current selection's row range, run `fn(srow, erow)`, then
--- reselect the same rows linewise. Use for actions that rewrite line
--- *contents* in place without changing the line count (bullet/checkbox
--- toggles, sort/reverse/rotate, indent, ...).
---@generic T
---@param fn fun(srow: integer, erow: integer): T
---@return T
function M.keep_lines(fn)
  local srow, erow = M.lines()
  local ret = fn(srow, erow)
  M.reselect_lines(srow, erow)
  return ret
end

--- 0-based row and inclusive byte-column range of the current Visual
--- selection, if (and only if) it is charwise and confined to one line.
---@return integer|nil row, integer|nil scol, integer|nil ecol # nil for a linewise/blockwise or multi-line selection.
function M.chars()
  if vim.fn.mode() ~= "v" then
    return nil
  end
  local row_v, col_v = vim.fn.line("v"), vim.fn.col("v")
  local row_d, col_d = vim.fn.line("."), vim.fn.col(".")
  if row_v ~= row_d then
    return nil
  end
  local scol, ecol = col_v - 1, col_d - 1
  if scol > ecol then
    scol, ecol = ecol, scol
  end
  return row_d - 1, scol, ecol
end

--- Restore a charwise (`v`) selection spanning byte columns `[scol, ecol]`
--- (0-based inclusive) on `row` (0-based). Byte columns are converted to
--- character offsets first, so multibyte text still lands on the right
--- boundary (`l` motions move per character, not per byte).
---@param row integer
---@param scol integer
---@param ecol integer
---@return nil
function M.reselect_chars(row, scol, ecol)
  local line = vim.api.nvim_buf_get_lines(0, row, row + 1, false)[1] or ""
  local sc = math.max(vim.fn.charidx(line, scol), 0)
  local ec = math.max(vim.fn.charidx(line, ecol), sc)

  local keys = string.format("<Esc>%dG0", row + 1)
  if sc > 0 then
    keys = keys .. sc .. "l"
  end
  keys = keys .. "v"
  if ec > sc then
    keys = keys .. (ec - sc) .. "l"
  end
  feed(keys)
end

--- Capture the current same-line charwise selection, run
--- `fn(row, scol, ecol)`, then reselect the same byte-column span. If the
--- current selection is not a same-line charwise selection (`M.chars()`
--- returns nil), `fn` is not called at all — callers should fall back to
--- their own handling (e.g. feeding `gv`) when `applicable` is false.
---@generic T
---@param fn fun(row: integer, scol: integer, ecol: integer): T
---@return T|nil ret, boolean applicable
function M.keep_chars(fn)
  local row, scol, ecol = M.chars()
  -- All three or none -- but the type system only learns that from three
  -- checks, and `fn`/`reselect_chars` take plain integers.
  if not row or not scol or not ecol then
    return nil, false
  end
  local ret = fn(row, scol, ecol)
  M.reselect_chars(row, scol, ecol)
  return ret, true
end

--- 0-based row and inclusive byte-column bounds of the current Visual
--- selection, if (and only if) it is charwise and spans *more than one*
--- line — the complement of `M.chars()`, which only covers the same-line
--- case. `srow`/`scol` is always the earlier point in the buffer and
--- `erow`/`ecol` the later one, regardless of which end the cursor is on
--- (Visual selections can be drawn in either direction).
---@return integer|nil srow, integer|nil scol, integer|nil erow, integer|nil ecol # nil for a linewise/blockwise or same-line selection.
function M.chars_multiline()
  if vim.fn.mode() ~= "v" then
    return nil
  end
  local row_v, col_v = vim.fn.line("v"), vim.fn.col("v")
  local row_d, col_d = vim.fn.line("."), vim.fn.col(".")
  if row_v == row_d then
    return nil
  end
  if row_v < row_d then
    return row_v - 1, col_v - 1, row_d - 1, col_d - 1
  end
  return row_d - 1, col_d - 1, row_v - 1, col_v - 1
end

--- Restore a charwise (`v`) selection running from byte column `scol` on
--- `srow` (0-based) to byte column `ecol` on `erow` (0-based, inclusive),
--- covering every full line in between. Byte columns are converted to
--- character offsets first, same as `M.reselect_chars`.
---@param srow integer
---@param scol integer
---@param erow integer
---@param ecol integer
---@return nil
function M.reselect_chars_multiline(srow, scol, erow, ecol)
  local first = vim.api.nvim_buf_get_lines(0, srow, srow + 1, false)[1] or ""
  local last = vim.api.nvim_buf_get_lines(0, erow, erow + 1, false)[1] or ""
  local sc = math.max(vim.fn.charidx(first, scol), 0)
  local ec = math.max(vim.fn.charidx(last, ecol), 0)

  local keys = string.format("<Esc>%dG0", srow + 1)
  if sc > 0 then
    keys = keys .. sc .. "l"
  end
  keys = keys .. "v" .. string.format("%dG0", erow + 1)
  if ec > 0 then
    keys = keys .. ec .. "l"
  end
  feed(keys)
end

--- Capture the current multi-line charwise selection, run
--- `fn(srow, scol, erow, ecol)`, then reselect the same bounds. If the
--- current selection is not multi-line charwise (`M.chars_multiline()`
--- returns nil), `fn` is not called at all — callers should fall back to
--- their own handling (e.g. feeding `gv`) when `applicable` is false.
---
--- Only correct when `fn` rewrites the selected text in place without
--- shifting where it starts/ends — same caveat as `M.keep_chars`. A
--- mutation that changes the byte width of the first or last line (e.g.
--- `9.` -> `10.`) needs to reselect explicit new bounds itself via
--- `M.reselect_chars_multiline` instead of this wrapper.
---@generic T
---@param fn fun(srow: integer, scol: integer, erow: integer, ecol: integer): T
---@return T|nil ret, boolean applicable
function M.keep_chars_multiline(fn)
  local srow, scol, erow, ecol = M.chars_multiline()
  -- Same all-or-nothing contract as in `keep_chars`.
  if not srow or not scol or not erow or not ecol then
    return nil, false
  end
  local ret = fn(srow, scol, erow, ecol)
  M.reselect_chars_multiline(srow, scol, erow, ecol)
  return ret, true
end

---@type Lib.Selection
return M
