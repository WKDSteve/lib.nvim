---@module 'lib.nvim.window.make_scratch'
---Create a scratch buffer inside a floating window in one call.
---
---Returns `winid, bufnr` (or `nil` on failure). The buffer is an unlisted
---`nofile` scratch buffer wiped on hide; the window is a centered float with
---sensible overlay defaults (no numbers, no signcolumn, no wrap) that callers
---can override. Optionally attaches `nice_quit` so the overlay closes with
---`q` / `<Esc>` straight away.

require("lib.nvim.window.@types")

local api = vim.api
local notify = require("lib.nvim.notify").create("[lib.nvim.window.make_scratch]")
local nice_quit = require("lib.nvim.window.nice_quit")
local max_float_width = require("lib.nvim.window.max_float_width")
local nul_safe = require("lib.lua.strings.core").nul_safe
local printable_title = require("lib.nvim.window.printable_title")

---Window-local options applied to every scratch float unless overridden via `opts.wo`.
---
---`scrolloff`/`sidescrolloff` at 0: both are WINDOW-local but fall back to the
---global value when unset, and a user who keeps the cursor away from the
---edges globally (`scrolloff = 8`, or the "keep it centered" `999`) gets that
---same margin enforced in a scratch float too -- which, once the float is
---shorter than its content, means scrolling can show blank space past the
---buffer's last line purely to satisfy a margin nothing here asked for. A
---list/menu/chooser overlay should only ever scroll to reveal more of its
---own content, never past the end of it.
local DEFAULT_WO = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  wrap = false,
  cursorline = false,
  scrolloff = 0,
  sidescrolloff = 0,
}

---@internal
---Widest display column count across `lines` (multibyte-aware). A NUL byte in a line is
---measured as the `^@` it is drawn as (`nul_safe`): `strdisplaywidth()` raises E976 on one,
---and a single such line in a list of case titles would keep the whole list from opening.
---@param lines string[]
---@return integer
local function content_width(lines)
  local max = 0
  for _, line in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(nul_safe(line))
    if w > max then
      max = w
    end
  end
  return max
end

---@internal
---Display width of a title or footer as it is drawn: a string (after `printable_title`, which spells out
---control characters) or a list of `{ text, hl }` chunks; anything else is 0.
---@param label any
---@return integer
local function label_width(label)
  if type(label) == "string" then
    return vim.fn.strdisplaywidth(nul_safe(printable_title(label)))
  end
  if type(label) ~= "table" then
    return 0
  end
  local w = 0
  for _, chunk in ipairs(label) do
    if type(chunk) == "table" and type(chunk[1]) == "string" then
      w = w + vim.fn.strdisplaywidth(nul_safe(chunk[1]))
    end
  end
  return w
end

---@internal
---Clamp `value` into the inclusive `[lo, hi]` range.
---@param value integer
---@param lo integer
---@param hi integer
---@return integer
local function clamp(value, lo, hi)
  return math.max(lo, math.min(value, hi))
end

---@internal
---A size given as a fraction of the editor, or as absolute cells.
---
---Strictly between 0 and 1 is a fraction of the editor; anything else is
---cells. Nearly the convention `lib.nvim.ui.kit.layout` already uses, which
---existed there while every caller of this function wrote
---`math.floor(vim.o.columns * 0.8)` by hand -- nine plugins, twenty-six call
---sites, the same arithmetic each time.
---
---The one difference is deliberate and load-bearing: `layout` treats `1` as
---"the whole thing", this treats it as one cell. A pane one cell tall is
---meaningless, so `layout` can spend the value on the fraction; a *float* one
---cell tall is every prompt in this library -- `kit.input`, `kit.live_input`,
---both progress styles and the statusline all pass `height = 1` and mean it.
---Reading that as 100% would open a full-height window for a one-line prompt.
---
---`0` is not a fraction either: it returns nil, so the caller falls back to
---sizing from the content rather than opening something invisible.
---@param size number|nil
---@param total integer
---@return integer|nil
local function resolve_size(size, total)
  if type(size) ~= "number" or size <= 0 then
    return nil
  end
  if size < 1 then
    return math.floor(size * total)
  end
  return math.floor(size)
end

