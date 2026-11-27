---@module 'lib.nvim.ui.kit.viewer_keys'
--- Keys, a winbar legend and a `?` cheatsheet for a `lib.nvim.ui.kit.viewer`.
---
--- A read-only float with five bindings and nothing on screen saying so is a
--- float whose bindings nobody finds. This module is what makes a viewer
--- self-describing: the caller hands over the keys once (`opts.keys`), and
--- the winbar legend, the `?` cheatsheet and the keymaps are all derived from
--- that one list — so a view can never advertise a key it did not wire up,
--- which is the whole reason for building the legend from the entries rather
--- than writing it by hand next to the keymaps.
---
--- It started as `runtime-analysis.ui.float`, written for `:RA` reports and
--- needed a second time by `:RA startup profile`; `hover.nvim`'s status board
--- is a third consumer of the same shape. The extra options of the viewer
--- (`keys`, `table_view`, `on_lines`) are the parts that were not specific to
--- a report.
---
--- `legend`, `cheatsheet_lines` and `cheatsheet` also serve windows that are
--- not a `lib.nvim.ui.kit.viewer` (two plain splits, say): they are `require("lib.nvim.ui.kit").keys`,
--- and `Lib.UI.Kit.KeysHelpOpts` names the help key and the texts, so a view that
--- binds its help elsewhere or speaks another language does not advertise a
--- wrong `?`.
---
--- **Not in `lib.nvim`'s frozen copy of the kit** ("no new features" over
--- there, see `TESTS/kit_drift_spec.lua`): this file exists only here, and
--- `viewer.lua` only gained lines.

local M = {}

