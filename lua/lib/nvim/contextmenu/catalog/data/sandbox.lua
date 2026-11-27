---@module 'lib.nvim.contextmenu.catalog.data.sandbox'
---`sandbox.integrations.menu` turns the `keys` of a list view into entries (label = the key's
---description, capitalised; the row under the cursor is the item). The rows depend on the
---view, so one placeholder row stands for them (like `filetree.tree_actions`).
---@type Lib.ContextMenu.Catalog.Block
return {
  plugin = "sandbox",
  source = "sandbox.integrations.menu",
  defaults = {
    context = { "list", "line" },
    needs = { "item" },
    requires = { plugins = { "sandbox", "ui.contextmenu" } },
    effect = "modify",
  },
  entries = {
    {
      id = "list_actions",
      label = "List-view actions",
      group = "list",
      note = "dynamic: one entry per key of the list view; entries that need an item are hidden when the cursor is not on a row",
    },
  },
}
