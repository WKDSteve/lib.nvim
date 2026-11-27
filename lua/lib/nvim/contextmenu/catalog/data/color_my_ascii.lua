---@module 'lib.nvim.contextmenu.catalog.data.color_my_ascii'
---Entries of `color_my_ascii.integrations.menu`: ASCII-art highlighting and the `:Fence`
---commands. The fence entries are hidden when the cursor is not in a fenced block; `wrap`
---creates a fence, so it has no such precondition.
---@type Lib.ContextMenu.Catalog.Block
return {
  plugin = "color_my_ascii",
  source = "color_my_ascii.integrations.menu",
  defaults = {
    context = { "line", "buffer" },
    needs = { "buffer" },
    requires = { plugins = { "color_my_ascii", "ui.contextmenu" } },
    effect = "modify",
  },
  entries = {
    { id = "toggle", label = "Toggle ASCII highlighting", group = "highlight", effect = "view" },
    { id = "scheme", label = "Switch color scheme", group = "highlight", effect = "view" },
    {
      id = "char_info",
      label = "Highlight info for character under cursor",
      group = "highlight",
      effect = "view",
    },
    { id = "fence_yank", label = "Yank fence content", group = "fence", effect = "copy" },
    { id = "fence_split", label = "Open fence in split", group = "fence", effect = "open" },
    {
      id = "fence_run",
      label = "Run fence content",
      group = "fence",
      effect = "external",
    },
    { id = "fence_format", label = "Format fence", group = "fence-edit" },
    {
      id = "fence_align",
      label = "Straighten box-drawing edges (align)",
      group = "fence-edit",
    },
    { id = "fence_unwrap", label = "Unwrap fence under cursor", group = "fence-edit" },
    {
      id = "fence_wrap",
      label = "Wrap line in a fence",
      group = "fence-new",
      context = { "line", "selection" },
    },
  },
}
