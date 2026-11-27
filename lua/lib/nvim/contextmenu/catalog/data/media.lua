---@module 'lib.nvim.contextmenu.catalog.data.media'
---`media.integrations.menu` (the media hub dashboard) offers the actions that fit the kind of
---the row, or of the whole mark set (only batchable ones then), so the rows are not fixed:
---one placeholder row stands for them (like `filetree.tree_actions`). An action whose tool is
---missing stays visible, greyed, with the reason as its key text.
---@type Lib.ContextMenu.Catalog.Block
return {
  plugin = "media",
  source = "media.integrations.menu",
  defaults = {
    context = { "dashboard-row", "file" },
    needs = { "path" },
    requires = { plugins = { "media", "lib.nvim.contextmenu" } },
    effect = "modify",
  },
  entries = {
    {
      id = "kind_actions",
      label = "<media action>",
      group = "media",
      note = "dynamic: from `media.hub.actions` by the kind of the row(s); see that module for the list",
    },
  },
}
