---@module 'lib.nvim.contextmenu.catalog.data.lsp'
---`lsp.integrations.menu` builds its fly-outs from the keymaps the plugin registered
---(`require("lsp").status().keymaps`, grouped by name), so the rows are not fixed: one
---placeholder row stands for them (like `filetree.tree_actions`).
---@type Lib.ContextMenu.Catalog.Block
return {
  plugin = "lsp",
  source = "lsp.integrations.menu",
  defaults = {
    context = { "line", "buffer", "selection" },
    needs = { "buffer" },
    requires = { plugins = { "lsp", "ui.contextmenu" } },
    effect = "navigate",
  },
  entries = {
    {
      id = "keymap_actions",
      label = "<LSP keymap action>",
      group = "lsp",
      note = "dynamic: one fly-out per keymap group, one entry per registered LSP keymap (label = its description, key shown); keymaps whose `requires` module is missing are left out",
    },
  },
}
