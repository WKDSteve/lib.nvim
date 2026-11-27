---@module 'lib.nvim.contextmenu.catalog.data.github_stats'
---Entries of `github_stats.integrations.menu`: the dashboard. The "selected" entries are
---hidden while no repository row is selected.
---@type Lib.ContextMenu.Catalog.Block
return {
  plugin = "github_stats",
  source = "github_stats.integrations.menu",
  defaults = {
    context = { "dashboard-row", "buffer" },
    needs = { "buffer" },
    requires = { plugins = { "github_stats", "ui.contextmenu" } },
    effect = "modify",
  },
  entries = {
    { id = "show_details", label = "Show details", group = "repo", rtxt = "<CR>", effect = "view" },
    { id = "cycle_sort", label = "Cycle sort", group = "view", effect = "view" },
    { id = "cycle_range", label = "Cycle time range", group = "view", effect = "view" },
    { id = "custom_range", label = "Custom time range…", group = "view", effect = "view" },
    { id = "max_range", label = "Maximum time range", group = "view", effect = "view" },
    { id = "refresh", label = "Refresh dashboard", group = "refresh", rtxt = "r", effect = "view" },
    {
      id = "refresh_all",
      label = "Force-refresh all repositories",
      group = "refresh",
      rtxt = "R",
      effect = "external",
      note = "calls the GitHub API",
    },
    {
      id = "refresh_selected",
      label = "Force-refresh selected repository",
      group = "refresh",
      rtxt = "f",
      effect = "external",
      note = "calls the GitHub API",
    },
    {
      id = "export_selected",
      label = "Export selected…",
      group = "export",
      effect = "modify",
      cross = { "pdfport" },
      note = "the PDF format needs pdfport.nvim",
    },
  },
}
