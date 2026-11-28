---@meta
---@module 'lib.nvim.contextmenu.@types'

---One context-menu entry: either a leaf action (`cmd`), a nested
---fly-out (`items`), or a separator (`name = "separator"`, no other field).
---@class Lib.ContextMenu.Item
---@field name string                Label, or the literal `"separator"`
---@field cmd? function|string       Leaf action: a callback, or an Ex command string
---@field items? Lib.ContextMenu.Item[]  Nested fly-out entries (mutually exclusive with `cmd`)
---@field rtxt? string               Right-aligned hint text (usually a default keymap)
---@field icon? string               Leading glyph, drawn in a column of its own -- NOT part of `name`
---@field icon_hl? string            Highlight group for the icon
---@field hl? string                 Highlight group for the label
---@field __heading? boolean         Group heading marker (see `heading`); not a row

---Options for `require("lib.nvim.contextmenu").bind_buffer(bufnr, get_items, opts)`.
---@class Lib.ContextMenu.BindOpts
---@field keymap? string     Trigger key (default `"<RightMouse>"`)
---@field modes? string[]    Modes to bind in (default `{ "n", "v" }`)
---@field mouse? boolean     Pass `{ mouse = true }` to `menu.open` (default `true`)
---@field desc? string       Keymap description (default `"Context menu"`)

---@alias Lib.ContextMenu.ItemsProvider fun(): Lib.ContextMenu.Item[]

---Presentation extras for `entry` / `submenu`. `icon` is a field rather than
---something a caller prefixes onto the label on purpose: the kit renderer
---gives icons a column, so labels stay aligned whether or not an entry has
---one.
---@class Lib.ContextMenu.ItemOpts
---@field icon? string     Leading glyph (one display cell)
---@field icon_hl? string  Highlight group for the icon
---@field hl? string       Highlight group for the label

---Which component draws the menu: only the kit (`lib.nvim.ui.kit.menu`).
---`setup` warns once about any other value and keeps the kit.
---@alias Lib.ContextMenu.Renderer "kit"

---Options for `require("lib.nvim.contextmenu").open(items, opts)`.
---@class Lib.ContextMenu.OpenOpts
---@field mouse? boolean   Anchor at the mouse pointer (default `true`)
---@field title? string    Menu title
---@field theme? any       `Lib.UI.Kit.ThemeArg`
---@field group_style? "box"|"header"|"plain"  How a group is drawn; default `"box"`
---@field submenu_marker? string  Glyph marking a nested entry
---@field relative? "editor"|"cursor"|"win"|"mouse"  Explicit anchor; overrides `mouse`
---@field win? integer     Anchor window when `relative = "win"` -- e.g. to open the menu beside a plugin's own window instead of at the pointer
---@field anchor? "NW"|"NE"|"SW"|"SE"  Which corner of the menu sits at (row, col)
---@field row? integer     Explicit row, paired with `relative`/`win`
---@field col? integer     Explicit column
---@field hover? boolean   Follow the mouse without a click; default true

--- `lib.nvim.contextmenu` module surface.
---@class Lib.ContextMenu
---@field setup fun(opts?: { renderer?: Lib.ContextMenu.Renderer, native_popup?: boolean })  Sets `'mousemodel' = "extend"` by default, turning off Neovim's own built-in PopUp menu; `native_popup = true` opts back into it.
---@field renderer fun(): Lib.ContextMenu.Renderer
---@field set_enabled fun(value: boolean)  Enable/disable the renderer/trigger without touching the item builders (`ui.setup({ menu = false })`'s target)
---@field is_enabled fun(): boolean  Whether the renderer/trigger are currently active -- for `:checkhealth` and tests
---@field entry fun(available: any, label: string, fn: function, rtxt?: string, opts?: Lib.ContextMenu.ItemOpts): Lib.ContextMenu.Item|nil
---@field heading fun(title: string): Lib.ContextMenu.Item
---@field group fun(out: Lib.ContextMenu.Item[], ...: Lib.ContextMenu.Item|nil): boolean
---@field submenu fun(label: string, items: Lib.ContextMenu.Item[], opts?: Lib.ContextMenu.ItemOpts): Lib.ContextMenu.Item|nil
---@field open fun(items: Lib.ContextMenu.Item[], opts?: Lib.ContextMenu.OpenOpts): Lib.UI.Kit.Surface|nil  Returns the kit surface (nil when disabled or `items` is empty)
---@field bind_buffer fun(bufnr: integer, get_items: Lib.ContextMenu.ItemsProvider, opts?: Lib.ContextMenu.BindOpts)
