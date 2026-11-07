---@module 'lib.nvim.ui.kit.chooser'
--- Native themed list chooser. Built on the kit surface; replaces the Phase-2
--- delegation to lib.nvim.ui.hover_select and is a superset of
--- `Lib.HoverSelect.Options`, so hover_select can shim over it with no feature
--- gaps.
---
--- Navigation matches the original hover_select: j/k/arrows move (wrap-around),
--- <CR> selects, <Esc>/q close, h/l (and other horizontal motions) blocked;
--- in multi-select, <Tab>/<S-Tab> toggle. Selection uses the theme's
--- `KitSelection` (current line) and `KitAccent` (marked lines) groups.
---
--- Items are plain strings (one buffer line each) by default, or "rich"
--- tables — `{ lines = {...}, highlights? = {...}, anchor? = 0 }` — for a
--- multi-line entry with per-column highlight groups (see
--- rich items). Navigation moves by logical item,
--- not raw buffer line, so this is transparent to plain-string callers
--- (every item is 1 line, anchor 0 — identical to the old behavior).
---
--- A rich item may set `selectable = false` (separators, headings): the
--- cursor steps over it, <CR> on it is inert, and it can't be marked in
--- multi-select. Plain-string items are always selectable.
---
--- Five presentation options are off by default because they change how the
--- list behaves, not just how it looks, and the chooser is shared by
--- `select`/`picker`/`compare` (see `kit.menu`, which turns all five on):
---
--- - `hide_cursor` — blank the terminal cursor while the list is open, so the
---   highlighted row alone says where you are. `'guicursor'` is global, so it
---   is saved and restored when the list closes for any reason.
--- - `single_click` — one left click picks the row under the pointer, and a
---   click outside the list dismisses it. Without it only `<2-LeftMouse>`
---   selects and a stray click leaves the list open behind the cursor.
--- - `close_on_focus_lost` — dismiss the list when focus moves elsewhere.
---   Wrong for the picker, whose prompt window holds focus by design.
--- - `flash_on_select` — light the picked row for `flash_ms` before the
---   selection is delivered, the way a button acknowledges a press. It has to
---   delay the callback, not run alongside it: a leaf action closes the list,
---   so a flash painted at the same moment is never on screen long enough to
---   see. Off for `select`/`picker`, where the caller may be driving submits
---   programmatically and a deferred callback would change the contract.
--- - `hover` — follow the mouse without a click: whatever row the pointer is
---   over gets the theme's `KitHover` highlight (an extmark of its own, not
---   left to `CursorLine` alone -- see `paint_hover`) and becomes the
---   selection, via `'mousemoveevent'` and the `<MouseMove>` pseudo-key (a
---   silent no-op if that option cannot be set, older than this plugin's own
---   0.10 floor). A terminal grid has no per-pixel blending for text
---   highlights, so this is an instant, unambiguous "this row is hot", not a
---   simulated fade -- the honest equivalent of a button's hover state.

local surface = require("lib.nvim.ui.kit.surface")
local map = require("lib.nvim.bindings.keymap")
local notify = require("lib.nvim.notify").create("[lib.nvim.ui.kit.chooser]")
local autocmd = require("lib.nvim.bindings.autocmd")
-- Soft: `printable_title` arrived with lib.nvim 863952e. With an older lib.nvim the title is
-- drawn as given, rather than `require("lib.nvim.ui.kit")` failing outright. Only a module that is simply
-- missing falls back silently; any other load error (a syntax or runtime error inside it) warns
-- once, so titles do not quietly go back to being drawn raw.
local printable_title
do
  local TITLE_MODULE = "lib.nvim.window.printable_title"
  local ok_title, loaded = pcall(require, TITLE_MODULE)
  if ok_title and type(loaded) == "function" then
    printable_title = loaded
  else
    if
      not ok_title
      and not tostring(loaded):find("module '" .. TITLE_MODULE .. "' not found", 1, true)
    then
      notify.warn(
        "could not load " .. TITLE_MODULE .. ", titles are drawn as given: " .. tostring(loaded)
      )
    end
    printable_title = function(title)
      return title
    end
  end
end

local api = vim.api
local theme = require("lib.nvim.ui.kit.theme")

local M = {}

