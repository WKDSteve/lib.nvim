-- docs/EXAMPLES/kit-menu.lua
--
-- Module:   lib.nvim.ui.kit.menu (lib.nvim.ui.kit.menu)
-- Scenario: a cursor-anchored action list -- each item pairs a label with
--           a callback, and picking an item just runs that callback. This
--           is the "right-click context menu" shape: no on_select
--           dispatch to write yourself, each item already knows what it
--           does.

local kit = require("lib.nvim.ui.kit")

kit.menu({
  title = "Actions",
  items = {
    {
      label = "Rename",
      action = function()
        require("myplugin").rename_under_cursor()
      end,
    },
    {
      label = "Delete",
      action = function()
        require("myplugin").delete_under_cursor()
      end,
    },
    {
      label = "Copy path",
      action = function()
        vim.fn.setreg("+", vim.api.nvim_buf_get_name(0))
      end,
    },
  },
})

-- Bind it to a keymap for a real "context menu on demand" feel -- opens
-- anchored at the cursor by default (`relative = "cursor"`), so it behaves
-- like a native right-click menu even though it was triggered from the
-- keyboard:
vim.keymap.set("n", "<leader>m", function()
  kit.menu({
    items = {
      { label = "Go to definition", action = vim.lsp.buf.definition },
      { label = "Rename symbol", action = vim.lsp.buf.rename },
      { label = "Show references", action = vim.lsp.buf.references },
    },
  })
end, { desc = "Open the LSP action menu" })

-- ---------------------------------------------------------------------------
-- The same component also renders `lib.nvim.contextmenu` item tables, which
-- is how a right-click menu gets drawn. That
-- shape spells things differently (`name`/`cmd` instead of `label`/`action`)
-- and adds three things the plain shape has no use for: `{ name =
-- "separator" }` dividers, a right-aligned `rtxt` hint column, and nesting.
--
-- Nesting is a drill-down: picking "Git" replaces the list with its children
-- and `<BS>` walks back up. `mouse = true` anchors at the pointer
-- (`relative = "mouse"`), which is what makes it usable from <RightMouse>.
kit.menu({
  mouse = true,
  items = {
    { name = "Format buffer", cmd = "%!prettier", rtxt = "<leader>fm" },
    { name = "Code actions", cmd = vim.lsp.buf.code_action, rtxt = "<leader>ca" },
    { name = "separator" },
    {
      name = "Git",
      hl = "ExGreen",
      items = {
        { name = "Stage hunk", cmd = function() end, rtxt = "<leader>gs" },
        { name = "Reset hunk", cmd = function() end, rtxt = "<leader>gr" },
      },
    },
  },
})

-- ---------------------------------------------------------------------------
-- Icons and named sections.
--
-- `icon` is a FIELD, not something you prefix onto the label. The renderer
-- gives icons a column of their own and measures it across the whole menu, so
-- an entry with a glyph and an entry without still start their labels in the
-- same screen column. A glyph inside `name` is just text -- it indents that
-- one row, and "  Do X" (two spaces where a glyph was meant to go) looks
-- exactly like a working entry until you see it next to a real one.
--
-- `__heading` names a group. A named group is drawn as a titled frame
-- (`group_style = "box"`, the default); `"header"` draws a titled rule
-- instead, and `"plain"` is the old divider look. A menu that names no group
-- gets `"plain"` regardless -- an untitled frame says nothing a divider does
-- not.
local nerd = require("lib.nvim.ui.nerd_font")

kit.menu({
  mouse = true,
  items = {
    { name = "Clipboard", __heading = true },
    {
      name = "Copy all",
      icon = nerd.glyph("F0C5", "+"),
      cmd = "%y+",
      rtxt = "<C-a>",
    },
    { name = "Danger", __heading = true },
    {
      name = "Delete file",
      icon = nerd.glyph("F1F8", "x"),
      icon_hl = "DiagnosticError",
      cmd = function() end,
      rtxt = "df",
    },
  },
})

-- In practice you don't hand-write that table: `lib.nvim.contextmenu`'s
-- `entry`/`group`/`submenu` build it with the gating and separators handled,
-- and `contextmenu.open(items, { mouse = true })` picks the renderer.
