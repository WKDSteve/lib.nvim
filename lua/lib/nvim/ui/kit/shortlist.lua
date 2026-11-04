---@module 'lib.nvim.ui.kit.shortlist'
--- Promptless, stacked list+preview for short lists that don't need fuzzy
--- search -- a handful of items (marks, recent buffers, ...), not a haystack
--- to filter through a prompt. Preview sits above the results, both full
--- width -- more room for a real file path than the `picker` template's
--- side-by-side columns leave.
---
--- Built on `lib.nvim.ui.kit.chooser` for the results pane -- j/k/arrows wrap-around,
--- <CR> selects, <Esc>/q closes, all for free -- exactly the use its own
--- module doc calls out ("a caller building extra keymaps/behavior on top of
--- current_item()/move() outside of on_select"). The preview is a plain
--- `lib.nvim.ui.kit.surface`, kept in sync via `CursorMoved` on the chooser's buffer,
--- so any way the cursor gets there (keys, mouse, `gg`/`G`) updates it, not
--- just the couple of keys a hand-rolled `move()` would have covered.
---
--- `render(item, surface)` is the same one-contract rendering `lib.nvim.ui.kit.compare`
--- uses: fill `surface:set_lines(...)` for text, or draw directly against
--- `surface.winid`'s geometry for anything else (an image, a diff).
---
--- The preview is a real, read-only window (the caller decides how read-only
--- through `preview_bo`), so it can be worked in, not only looked at:
---
---   - from the list, `<C-f>`/`<C-p>` (or <PageDown>/<PageUp>) scroll it one
---     page, `<C-d>`/`<C-u>` half a page;
---   - `<Tab>` (and `<C-w>w`, `<C-w><C-w>`, `<C-w>W`) hop between list and
---     preview -- the cycle is closed on purpose: left alone, `<C-w>w` walks on
---     into the editor window underneath and leaves the popup stranded on top;
---     `<C-w>j`/`<C-w>k` do the same, but direction-aware (preview sits above
---     the list, so `<C-w>j` only does something from the preview, `<C-w>k`
---     only from the list -- otherwise a no-op, not a jump the wrong way);
---   - inside the preview everything that reads works (motions, `/`, visual,
---     `y`), `<CR>` submits at the cursor line (`on_preview_submit`), `q` and
---     `<Esc>` close the popup;
---   - focus leaving both windows for any other one closes the popup;
---   - the focused window's border is lit and each window carries a footer
---     with the keys that work in it.
---
--- All of it is on by default and switchable: `preview_keys = false` drops the
--- keys, a group set to `false` (or a list of your own) changes one,
--- `close_on_leave = false` and `hints = false` the other two.
---
--- `number_keys = true` (off by default) adds harpoon-style digits: `1`..`9` in
--- the list submit the first nine entries the way `<CR>` does
--- (`on_submit(item, idx)`), and each of those lines starts with its digit.
--- `number_keys = { label = false }` keeps the keys but leaves drawing the digit
--- to the caller's `format_item`, which gets the index as its third argument.

local layout = require("lib.nvim.ui.kit.layout")
local chooser = require("lib.nvim.ui.kit.chooser")
local surface = require("lib.nvim.ui.kit.surface")
local theme = require("lib.nvim.ui.kit.theme")
local notify = require("lib.nvim.notify").create("[lib.nvim.ui.kit.shortlist]")
local autocmd = require("lib.nvim.bindings.autocmd")
local map = require("lib.nvim.bindings.keymap")

local api = vim.api

local M = {}

---@class Lib.UI.Kit.ShortlistKeys
---@field scroll_down? string[]|string|false  # preview, one page down (list and preview)
---@field scroll_up? string[]|string|false    # preview, one page up (list and preview)
---@field half_down? string[]|string|false    # preview, half a page down
---@field half_up? string[]|string|false      # preview, half a page up
---@field focus? string[]|string|false        # hop between list and preview
---@field cycle? string[]|string|false        # window-cycle keys, kept inside the popup
---@field close? string[]|string|false        # close the popup, from the preview and from the list (`q`/`<Esc>` on the list are the chooser's own and always there); add a key that also opens the popup to make it a toggle
---@field submit? string[]|string|false       # submit at the cursor line (preview only)

---@class Lib.UI.Kit.ShortlistNumberKeys
---@field label? boolean  # draw the digit before the entry (default true); false = the caller's `format_item(item, width, idx)` shows it itself

--- How many entries get a digit key: `1`..`9`.
local MAX_DIGIT = 9

--- The cells the digit label takes in front of an entry: the digit and a space.
local LABEL_WIDTH = 2

--- The keys of the preview pane. `<C-p>` scrolls up on purpose although Vim
--- means "one line up" by it: it pairs with `<C-f>`, and `<C-b>` stays as the
--- alias for whoever's fingers know Vim's own pair.
---@type Lib.UI.Kit.ShortlistKeys
local DEFAULT_KEYS = {
  scroll_down = { "<C-f>", "<PageDown>" },
  scroll_up = { "<C-p>", "<C-b>", "<PageUp>" },
  half_down = { "<C-d>" },
  half_up = { "<C-u>" },
  focus = { "<Tab>" },
  cycle = { "<C-w>w", "<C-w><C-w>", "<C-w>W", "<C-w>j", "<C-w>k" },
  close = { "q", "<Esc>" },
  submit = { "<CR>" },
}

--- What each scroll group does to the preview window (Vim's own commands, so a
--- page is a page as Vim counts it: the window height less two lines of
--- overlap).
---@type table<string, string>
local SCROLL = {
  scroll_down = "<C-f>",
  scroll_up = "<C-b>",
  half_down = "<C-d>",
  half_up = "<C-u>",
}

---@internal
--- One key group as the caller wrote it, cleaned up: the non-empty strings of a
--- list (a bare string counts as a list of one), or nil when none is left. The
--- keys come from a user's config, and a bad entry must not get as far as the
--- `map` call (which raises on an empty lhs) or the hint text (which cannot join
--- a table): both run after the windows are up, and would leave them open with
--- no handle to close them.
---@param v any
---@return string[]|nil
local function key_list(v)
  if type(v) == "string" then
    v = { v }
  end
  if type(v) ~= "table" then
    return nil
  end
  local out = {}
  for _, key in ipairs(v) do
    if type(key) == "string" and key ~= "" then
      out[#out + 1] = key
    end
  end
  return #out > 0 and out or nil
end

---@internal
--- Merge the caller's `preview_keys` over the defaults, group by group. `false`
--- (as a whole, or for one group) means "none"; a list replaces that group.
---@param given any
---@return table<string, string[]>
local function resolve_keys(given)
  local out = {}
  if given == false then
    return out
  end
  local over = type(given) == "table" and given or {}
  for group, default in pairs(DEFAULT_KEYS) do
    local v = over[group]
    if v == nil then
      out[group] = default
    else
      out[group] = key_list(v)
    end
  end
  return out
end

---@internal
--- The caller's `number_keys` as a table, or nil when the option is off. Only
--- `true` and a table turn it on; anything else (a typo'd string, a number)
--- leaves the list as it was rather than guessing.
---@param given any
---@return { label: boolean }|nil
local function resolve_number_keys(given)
  if given == true then
    return { label = true }
  end
  if type(given) == "table" then
    return { label = given.label ~= false }
  end
  return nil
end

---@internal
--- Point the `FloatBorder` entry of a window's 'winhighlight' at `group`, leaving
--- every other entry alone (the chooser adds its own `CursorLine` mapping).
---@param winid integer
---@param group string
local function set_border_group(winid, group)
  if not api.nvim_win_is_valid(winid) then
    return
  end
  local cur = api.nvim_get_option_value("winhighlight", { win = winid })
  local parts, seen = {}, false
  for entry in cur:gmatch("[^,]+") do
    if entry:match("^FloatBorder:") then
      parts[#parts + 1] = "FloatBorder:" .. group
      seen = true
    else
      parts[#parts + 1] = entry
    end
  end
  if not seen then
    parts[#parts + 1] = "FloatBorder:" .. group
  end
  pcall(api.nvim_set_option_value, "winhighlight", table.concat(parts, ","), { win = winid })
end

---@internal
--- The footer text of one window: the keys that work there, as configured. A
--- group that is off leaves its hint out.
---@param keys table<string, string[]>
---@param in_preview boolean
---@param digits integer  # how many entries have a digit key (0 = none)
---@return string
local function hint_text(keys, in_preview, digits)
  local parts = {}
  if keys.scroll_down and keys.scroll_up then
    parts[#parts + 1] = keys.scroll_down[1] .. "/" .. keys.scroll_up[1] .. " scroll"
  end
  if in_preview then
    parts[#parts + 1] = "y copy"
    if keys.submit then
      parts[#parts + 1] = keys.submit[1] .. " open at line"
    end
    if keys.focus then
      parts[#parts + 1] = keys.focus[1] .. " list"
    end
    if keys.close then
      parts[#parts + 1] = keys.close[1] .. " close"
    end
  else
    if keys.focus then
      parts[#parts + 1] = keys.focus[1] .. " preview"
    end
    -- The list's own keys: the chooser binds these itself.
    parts[#parts + 1] = "<CR> open"
    if digits == 1 then
      parts[#parts + 1] = "1 open"
    elseif digits > 1 then
      parts[#parts + 1] = ("1-%d open"):format(digits)
    end
    parts[#parts + 1] = "q close"
  end
  return " " .. table.concat(parts, "  ") .. " "
end

---@internal
--- Put `text` in the window's footer -- only where the float has a border to
--- carry one.
---@param winid integer
---@param text string
local function set_footer(winid, text)
  if not api.nvim_win_is_valid(winid) then
    return
  end
  local border = api.nvim_win_get_config(winid).border
  if type(border) ~= "table" or #border == 0 then
    return
  end
  pcall(api.nvim_win_set_config, winid, {
    footer = { { text, theme.scoped_group(winid, "KitMuted") } },
    footer_pos = "center",
  })
end

--- Open a promptless, stacked list+preview.
---
--- `opts.on_preview_submit(item, idx, pos)` runs for <CR> inside the preview,
--- after the popup has closed; `pos` is `{ row = <1-based>, col = <0-based> }`,
--- the preview cursor, so a file preview can open the file at that line. Without
--- it, <CR> in the preview falls back to `on_submit(item, idx)`.
---
--- `opts.number_keys` (see the module doc): `true` binds `1`..`9` in the list to
--- the first nine entries and labels them; `{ label = false }` binds without
--- labelling, for a `format_item` that draws the digit itself.
---@param opts table  # { items, format_item?(item, width, idx)->string, render(item, surface), on_submit?(item, idx), on_preview_submit?(item, idx, pos), on_close?(), title?, preview_title?, preview_filetype?, preview_bo?, theme?, initial_index?, spec?, preview_keys?: Lib.UI.Kit.ShortlistKeys|false, close_on_leave?: boolean, hints?: boolean, number_keys?: boolean|Lib.UI.Kit.ShortlistNumberKeys }
---@return table|nil handle  # { close(), current_item(), current_index(), results, preview }
function M.open(opts)
  opts = opts or {}
  local items = opts.items
  if type(items) ~= "table" or #items == 0 then
    notify.error("shortlist: `items` is required and must be non-empty")
    return nil
  end
  local render = opts.render
  if type(render) ~= "function" then
    notify.error("shortlist: opts.render(item, surface) is required")
    return nil
  end
  local format_item = opts.format_item
    or function(item, _width, _idx)
      return tostring(item)
    end
  local number_keys = resolve_number_keys(opts.number_keys)
  local digits = number_keys and math.min(MAX_DIGIT, #items) or 0

  --- One results line: the caller's text, behind its digit when the shortlist
  --- draws the labels (entries past the ninth get blanks, so the text lines up).
  --- The caller's width budget shrinks by the label, so a path it truncates to
  --- fit still fits.
  ---@param idx integer
  ---@param raw any
  ---@param width integer
  ---@return string
  local function format_line(idx, raw, width)
    if not (number_keys and number_keys.label) then
      return format_item(raw, width, idx)
    end
    local label = idx <= MAX_DIGIT and tostring(idx) or " "
    return label .. " " .. format_item(raw, math.max(1, width - LABEL_WIDTH), idx)
  end
  --- Also the fallback for `<CR>` in the preview, which adds the cursor position.
  ---@type fun(item: any, idx: integer, pos?: { row: integer, col: integer })
  local on_submit = opts.on_submit or function(_item, _idx) end

  local spec = vim.deepcopy(layout.templates.shortlist.spec)
  if type(opts.spec) == "table" then
    spec = vim.tbl_deep_extend("force", spec, opts.spec)
  end
  local geo = layout.compute(spec)
  if not (geo.slots.preview and geo.slots.results) then
    notify.error("shortlist: layout template is missing the preview/results slots")
    return nil
  end

  -- The window `surface.open`/`chooser.open` below open share the SAME
  -- `theme.apply` machinery, so this is the identical group name they will
  -- point `winhighlight` at -- resolving it here too means `update_focus`
  -- (below) can restore the idle border to this popup's own color instead of
  -- a globally-shared, easily recolored-by-something-else fixed name (see
  -- theme.lua's own doc comment on `M.window_groups`).
  local groups = theme.window_groups(theme.resolve(opts.theme))
  local border_idle = groups.border
  -- A `winhighlight` target is not remapped by the window's `KitAccent` entry.
  local border_focused = groups.accent

  local preview_surf = surface.open(vim.tbl_extend("force", geo.slots.preview, {
    theme = opts.theme,
    filetype = opts.preview_filetype,
    title = opts.preview_title or "preview",
    bo = opts.preview_bo,
  }))
  if not preview_surf then
    return nil
  end

  local chooser_items = {}
  for i, raw in ipairs(items) do
    chooser_items[i] = { lines = { format_line(i, raw, geo.slots.results.width) }, data = raw }
  end

  local results_surf = chooser.open({
    items = chooser_items,
    relative = geo.slots.results.relative,
    row = geo.slots.results.row,
    col = geo.slots.results.col,
    width = geo.slots.results.width,
    height = geo.slots.results.height,
    theme = opts.theme,
    title = opts.title,
    initial_index = opts.initial_index,
    on_select = function(picked, idx)
      on_submit(picked.data, idx)
    end,
  })
  if not results_surf then
    preview_surf:close()
    return nil
  end

  -- `chooser.open` already closed any previously open chooser (single active
  -- instance); a bare `q`/`<Esc>`/click-away closes ONLY the results window,
  -- so the preview pane must be torn down from the same lifecycle, not left
  -- to linger behind it -- and this also covers the on_select path above,
  -- since `deliver()` closes the results surface before that callback runs.
  -- Wired both ways: `results_surf` is `chooser`'s single active instance,
  -- so a new chooser-based popup taking over already tears this one (and
  -- hence `preview_surf`, via the callback below) down. But `preview_surf`
  -- is a plain, focusable surface of its own -- nothing stops the user
  -- moving focus there and closing it directly (`<C-w>c`, `:q`) -- and
  -- without this second direction that left `results_surf` open and
  -- preview-less, its CursorMoved/VimResized autocmds still firing against
  -- a dead preview.
  results_surf:on_close(function()
    preview_surf:close()
  end)
  preview_surf:on_close(function()
    results_surf:close()
  end)
  if opts.on_close then
    results_surf:on_close(opts.on_close)
  end

  local function render_current()
    local entry = chooser.current_item()
    if not (entry and preview_surf:is_valid()) then
      return
    end
    local ok, err = pcall(render, entry.data, preview_surf)
    if not ok then
      -- Say so instead of leaving the previous item's text under this item's
      -- row: with the keys of the preview pane, <CR> there acts on what it
      -- shows (opens this item at that text's line).
      local first = tostring(err):match("[^\n]*")
      pcall(preview_surf.set_lines, preview_surf, { "preview failed: " .. first })
      pcall(api.nvim_win_set_cursor, preview_surf.winid, { 1, 0 })
    end
  end
  render_current()

  local sync_group = autocmd.group("lib_kit_shortlist_" .. results_surf.winid, true)
  autocmd.create("CursorMoved", render_current, {
    group = sync_group,
    buffer = results_surf.bufnr,
    record = false, -- throwaway per-popup hook: not recorded (see lib.nvim.ui.kit.surface)
    desc = "lib.nvim.ui.kit.shortlist: keep the preview in sync with the selection",
  })

  local keys = resolve_keys(opts.preview_keys)
  local hints = opts.hints ~= false

  --- Both windows still there? (A close callback may run mid-way.)
  ---@return boolean
  local function alive()
    return results_surf:is_valid() and preview_surf:is_valid()
  end

  local function apply_hints()
    if not (hints and alive()) then
      return
    end
    set_footer(results_surf.winid, hint_text(keys, false, digits))
    set_footer(preview_surf.winid, hint_text(keys, true, digits))
  end

  local function update_focus()
    if not (hints and alive()) then
      return
    end
    local cur = api.nvim_get_current_win()
    set_border_group(
      results_surf.winid,
      cur == results_surf.winid and border_focused or border_idle
    )
    set_border_group(
      preview_surf.winid,
      cur == preview_surf.winid and border_focused or border_idle
    )
  end

  autocmd.create("VimResized", function()
    local g = layout.compute(spec)
    if results_surf:is_valid() then
      pcall(api.nvim_win_set_config, results_surf.winid, g.slots.results)
      -- Re-run format_item at the new width too, not just reposition the
      -- window: a caller's format_item (e.g. sessions.nvim's marks menu)
      -- budgets a truncated path against the width it was given, so a
      -- resize that grows the window must re-format to actually show more
      -- of the path, and a resize that shrinks it must re-truncate rather
      -- than leave a line wider than the new window. One line per item
      -- both before and after, so this never disturbs chooser's own row
      -- bookkeeping or the current selection.
      local new_lines = {}
      for i, raw in ipairs(items) do
        new_lines[i] = format_line(i, raw, g.slots.results.width)
      end
      results_surf:set_lines(new_lines)
    end
    if preview_surf:is_valid() then
      pcall(api.nvim_win_set_config, preview_surf.winid, g.slots.preview)
    end
    apply_hints()
  end, {
    group = sync_group,
    record = false, -- throwaway per-popup hook: not recorded (see lib.nvim.ui.kit.surface)
    desc = "lib.nvim.ui.kit.shortlist: keep the list sized to the editor",
  })

  -- ---------------------------------------------------------------- focus

  --- Hop between the two windows: the list's <Tab>, and the window-cycle keys
  --- (`<C-w>w` and friends), which would otherwise walk on into the editor.
  local function toggle_focus()
    if not alive() then
      return
    end
    if api.nvim_get_current_win() == preview_surf.winid then
      results_surf:focus()
    else
      preview_surf:focus()
    end
  end

  --- `<C-w>j`/`<C-w>k`, direction-aware unlike `toggle_focus`: preview sits
  --- above the list in this template, so "down" only does something FROM the
  --- preview and "up" only FROM the list -- the edge (list pressing `<C-w>j`,
  --- preview pressing `<C-w>k`) is a no-op, the way a real `<C-w>j`/`<C-w>k`
  --- does nothing at the edge of a window layout, rather than jumping the
  --- wrong way the way a blind toggle would.
  ---@param dir "up"|"down"
  local function move_focus(dir)
    if not alive() then
      return
    end
    local cur = api.nvim_get_current_win()
    if dir == "down" and cur == preview_surf.winid then
      results_surf:focus()
    elseif dir == "up" and cur == results_surf.winid then
      preview_surf:focus()
    end
  end

  --- Which of `keys.cycle`'s entries are direction-aware (`move_focus`) rather
  --- than a blind toggle (`toggle_focus`, same as `<C-w>w` and friends).
  ---@type table<string, "up"|"down">
  local CYCLE_DIRECTION = { ["<C-w>j"] = "down", ["<C-w>k"] = "up" }

  --- Focus left both popup windows for some other one (a click into the editor,
  --- `<C-w>h`, a tab switch): the popup is not wanted any more. Checked after
  --- the event, since a window switch can pass through a window on its way.
  local function close_when_left()
    vim.schedule(function()
      if not alive() then
        return
      end
      local cur = api.nvim_get_current_win()
      if cur ~= results_surf.winid and cur ~= preview_surf.winid then
        results_surf:close()
      end
    end)
  end

  autocmd.create("WinEnter", function()
    update_focus()
    if opts.close_on_leave ~= false then
      close_when_left()
    end
  end, {
    group = sync_group,
    record = false, -- throwaway per-popup hook: not recorded (see lib.nvim.ui.kit.surface)
    desc = "lib.nvim.ui.kit.shortlist: light the focused window, close when focus leaves",
  })

  -- --------------------------------------------------------------- scrolling

  --- Scroll the preview by one of the SCROLL groups, whichever window the
  --- caller is in.
  ---@param group string
  local function scroll(group)
    if not preview_surf:is_valid() then
      return
    end
    local key = vim.keycode(SCROLL[group])
    api.nvim_win_call(preview_surf.winid, function()
      pcall(vim.cmd.normal, { args = { key }, bang = true })
    end)
  end

  --- <CR> inside the preview: hand the item and the cursor line to the caller.
  local function submit_from_preview()
    if not alive() then
      return
    end
    local entry = chooser.current_item()
    local idx = chooser.current_index()
    if not (entry and idx) then
      return
    end
    local cursor = api.nvim_win_get_cursor(preview_surf.winid)
    results_surf:close()
    local handler = opts.on_preview_submit or on_submit
    handler(entry.data, idx, { row = cursor[1], col = cursor[2] })
  end

  -- ------------------------------------------------------------------- keys

  -- `record = false`: these are throwaway buffer-local keys of a float, and the
  -- keymap records are keyed by buffer number -- a new one every time the popup
  -- opens -- so recording them would add a few dozen entries per open, forever.
  local list_map = { buffer = results_surf.bufnr, nowait = true, record = false }
  local view_map = { buffer = preview_surf.bufnr, nowait = true, record = false }

  for group in pairs(SCROLL) do
    for _, lhs in ipairs(keys[group] or {}) do
      local function go()
        scroll(group)
      end
      map("n", lhs, go, list_map, "lib.nvim.ui.kit.shortlist: scroll the preview")
      map("n", lhs, go, view_map, "lib.nvim.ui.kit.shortlist: scroll the preview")
    end
  end
  for _, lhs in ipairs(keys.focus or {}) do
    map("n", lhs, toggle_focus, list_map, "lib.nvim.ui.kit.shortlist: focus the preview")
    map("n", lhs, toggle_focus, view_map, "lib.nvim.ui.kit.shortlist: focus the list")
  end
  for _, lhs in ipairs(keys.cycle or {}) do
    local dir = CYCLE_DIRECTION[lhs]
    local fn = dir and function()
      move_focus(dir)
    end or toggle_focus
    map("n", lhs, fn, list_map, "lib.nvim.ui.kit.shortlist: cycle within the popup")
    map("n", lhs, fn, view_map, "lib.nvim.ui.kit.shortlist: cycle within the popup")
  end
  for _, lhs in ipairs(keys.close or {}) do
    local function close_all()
      results_surf:close()
    end
    map("n", lhs, close_all, view_map, "lib.nvim.ui.kit.shortlist: close")
    -- The list closes on `q`/`<Esc>` by itself (chooser); any other close key
    -- -- `<C-e>` as the toggle for the key that opened the popup -- is bound
    -- there too, or it would only work once focus had hopped to the preview.
    if lhs ~= "q" and lhs ~= "<Esc>" then
      map("n", lhs, close_all, list_map, "lib.nvim.ui.kit.shortlist: close")
    end
  end
  for _, lhs in ipairs(keys.submit or {}) do
    map(
      "n",
      lhs,
      submit_from_preview,
      view_map,
      "lib.nvim.ui.kit.shortlist: open at the cursor line"
    )
  end

  -- Digits in the list only: in the preview they stay counts (`5j`).
  for idx = 1, digits do
    map("n", tostring(idx), function()
      if not results_surf:is_valid() then
        return
      end
      -- Closed first, the way the chooser closes before `on_select`: a handler
      -- that opens a file must not land it in the popup.
      results_surf:close()
      on_submit(items[idx], idx)
    end, list_map, ("lib.nvim.ui.kit.shortlist: open entry %d"):format(idx))
  end

  results_surf:on_close(function()
    pcall(api.nvim_del_augroup_by_id, sync_group)
  end)

  -- The popup always starts in the list -- the preview is something you go into
  -- (`<Tab>`/`<C-w>w`), not something it opens into. `chooser.open()`'s own
  -- `enter = true`, called after `preview_surf` above, already leaves focus here in
  -- practice; making it explicit stops that ordering from being the only thing this
  -- invariant rests on.
  results_surf:focus()

  apply_hints()
  update_focus()

  return {
    close = function()
      results_surf:close()
    end,
    current_item = function()
      local entry = chooser.current_item()
      return entry and entry.data or nil
    end,
    current_index = chooser.current_index,
    results = results_surf,
    preview = preview_surf,
  }
end

return M