--- Horizontal motions blocked so the cursor stays on whole rows.
local HORIZONTAL = { "h", "l", "<Left>", "<Right>", "0", "^", "$", "w", "e", "b", "W", "E", "B" }

--- Milliseconds the picked row stays lit before the selection is delivered.
--- Long enough to register as feedback, short enough not to read as lag --
--- the same ~100ms window UI toolkits give a button's pressed state.
local FLASH_MS = 100

--- Highlight the cursor is pointed at while `hide_cursor` is on. `blend = 100`
--- makes it fully transparent; `reverse` keeps it from falling back to a solid
--- block on a UI that ignores blending.
local CURSOR_HL = "KitHiddenCursor"

--- Single active chooser (mirrors hover_select's single-instance model).
local state = {
  surf = nil,
  items = {}, -- raw items as passed in opts.items (strings and/or rich tables)
  entries = {}, -- normalized: { value, lines, highlights, start_row, end_row, anchor_row } (0-based rows)
  on_select = nil,
  multi = false,
  selections = {}, -- keyed by 1-based item index
  ns = api.nvim_create_namespace("lib_kit_chooser"), -- selection marks
  content_ns = api.nvim_create_namespace("lib_kit_chooser_content"), -- per-item custom highlights
  flash_ns = api.nvim_create_namespace("lib_kit_chooser_flash"), -- the pick acknowledgement
  hover_ns = api.nvim_create_namespace("lib_kit_chooser_hover"), -- the row under the pointer
  hover_row = nil, -- 1-based logical item index currently painted, or nil
  saved_guicursor = nil, -- non-nil while `hide_cursor` is in effect
  saved_mousemoveevent = nil, -- non-nil while `hover` is in effect
  -- true while the open chooser is centered on the editor (relative =
  -- "editor" with no explicit row/col) -- see `relayout`.
  centered = false,
  flash_on_select = false,
  flash_ms = 0,
  flashing = false, -- a pick is lit and its delivery is pending
  -- Bumped by every close. A flash defers its delivery, so between the two
  -- the list can be dismissed (<Esc>, a click elsewhere, focus lost); the
  -- pending callback compares this and stays silent when it has gone stale.
  -- Cancelling a timer would not cover it: `close` is reachable from paths
  -- that never see the pending flash at all.
  generation = 0,
}

--- Whether a chooser is currently open.
---@return boolean
function M.is_open()
  return state.surf ~= nil and state.surf:is_valid()
end

---@internal
--- Blank the terminal cursor for the duration of the list. `'guicursor'` is a
--- global option, so the previous value is kept and restored -- leaking an
--- invisible cursor into the rest of the session would be worse than never
--- hiding it.
local function hide_cursor()
  if state.saved_guicursor ~= nil then
    return
  end
  state.saved_guicursor = vim.o.guicursor
  pcall(api.nvim_set_hl, 0, CURSOR_HL, { reverse = true, blend = 100 })
  pcall(function()
    vim.opt.guicursor:append("a:" .. CURSOR_HL .. "/lCursor")
  end)
end

---@internal
--- Restore the cursor saved by `hide_cursor` (idempotent, and a no-op when it
--- was never hidden).
local function restore_cursor()
  if state.saved_guicursor == nil then
    return
  end
  local saved = state.saved_guicursor
  state.saved_guicursor = nil
  pcall(function()
    vim.o.guicursor = saved
  end)
end

--- Normalize one raw item (string or rich table) into an entry, without row
--- offsets yet (those are assigned in a second pass once every item's line
--- count is known).
---@internal
---@param item any
---@return table entry
local function normalize_item(item)
  if type(item) == "table" and type(item.lines) == "table" then
    return {
      value = item,
      lines = item.lines,
      highlights = item.highlights,
      anchor_row = item.anchor or 0,
      selectable = item.selectable ~= false,
      hover_start_col = item.hover_start_col,
      hover_end_col = item.hover_end_col,
    }
  end
  return {
    value = item,
    lines = { tostring(item) },
    highlights = nil,
    anchor_row = 0,
    selectable = true,
  }
end

--- First selectable entry index at or after `from`, searching in `dir`
--- (+1/-1) and wrapping around. Returns nil when no entry is selectable at
--- all -- a list built entirely from decoration, which the caller must not
--- turn into an endless scan.
---@internal
---@param from integer
---@param dir integer
---@return integer|nil
local function next_selectable(from, dir)
  local count = #state.entries
  if count == 0 then
    return nil
  end
  local idx = from
  for _ = 1, count do
    if idx < 1 then
      idx = count
    elseif idx > count then
      idx = 1
    end
    if state.entries[idx].selectable then
      return idx
    end
    idx = idx + dir
  end
  return nil
end

--- Build `state.entries` (with row offsets) and the flattened buffer lines
--- from `items`.
---@internal
---@param items any[]
---@return table[] entries, string[] flat_lines
local function build_entries(items)
  local entries = {}
  local flat = {}
  local row = 0 -- 0-based, next free buffer row
  for i, item in ipairs(items) do
    local e = normalize_item(item)
    e.start_row = row
    for _, l in ipairs(e.lines) do
      flat[#flat + 1] = l
    end
    row = row + #e.lines
    e.end_row = row - 1
    entries[i] = e
  end
  return entries, flat
end

--- Resolve the logical (1-based) item index containing 0-based buffer `row`.
---@internal
---@param row0 integer
---@return integer|nil
local function item_at_row(row0)
  for i, e in ipairs(state.entries) do
    if row0 >= e.start_row and row0 <= e.end_row then
      return i
    end
  end
  return nil
end

---@internal
--- Paint `KitHover` across every row of entry `idx` (its own extmark
--- namespace, so it composes independently of the selection mark, the flash
--- acknowledgement, and each entry's own content highlights). Painted
--- explicitly rather than left to `CursorLine`/`KitSelection` alone: a
--- window-option-driven highlight depends on that window actually being
--- the one Nvim thinks has focus and on a timely redraw, both of which a
--- given terminal/GUI frontend's mouse-motion handling can get wrong in
--- ways an extmark -- a direct buffer decoration -- does not.
---@param idx integer?
local function paint_hover(idx)
  local buf = state.surf and state.surf.bufnr
  if not buf or not api.nvim_buf_is_valid(buf) then
    return
  end
  api.nvim_buf_clear_namespace(buf, state.hover_ns, 0, -1)
  local e = idx and state.entries[idx]
  if not e then
    state.hover_row = nil
    return
  end
  for row = e.start_row, e.end_row do
    if e.hover_end_col then
      -- Span exactly the row's actual field (icon/label/marker/rtxt), not
      -- the border character or the blank padding out past it -- `kit.menu`'s
      -- frame_row supplies both bounds; anything that doesn't (a plain
      -- string, another RichItem producer) falls through to hl_eol below.
      pcall(api.nvim_buf_set_extmark, buf, state.hover_ns, row, e.hover_start_col or 0, {
        end_col = e.hover_end_col,
        hl_group = "KitHover",
        priority = 120,
      })
    else
      pcall(api.nvim_buf_set_extmark, buf, state.hover_ns, row, 0, {
        line_hl_group = "KitHover",
        hl_eol = true,
        priority = 120,
      })
    end
  end
  state.hover_row = idx
end

---@internal
--- Move the cursor to whatever selectable row the pointer is over (so `<CR>`
--- and a following click agree with what is visibly lit) and paint that row
--- with `paint_hover` -- the terminal equivalent of a button's hover state.
--- A terminal cell grid has no size to animate and no per-pixel blending for
--- text highlights, so an instant, unambiguous "this row is hot" is the
--- honest version of that effect, not a simulated fade. Bound to
--- `<MouseMove>` (see `M.open`), which only ever fires while
--- `'mousemoveevent'` is on -- `enable_hover`/`disable_hover` below.
local function on_hover_move()
  local ok, pos = pcall(vim.fn.getmousepos)
  if not ok or type(pos) ~= "table" or not state.surf or pos.winid ~= state.surf.winid then
    return
  end
  if type(pos.line) ~= "number" or pos.line < 1 then
    return
  end
  local idx = item_at_row(pos.line - 1)
  if not idx or not state.entries[idx].selectable then
    return
  end
  -- <MouseMove> fires on every cell the pointer crosses, not once per row --
  -- skip the repaint once this row is already the one lit.
  if state.hover_row == idx then
    return
  end
  paint_hover(idx)
  local e = state.entries[idx]
  local target = e.start_row + e.anchor_row + 1
  pcall(api.nvim_win_set_cursor, state.surf.winid, { target, 0 })
end

---@internal
--- Turn on `<MouseMove>` as a real input event. `'mousemoveevent'` is
--- global, so the previous value is saved and restored like `'guicursor'`
--- in `hide_cursor`/`restore_cursor`. Guarded with `pcall`: the option was
--- added after this plugin's own 0.10 floor, so setting it on an older
--- Neovim must degrade to "no hover tracking", not an error.
local function enable_hover()
  if state.saved_mousemoveevent ~= nil then
    return
  end
  local ok_read, prev = pcall(function()
    return vim.o.mousemoveevent
  end)
  if not ok_read then
    return
  end
  local ok_write = pcall(function()
    vim.o.mousemoveevent = true
  end)
  if not ok_write then
    return
  end
  state.saved_mousemoveevent = prev
end

---@internal
--- Restore `'mousemoveevent'` saved by `enable_hover` (idempotent, and a
--- no-op when hover tracking was never turned on).
local function disable_hover()
  if state.saved_mousemoveevent == nil then
    return
  end
  local saved = state.saved_mousemoveevent
  state.saved_mousemoveevent = nil
  pcall(function()
    vim.o.mousemoveevent = saved
  end)
end

---@internal
--- Re-center an editor-relative chooser after `VimResized` -- content size
--- doesn't change, only where the editor's midpoint now is. Cursor/mouse/win
--- -relative choosers are left alone: their anchor is a point on screen, not
--- an editor-size fraction, so a resize doesn't make their position stale the
--- same way (mirrors PERF-92's `ui.screenkey` fix, minus the width/height --
--- a chooser's size is content-driven, never a fraction of the editor).
local function relayout()
  if not state.centered or not M.is_open() then
    return
  end
  local ok, cfg = pcall(api.nvim_win_get_config, state.surf.winid)
  if not ok then
    return
  end
  pcall(api.nvim_win_set_config, state.surf.winid, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - cfg.height) / 2 - 1)),
    col = math.max(0, math.floor((vim.o.columns - cfg.width) / 2)),
    width = cfg.width,
    height = cfg.height,
  })