---The options of `viewer` that only this copy of the kit has (declared here,
---not in `@types/init.lua`, which lib.nvim's frozen copy mirrors line for line).
---@class Lib.UI.Kit.ViewerOpts
---@field keys? Lib.UI.Kit.ViewerKey[]                       # extra bindings; the winbar legend, the `?` cheatsheet and the keymaps are all derived from this one list
---@field desc_prefix? string                             # prefix of the keymap descriptions (default "lib.nvim.ui.kit.viewer")
---@field help_title? string                              # title of the cheatsheet (default: the viewer's title)
---@field help_filetype? string                           # filetype of the cheatsheet window (default "lib-kit-viewer-help")
---@field table_view? boolean                             # no wrap + cursorline, cursor on the first content row (an aligned, row-addressed table)
---@field on_lines? fun(bufnr: integer, lines: string[])  # runs after the first lines and after every `set_lines`, for a view that highlights its own rows
---@field help_lhs? string                               # key of the cheatsheet (default "?")
---@field help_label? string                             # its winbar legend text (default "Keys")
---@field help_desc? string                              # its cheatsheet row (default "Show this help")
---@field heading? string                                # cheatsheet heading, `%s` is the title (default "%s keys")
---@field copy_all? boolean                               # `<C-c>` copies the whole text to the clipboard (default true; false: the caller binds `<C-c>` itself)

---The help key and the texts of a legend and a cheatsheet. Every field is optional.
---@class Lib.UI.Kit.KeysHelpOpts
---@field help_lhs? string|false   # key of the cheatsheet (default "?"); false: no help entry (the caller lists it, or has none)
---@field help_label? string       # legend text of the help key (default "Keys")
---@field help_desc? string        # cheatsheet row of the help key (default "Show this help")
---@field heading? string          # cheatsheet heading and window title, `%s` is the title (default "%s keys" / "%s Keys")
---@field filetype? string         # filetype of the cheatsheet window (`cheatsheet` only; default "lib-kit-viewer-help")

---@class Lib.UI.Kit.ViewerKey
---@field lhs string
---@field desc string                       # shown in the `?` cheatsheet
---@field legend? string                    # shown in the winbar; a key without one still works, it is just not advertised there
---@field run fun(view: Lib.UI.Kit.ViewerView)

---@class Lib.UI.Kit.ViewerView
---@field bufnr integer
---@field winid integer
---@field set_lines fun(lines: string[])    # replaces the content and runs `on_lines` again, so a refresh keeps the caller's highlights
---@field set_title fun(title: string)
---@field close fun()

---The one-line key legend of a viewer's `winbar`.
---
---The help key (`? Keys` by default) is always last: it is how everything not
---worth a legend entry stays reachable. `opts.help_lhs = false` leaves it out.
---@param entries { lhs: string, legend?: string }[]
---@param opts? Lib.UI.Kit.KeysHelpOpts
---@return string
function M.legend(entries, opts)
  opts = opts or {}
  -- a `%` in a key or a text is a statusline item to the winbar (`%{...}` even evaluates an expression)
  local function plain(s)
    return (tostring(s):gsub("%%", "%%%%"))
  end
  local parts = {}
  for _, e in ipairs(entries) do
    if e.legend then
      parts[#parts + 1] = ("%%#Special#%s %%#Comment#%s"):format(plain(e.lhs), plain(e.legend))
    end
  end
  local help = opts.help_lhs == nil and "?" or opts.help_lhs
  if help then
    parts[#parts + 1] = ("%%#Special#%s %%#Comment#%s"):format(
      plain(help),
      plain(opts.help_label or "Keys")
    )
  end
  return " " .. table.concat(parts, "%#NonText#  │  ") .. "%#Normal#"
end

---`heading` with `title` put in for its `%s`. Plain substitution, not
---`string.format`: a heading with any other `%` ("100% Tasten") would raise.
---@param heading string
---@param title string
---@return string
local function fill(heading, title)
  return (heading:gsub("%%s", function()
    return title
  end))
end

---The lines of the cheatsheet for `rows`; the help key (`?` by default) is
---added last unless `opts.help_lhs` is false.
---@param title string
---@param rows { lhs: string, desc: string }[]
---@param opts? Lib.UI.Kit.KeysHelpOpts
---@return string[]
function M.cheatsheet_lines(title, rows, opts)
  opts = opts or {}
  local help = opts.help_lhs == nil and "?" or opts.help_lhs
  local widest = help and vim.fn.strdisplaywidth(help) or 1
  for _, r in ipairs(rows) do
    widest = math.max(widest, vim.fn.strdisplaywidth(r.lhs))
  end
  local lines = { "", " " .. fill(opts.heading or "%s keys", title), "" }
  -- padded by display width: `%-Ns` counts bytes, so an umlaut or `…` would drift
  local function row(lhs, desc)
    local pad = widest - vim.fn.strdisplaywidth(lhs)
    lines[#lines + 1] = ("  %s%s   %s"):format(lhs, string.rep(" ", pad), desc)
  end
  for _, r in ipairs(rows) do
    row(r.lhs, r.desc)
  end
  if help then
    row(help, opts.help_desc or "Show this help")
  end
  lines[#lines + 1] = ""
  return lines
end

---Open the cheatsheet of a viewer, or of any window with keys of its own.
---@param title string
---@param rows { lhs: string, desc: string }[]
---@param opts? string|Lib.UI.Kit.KeysHelpOpts  a string is the filetype (the older call)
---@return Lib.UI.Kit.Surface|nil
function M.cheatsheet(title, rows, opts)
  if type(opts) == "string" then
    opts = { filetype = opts }
  end
  opts = opts or {}
  local lines = M.cheatsheet_lines(title, rows, opts)
  local width = 40
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  return require("lib.nvim.ui.kit.viewer").open({
    lines = lines,
    title = opts.heading and fill(opts.heading, title) or (title .. " Keys"),
    filetype = opts.filetype or "lib-kit-viewer-help",
    width = math.min(width + 2, math.floor(vim.o.columns * 0.9)),
    height = math.min(#lines, math.floor(vim.o.lines * 0.8)),
  })
end

---Wire `opts.keys`, `opts.table_view` and `opts.on_lines` onto a viewer that
---is already open. Called by `lib.nvim.ui.kit.viewer` and nowhere else.
---@param surf Lib.UI.Kit.Surface
---@param opts Lib.UI.Kit.ViewerOpts
---@return nil
function M.attach(surf, opts)
  local api = vim.api
  local keys = opts.keys
  local prefix = opts.desc_prefix or "lib.nvim.ui.kit.viewer"
  local lines = api.nvim_buf_get_lines(surf.bufnr, 0, -1, false)

  ---@type Lib.UI.Kit.KeysHelpOpts
  local help = {
    help_lhs = opts.help_lhs or "?",
    help_label = opts.help_label,
    help_desc = opts.help_desc,
    heading = opts.heading,
    filetype = opts.help_filetype,
  }

  if keys and api.nvim_win_is_valid(surf.winid) then
    api.nvim_set_option_value("winbar", M.legend(keys, help), { win = surf.winid })
    -- The winbar takes a row out of a height that was sized to the content;
    -- give it back (a height the caller chose is theirs).
    if opts.height == nil then
      local h = api.nvim_win_get_height(surf.winid)
      pcall(api.nvim_win_set_height, surf.winid, math.min(h + 1, math.max(1, vim.o.lines - 6)))
    end
  end

  if opts.table_view and api.nvim_win_is_valid(surf.winid) then
    -- A wrapped row of an aligned table destroys the alignment that is the
    -- point of it, and a row-addressed view has to show which row is current.
    api.nvim_set_option_value("wrap", false, { win = surf.winid })
    api.nvim_set_option_value("cursorline", true, { win = surf.winid })
    -- Line 1 is the heading row: start on the first content row.
    pcall(api.nvim_win_set_cursor, surf.winid, { math.min(2, #lines), 0 })
  end

  local on_lines = opts.on_lines
  if on_lines then
    on_lines(surf.bufnr, lines)
    -- A refresh must not drop the caller's decoration: the heading row would
    -- look like an ordinary row from then on.
    local raw = surf.set_lines
    surf.set_lines = function(self, fresh)
      raw(self, fresh)
      on_lines(self.bufnr, fresh)
    end
  end

  if not keys then
    return
  end

  ---@type Lib.UI.Kit.ViewerView
  local view = {
    bufnr = surf.bufnr,
    winid = surf.winid,
    set_lines = function(fresh)
      surf:set_lines(fresh)
    end,
    set_title = function(title)
      surf:set_title(title)
    end,
    close = function()
      surf:close()
    end,
  }

  local km = { noremap = true, silent = true, buffer = surf.bufnr }
  local keymap = require("lib.nvim.bindings.keymap")
  local rows = { { lhs = "j/k", desc = "Move" } }
  for _, k in ipairs(keys) do
    rows[#rows + 1] = { lhs = k.lhs, desc = k.desc }
    keymap("n", k.lhs, function()
      k.run(view)
    end, km, prefix .. ": " .. k.desc)
  end
  rows[#rows + 1] = { lhs = "q, <Esc>", desc = "Close" }

  local help_title = opts.help_title or vim.trim(opts.title or "Viewer")
  keymap("n", help.help_lhs, function()
    M.cheatsheet(help_title, rows, help)
  end, km, prefix .. ": show keymap cheatsheet")
end

return M
