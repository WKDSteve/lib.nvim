---@module 'lib.nvim.ui.kit.menu'
--- Menu component: an anchored action list. Each item pairs a label with a
--- callback; picking an item runs its callback. Built on the native chooser
--- (lib.nvim.ui.kit.chooser), so it inherits themed selection and the same
--- navigation (j/k/arrows, <CR>, <Esc>/q).
---
--- It accepts two item shapes, because it doubles as the native renderer for
--- `lib.nvim.contextmenu` (see that module's `renderer` option):
---
--- - the kit's own `{ label = "Do X", action = fn }`, and
--- - nvzone/menu's `{ name = "Do X", cmd = fn, rtxt = "<leader>x", hl = … }`,
---   including `{ name = "separator" }` dividers and nested fly-outs
---   (`{ name = "Git", items = { … } }`, or `items = "gitsigns"` for one of
---   nvzone/menu's own `menus.*` tables).
---
--- Nesting is a **drill-down**, not a side-by-side fly-out: picking a nested
--- entry replaces the current list with its children (the chooser is a single
--- active instance). Every level below the top opens with a `Back` entry, and
--- `<BS>` does the same thing from the keyboard — a menu reached by
--- <RightMouse> has to be leavable with the mouse too. That drill-down is the
--- one behavioural difference from nvzone/menu, which opens the child in a
--- second window beside the parent.
---
--- # Layout
---
--- A row is a set of fixed-width columns, measured across the **whole** level
--- rather than per group, so everything lines up regardless of which section
--- an entry sits in:
---
--- >
---   ╭─ Clipboard ────────────────────╮
---   │   Copy All (Buffer)      <C-a> │
---   │   Git Actions        →         │
---   ╰────────────────────────────────╯
--- <
---
--- The leading glyph is an `icon` **field**, not part of `label`. That
--- distinction is the whole point: a glyph baked into the label string is
--- just text, so an item that has one is indented past every item that does
--- not, and one contributor's `"  Open"` (two spaces where a glyph was meant
--- to be — a real bug, found twice in this codebase) silently shifts a whole
--- section out of line. As a column, an icon is either present or blank, and
--- the labels align either way. `label_of` also trims, so a stray leading
--- space cannot reintroduce the problem from a caller this module does not
--- own.
---
--- # Groups
---
--- Items are partitioned into groups by `{ name = "separator" }` and by
--- heading markers (`{ __heading = true, name = "Clipboard" }`, produced by
--- `lib.nvim.contextmenu.heading`). How a group is drawn is `group_style`:
---
--- - `"box"` (default) — a titled frame per group, so a section reads as one
---   thing rather than as a run of rows between two thin lines. A level with
---   no group titles at all falls back to `"plain"`: an untitled frame says
---   nothing a divider does not, and a caller that never named its sections
---   keeps exactly the look it had.
--- - `"header"` — a titled rule above each group, no frame.
--- - `"plain"` — the pre-group look: a divider line between groups, and a
---   title (if any) as an inert heading row.

local chooser = require("lib.nvim.ui.kit.chooser")
local theme = require("lib.nvim.ui.kit.theme")
local map = require("lib.nvim.bindings.keymap")
local notify = require("lib.nvim.notify").create("[lib.nvim.ui.kit.menu]")
local strings = require("lib.lua.strings.core")

local M = {}

--- Columns between a label and its right-aligned `rtxt` hint.
local RTXT_GAP = 3

--- Columns between the icon column and the label column.
local ICON_GAP = 1

--- Columns between the label column and the submenu marker.
---
--- The marker follows the **label** column, not the row. Pushed to the right
--- edge it sits a long way from the text it belongs to and starts reading as
--- part of the frame; parked just past the longest label it stays attached to
--- the list -- which, in a menu that also carries keymap hints, puts it at
--- roughly two thirds of the width. The hint column keeps the right edge,
--- where a key is looked for.
local MARKER_GAP = 2

--- Columns of empty space at each edge of a row, so labels and `rtxt` hints
--- don't sit flush against the border. nvzone/menu spends the same budget
--- differently -- one leading space plus an `item_gap` of 5 added to the
--- window width -- but the effect it is after is this one: air around the
--- text. Since the menu passes its own width (see `open_level`), the padding
--- has to be part of the row, not slack left over in the window.
local PAD = " "

--- Marker on an entry that opens a nested list. It gets a column of its own
--- and the theme's accent, rather than trailing the label as plain text: a
--- fly-out is the one thing in a menu that says "this does not run, it goes
--- deeper", and it used to be the least visible mark on the row.
---
--- An arrow with a shaft, not a bare triangle: at one cell a triangle reads
--- as a bullet, and the shaft is what makes the direction the first thing you
--- see.
---
--- Plain Unicode, not a Nerd Font glyph: a menu that has to render on any
--- terminal is the wrong place to require a patched font. `submenu_marker`
--- overrides it if the default measures wide in a given terminal.
local SUBMENU_MARKER = "→"

--- Label and icon of the entry that walks one level back up. It exists so the
--- drill-down is usable with the mouse, which `<BS>` alone is not.
local BACK_LABEL = "Back"
local BACK_ICON = "◂"

--- Box-drawing set for a theme whose border is `"none"`. The group frames are
--- drawn into the buffer and stay meaningful without a window border to match,
--- so this falls back to a shape rather than to nothing.
local FALLBACK_GLYPHS = { tl = "╭", tr = "╮", bl = "╰", br = "╯", h = "─", v = "│" }

--- Display width -- the only measurement that matters for column alignment. A NUL byte in a
--- label or a title is the two cells it is drawn as; `strdisplaywidth()` would raise E976 on it
--- and the whole menu would not open.
---@internal
---@param s string
---@return integer
local function dw(s)
  return vim.fn.strdisplaywidth(strings.nul_safe(s))
end

--- Resolve an item's display label across both accepted shapes.
---
--- Trimmed, deliberately: contributors have twice shipped labels padded with
--- leading spaces in place of a glyph they meant to add, which pushes their
--- rows out of line with everyone else's. The icon column is the supported
--- way to put something in front of a label.
---@internal
---@param it any
---@return string
local function label_of(it)
  local s
  if type(it) ~= "table" then
    s = tostring(it)
  else
    s = tostring(it.label or it.name or it.text or "")
  end
  return strings.trim(s)
end

--- An item's icon, or the empty string. Never part of the label -- see the
--- module header for why that separation is the fix rather than a nicety.
---@internal
---@param it any
---@return string
local function icon_of(it)
  if type(it) ~= "table" or it.icon == nil then
    return ""
  end
  return tostring(it.icon)
end

--- An item's right-aligned hint text, or the empty string.
---@internal
---@param it any
---@return string
local function rtxt_of(it)
  if type(it) ~= "table" or it.rtxt == nil then
    return ""
  end
  return tostring(it.rtxt)
end

--- Resolve an item's nested children, following nvzone/menu's `items = "name"`
--- indirection into `menus.<name>`. Returns nil when the item is a leaf.
---@internal
---@param it any
---@return Lib.UI.Kit.MenuItem[]|nil
local function children_of(it)
  if type(it) ~= "table" then
    return nil
  end
  local items = it.items
  if type(items) == "string" then
    local ok, mod = pcall(require, "menus." .. items)
    if not ok or type(mod) ~= "table" then
      return nil
    end
    items = mod
  end
  if type(items) == "table" and #items > 0 then
    return items
  end
  return nil
end

--- Resolve an item's leaf action, normalizing nvzone/menu's Ex-command
--- strings into callables.
---@internal
---@param it any
---@return fun()|nil
local function action_of(it)
  if type(it) ~= "table" then
    return nil
  end
  local action = it.action or it.cb or it.cmd
  if type(action) == "function" then
    return action
  end
  if type(action) == "string" then
    return function()
      vim.cmd(action)
    end
  end
  return nil
end

--- Whether the item is nvzone/menu's divider.
---@internal
---@param it any
---@return boolean
local function is_separator(it)
  return type(it) == "table" and it.name == "separator" and it.cmd == nil and it.items == nil
end

--- Whether the item is a group heading marker rather than a row.
---@internal
---@param it any
---@return boolean
local function is_heading(it)
  return type(it) == "table" and it.__heading == true
end

--- Split a flat item list into blocks: titled/untitled groups, plus "loose"
--- blocks for items that must stay outside any frame (the `Back` entry).
---
--- A separator ends the current group; a heading starts a new one. That keeps
--- every existing caller working: a list that only ever used separators comes
--- out as the same sections it always described, now merely drawn as such.
---@internal
---@param items any[]
---@return { title?: string, loose: boolean, items: any[] }[]
local function partition(items)
  local blocks, cur = {}, nil

  local function flush()
    if cur and #cur.items > 0 then
      blocks[#blocks + 1] = cur
    end
    cur = nil
  end

  for _, it in ipairs(items) do
    if is_separator(it) then
      flush()
    elseif is_heading(it) then
      flush()
      cur = { title = label_of(it), loose = false, items = {} }
    else
      local loose = type(it) == "table" and it.__loose == true
      if cur == nil or cur.loose ~= loose then
        flush()
        cur = { title = nil, loose = loose, items = {} }
      end
      cur.items[#cur.items + 1] = it
    end
  end
  flush()

  return blocks
end

--- Pick the group style for this level.
---
--- The one override: a level with no group titles at all falls back to
--- `"plain"`. An untitled frame says nothing a divider does not already say,
--- and the fallback is what keeps this change from redrawing every menu in
--- the wild -- a caller that only ever passed separators keeps the look it
--- has, and opts into frames by naming its sections.
---@internal
---@param opts table
---@param blocks table[]
---@return "box"|"header"|"plain"
local function resolve_style(opts, blocks)
  local style = opts.group_style
  if style ~= "box" and style ~= "header" and style ~= "plain" then
    style = "box"
  end
  if style ~= "box" then
    return style
  end

  for _, b in ipairs(blocks) do
    if not b.loose and b.title ~= nil and b.title ~= "" then
      return "box"
    end
  end
  return "plain"
end

--- Measure every column across the whole level. Global, not per group: two
--- sections whose labels are indented differently from each other read as a
--- rendering fault, not as structure.
---@internal
---@param blocks table[]
---@param marker string
---@return { icon_w: integer, label_w: integer, rtxt_w: integer, marker_w: integer }
local function measure(blocks, marker)
  local cols = { icon_w = 0, label_w = 0, rtxt_w = 0, marker_w = 0 }
  for _, b in ipairs(blocks) do
    for _, it in ipairs(b.items) do
      cols.icon_w = math.max(cols.icon_w, dw(icon_of(it)))
      cols.label_w = math.max(cols.label_w, dw(label_of(it)))
      cols.rtxt_w = math.max(cols.rtxt_w, dw(rtxt_of(it)))
      if children_of(it) then
        cols.marker_w = math.max(cols.marker_w, dw(marker))
      end
    end
  end
  return cols
end

--- Total display width of a row's content, excluding frame and padding. A
--- column no item fills costs nothing.
---@internal
---@param cols table
---@return integer
local function content_width(cols)
  return (cols.icon_w > 0 and cols.icon_w + ICON_GAP or 0)
    + cols.label_w
    + (cols.rtxt_w > 0 and RTXT_GAP + cols.rtxt_w or 0)
    + (cols.marker_w > 0 and MARKER_GAP + cols.marker_w or 0)
end

--- Columns spent on each side of the content: the pad column, plus the group
--- frame's vertical rule and its inner space where one is drawn.
---@internal
---@param style string
---@return integer
local function side_width(style)
  return style == "box" and 3 or dw(PAD)
end

--- Build one item's content string and its highlight spans (byte offsets,
--- relative to the start of the content).
---@internal
---@param it any
---@param cols table
---@param marker string
---@return string content, table[] highlights
local function content_of(it, cols, marker)
  local parts, hls, off = {}, {}, 0

  local function add(text, hl_group)
    if text == "" then
      return
    end
    parts[#parts + 1] = text
    if hl_group then
      hls[#hls + 1] = { line = 0, col_start = off, col_end = off + #text, hl_group = hl_group }
    end
    off = off + #text
  end

  local tbl = type(it) == "table"
  local item_hl = tbl and it.hl or nil

  if cols.icon_w > 0 then
    local icon = icon_of(it)
    -- An icon with no highlight of its own takes the accent: colour is what
    -- makes a glyph column read as a column rather than as noise in front of
    -- the label.
    add(icon, icon ~= "" and ((tbl and it.icon_hl) or item_hl or "KitAccent") or nil)
    add(string.rep(" ", math.max(0, cols.icon_w - dw(icon)) + ICON_GAP))
  end

  local label = label_of(it)
  add(label, item_hl)
  add(string.rep(" ", math.max(0, cols.label_w - dw(label))))

  -- Marker before hint: see MARKER_GAP. Left-aligned in its column, because
  -- the column begins where the longest label ends -- that edge is the
  -- position being aimed at, not the column's right-hand end.
  if cols.marker_w > 0 then
    local mark = children_of(it) and marker or ""
    add(string.rep(" ", MARKER_GAP))
    add(mark, mark ~= "" and "KitAccent" or nil)
    add(string.rep(" ", math.max(0, cols.marker_w - dw(mark))))
  end

  if cols.rtxt_w > 0 then
    local rtxt = rtxt_of(it)
    add(string.rep(" ", RTXT_GAP + math.max(0, cols.rtxt_w - dw(rtxt))))
    add(rtxt, rtxt ~= "" and "KitMuted" or nil)
  end

  return table.concat(parts), hls
end

--- Wrap a content string in its frame (or in matching blank columns, for a
--- row outside every group), shifting the content's highlight offsets by the
--- left frame's byte length.
---@internal
---@param content string
---@param hls table[]
---@param style string
---@param framed boolean
---@param glyphs table
---@param groups { border: string, title: string }
---@return Lib.UI.Kit.RichItem
local function frame_row(content, hls, style, framed, glyphs, groups)
  local left, right = PAD, PAD
  if style == "box" then
    left = framed and (PAD .. glyphs.v .. " ") or string.rep(" ", 3)
    right = framed and (" " .. glyphs.v .. PAD) or string.rep(" ", 3)
  end

  local shift = #left
  local out = {}
  for _, h in ipairs(hls) do
    out[#out + 1] = {
      line = 0,
      col_start = h.col_start + shift,
      col_end = h.col_end + shift,
      hl_group = h.hl_group,
    }
  end
  if style == "box" and framed then
    local rstart = shift + #content + 1
    out[#out + 1] =
      { line = 0, col_start = #PAD, col_end = #PAD + #glyphs.v, hl_group = groups.border }
    out[#out + 1] =
      { line = 0, col_start = rstart, col_end = rstart + #glyphs.v, hl_group = groups.border }
  end

  return {
    lines = { left .. content .. right },
    highlights = #out > 0 and out or nil,
    -- Where the row's actual field (icon/label/marker/rtxt columns) starts
    -- and ends, byte-offsets -- the chooser's hover paint spans exactly
    -- this instead of the whole row out to (and including) the border,
    -- which read as "the whole shelf lit up" rather than "this entry is
    -- highlighted".
    hover_start_col = shift,
    hover_end_col = shift + #content,
  }
end

--- A decoration row: never selectable, and spanning the full window width.
---@internal
---@param line string
---@param hls table[]|nil
---@return Lib.UI.Kit.RichItem
local function decoration(line, hls)
  return { lines = { line }, highlights = hls, selectable = false }
end

--- Columns between a box frame's two vertical rules, for a window of `width`.
---@internal
---@param width integer
---@return integer
local function box_inner(width)
  return math.max(1, width - 2 * dw(PAD) - 2)
end

--- Minimum window width the widest group title needs in `style`, so a title
--- is never clipped by the rule it is set into.
---@internal
---@param blocks table[]
---@param style string
---@return integer
local function title_min_width(blocks, style)
  local extra = (style == "box" and 7) or (style == "header" and 4) or dw(PAD)
  local need = 0
  for _, b in ipairs(blocks) do
    if not b.loose and b.title and b.title ~= "" then
      need = math.max(need, dw(b.title) + extra)
    end
  end
  return need
end

--- A group's opening line: the box's top rule with the title set into it, the
--- header rule, or the plain heading row. Nil where the style draws none.
---@internal
---@param title string|nil
---@param style string
---@param width integer  # full window width
---@param glyphs table
---@param groups { border: string, title: string }
---@return Lib.UI.Kit.RichItem|nil
local function group_open(title, style, width, glyphs, groups)
  local titled = title ~= nil and title ~= ""

  if style == "box" then
    local inner = box_inner(width)
    local line
    if titled then
      local cap = " " .. title .. " "
      local fill = math.max(0, inner - 1 - dw(cap))
      line = PAD .. glyphs.tl .. glyphs.h .. cap .. string.rep(glyphs.h, fill) .. glyphs.tr .. PAD
    else
      line = PAD .. glyphs.tl .. string.rep(glyphs.h, inner) .. glyphs.tr .. PAD
    end
    local hls = { { line = 0, col_start = 0, col_end = #line, hl_group = groups.border } }
    if titled then
      local start = #PAD + #glyphs.tl + #glyphs.h + 1
      hls[#hls + 1] =
        { line = 0, col_start = start, col_end = start + #title, hl_group = groups.title }
    end
    return decoration(line, hls)
  end

  if not titled then
    return nil
  end

  if style == "header" then
    -- Same span as the divider it stands in for: one column of indent, and
    -- one column short of the right edge.
    local span = math.max(1, width - 2 * dw(PAD))
    local cap = " " .. title .. " "
    local fill = math.max(0, span - 1 - dw(cap))
    local line = PAD .. glyphs.h .. cap .. string.rep(glyphs.h, fill)
    local start = #PAD + #glyphs.h + 1
    return decoration(line, {
      { line = 0, col_start = 0, col_end = #line, hl_group = groups.border },
      { line = 0, col_start = start, col_end = start + #title, hl_group = groups.title },
    })
  end

  local line = PAD .. title
  return decoration(
    line,
    { { line = 0, col_start = #PAD, col_end = #line, hl_group = groups.title } }
  )
end

--- A group's closing line -- the box's bottom rule. Nothing to draw in the
--- other styles: there the next group's own opener does the separating.
---@internal
---@param style string
---@param width integer
---@param glyphs table
---@param groups { border: string, title: string }
---@return Lib.UI.Kit.RichItem|nil
local function group_close(style, width, glyphs, groups)
  if style ~= "box" then
    return nil
  end
  local line = PAD .. glyphs.bl .. string.rep(glyphs.h, box_inner(width)) .. glyphs.br .. PAD
  return decoration(
    line,
    { { line = 0, col_start = 0, col_end = #line, hl_group = groups.border } }
  )
end

--- The divider drawn between two groups in `header`/`plain` style.
---
--- Indented, and one column short of the right edge: a divider running border
--- to border reads as a second border rather than as a grouping inside one
--- menu. Same shape nvzone/menu draws.
---@internal
---@param width integer  # full window width
---@param glyphs table
---@param groups { border: string, title: string }
---@return Lib.UI.Kit.RichItem
local function divider(width, glyphs, groups)
  local line = PAD .. string.rep(glyphs.h, math.max(1, width - 2 * dw(PAD)))
  return decoration(
    line,
    { { line = 0, col_start = 0, col_end = #line, hl_group = groups.border } }
  )
end

--- The level currently on screen: `{ opts, items, raw_items, stack }`. The
--- menu is a single instance (it rides the chooser's), and every level after
--- the first reuses the same window and the same buffer -- so the chooser's
--- `on_select` and the `<BS>` mapping are wired up once, at open time, and
--- read the live level from here instead of closing over one.
---
--- `items` is **row-aligned**, not the caller's list: group frames and
--- headings take chooser rows of their own, so `on_select`'s index only means
--- anything against a list holding one slot per rendered row (`false` for
--- every decoration row).
---@type table|nil
local current = nil

--- A shallow copy of `opts` with `title` replaced -- including replaced by
--- nil, which `vim.tbl_extend("force", …)` cannot do: an absent key there
--- leaves the old value standing, so walking back to an untitled top level
--- would keep the child's title on the frame.
---@internal
---@param opts table
---@param title string|nil
---@return table
local function with_title(opts, title)
  local out = {}
  for k, v in pairs(opts) do
    out[k] = v
  end
  out.title = title
  return out
end

---@internal
---@param opts table
---@param raw_items any[]  # the level's own items, without the back entry
---@param stack table[]
---@return any[] row_items, Lib.UI.Kit.RichItem[] rows, integer width
local function build_level(opts, raw_items, stack)
  -- Below the top level, the list gets a back entry of its own. `<BS>` alone
  -- would leave the drill-down unusable with the mouse -- and <RightMouse> is
  -- how this menu is opened in the first place. `raw_items` stays the version
  -- without it, so a level pushed onto the stack doesn't grow a second back
  -- entry when it is reopened. It is `__loose`: a one-row framed "Back" box
  -- above the real sections would read as a section of its own.
  local items = raw_items
  if #stack > 0 then
    items = { { name = BACK_LABEL, icon = BACK_ICON, __back = true, __loose = true } }
    vim.list_extend(items, raw_items)
  end

  local marker = opts.submenu_marker or SUBMENU_MARKER
  local resolved = theme.resolve(opts.theme or "menu")
  local glyphs = theme.border_glyphs(resolved) or FALLBACK_GLYPHS
  -- The window `chooser.open` opens below shares the SAME `theme.apply`
  -- machinery, so this is the identical group name it will point
  -- `winhighlight` at -- fetching it here too means the frame/title
  -- decoration this function draws as buffer text always matches the
  -- window's own border color instead of a globally-shared, easily
  -- recolored-by-something-else name (see theme.lua's own doc comment on
  -- `M.window_groups`).
  local groups = theme.window_groups(resolved)

  local blocks = partition(items)
  local style = resolve_style(opts, blocks)
  local cols = measure(blocks, marker)
  local side = side_width(style)

  -- Explicit width, because the rows carry their own padding now: left to
  -- itself, make_scratch sizes to the widest line plus two, which would put
  -- all the slack on the right and none on the left. A drill-down level also
  -- gets a title (the parent's label), which must not be clipped -- the float
  -- spends two columns of it on the border corners.
  local natural = content_width(cols) + 2 * side
  local width = math.max(
    natural,
    opts.title and (dw(opts.title) + 2) or 0,
    -- A group title is set into a rule, not into a row, so it can be wider
    -- than anything the columns measured -- and a clipped section title is
    -- worse than a menu two columns wider than it had to be.
    title_min_width(blocks, style)
  )
  -- Surplus goes to the label column, the only elastic one, so every row
  -- still fills the window exactly.
  cols.label_w = cols.label_w + (width - natural)

  local rows, row_items = {}, {}
  local function push(row, item)
    rows[#rows + 1] = row
    row_items[#row_items + 1] = item
  end

  for i, block in ipairs(blocks) do
    -- Spelled as an `if`, not as `block.loose and nil or group_open(...)`:
    -- `nil` is falsy, so that idiom evaluates the right-hand side anyway and
    -- framed a loose block in an empty box.
    local open = nil
    if not block.loose then
      open = group_open(block.title, style, width, glyphs, groups)
    end
    -- In the frameless styles a titled group announces itself; an untitled
    -- one still needs the divider to be told apart from the group above it.
    if style ~= "box" and i > 1 and not open then
      push(divider(width, glyphs, groups), false)
    end
    if open then
      push(open, false)
    end
    for _, it in ipairs(block.items) do
      local content, hls = content_of(it, cols, marker)
      push(frame_row(content, hls, style, not block.loose, glyphs, groups), it)
    end
    local close = nil
    if not block.loose then
      close = group_close(style, width, glyphs, groups)
    end
    if close then
      push(close, false)
    end
  end

  return row_items, rows, width
end

---@type fun(opts: table, raw_items: any[], stack: table[], reuse: boolean): Lib.UI.Kit.Surface|nil
local open_level

--- Walk one level back up, if there is one.
---@internal
local function go_back()
  local cur = current
  if not cur then
    return
  end
  local parent = cur.stack[#cur.stack]
  if not parent then
    return
  end
  local prev_stack = vim.list_extend({}, cur.stack)
  prev_stack[#prev_stack] = nil
  open_level(with_title(cur.opts, parent.title), parent.items, prev_stack, true)
end

--- The zindex a new menu opens on: the caller's `zindex`, or else the theme's
--- `zindex.menu`, raised above every float the menu is opened from (the
--- current window, `win`, and with `mouse` the window under the pointer). A
--- menu below such a float takes the focus but cannot be seen: a snacks
--- picker's floats sit at 52-55, above the theme's 60 only by chance.
---@param opts Lib.UI.Kit.MenuOpts
---@param relative string
---@return integer
local function menu_zindex(opts, relative)
  if opts.zindex then
    return opts.zindex
  end
  local resolved = theme.resolve(opts.theme or "menu")
  local z = resolved.zindex and (resolved.zindex.menu or resolved.zindex.popup) or 50
  local wins = { vim.api.nvim_get_current_win(), opts.win }
  if relative == "mouse" then
    wins[#wins + 1] = vim.fn.getmousepos().winid
  end
  for i = 1, 3 do
    local w = wins[i]
    if w and w ~= 0 and vim.api.nvim_win_is_valid(w) then
      local cfg = vim.api.nvim_win_get_config(w)
      if cfg.relative ~= "" and (cfg.zindex or 0) >= z then
        z = cfg.zindex + 1
      end
    end
  end
  return z
end

--- Show one level of the menu. `stack` carries the ancestors, so `<BS>` and
--- the back entry can walk up without the caller knowing about nesting.
---
--- `reuse` swaps the list into the window that is already open, instead of
--- closing it and opening another. Only the level changes take it: closing
--- and reopening lets the editor underneath repaint in between, which reads
--- as the menu flashing, and it re-anchors a `relative = "mouse"` menu to
--- wherever the pointer has drifted to.
---@internal
---@param opts table
---@param raw_items any[]  # the level's own items, without the back entry
---@param stack table[]  # { { items = …, title = … }, … }, outermost first
---@param reuse boolean
---@return Lib.UI.Kit.Surface|nil
function open_level(opts, raw_items, stack, reuse)
  local items, rows, width = build_level(opts, raw_items, stack)
  current = { opts = opts, items = items, raw_items = raw_items, stack = stack }

  if reuse and chooser.set_items({ items = rows, width = width, title = opts.title }) then
    return nil
  end

  -- `mouse = true` is nvzone/menu's spelling for "anchor at the pointer";
  -- Neovim's own `relative = "mouse"` does exactly that, so it needs no
  -- coordinate arithmetic here. Passing `win` only makes sense against
  -- `relative = "win"`, so it implies that value when `relative` itself is
  -- left unset.
  local relative = opts.relative or (opts.win and "win") or (opts.mouse and "mouse") or "cursor"

  local surf = chooser.open({
    items = rows,
    width = width,
    title = opts.title,
    theme = opts.theme or "menu",
    relative = relative,
    -- A menu is picked from, not navigated in: hide the block cursor so the
    -- highlighted row is the only thing saying where you are, let one left
    -- click choose, and dismiss on a click or focus change elsewhere. Every
    -- one of these is off by default in the chooser because it is shared
    -- with select/picker/compare, where they would be wrong.
    hide_cursor = opts.hide_cursor ~= false,
    single_click = opts.single_click ~= false,
    close_on_focus_lost = opts.close_on_focus_lost ~= false,
    -- The row under the pointer selects itself as you move over it, so the
    -- one you are about to click is never a guess.
    hover = opts.hover ~= false,
    -- And light the row that was picked before acting on it. A menu entry is
    -- a button; a button that changes the screen with no acknowledgement
    -- leaves you unsure which row you actually hit.
    flash_on_select = opts.flash_on_select ~= false,
    flash_ms = opts.flash_ms,
    -- The menu owns the window across levels; only a leaf closes it, and it
    -- does so itself, below.
    close_on_select = false,
    win = opts.win,
    anchor = opts.anchor,
    row = opts.row,
    col = opts.col,
    zindex = menu_zindex(opts, relative),
    on_select = function(_, idx)
      local cur = current
      local it = cur and cur.items[idx]
      -- `false` is a decoration row. The chooser already refuses to submit on
      -- one (they are `selectable = false`), so this is belt and braces, not
      -- the guard the drawing relies on.
      if not it then
        return
      end
      if it.__back then
        go_back()
        return
      end
      local nested = children_of(it)
      if nested then
        local next_stack = vim.list_extend({}, cur.stack)
        next_stack[#next_stack + 1] = { items = cur.raw_items, title = cur.opts.title }
        open_level(with_title(cur.opts, label_of(it)), nested, next_stack, true)
        return
      end
      -- A leaf ends the menu. Close before running, so an action that opens
      -- a window of its own doesn't have to work around this one.
      M.close()
      local action = action_of(it)
      if action then
        action()
      end
    end,
  })

  -- One mapping for the life of the window: the buffer survives every level
  -- change, and go_back reads the live level rather than a captured one.
  if surf then
    map("n", "<BS>", go_back, {
      buffer = surf.bufnr,
      nowait = true,
      record = false, -- throwaway buffer-local key: not recorded (see lib.nvim.ui.kit.chooser's `mo`)
      desc = "kit.menu: back to parent menu",
    })
  end

  return surf
end

--- Open an action menu.
---@param opts Lib.UI.Kit.MenuOpts
---@return Lib.UI.Kit.Surface|nil
function M.open(opts)
  opts = opts or {}
  local items = opts.items or {}
  if type(items) ~= "table" or #items == 0 then
    notify.error("menu: `items` is required and must be non-empty")
    return nil
  end
  -- Never `reuse`: a chooser that happens to be open here belongs to
  -- something else (a select, a picker) and must not be taken over.
  return open_level(opts, items, {}, false)
end

--- Close the menu if one is open (it shares the chooser's single instance).
function M.close()
  current = nil
  chooser.close()
end

--- Whether a menu (or any other chooser-backed component) is open.
---@return boolean
function M.is_open()
  return chooser.is_open()
end

return M