end

---@internal
--- Paint every entry's custom highlight spans (once, at open time — entries
--- never change after that, unlike selection marks which toggle).
local function render_content_highlights()
  local buf = state.surf and state.surf.bufnr
  if not buf or not api.nvim_buf_is_valid(buf) then
    return
  end
  api.nvim_buf_clear_namespace(buf, state.content_ns, 0, -1)
  for _, e in ipairs(state.entries) do
    if e.highlights then
      for _, h in ipairs(e.highlights) do
        local row = e.start_row + (h.line or 0)
        local col_start = h.col_start or 0
        local col_end = h.col_end
        if not col_end then
          local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
          col_end = #line
        end
        pcall(api.nvim_buf_set_extmark, buf, state.content_ns, row, col_start, {
          end_col = col_end,
          hl_group = h.hl_group,
        })
      end
    end
  end
end

---@internal
--- Clear multi-select marks from the chooser buffer.
local function clear_marks()
  if state.surf and api.nvim_buf_is_valid(state.surf.bufnr) then
    api.nvim_buf_clear_namespace(state.surf.bufnr, state.ns, 0, -1)
  end
end

---@internal
--- Repaint multi-select marks from `state.selections`. A marked item's whole
--- row span is highlighted, not just its anchor row.
local function render_marks()
  clear_marks()
  local buf = state.surf and state.surf.bufnr
  if not buf or not api.nvim_buf_is_valid(buf) then
    return
  end
  for idx, selected in pairs(state.selections) do
    local e = state.entries[idx]
    if selected and e then
      for row = e.start_row, e.end_row do
        pcall(api.nvim_buf_set_extmark, buf, state.ns, row, 0, {
          line_hl_group = "KitAccent",
          hl_eol = true,
        })
      end
    end
  end
