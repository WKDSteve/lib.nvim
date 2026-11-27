---@module 'lib.nvim.contextmenu.catalog.data.gitsuite'
---Entries of the gitsuite dashboard (`gitsuite.features.dashboard.view`): one row per
---repository. It binds the menu itself with `bind_buffer` (`dashboard.context_menu`). Over a
---mark set the menu offers the batch rows, otherwise the row under the cursor, plus the
---whole-dashboard rows. The key shown is the dashboard key of the same action.
---@type Lib.ContextMenu.Catalog.Block
return {
  plugin = "gitsuite",
  source = "gitsuite.features.dashboard.view",
  defaults = {
    context = { "dashboard-row", "git-repo" },
    needs = { "buffer" },
    requires = { plugins = { "gitsuite", "lib.nvim.contextmenu" }, tools = { "git" } },
    effect = "modify",
  },
  entries = {
    { id = "open", label = "Open", group = "repo", rtxt = "<CR>", effect = "open" },
    { id = "push", label = "Push", group = "repo", rtxt = "p", effect = "external" },
    { id = "pull", label = "Pull", group = "repo", rtxt = "P", effect = "external" },
    { id = "fetch", label = "Fetch", group = "repo", rtxt = "f", effect = "external" },
    { id = "status", label = "Status", group = "repo", rtxt = "S", effect = "view" },
    {
      id = "lazygit",
      label = "Lazygit",
      group = "repo",
      rtxt = "L",
      effect = "external",
      requires = { plugins = { "gitsuite", "lib.nvim.contextmenu" }, tools = { "lazygit" } },
    },
    { id = "reread", label = "Re-read", group = "repo", rtxt = "r", effect = "view" },
    {
      id = "mark",
      label = "Mark / Unmark",
      group = "repo",
      rtxt = "m",
      note = "label follows the mark state",
    },
    { id = "yank_path", label = "Yank path", group = "repo", rtxt = "y", effect = "copy" },
    { id = "remove", label = "Remove from page", group = "repo", rtxt = "x" },
    {
      id = "marked_push",
      label = "Push (marked)",
      group = "marked",
      effect = "external",
      rtxt = "p",
      note = "shown instead of the row entries while repositories are marked",
    },
    {
      id = "marked_pull",
      label = "Pull (marked)",
      group = "marked",
      rtxt = "P",
      effect = "external",
    },
    {
      id = "marked_fetch",
      label = "Fetch (marked)",
      group = "marked",
      rtxt = "f",
      effect = "external",
    },
    { id = "marked_clear", label = "Clear marks", group = "marked", rtxt = "M", effect = "view" },
    {
      id = "fetch_all",
      label = "Fetch all",
      group = "dashboard",
      rtxt = "gf",
      effect = "external",
    },
    {
      id = "pull_all",
      label = "Pull all…",
      group = "dashboard",
      rtxt = "gP",
      effect = "external",
    },
    { id = "push_all", label = "Push all", group = "dashboard", rtxt = "gp", effect = "external" },
    {
      id = "update_all",
      label = "Update all",
      group = "dashboard",
      rtxt = "gu",
      effect = "external",
    },
    {
      id = "sync_pending",
      label = "Sync pending",
      group = "dashboard",
      rtxt = "gs",
      effect = "external",
    },
    { id = "sync_all", label = "Sync all", group = "dashboard", rtxt = "gS", effect = "external" },
    { id = "export", label = "Export…", group = "dashboard", rtxt = "E", effect = "copy" },
  },
}
