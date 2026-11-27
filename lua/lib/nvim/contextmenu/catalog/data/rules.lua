---@module 'lib.nvim.contextmenu.catalog.data.rules'
---Entries of the rules review buffer (`rules.report.review`): one proposal per row. It binds
---the menu itself with `bind_buffer`, there is no `integrations.menu` module.
---@type Lib.ContextMenu.Catalog.Block
return {
  plugin = "rules",
  source = "rules.report.review",
  defaults = {
    context = { "list", "line" },
    needs = { "buffer" },
    requires = { plugins = { "rules", "lib.nvim.contextmenu" } },
    effect = "modify",
  },
  entries = {
    { id = "accept", label = "Accept", group = "proposal", rtxt = "a" },
    { id = "waive", label = "Waive", group = "proposal", rtxt = "w" },
    { id = "discard", label = "Discard", group = "proposal", rtxt = "x" },
    {
      id = "open_finding",
      label = "Open finding",
      group = "proposal",
      rtxt = "<CR>",
      effect = "open",
      note = "hidden when the proposal has no findings",
    },
  },
}