end

---@internal
--- Light entry `idx` across every row it occupies.
---@param idx integer|nil
local function paint_flash(idx)
  local buf = state.surf and state.surf.bufnr
  local e = idx and state.entries[idx]
  if not buf or not e or not api.nvim_buf_is_valid(buf) then
    return
  end
  for row = e.start_row, e.end_row do
    pcall(api.nvim_buf_set_extmark, buf, state.flash_ns, row, 0, {
      line_hl_group = "KitFlash",
      hl_eol = true,
      -- Above the per-column content highlights and the multi-select marks,
      -- which sit on the same rows.
      priority = 200,
    })
  end
end

---@internal
--- Clear the pick acknowledgement.
local function clear_flash()
  local buf = state.surf and state.surf.bufnr
  if buf and api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, state.flash_ns, 0, -1)
  end
end

--- Close the chooser and reset state (idempotent).
function M.close()
  restore_cursor()
  disable_hover()
  pcall(vim.api.nvim_del_augroup_by_name, "lib_kit_chooser_resize")
  if state.surf then
    clear_marks()
    clear_flash()
    state.surf:close()
  end
  state.surf = nil
  state.hover_row = nil
  state.items = {}
  state.entries = {}
  state.on_select = nil
  state.multi = false
  state.selections = {}
  state.keep_open = false
  state.centered = false
  state.flashing = false
  state.generation = state.generation + 1
