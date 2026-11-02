---@module 'lib.nvim.ui.kit.message_log'
--- Scrollable, time-ordered, paginated, collapsible entry list popup --
--- generalizes "show a recent, growing, time-stamped list" (first consumer:
--- debugging.nvim's recent-messages view, backed by lib.nvim.messages).
--- Deliberately knows nothing about where entries come from: plain tables
--- in (`{time_ms, level?, content}`, `time_ms` any clock as long as it's
--- consistent -- monotonic or epoch, this module only ever compares two of
--- the caller's own values), callbacks for "there's more" and live updates.

local surface = require("lib.nvim.ui.kit.surface")
local close_on_focus_lost = require("lib.nvim.window.close_on_focus_lost")

local M = {}

-- Module-level, not per-instance: `nvim_create_namespace` has no delete
-- API, so a namespace created fresh in every `M.open()` (the earlier,
-- bufnr-suffixed approach) leaked two registry entries per popup for the
-- life of the session. Every use below is already scoped to `self.surf.
-- bufnr` explicitly, so sharing one id across concurrently-open instances
-- is safe -- the same pattern `chooser.lua`/`preview.lua` already use.
local HL_NS = vim.api.nvim_create_namespace("ui_kit_message_log_hl")
local ARROW_NS = vim.api.nvim_create_namespace("ui_kit_message_log_arrows")
local MARK_NS = vim.api.nvim_create_namespace("ui_kit_message_log_marks")
local HINT_NS = vim.api.nvim_create_namespace("ui_kit_message_log_hint")

---@internal
local LEVEL_HL = {
  [vim.log.levels.WARN] = "DiagnosticWarn",
  [vim.log.levels.ERROR] = "DiagnosticError",
}

---@internal
---Default "Ns ago" formatter: `now_ms`/`entry.time_ms` must share a clock.
---@param entry table
---@param now_ms number
---@return string
local function default_format_time(entry, now_ms)
  local delta_s = math.max(0, (now_ms - (entry.time_ms or now_ms)) / 1000)
  if delta_s < 60 then
    return ("%ds ago"):format(math.floor(delta_s))
  end
  local m = math.floor(delta_s / 60)
  local s = math.floor(delta_s % 60)
  return ("%dm %ds ago"):format(m, s)
end

---@internal
---The lines of an entry's content as they are drawn -- the one definition, shared by the
---renderer and the "nothing to fold" check. CRLF (and "\r\r\n") would show a stray ^M, a
---progress bar redrawing itself with a lone CR would pile up its frames (only what is after
---the last CR of a line is kept, as a terminal would show it), a trailing newline would add an
---empty extra line (and inflate the "+N more lines" count), and a NUL byte is shown as the
---replacement character.
---@param entry table
---@return string[]  # at least one line
local function content_lines_of(entry)
  local text = tostring(entry.content or "")
  if text:find("\0", 1, true) then
    text = text:gsub("%z", "\u{FFFD}")
  end
  local lines = vim.split(text, "\n", { plain = true })
  for i, line in ipairs(lines) do
    if line:find("\r", 1, true) then
      lines[i] = line:gsub("\r+$", ""):match("[^\r]*$")
    end
  end
  while #lines > 1 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  return lines
end

---@internal
---One entry -> its rendered line(s). Collapsed: first content line only,
---with a "… (N more lines)" marker when truncated.
---@param entry table
---@param opts Lib.UI.Kit.MessageLog.Opts
---@param collapsed boolean
---@param now_ms number
---@return string[] lines, string|nil hl_group, integer content_lines  # hl_group applies to every line of this entry
local function render_entry(entry, opts, collapsed, now_ms)
  local format_time = opts.format_entry_time or default_format_time
  local time_label = format_time(entry, now_ms)
  local content_lines = content_lines_of(entry)
  local hl = entry.level and LEVEL_HL[entry.level] or nil

  local lines = { ("[%s] %s"):format(time_label, content_lines[1] or "") }
  if collapsed then
    if #content_lines > 1 then
      lines[1] = lines[1]
        .. ("  … (+%d more line%s)"):format(
          #content_lines - 1,
          #content_lines - 1 == 1 and "" or "s"
        )
    end
  else
    for i = 2, #content_lines do
      lines[#lines + 1] = content_lines[i]
    end
  end
  return lines, hl, #content_lines
end

---@class Lib.UI.Kit.MessageLog.Handle
---@field surf Lib.UI.Kit.Surface  # the underlying window/buffer -- e.g. for a caller's own window-tag bookkeeping
---@field package opts Lib.UI.Kit.MessageLog.Opts
---@field package entries table[]  oldest first
---@field package collapsed boolean  # the default for every entry without an override in `expanded`
---@field package expanded table<table, boolean>  # per-entry override of `collapsed` (true = open)
---@field package has_more_older boolean
---@field package has_more_newer boolean
---@field package _older_pages integer[]
---@field package _pending table[]  entries parked by `append` until the main loop can draw them
---@field package _flush_scheduled boolean
---@field package _line_entry (table|nil)[]|nil  # buffer line -> the entry drawn there (nil before the first draw)
---@field package _first_line table<table, integer>|nil  # entry -> the buffer line it starts on
---@field package _title_w integer  # display width of the full title, a floor for the window width
---@field package _hint_gen integer  # generation of the transient hint, so an old timer cannot clear a newer one
---@field package _focus_group integer|nil  # the close-on-focus-lost augroup, nil while suspended
---@field package _cheat Lib.UI.Kit.Surface|nil  # the open cheatsheet
local Handle = {}
Handle.__index = Handle

---@internal
---@return table<table, boolean>
local function new_overrides()
  return setmetatable({}, { __mode = "k" })
end

---@internal
---Whether `entry` is drawn collapsed: its own override, else the log-wide state.
---@param entry table
---@return boolean
function Handle:_is_collapsed(entry)
  local override = self.expanded[entry]
  if override ~= nil then
    return not override
  end
  return self.collapsed
end

---@internal
---The entry the cursor is on (any of its lines), nil on the placeholder.
---@return table|nil
function Handle:_entry_at_cursor()
  if not self._line_entry or not self.surf:is_valid() then
    return nil
  end
  local ok, pos = pcall(vim.api.nvim_win_get_cursor, self.surf.winid)
  return ok and self._line_entry[pos[1]] or nil
end

---@internal
---Full re-render: order, collapse, line-highlights, pagination hints.
---The cursor stays on `anchor` (default: the entry it is on now) -- toggling
---an entry, paging in older ones or a live append all change the line
---numbers, but never what the user is looking at. The first draw puts it on
---the newest entry.
---@param anchor? table
function Handle:_redraw(anchor)
  anchor = anchor or self:_entry_at_cursor()
  local first_draw = self._line_entry == nil

  -- Where the reader is, inside the anchor entry and on the screen: a redraw changes line
  -- numbers above the anchor, never what is being read (a stack trace, a long error). Only
  -- when the anchor really is the entry under the cursor -- an explicit anchor (a toggled
  -- entry, the newest one to follow) has no reading position of its own.
  local offset, screen_row = 0, nil
  if anchor and self._first_line and anchor == self:_entry_at_cursor() then
    local lnum = vim.api.nvim_win_get_cursor(self.surf.winid)[1]
    offset = lnum - (self._first_line[anchor] or lnum)
    screen_row = lnum
      - vim.api.nvim_win_call(self.surf.winid, function()
        return vim.fn.line("w0")
      end)
  end

  local ordered = self.entries
  if self.opts.order == "newest_first" then
    ordered = {}
    for i = #self.entries, 1, -1 do
      ordered[#ordered + 1] = self.entries[i]
    end
  end

  local now_ms = self.now_ms_fn()
  local lines, highlights = {}, {}
  local line_entry, first_line, n_lines, marks = {}, {}, {}, {}
  local max_w = 0
  for _, entry in ipairs(ordered) do
    local collapsed = self:_is_collapsed(entry)
    local entry_lines, hl, n_content = render_entry(entry, self.opts, collapsed, now_ms)
    first_line[entry] = #lines + 1
    n_lines[entry] = #entry_lines
    for i, l in ipairs(entry_lines) do
      local lnum = #lines + 1
      lines[lnum] = l
      line_entry[lnum] = entry
      -- A line cannot be wider (in cells) than it is long (in bytes): measure only the
      -- ones that could beat the widest so far.
      if #l > max_w then
        max_w = math.max(max_w, vim.fn.strdisplaywidth(l))
      end
      if hl then
        highlights[lnum] = hl
      end
      -- "▸"/"▾" tell a folded entry from an open one at a glance; a single-line
      -- entry has nothing to fold and gets blanks, an open entry's further lines a bar.
      if i == 1 then
        marks[lnum] = n_content < 2 and "  " or (collapsed and "▸ " or "▾ ")
      else
        marks[lnum] = "│ "
      end
    end
  end
  if #lines == 0 then
    lines = { "(no messages)" }
  end

  self.surf:set_lines(lines)
  self._line_entry = line_entry
  self._first_line = first_line
  self:_clear_hint()

  -- Each arrow hint is its own extmark virt_line -- a real, rendered row in
  -- the window, just not part of the buffer text -- so the window must be
  -- at least that many rows taller than the content or the hint is placed
  -- but has no room to actually show without the user scrolling. Tracked
  -- alongside the extmark calls below so _resize_to_content gets the true
  -- visible-row count, not just the buffer's own line count.
  local visible_rows = #lines

  if vim.api.nvim_buf_is_valid(self.surf.bufnr) then
    vim.api.nvim_buf_clear_namespace(self.surf.bufnr, self._hl_ns, 0, -1)
    for lnum, hl in pairs(highlights) do
      -- Whole-line highlight as an extmark (nvim_buf_add_highlight is
      -- deprecated since 0.11); end_col = the line's byte length mirrors
      -- its col_end = -1.
      pcall(vim.api.nvim_buf_set_extmark, self.surf.bufnr, self._hl_ns, lnum - 1, 0, {
        end_col = #(lines[lnum] or ""),
        hl_group = hl,
      })
    end
    pcall(vim.api.nvim_buf_clear_namespace, self.surf.bufnr, MARK_NS, 0, -1)
    for lnum, text in pairs(marks) do
      pcall(vim.api.nvim_buf_set_extmark, self.surf.bufnr, MARK_NS, lnum - 1, 0, {
        virt_text = { { text, "Comment" } },
        virt_text_pos = "inline",
      })
    end
    pcall(vim.api.nvim_buf_clear_namespace, self.surf.bufnr, self._arrow_ns, 0, -1)
    if self.has_more_older then
      pcall(vim.api.nvim_buf_set_extmark, self.surf.bufnr, self._arrow_ns, 0, 0, {
        virt_lines = { { { "󰁝 more above -- <C-j> or +", "Comment" } } },
        virt_lines_above = true,
      })
      visible_rows = visible_rows + 1
    end
    if self.has_more_newer then
      pcall(vim.api.nvim_buf_set_extmark, self.surf.bufnr, self._arrow_ns, #lines - 1, 0, {
        virt_lines = { { { "󰁅 more below -- <C-k> or -", "Comment" } } },
      })
      visible_rows = visible_rows + 1
    end
  end

  self:_resize_to_content(visible_rows, max_w)

  -- Cursor: back on the anchor, on the same line of it and the same screen row (if that
  -- entry was trimmed away, the line number is what set_lines clamped it to); the newest
  -- entry at first.
  local target
  if anchor and first_line[anchor] then
    target = first_line[anchor] + math.min(offset, n_lines[anchor] - 1)
  elseif first_draw then
    target = self.opts.order == "newest_first" and 1 or #lines
  end
  if target and self.surf:is_valid() then
    if screen_row then
      pcall(vim.api.nvim_win_call, self.surf.winid, function()
        local height = vim.api.nvim_win_get_height(0)
        local top = math.max(1, math.min(target - screen_row, #lines - height + 1))
        vim.fn.winrestview({ lnum = target, col = 0, topline = top })
      end)
    else
      pcall(vim.api.nvim_win_set_cursor, self.surf.winid, { target, 0 })
    end
  end
  self:_reveal_more_above_hint()
end

---@internal
---`virt_lines_above` on buffer line 1 is NOT shown by the window's default
---viewport -- `_resize_to_content` makes room for it, but Neovim still
---needs an explicit scroll ("topfill", the same field `winsaveview()`
---reports for diff/virtual-line filler above topline) to actually reveal
---it; otherwise the row sits there blank and the hint is only visible
---after the user manually scrolls up (`<C-y>`, discovered live-testing
---this exact popup). `winrestview` applies a PARTIAL view update -- only
---`topfill` changes here, cursor/topline are left alone. Harmless no-op
---for `has_more_newer` (a trailing virt_line needs no such scroll).
function Handle:_reveal_more_above_hint()
  if not vim.api.nvim_win_is_valid(self.surf.winid) then
    return
  end
  pcall(vim.api.nvim_win_call, self.surf.winid, function()
    -- Only when the view starts at line 1: the cursor sits on the newest entry
    -- (the last line) when the content outgrows the window, and a filler row
    -- above some middle line would only push a content row out of view.
    if vim.fn.winsaveview().topline == 1 then
      vim.fn.winrestview({ topfill = self.has_more_older and 1 or 0 })
    end
  end)
end

---@internal
---Grow/shrink the window to fit `num_rows` (buffer lines, PLUS any arrow
---hint virt_lines the caller already counted in -- a virt_line is a real
---rendered row with nowhere to go if the window is sized to the buffer's
---own line count only), the same way `lib.nvim.window.make_scratch`'s own
---content-derived sizing works (clamped to the editor, floored at 2 so the
---popup never drops below `lib.nvim.window.tag.find()`'s `height > 1` floor
----- see this module's own commit history for why that matters: `M.open()`
---seeds the window with a 1-line placeholder before the first real
---`_redraw()`, and a sparse live feed can legitimately render just one
---entry). An explicit `opts.height` / `opts.width` is a deliberate fixed size,
---not a hint to override: that dimension is left alone.
---@param num_rows integer
---@param max_w? integer  # widest content line in cells; the window grows to fit it (never shrinks)
function Handle:_resize_to_content(num_rows, max_w)
  local winid = self.surf.winid
  if not vim.api.nvim_win_is_valid(winid) then
    return
  end
  local cur = vim.api.nvim_win_get_config(winid)
  local cfg = {}
  local height = cur.height
  if not self.opts.height then
    local max_h = math.max(1, vim.o.lines - 4)
    height = math.max(2, math.min(num_rows, max_h))
    cfg.height = height
  end
  -- Width: make_scratch sized the window for the 1-line placeholder (its 60-column default),
  -- so a long message would be cut off. Grow to the widest line + the fold mark + a margin,
  -- at least as wide as the title; never shrink, so a live feed does not make it jitter.
  local width = cur.width
  if not self.opts.width and max_w then
    local want = math.max(max_w + 3, self._title_w + 2)
    want = math.min(want, math.max(1, vim.o.columns - 4))
    if want > width then
      width = want
      cfg.width = width
    end
  end
  -- make_scratch centred on that placeholder too: keep it centred as the size changes
  -- (nvim_win_set_config wants relative, row and col together).
  if (self.opts.relative or "editor") == "editor" then
    cfg.relative = "editor"
    cfg.row = math.max(0, math.floor((vim.o.lines - height) / 2 - 1))
    cfg.col = math.max(0, math.floor((vim.o.columns - width) / 2))
  end
  if next(cfg) then
    pcall(vim.api.nvim_win_set_config, winid, cfg)
  end
end

---@internal
---Drop the oldest entries past `opts.max_entries` (unset = unbounded, the
---pre-existing default). Without this, a popup left open against a live
---feed (`on_message` -> `append`) grows `self.entries` and therefore the
---cost of every `_redraw()` for as long as the window stays open. Called
---only from `append` -- see `load_more`'s own comment for why pagination
---must not be capped the same way.
---
---Deliberately does NOT touch `has_more_older`: that flag means "`opts.
---load_more` can supply older data", set once in `M.open()` and cleared
---only when `load_more("older")` itself reports nothing left -- trimming
---changes what's in memory, not whether the data source has more. An
---earlier version set it here unconditionally, which (a) showed a dead
---"more above" hint with no `load_more` configured at all (trimming is the
---only way to reach max_entries, so this path always ran once the cap hit),
---and (b) could resurrect the hint after `load_more("older")` had already
---reported exhausted.
function Handle:_trim()
  local max_entries = self.opts.max_entries
  if not max_entries or #self.entries <= max_entries then
    return
  end
  for _ = 1, #self.entries - max_entries do
    table.remove(self.entries, 1)
  end
end

---Append newly-arrived entries (a live feed) without discarding history
---already loaded. The caller owns its own subscription to its data source
---and is responsible for only calling this with entries that belong here
---(already filtered/ordered the way the caller wants).
---@param new_entries table[]
function Handle:append(new_entries)
  -- Live-feed callers (`lib.nvim.messages.on_message`, fed by a
  -- `vim.ui_attach` callback) can run in a fast event context, where
  -- `nvim_win_is_valid` and every other window/buffer API is forbidden
  -- (E5560). Park the entries in `_pending` and flush them from the main
  -- loop. Every later append -- fast or not -- goes through the same queue
  -- while it is non-empty, so entries can never be reordered, and a burst
  -- of messages costs one redraw instead of one per message.
  if #new_entries == 0 then
    return
  end
  local pending = self._pending
  if vim.in_fast_event() or #pending > 0 then
    vim.list_extend(pending, new_entries)
    if not self._flush_scheduled then
      self._flush_scheduled = true
      vim.schedule(function()
        self._flush_scheduled = false
        local queued = self._pending
        self._pending = {}
        if #queued > 0 then
          self:append(queued)
        end
      end)
    end
    return
  end
  if not self.surf:is_valid() then
    return
  end
  -- A cursor on the newest entry follows the feed (tail -f); anywhere else it
  -- stays on the entry being read while the new ones arrive around it.
  local anchor = self:_entry_at_cursor()
  local follow = #self.entries == 0 or (anchor ~= nil and anchor == self.entries[#self.entries])
  for _, e in ipairs(new_entries) do
    self.entries[#self.entries + 1] = e
  end
  self:_trim()
  self:_redraw(follow and new_entries[#new_entries] or nil)
  if follow and self.opts.order ~= "newest_first" and self.surf:is_valid() then
    -- tail -f: rest on the last line (like the first draw), so a multi-line entry is in
    -- view as a whole and not just its header line.
    pcall(
      vim.api.nvim_win_set_cursor,
      self.surf.winid,
      { vim.api.nvim_buf_line_count(self.surf.bufnr), 0 }
    )
  end
end

---Load older or newer entries via `opts.load_more`, prepending/appending
---them. Hides that direction's pagination hint once `load_more` reports
---nothing left (an empty return).
---@param direction "older"|"newer"
function Handle:load_more(direction)
  if type(self.opts.load_more) ~= "function" then
    return
  end
  local more = self.opts.load_more(direction) or {}
  if #more == 0 then
    if direction == "older" then
      self.has_more_older = false
    else
      self.has_more_newer = false
    end
    self:_redraw()
    return
  end
  -- `max_entries` (see `_trim`) deliberately does NOT apply here: pagination
  -- is explicit and self-limiting (a user presses <C-j>/<C-k>, not an
  -- unbounded live feed), and trimming a direction's own just-loaded
  -- entries straight back out -- oldest-first, i.e. exactly what
  -- `load_more("older")` just prepended -- would make paging backward
  -- through history a no-op once the cap is hit.
  if direction == "older" then
    local merged = {}
    for _, e in ipairs(more) do
      merged[#merged + 1] = e
    end
    for _, e in ipairs(self.entries) do
      merged[#merged + 1] = e
    end
    self.entries = merged
    self._older_pages[#self._older_pages + 1] = #more
  else
    for _, e in ipairs(more) do
      self.entries[#self.entries + 1] = e
    end
  end
  self:_redraw()
end

---Take the page `load_more("older")` loaded last out again (`-`): the entries go, `has_more_older` is
---true again and `opts.on_unload("older", n)` tells the caller how many entries left, so it can move
---its own page cursor back. Returns whether a page was taken out; false when none was loaded.
---@return boolean
function Handle:unload_older()
  local count = table.remove(self._older_pages)
  if not count then
    return false
  end
  count = math.min(count, #self.entries) -- a live feed's `max_entries` trim may have dropped some already
  self.entries = vim.list_slice(self.entries, count + 1)
  self.has_more_older = type(self.opts.load_more) == "function"
  if type(self.opts.on_unload) == "function" then
    pcall(self.opts.on_unload, "older", count)
  end
  self:_redraw()
  return true
end

---Fold or unfold every entry at once (first-line-only when collapsed), dropping
---the per-entry choices made with `set_entry_collapsed`/`toggle_entry`.
---@param value? boolean  # explicit state; omit to flip
function Handle:set_collapsed(value)
  self.collapsed = value == nil and not self.collapsed or value == true
  self.expanded = new_overrides()
  self:_redraw()
end

---Fold (`true`) or unfold (`false`) one entry, flipping it when `value` is nil.
---Without `entry` it is the one under the cursor; a no-op on the placeholder.
---@param value? boolean
---@param entry? table
function Handle:set_entry_collapsed(value, entry)
  local by_key = entry == nil
  entry = entry or self:_entry_at_cursor()
  if not entry then
    return
  end
  if by_key and #content_lines_of(entry) < 2 then
    -- Nothing would change on screen: say so instead of looking like a dead key. Inline and
    -- transient, not a notification: that is recorded as a message (and shown in this very
    -- log), prompts on a narrow UI and would pile up while the key is held.
    self:_hint("single-line entry, nothing to fold")
    return
  end
  if value == nil then
    value = not self:_is_collapsed(entry)
  end
  self.expanded[entry] = not value
  self:_redraw(entry)
end

---@internal
---Drop the transient hint (see `_hint`).
function Handle:_clear_hint()
  self._hint_gen = self._hint_gen + 1
  if vim.api.nvim_buf_is_valid(self.surf.bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, self.surf.bufnr, HINT_NS, 0, -1)
  end
end

---@internal
---A short note at the end of the cursor line that goes away on its own after a moment (or
---with the next redraw). Buffer-local virtual text: nothing the message channels record.
---@param text string
function Handle:_hint(text)
  self:_clear_hint()
  if not self.surf:is_valid() then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(self.surf.winid)[1]
  pcall(vim.api.nvim_buf_set_extmark, self.surf.bufnr, HINT_NS, lnum - 1, 0, {
    virt_text = { { "  " .. text, "WarningMsg" } },
    virt_text_pos = "eol",
  })
  local gen = self._hint_gen
  vim.defer_fn(function()
    if self._hint_gen == gen then
      self:_clear_hint()
    end
  end, 2000)
end

---Flip the entry under the cursor.
function Handle:toggle_entry()
  self:set_entry_collapsed(nil)
end

---Register a callback for when the window closes (any cause).
---@param cb fun()
function Handle:on_close(cb)
  self.surf:on_close(cb)
end

function Handle:close()
  self.surf:close()
end

---@internal
---(Re-)arm the dismiss-on-focus-lost autocmd, unless the caller opted out.
function Handle:_arm_focus_close()
  if self.opts.close_on_focus_lost == false or self._focus_group or not self.surf:is_valid() then
    return
  end
  self._focus_group = close_on_focus_lost(self.surf.winid)
end

---@internal
---Take the focus-lost autocmd away -- while the cheatsheet has the focus the log
---must stay behind it instead of vanishing the moment `?` is pressed.
function Handle:_suspend_focus_close()
  if self._focus_group then
    pcall(vim.api.nvim_del_augroup_by_id, self._focus_group)
    self._focus_group = nil
  end
end

---The keys of the log: one row each, shared by the mappings and the cheatsheet so the
---two can never drift apart. `show` is the label in the cheatsheet (default: all keys).
---@internal
---@type { keys: string[], show?: string, desc: string, run: fun(self: Lib.UI.Kit.MessageLog.Handle) }[]
local KEYS = {
  {
    keys = { "<CR>", "<Tab>", "za", "<2-LeftMouse>" },
    show = "<CR> <Tab> za",
    desc = "expand / collapse the entry under the cursor",
    run = function(self)
      self:toggle_entry()
    end,
  },
  {
    keys = { "zo" },
    desc = "expand the entry under the cursor",
    run = function(self)
      self:set_entry_collapsed(false)
    end,
  },
  {
    keys = { "zc" },
    desc = "collapse the entry under the cursor",
    run = function(self)
      self:set_entry_collapsed(true)
    end,
  },
  {
    keys = { "<C-l>", "zR" },
    desc = "expand all entries",
    run = function(self)
      self:set_collapsed(false)
    end,
  },
  {
    keys = { "<C-h>", "<BS>", "zM" },
    desc = "collapse all entries (first line only)",
    run = function(self)
      self:set_collapsed(true)
    end,
  },
  {
    keys = { "<C-e>" },
    desc = "flip between all expanded / all collapsed",
    run = function(self)
      self:set_collapsed()
    end,
  },
  {
    keys = { "<C-j>", "+" },
    desc = "load older entries",
    run = function(self)
      self:load_more("older")
    end,
  },
  {
    keys = { "<C-k>", "-" },
    desc = "unload the last loaded older page (with on_unload), else load newer entries",
    run = function(self)
      -- unloading is for callers that move their page cursor back (`on_unload`): without one the next
      -- `+` would skip the unloaded page
      if not (type(self.opts.on_unload) == "function" and self:unload_older()) then
        self:load_more("newer")
      end
    end,
  },
  {
    keys = { "?", "g?" },
    desc = "this cheatsheet",
    run = function(self)
      self:toggle_cheatsheet()
    end,
  },
  {
    keys = { "q", "<Esc>" },
    desc = "close",
    run = function(self)
      self:close()
    end,
  },
}

---@internal
---@param opts Lib.UI.Kit.MessageLog.Opts
---@return string[]
local function cheatsheet_lines(opts)
  local width = 0
  for _, k in ipairs(KEYS) do
    width = math.max(width, vim.fn.strdisplaywidth(k.show or table.concat(k.keys, " ")))
  end
  local lines = {}
  for _, k in ipairs(KEYS) do
    local label = k.show or table.concat(k.keys, " ")
    local pad = (" "):rep(width - vim.fn.strdisplaywidth(label))
    lines[#lines + 1] = (" %s%s   %s "):format(label, pad, k.desc)
  end
  for _, extra in ipairs(opts.extra_cheatsheet_lines or {}) do
    lines[#lines + 1] = " " .. extra .. " "
  end
  return lines
end

---Show the key list (a `lib.nvim.ui.kit.viewer`) over the log, or close it again if it is up.
---The log stays open behind it, and the focus comes back to it.
function Handle:toggle_cheatsheet()
  if self._cheat and self._cheat:is_valid() then
    self._cheat:close()
    return
  end
  -- Before the viewer opens: entering it fires WinLeave on the log at once.
  self:_suspend_focus_close()
  local cheat = require("lib.nvim.ui.kit.viewer").open({
    title = "message log -- keys",
    lines = cheatsheet_lines(self.opts),
  })
  if not cheat then
    self:_arm_focus_close()
    return
  end
  self._cheat = cheat
  -- The keys that opened the sheet close it again, next to the viewer's own q/<Esc>.
  for _, lhs in ipairs({ "?", "g?" }) do
    vim.keymap.set("n", lhs, function()
      cheat:close()
    end, {
      buffer = cheat.bufnr,
      nowait = true,
      silent = true,
      desc = "message log: close the cheatsheet",
    })
  end
  cheat:on_close(function()
    self._cheat = nil
    vim.schedule(function()
      if not self.surf:is_valid() then
        return
      end
      if vim.api.nvim_get_current_win() == self.surf.winid then
        self:_arm_focus_close()
      elseif self.opts.close_on_focus_lost ~= false then
        -- The focus went somewhere else while the sheet was up: what the log would
        -- have done on its own, had the sheet not been in the way.
        self:close()
      else
        self:_arm_focus_close()
      end
    end)
  end)
end

---Open the popup. Returns nil if the underlying window could not be
---created (same failure contract as `lib.nvim.ui.kit.surface.open`).
---@param opts Lib.UI.Kit.MessageLog.Opts
---@return Lib.UI.Kit.MessageLog.Handle|nil
function M.open(opts)
  opts = opts or {}
  local now_ms_fn = opts.now_ms or function()
    return vim.uv.hrtime() / 1e6
  end

  -- The keys reminder is part of the title from the start (a row of its own would cost
  -- content space): set later it would lose the theme's title_pos and could fail with the
  -- window already open.
  local title = (opts.title or "message log") .. "  ? keys | <CR> fold | q close"
  local surf = surface.open({
    lines = { "" },
    theme = opts.theme,
    title = title,
    width = opts.width,
    height = opts.height,
    relative = opts.relative or "editor",
    nice_quit = true,
    enter = true,
    filetype = opts.filetype or "ui-kit-message-log",
    modifiable = false,
    -- The cursor line is what <CR>/za act on.
    wo = { cursorline = true },
  })
  if not surf then
    return nil
  end

  local self = setmetatable({
    surf = surf,
    opts = opts,
    -- A copy of the list, not of the entries: an entry is its own identity (per-entry folding,
    -- `set_entry_collapsed(value, entry)`), and callers hand over what they still own.
    entries = vim.list_slice(opts.entries or {}),
    collapsed = opts.collapsed_default == true,
    expanded = new_overrides(),
    -- `load_more` can supply older data; the caller may know better up front.
    has_more_older = type(opts.load_more) == "function" and opts.has_more_older ~= false,
    has_more_newer = false, -- newest loaded entry is "now"; nothing newer until a live append arrives
    _older_pages = {}, -- sizes of the pages `load_more("older")` prepended, newest page last
    now_ms_fn = now_ms_fn,
    _title_w = vim.fn.strdisplaywidth(title),
    _hint_gen = 0,
    _pending = {}, -- live entries parked by a fast-event `append`, see there
    _flush_scheduled = false,
    _hl_ns = HL_NS,
    _arrow_ns = ARROW_NS,
  }, Handle)

  self:_arm_focus_close()
  surf:on_close(function()
    if self._cheat and self._cheat:is_valid() then
      self._cheat:close()
    end
  end)

  -- Our own q/<Esc> go over the `nice_quit` ones: this closes the log itself, whatever
  -- the tabpage looks like.
  for _, k in ipairs(KEYS) do
    for _, lhs in ipairs(k.keys) do
      vim.keymap.set("n", lhs, function()
        k.run(self)
      end, {
        buffer = surf.bufnr,
        nowait = true,
        silent = true,
        desc = "message log: " .. k.desc,
      })
    end
  end

  self:_redraw()
  return self
end

---@type Lib.UI.Kit.MessageLogModule
return M
