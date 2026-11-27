---@module 'lib.nvim.contextmenu.catalog.data.spotlight'
---Entries of `spotlight.integrations.menu`: highlighting every occurrence of the word under
---the cursor. The key shown comes from the spotlight keymaps.
---@type Lib.ContextMenu.Catalog.Block
return {
  plugin = "spotlight",
  source = "spotlight.integrations.menu",
  defaults = {
    context = { "line", "buffer" },
    needs = { "buffer" },
    requires = { plugins = { "spotlight", "ui.contextmenu" } },
    effect = "view",
  },
  entries = {
    { id = "toggle_here", label = "Spotlight this occurrence only", group = "spotlight" },
    { id = "toggle", label = "Spotlight every occurrence", group = "spotlight" },
    { id = "next", label = "Next occurrence", group = "spotlight", effect = "navigate" },
    { id = "prev", label = "Previous occurrence", group = "spotlight", effect = "navigate" },
    {
      id = "toggle_line",
      label = "Toggle whole-line rendering",
      group = "options",
      effect = "modify",
    },
    { id = "to_quickfix", label = "Send matches to quickfix", group = "options", effect = "open" },
    {
      id = "list",
      label = "Open spotlight list",
      group = "manage",
      context = { "list", "buffer" },
    },
    { id = "clear", label = "Clear all spotlights", group = "manage", effect = "modify" },
  },
}