---@internal
---Resolve width/height from opts and content, clamped to the editor size.
---@param lines string[]
---@param opts Lib.Window.MakeScratchOpts
---@return integer width
---@return integer height
local function resolve_dimensions(lines, opts)
  local max_w = max_float_width()
  local max_h = math.max(1, vim.o.lines - 4)

  -- +2 leaves room for a border; fall back to a comfortable default whenever
  -- that derived width is 2 cells or less -- not only for literally empty
  -- `lines`, but also non-empty lines that render at zero display width.
  -- The fallback is for *derived* widths only: an explicit width of 1 or 2 is
  -- what the caller asked for (`@field width` promises "`1` is one cell") and
  -- used to be silently widened to 60 columns. A fraction that rounds down to
  -- zero cells counts as "not given".
  local given_w = resolve_size(opts.width, vim.o.columns)
  if given_w and given_w < 1 then
    given_w = nil
  end
  local want_w = given_w or (content_width(lines) + 2)
  if not given_w and want_w <= 2 then
    want_w = math.min(60, max_w)
  end
  -- A title or footer wider than the content is drawn cut (`<port all to` for "Export all to"): a derived
  -- width makes room for it, with the same 2 cells as the content. Only with a border, the one place they
  -- are drawn; an explicit width stays what the caller asked for.
  if not given_w and opts.border ~= nil and opts.border ~= "none" and opts.border ~= "" then
    local edge = math.max(label_width(opts.title), label_width(opts.footer))
    if edge > 0 then
      want_w = math.max(want_w, edge + 2)
    end
  end

  -- Same "a fraction rounding to zero cells counts as not given" rule as
  -- width above: `0` is truthy in Lua, so `resolve_size(...) or #lines` never
  -- reached `#lines` for one -- an explicit height fraction small enough to
  -- floor to zero rows was forced straight to a bare 1 row, discarding
  -- however many lines the caller actually passed.
  local given_h = resolve_size(opts.height, vim.o.lines)
  if given_h and given_h < 1 then
    given_h = nil
  end
  local want_h = given_h or #lines
  if want_h < 1 then
    want_h = 1
  end

  return clamp(want_w, 1, max_w), clamp(want_h, 1, max_h)
end

