---@module 'lib.nvim.contextmenu'
--- Building blocks for context-menu entries: a self-gating item builder
--- (`entry`/`group`/`submenu`), a renderer (`open`), and a mouse-trigger
--- binder (`bind_buffer`).
---
--- The menu is drawn by the kit (`lib.nvim.ui.kit.menu`): no third-party
--- dependency, themed like every other kit surface. Nothing is `require()`d
--- until a menu actually opens.
---
--- `setup{...}` also turns off Neovim's OWN built-in right-click menu
--- (`:h popup-menu`) by default, which pops up under the editor's default
--- `'mousemodel'` (`popup_setpos`) wherever a click lands on no active
--- `<RightMouse>` mapping at all -- a blank line past a tree's last node,
--- say. From the user's chair that reads as "a different context menu
--- sometimes appears", indistinguishable at a glance from this one
--- degrading. Opt back into vanilla Neovim behaviour with
--- `setup{ native_popup = true }`.
---
--- Two integration shapes this supports (see filetree.nvim and
--- markdown.nvim for the two live reference implementations):
---
--- "Owns its buffer" (a plugin-created UI: a tree, a dashboard, a list-view)
--- >lua
---   -- integrations/menu.lua
---   local nerd = require("lib.nvim.ui.nerd_font")
---
---   function M.items()
---     local out = {}
---     contextmenu.group(out,
---       contextmenu.heading("My Plugin"),
---       contextmenu.entry(feature("x") ~= nil, "Do X", do_x, "<leader>x", {
---         icon = nerd.glyph("F0AD", "*"),
---       })
---     )
---     return out
---   end
---
---   -- features/ui/context_menu/init.lua, on the plugin's own buffer
---   contextmenu.bind_buffer(bufnr, require("myplugin.integrations.menu").items)
--- <
--- "Contributes only" (acts on ordinary filetype-scoped buffers): the plugin
--- ships just `integrations/menu.lua` (`items`/`submenu`) with no trigger
--- code at all; a host (typically the user's own RightMouse dispatcher)
--- composes `submenu(...)` into its own menu for the relevant filetype.

require("lib.nvim.contextmenu.@types")

local notify = require("lib.nvim.notify").create("[lib.nvim.contextmenu]")

local M = {}

--- Whether `M.open`/`M.bind_buffer` actually render/trigger anything --
--- `ui.setup({ menu = false })`'s target. `false` means the menu never
--- RENDERS, not that it is installed-but-silent: the item builders
--- (`entry`/`group`/`submenu`/`heading`) stay unconditional. Default `true`:
--- this is an opt-OUT for a host, not something to opt into.
---@type boolean
local enabled = true

--- Enable or disable the renderer/trigger without touching the data
--- builders. `bind_buffer`'s trigger delegates to `M.open`, so gating `open`
--- alone covers both (a disabled menu still runs `get_items()` on
--- `<RightMouse>`, cheap, and it just never renders).
---@param value boolean
---@return nil
function M.set_enabled(value)
  enabled = value
end

--- Whether the renderer/trigger are currently active (`:checkhealth`, tests).
---@return boolean
function M.is_enabled()
  return enabled
end

---@internal
--- Say once per session that a `renderer` other than `"kit"` was asked for
--- and the kit draws anyway. A value left in a user's config from an older
--- release (`"auto"`, or a renderer that no longer exists) must not stop the
--- setup, only be pointed out.
local _warned_renderer = false
local function warn_renderer_once(r)
  if _warned_renderer then
    return
  end
  _warned_renderer = true
  notify.warn(
    ("contextmenu: renderer %q is not available — the kit (lib.nvim.ui.kit.menu) draws the menu; drop the option"):format(
      tostring(r)
    )
  )
end

--- Check the renderer option, and (by default) suppress Neovim's built-in
--- right-click menu. Call once, from the host's setup path.
---@param opts? { renderer?: Lib.ContextMenu.Renderer, native_popup?: boolean }
function M.setup(opts)
  opts = opts or {}

  local r = opts.renderer
  if r ~= nil and r ~= "kit" then
    warn_renderer_once(r)
  end

  if opts.native_popup ~= true then
    -- The only other legal `'mousemodel'` value: replaces Neovim's built-in
    -- PopUp menu with the classic visual-extend click, everywhere, in every
    -- mode -- not just wherever this module's own callers happen to bind a
    -- mapping. Opt-out, not opt-in: any call to `setup()` at all disables the
    -- native menu unless it explicitly asks to keep it (`native_popup =
    -- true`) -- a host that never mentions the option still gets the sane
    -- default, with nothing for it to remember to configure.
    vim.o.mousemodel = "extend"
  end
end

--- The renderer that draws the menu: always `"kit"`.
---@return Lib.ContextMenu.Renderer
function M.renderer()
  return "kit"
end

--- Build one entry, or nil when `available` is falsy — lets a caller write a
--- flat list of `entry(...)` calls and rely on `group`/`vim.tbl_filter` to
--- drop the gaps, instead of hand-writing `if` guards around every item.
---
--- A leading glyph belongs in `opts.icon`, never in `label`. The kit renderer
--- draws icons as a column of their own, so an entry with one lines up with
--- an entry without; a glyph inside the label is just text, and indents that
--- row past every other. (Two contributors have shipped labels that begin
--- with two spaces where a glyph was meant to go — the icon column is what
--- makes that mistake impossible to make.)
---@param available any  Truthy to include the entry, falsy to omit it
---@param label string
---@param fn function     Called with no arguments when the entry is picked
---@param rtxt? string    Right-aligned hint text (usually a default keymap)
---@param opts? { icon?: string, icon_hl?: string, hl?: string }
---@return Lib.ContextMenu.Item|nil
function M.entry(available, label, fn, rtxt, opts)
  if not available then
    return nil
  end
  opts = opts or {}
  return {
    name = label,
    rtxt = rtxt,
    cmd = fn,
    icon = opts.icon,
    icon_hl = opts.icon_hl,
    hl = opts.hl,
  }
end

--- A group heading: an inert marker that titles the group it opens. Pass it
--- as the first argument to `group`.
---
--- It is a marker rather than a `title` parameter on `group` because gating
--- has to reach it: a section whose every entry is unavailable must not leave
--- its title standing over nothing, and `group` already knows which of its
--- arguments survived.
---@param title string
---@return Lib.ContextMenu.Item
function M.heading(title)
  return { name = title, __heading = true }
end

--- Append every non-nil argument to `out`, preceded by a separator when
--- `out` already holds entries and at least one argument survives (the
--- `{ name = "separator" }` entry the kit menu draws as a divider).
---
--- Takes varargs, not a table: a table literal like `{ entry(...), nil,
--- entry(...) }` loses everything past the first gap under `ipairs`/`#`
--- (Lua doesn't define a length for a table with holes), silently dropping
--- later entries whenever an earlier one in the same group gates off.
--- Varargs don't have that problem — `select('#', ...)` counts every
--- position, nil or not — so call this as
--- `group(out, entry(...), entry(...), entry(...))`, unpacking a
--- pre-built list with `group(out, unpack(list))` if you already have one.
---@param out Lib.ContextMenu.Item[]
---@param ... Lib.ContextMenu.Item|nil
---@return boolean added # Whether anything from the arguments was appended
function M.group(out, ...)
  local n = select("#", ...)
  local compact = {}
  for i = 1, n do
    local item = select(i, ...)
    if item ~= nil then
      compact[#compact + 1] = item
    end
  end

  -- A leading `heading(...)` titles the group. It is dropped along with the
  -- group when every real entry gated off: a title over an empty section is
  -- worse than no section at all.
  local heading = nil
  if compact[1] and compact[1].__heading then
    heading = table.remove(compact, 1)
  end

  if #compact == 0 then
    return false
  end
  -- A heading already starts a new group for the renderer; a separator on top
  -- of it would only add an empty divider line above the title.
  if #out > 0 and not heading then
    out[#out + 1] = { name = "separator" }
  end
  if heading then
    out[#out + 1] = heading
  end
  for _, item in ipairs(compact) do
    out[#out + 1] = item
  end
  return true
end

--- Wrap `items` as one nested fly-out entry (the "Lsp Actions ▸" shape).
--- Returns nil when `items` is empty, so callers can chain it straight into
--- a host's composed list without an extra emptiness check:
--- `vim.list_extend(composed, { contextmenu.submenu("My Plugin", items) })`
--- would insert a stray nil — check the return instead, as in the usage
--- examples above.
---@param label string
---@param items Lib.ContextMenu.Item[]
---@param opts? { icon?: string, icon_hl?: string, hl?: string }
---@return Lib.ContextMenu.Item|nil
function M.submenu(label, items, opts)
  if type(items) ~= "table" or #items == 0 then
    return nil
  end
  opts = opts or {}
  return {
    name = label,
    items = items,
    icon = opts.icon,
    icon_hl = opts.icon_hl,
    hl = opts.hl,
  }
end

--- Open a menu with the kit renderer. `items` is a built item list.
---
--- This is the single place the renderer is reached from: callers build
--- items with `entry`/`group`/`submenu` and never touch the kit menu
--- themselves.
---
--- Returns the kit surface handle -- a caller that needs to know when the
--- menu closes (to clear a highlight it set for the duration, say) can
--- `surf:on_close(cb)` on it; one that does not can just ignore the return.
--- Returns nil when the menu is disabled or `items` is empty.
---@param items Lib.ContextMenu.Item[]
---@param opts? Lib.ContextMenu.OpenOpts
---@return Lib.UI.Kit.Surface|nil
function M.open(items, opts)
  if not enabled then
    return nil
  end

  opts = opts or {}
  local mouse = opts.mouse ~= false

  if type(items) ~= "table" or #items == 0 then
    return nil
  end

  return require("lib.nvim.ui.kit.menu").open({
    items = items,
    title = opts.title,
    theme = opts.theme,
    group_style = opts.group_style,
    submenu_marker = opts.submenu_marker,
    relative = opts.relative,
    win = opts.win,
    anchor = opts.anchor,
    row = opts.row,
    col = opts.col,
    hover = opts.hover,
    mouse = mouse,
  })
end

--- Bind a mouse trigger on `bufnr` that opens `get_items()` with the kit
--- renderer. Nothing is required at bind time, so this is safe to call
--- unconditionally from a plugin's setup path; the kit menu is loaded when
--- the trigger fires.
---@param bufnr integer
---@param get_items Lib.ContextMenu.ItemsProvider
---@param opts? { keymap?: string, modes?: string[], mouse?: boolean, desc?: string }
function M.bind_buffer(bufnr, get_items, opts)
  opts = opts or {}
  local keymap = opts.keymap or "<RightMouse>"
  local modes = opts.modes or { "n", "v" }
  local mouse = opts.mouse ~= false

  vim.keymap.set(modes, keymap, function()
    -- `get_items` is supplied by another plugin; a raised error here must
    -- not turn a right-click into a raw traceback (ERR-01).
    local ok, items = pcall(get_items)
    if not ok then
      -- `items` here is whatever the provider raised, not necessarily a
      -- string -- a table with a throwing `__tostring` would otherwise make
      -- `format`'s own `tostring` call re-raise, uncaught, right back into
      -- this callback (the exact class of failure ERR-01 exists to prevent).
      local msg_ok, msg = pcall(tostring, items)
      notify.error(
        ("contextmenu: items provider failed: %s"):format(
          msg_ok and msg or "<error message unavailable>"
        )
      )
      return
    end
    if type(items) ~= "table" or #items == 0 then
      return
    end

    M.open(items, { mouse = mouse })
  end, {
    buffer = bufnr,
    silent = true,
    desc = opts.desc or "Context menu",
  })
end

---@type Lib.ContextMenu
return M