end

---@internal
--- Land the cursor on `initial_index`, falling forward to the first
--- selectable entry (so a list opening on a separator still starts on a real
--- item).
---@param initial_index? integer
local function place_cursor(initial_index)
  local entries = state.entries
  if not state.surf or not state.surf:is_valid() or not entries[1] then
    return
  end
  local initial = entries[initial_index] and initial_index or 1
  initial = next_selectable(initial, 1) or initial
  local e = entries[initial]
  pcall(api.nvim_win_set_cursor, state.surf.winid, { e.start_row + e.anchor_row + 1, 0 })
end

--- Replace the open chooser's list in place: new items, new size, new title,
--- same window. Returns false when nothing is open.
---
--- This exists for a drill-down menu. Closing the chooser and opening a
--- second one at the next level costs a redraw of whatever sits underneath,
--- which the eye reads as the menu flashing; it also re-anchors the window,
--- so a `relative = "mouse"` menu jumps to wherever the pointer happens to
--- be. Swapping the content keeps both the frame and its position still.
---@param opts table  # { items, title?, width?, height?, initial_index? }
---@return boolean replaced
function M.set_items(opts)
  if not M.is_open() or not opts or type(opts.items) ~= "table" or #opts.items == 0 then
    return false
  end

  local surf = state.surf
  local entries, flat_lines = build_entries(opts.items)

  clear_marks()
  -- The old row's extmark would otherwise point at whatever content ends up
  -- on that row number after the rewrite below, not at the entry it was
  -- actually painted for.
  if surf.bufnr and api.nvim_buf_is_valid(surf.bufnr) then
    api.nvim_buf_clear_namespace(surf.bufnr, state.hover_ns, 0, -1)
  end
  state.hover_row = nil
  state.items = opts.items
  state.entries = entries
  state.selections = {}

  -- The cursor may be past the end of the new, shorter list while the buffer
  -- is being rewritten; park it at the top first so the write can't fail.
  pcall(api.nvim_win_set_cursor, surf.winid, { 1, 0 })
  surf:set_lines(flat_lines)

  -- Re-anchor to where the window already is, rather than to whatever
  -- `relative` it was opened with: re-applying `relative = "mouse"` would
  -- move the menu to the pointer's current position on every level change.
  local pos = vim.fn.win_screenpos(surf.winid)
  local cfg = api.nvim_win_get_config(surf.winid)
  cfg.relative = "editor"
  cfg.win = nil
  -- `win_screenpos` always reports the window's top-left corner, regardless
  -- of the anchor it was opened with -- a menu that auto-flipped to "SW"
  -- near the bottom of the screen (see @types' `anchor` field) must be
  -- re-anchored to "NW" here, or the row/col below would shift it by its
  -- own height on the next level change.
  cfg.anchor = "NW"
  cfg.row = math.max(0, pos[1] - 1)
  cfg.col = math.max(0, pos[2] - 1)
  cfg.width = math.max(1, opts.width or cfg.width)
  cfg.height = math.max(1, opts.height or #flat_lines)
  -- Empty string, not nil: an omitted `title` leaves the existing one in
  -- place, so walking from a titled submenu back to an untitled top level
  -- would keep the child's title on the frame.
  cfg.title = printable_title(opts.title or "")
  pcall(api.nvim_win_set_config, surf.winid, cfg)

  render_content_highlights()
  place_cursor(opts.initial_index)
  return true
end

--- Move the current selection by `delta` items, wrapping around. Reusable by
--- the picker prompt (Part B) to drive a results slot.
---@param delta integer
function M.move(delta)
  if not M.is_open() then
    return
  end
  local win = state.surf.winid
  local count = #state.entries
  if count == 0 then
    return
  end
  local cur_row0 = api.nvim_win_get_cursor(win)[1] - 1
  local cur_idx = item_at_row(cur_row0) or 1
  -- Non-selectable entries (separators, headings) are stepped over rather
  -- than landed on, in the direction of travel.
  local idx = next_selectable(cur_idx + delta, delta >= 0 and 1 or -1)
  if not idx then
    return
  end
  local e = state.entries[idx]
  api.nvim_win_set_cursor(win, { e.start_row + e.anchor_row + 1, 0 })
  -- Keyboard navigation takes over from a stale mouse hover: leaving the
  -- last-hovered row lit while j/k moved the actual selection elsewhere
  -- would show two different rows as "the one about to be picked". Only
  -- when hover is actually on for this chooser -- select/picker/compare
  -- never enable it, and must not gain this highlight as a side effect.
  if state.saved_mousemoveevent ~= nil then
    paint_hover(idx)
  end
end

--- 1-based logical item index at the cursor, or nil when closed.
---@return integer|nil
function M.current_index()
  if not M.is_open() then
    return nil
  end
  local row0 = api.nvim_win_get_cursor(state.surf.winid)[1] - 1
  return item_at_row(row0)
end

--- The original value (string or rich table) of the item at the cursor, or
--- nil when closed. For a consumer building extra actions on top of the
--- picker (keymaps that read the highlighted item without submitting/
--- closing, e.g. "yank without closing") -- `on_select`'s callback only
--- fires on an actual selection, this is the same lookup available anytime
--- the chooser is open.
---@return any
function M.current_item()
  local idx = M.current_index()
  local e = idx and state.entries[idx]
  return e and e.value
end

--- Toggle the current item's mark (multi-select). Also drivable by the picker.
function M.toggle()
  if not M.is_open() then
    return
  end
  local idx = M.current_index()
  if not idx or not state.entries[idx].selectable then
    return
  end
  state.selections[idx] = not state.selections[idx]
  render_marks()
end

---@internal
--- Resolve the selection for `idx`, fire the callback, and close unless the
--- callback was promised the window.
---@param idx integer|nil
local function deliver(idx)
  local cb, multi, entries = state.on_select, state.multi, state.entries
  -- `close_on_select = false`: the callback owns the window from here. A menu
  -- drilling into a submenu uses this to swap the list in place instead of
  -- closing and reopening -- the close/reopen pair costs a redraw of whatever
  -- is underneath, which reads as a flash between the two levels.
  local keep = state.keep_open

  if multi then
    local idxs = {}
    for i, selected in pairs(state.selections) do
      if selected and entries[i] then
        idxs[#idxs + 1] = i
      end
    end
    table.sort(idxs)
    if #idxs == 0 and idx then
      idxs = { idx }
    end
    local chosen = {}
    for _, i in ipairs(idxs) do
      chosen[#chosen + 1] = entries[i].value
    end
    if not keep then
      M.close()
    end
    if cb and #chosen > 0 then
      cb(chosen, idxs)
    end
  else
    local entry = idx and entries[idx]
    if not keep then
      M.close()
    end
    if cb and entry ~= nil then
      cb(entry.value, idx)
    end
  end
end

--- Resolve the selection, fire the callback, then close. Also drivable by the
--- picker prompt (Part B) to submit the highlighted item.
---
--- With `flash_on_select` the picked row is lit first and the delivery waits
--- `flash_ms`. That wait is the feature, not an implementation detail: the
--- delivery is what closes the list or swaps it to another level, so
--- acknowledging a pick means being on screen before it happens.
function M.submit()
  if not M.is_open() then
    return
  end
  -- A pick is already lit and waiting to be delivered. A second <CR> inside
  -- that window would run two selections off one list.
  if state.flashing then
    return
  end
  local idx = M.current_index()
  -- A non-selectable entry (separator, heading) is inert: picking it does
  -- nothing and leaves the chooser open, rather than closing with no value.
  if idx and not state.entries[idx].selectable then
    return
  end

  if not state.flash_on_select or state.flash_ms <= 0 then
    deliver(idx)
    return
  end

  local gen = state.generation
  state.flashing = true
  paint_flash(idx)
  vim.defer_fn(function()
    -- Dismissed while lit: the pick was abandoned, so it is not delivered.
    -- Both ways that happens have to be caught. `close` bumps the generation;
    -- the window going away on its own does not, because close_on_focus_lost
    -- closes it directly and never routes through `close` -- only `is_open`
    -- sees that one.
    if state.generation ~= gen or not M.is_open() then
      state.flashing = false
      return
    end
    state.flashing = false
    clear_flash()
    deliver(idx)
  end, state.flash_ms)
end

---@internal
--- Pick the row under the mouse pointer and submit it. Returns false when the
--- click landed outside the chooser window, so the caller can decide what an
--- off-list click means.
---@return boolean handled
local function click_submit()
  if not M.is_open() then
    return false
  end
  local pos = vim.fn.getmousepos()
  if pos.winid ~= state.surf.winid then
    return false
  end
  -- getmousepos() reports 1-based screen lines within the window; a click on
  -- the border row yields line 0, which is not a row to select.
  if type(pos.line) ~= "number" or pos.line < 1 then
    return false
  end
  local idx = item_at_row(pos.line - 1)
  if not idx or not state.entries[idx].selectable then
    return true
  end
  local e = state.entries[idx]
  api.nvim_win_set_cursor(state.surf.winid, { e.start_row + e.anchor_row + 1, 0 })
  M.submit()
  return true
end

--- Open a chooser.
---@param opts table  # { items, on_select, multi_select?, title?, relative?, win?, anchor?, row?, col?, width?, height?, theme?, initial_index?, hide_cursor?, single_click?, close_on_focus_lost?, close_on_select?, flash_on_select?, flash_ms?, hover? }
---@return Lib.UI.Kit.Surface|nil
function M.open(opts)
  if not opts or type(opts.items) ~= "table" or #opts.items == 0 then
    notify.error("chooser: `items` is required and must be non-empty")
    return nil
  end
  if type(opts.on_select) ~= "function" then
    notify.error("chooser: `on_select` callback is required")
    return nil
  end

  M.close()

  local entries, flat_lines = build_entries(opts.items)

  local surf = surface.open({
    modal = true,
    lines = flat_lines,
    theme = opts.theme,
    title = opts.title,
    relative = opts.relative or "cursor",
    -- Explicit placement, for an anchor the surface can't derive on its own
    -- (`relative = "mouse"` with nvzone/menu's row/col offsets, say, or
    -- `relative = "win"` to sit beside another window rather than at the
    -- pointer -- see `win`/`anchor` below).
    win = opts.win,
    anchor = opts.anchor,
    row = opts.row,
    col = opts.col,
    width = opts.width,
    height = opts.height or #flat_lines,
    enter = true,
    filetype = "lib-kit-chooser",
    wo = { cursorline = true },
  })
  if not surf then
    return nil
  end

  -- Map the current line to the theme's selection highlight.
  local cur = api.nvim_get_option_value("winhighlight", { win = surf.winid })
  local sep = cur ~= "" and "," or ""
  pcall(
    api.nvim_set_option_value,
    "winhighlight",
    cur .. sep .. "CursorLine:" .. theme.scoped_group(surf.winid, "KitSelection"),
    { win = surf.winid }
  )

  state.surf = surf
  state.items = opts.items
  state.entries = entries
  state.on_select = opts.on_select
  state.multi = opts.multi_select or opts.multi or false
  state.selections = {}
  state.keep_open = opts.close_on_select == false
  state.flash_on_select = opts.flash_on_select == true
  state.flash_ms = opts.flash_ms or FLASH_MS
  state.flashing = false
  state.centered = opts.relative == "editor" and opts.row == nil and opts.col == nil
  if state.centered then
    autocmd.create("VimResized", relayout, {
      group = autocmd.group("lib_kit_chooser_resize", true),
      desc = "lib.nvim.ui.kit.chooser: keep an editor-centered chooser centered",
    })
  end

  render_content_highlights()

  if opts.hide_cursor then
    hide_cursor()
  end
  if opts.hover then
    enable_hover()
  end
  -- The window can also go away without M.close() -- close_on_focus_lost
  -- closes it directly, and `:q` from inside works too -- so the global
  -- 'guicursor'/'mousemoveevent' are restored from the surface's own
  -- lifecycle, not from the close path alone. The resize augroup rides the
  -- same lifecycle, for the same reason: `M.close()`'s own cleanup only
  -- covers the paths that call it.
  surf:on_close(restore_cursor)
  surf:on_close(disable_hover)
  surf:on_close(function()
    pcall(vim.api.nvim_del_augroup_by_name, "lib_kit_chooser_resize")
  end)

  if opts.close_on_focus_lost then
    require("lib.nvim.window.close_on_focus_lost")(surf.winid)
  end

  -- `record = false`: these are throwaway buffer-local keys of a float, not part
  -- of anyone's keymap surface. The keymap records are keyed by buffer number --
  -- a new one for every popup -- and never removed, so recording them added ~20
  -- entries per open for good (each holding its `rhs` closure, hence the popup's
  -- state, alive as well). Every kit popup that binds keys this way does the same.
  local mo = { buffer = surf.bufnr, nowait = true, record = false }
  for _, key in ipairs(HORIZONTAL) do
    map("n", key, "<Nop>", mo)
  end
  -- By item, not by buffer line: an item may span several rows, and a separator is no stop.
  for lhs, delta in pairs({ j = 1, k = -1, ["<Down>"] = 1, ["<Up>"] = -1 }) do
    map("n", lhs, function()
      for _ = 1, vim.v.count1 do
        M.move(delta)
      end
    end, mo)
  end
  map("n", "<CR>", M.submit, mo)
  map("n", "<2-LeftMouse>", M.submit, mo)
  map("n", "<Esc>", M.close, mo)
  map("n", "q", M.close, mo)
  -- Absorb a right-click landing on the chooser's own buffer (a border, a
  -- separator, the padding around a row -- anywhere <LeftMouse>'s
  -- click_submit() has no row for) rather than leaving it unbound. Nvim
  -- falls through an unbound key on a buffer-local mapping to whatever is
  -- mapped globally -- for <RightMouse> that is very often another context
  -- menu's own trigger, so a near-miss click used to close this menu only
  -- to immediately open a second, unrelated one on top of it.
  map("n", "<RightMouse>", M.close, mo)
  -- Neovim's default <ScrollWheelDown>/<Up> is a plain by-line window scroll
  -- (<C-e>/<C-y>), which -- unlike cursor-driven motions such as `G` or `j`
  -- at the last line -- has no built-in floor stopping `topline` once the
  -- last line has reached the window's bottom row: enough wheel ticks walk
  -- it straight past the end, leaving nothing but blank space below the
  -- content, permanently, for a window shorter than its list. Routed
  -- through `M.move` instead, which already lands on and stays on a real
  -- entry, the same way keyboard navigation does.
  map("n", "<ScrollWheelDown>", function()
    M.move(1)
  end, mo)
  map("n", "<ScrollWheelUp>", function()
    M.move(-1)
  end, mo)
  if opts.hover then
    -- `<MouseMove>` is a real, mappable key -- like `<LeftMouse>` -- but
    -- only ever fires while `'mousemoveevent'` is on, which `enable_hover`
    -- just turned on above.
    map("n", "<MouseMove>", on_hover_move, mo)
  end
  if opts.single_click then
    map("n", "<LeftMouse>", function()
      if not click_submit() then
        -- Clicked past the list: dismiss it. Leaving it open under the
        -- pointer is what makes a mis-click feel stuck, and this mapping has
        -- already swallowed the click either way.
        M.close()
      end
    end, mo)
  end
  if state.multi then
    map("n", "<Tab>", M.toggle, mo)
    map("n", "<S-Tab>", function()
      M.toggle()
      M.move(-1)
    end, mo)
  end

  -- opts.initial_index: land on a specific item (e.g. restoring cursor
  -- position across a refresh) instead of always item 1; out-of-range or
  -- absent falls back to item 1, and a separator is stepped over.
  place_cursor(opts.initial_index)

  return surf
end

return M