---@internal
---Create the scratch buffer and fill it with `lines`.
---@param lines string[]
---@param opts Lib.Window.MakeScratchOpts
---@return integer|nil bufnr
local function create_buffer(lines, opts)
  local ok, bufnr = pcall(api.nvim_create_buf, false, true)
  if not ok or not bufnr or bufnr == 0 then
    notify.error("make_scratch: failed to create buffer")
    return nil
  end

  api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
  api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
  api.nvim_set_option_value("swapfile", false, { buf = bufnr })

  if #lines > 0 then
    local set_ok, set_err = pcall(api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
    if not set_ok then
      -- A line with a newline in it (the API refuses those) must not leave the
      -- buffer made a few lines up behind, never shown and never wiped: take it
      -- out again and raise as before.
      pcall(api.nvim_buf_delete, bufnr, { force = true })
      error("make_scratch: " .. tostring(set_err), 0)
    end
  end

  if opts.filetype ~= nil then
    api.nvim_set_option_value("filetype", opts.filetype, { buf = bufnr })
  end

  for name, value in pairs(opts.bo or {}) do
    pcall(api.nvim_set_option_value, name, value, { buf = bufnr })
  end

  -- Lock the buffer last (default), after content and caller overrides are in.
  if opts.modifiable ~= true then
    api.nvim_set_option_value("modifiable", false, { buf = bufnr })
    api.nvim_set_option_value("modified", false, { buf = bufnr })
  end

  return bufnr
end

---@internal
---The anchor point's own on-screen row (1-based), for deciding whether a
---`relative = "cursor"`/`"mouse"` float fits below it. nil when it can't be
---determined (an unattached UI, e.g. headless) -- callers must then assume
---it fits, since there is nothing to flip against.
---@param relative string
---@return integer|nil
local function anchor_screenrow(relative)
  if relative == "mouse" then
    local ok, pos = pcall(vim.fn.getmousepos)
    return (ok and type(pos) == "table" and pos.screenrow and pos.screenrow > 0) and pos.screenrow
      or nil
  end
  if relative == "cursor" then
    local ok, row = pcall(vim.fn.screenrow)
    return (ok and type(row) == "number" and row > 0) and row or nil
  end
  return nil
end

---@internal
---Whether `border` draws a frame at all. `"none"` and `""` do not, and neither does a
---list of only empty strings; a footer has nowhere to go without one, and Neovim
---0.10 refuses `footer` on an unframed float outright rather than ignoring it.
---@param border string|string[]|table
---@return boolean
local function has_border(border)
  if type(border) == "string" then
    return border ~= "none" and border ~= ""
  end
  if type(border) == "table" then
    for _, part in ipairs(border) do
      local char = type(part) == "table" and part[1] or part
      if type(char) == "string" and char ~= "" then
        return true
      end
    end
    return false
  end
  return true
end

---@internal
---Build the floating-window config, centering on the editor when no position is given.
---@param width integer
---@param height integer
---@param opts Lib.Window.MakeScratchOpts
---@return table
local function build_win_config(width, height, opts)
  local relative = opts.relative or "editor"

  local row = opts.row
  local col = opts.col
  local anchor = opts.anchor

  if relative == "editor" and row == nil and col == nil then
    row = math.max(0, math.floor((vim.o.lines - height) / 2 - 1))
    col = math.max(0, math.floor((vim.o.columns - width) / 2))
  elseif relative == "cursor" or relative == "mouse" then
    -- Anchored NW with a small downward offset by default (row=1 unless the
    -- caller asked otherwise) -- the float extends DOWN from the cursor/
    -- mouse. Nothing here used to check whether that fits: a click low in
    -- the editor plus a float tall enough not to fit below it (a long
    -- context menu, say) opened anyway, extending past the bottom of the
    -- screen with no bounds check at all. Flip to anchor SW instead when it
    -- doesn't fit -- the float then extends UP from the anchor point, the
    -- way every native context menu behaves near a screen edge. An explicit
    -- `opts.anchor` opts out and always gets exactly the corner it asked for.
    row = row or 1
    col = col or 0
    if not anchor then
      anchor = "NW"
      local anchor_row = anchor_screenrow(relative)
      if anchor_row and anchor_row + row + height > vim.o.lines then
        anchor = "SW"
        row = 0
      end
    end
  end

  anchor = anchor or "NW"

  ---@type table
  local cfg = {
    relative = relative,
    anchor = anchor,
    width = width,
    height = height,
    row = row or 1,
    col = col or 0,
    border = opts.border or "rounded",
    style = "minimal",
    focusable = opts.focusable ~= false,
  }
  if relative == "win" then
    -- `nvim_open_win` requires `win` whenever `relative = "win"`; row/col are
    -- then offsets from ITS top-left corner, so a caller can position a
    -- float immediately beside another window (negative col to sit to its
    -- left, col = that window's width to sit to its right) without needing
    -- to know the float's own size in advance.
    cfg.win = opts.win
  end
  if opts.title ~= nil then
    cfg.title = printable_title(opts.title)
    if opts.title_pos ~= nil then
      cfg.title_pos = opts.title_pos
    end
  end
  -- Same treatment as the title: a footer is just as often built from a file
  -- name. Left out rather than passed on when there is no frame to put it in.
  if opts.footer ~= nil and has_border(cfg.border) then
    cfg.footer = printable_title(opts.footer)
    if opts.footer_pos ~= nil then
      cfg.footer_pos = opts.footer_pos
    end
  end
  if opts.zindex ~= nil then
    cfg.zindex = opts.zindex
  end
  return cfg
end

---Create a scratch buffer in a floating window.
---@param opts? Lib.Window.MakeScratchOpts
---@return integer|nil winid
---@return integer|nil bufnr
local function make_scratch(opts)
  opts = opts or {}
  local lines = opts.lines or {}

  local bufnr = create_buffer(lines, opts)
  if not bufnr then
    return nil, nil
  end

  local width, height = resolve_dimensions(lines, opts)
  local win_config = build_win_config(width, height, opts)

  local enter = opts.enter ~= false
  local ok, winid = pcall(api.nvim_open_win, bufnr, enter, win_config)
  if not ok or not winid or winid == 0 then
    notify.error("make_scratch: failed to create window")
    pcall(api.nvim_buf_delete, bufnr, { force = true })
    return nil, nil
  end

  -- Apply overlay window-local options, then caller overrides.
  for name, value in pairs(DEFAULT_WO) do
    pcall(api.nvim_set_option_value, name, value, { win = winid })
  end
  for name, value in pairs(opts.wo or {}) do
    pcall(api.nvim_set_option_value, name, value, { win = winid })
  end

  -- Optional: wire up q / <Esc> to close, reusing the dedicated helper.
  if opts.nice_quit then
    ---@type Lib.Window.NiceQuitOpts|nil
    local nq_opts
    if type(opts.nice_quit) == "table" then
      nq_opts = opts.nice_quit --[[@as Lib.Window.NiceQuitOpts]]
    end
    nice_quit(winid, nq_opts)
  end

  return winid, bufnr
end

return make_scratch
