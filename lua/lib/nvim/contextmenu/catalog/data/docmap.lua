---@module 'lib.nvim.contextmenu.catalog.data.docmap'
---`docmap.integrations.menu` builds its entries from the keys of a DocBrowse session
---(`st.keys`, filtered by mode), so the rows are not fixed: one placeholder row stands for
---them (like `filetree.tree_actions`).
---@type Lib.ContextMenu.Catalog.Block
return {
  plugin = "docmap",
  source = "docmap.integrations.menu",
  defaults = {
    context = { "list", "buffer" },
    needs = { "buffer" },
    requires = { plugins = { "docmap", "ui.contextmenu" } },
    effect = "navigate",
  },
  entries = {
    {
      id = "browse_actions",
      label = "<DocBrowse action>",
      group = "browse",
      effect = "view",
      note = "dynamic: one entry per browse key (label = its description, key shown); keys with `disabled`, `where = detail` or another mode are left out",
    },
  },
}
