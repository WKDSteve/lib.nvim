---@module 'lib.nvim.contextmenu.catalog.data.gitsuite'
---Entries of the gitsuite dashboard (`gitsuite.features.dashboard.view`): one row per
---repository. It binds the menu itself with `bind_buffer` (`dashboard.context_menu`). Over a
---mark set the menu offers the batch rows, otherwise the row under the cursor, plus the
---whole-dashboard rows. The key shown is the dashboard key of the same action.
---
---The `actions_*` entries are the other menu of gitsuite: `gitsuite.integrations.menu`, the
---"Git Actions" a host composes into the menu of any file buffer ("contributes only"). Each
---routes through a `:Git` command.

---An entry of `gitsuite.integrations.menu`: a file buffer instead of a dashboard row.
---@param e table
---@return table
local function action(e)
  e.source = "gitsuite.integrations.menu"
  e.context = e.context or { "buffer", "file" }
  e.needs = e.needs or { "buffer" }
  e.requires = e.requires or { plugins = { "gitsuite" }, tools = { "git" } }
  return e
end

local WITH_GITSIGNS = { plugins = { "gitsuite", "gitsigns" }, tools = { "git" } }

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
      cross = { "terminal" },
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
    {
      id = "show_in_filetree",
      label = "Show in Filetree",
      group = "repo",
      rtxt = "T",
      effect = "navigate",
      cross = { "filetree" },
      requires = {
        plugins = { "gitsuite", "lib.nvim.contextmenu", "filetree" },
        tools = { "git" },
      },
      note = "reveals the repository in filetree.nvim; only with nothing marked and filetree set up",
    },
    { id = "yank_path", label = "Yank path", group = "repo", rtxt = "y", effect = "copy" },
    { id = "remove", label = "Remove from page", group = "repo", rtxt = "x" },
    {
      id = "marked_push",
      label = "Push",
      group = "marked",
      effect = "external",
      rtxt = "p",
      note = "shown instead of the row entries while repositories are marked",
    },
    {
      id = "marked_pull",
      label = "Pull",
      group = "marked",
      rtxt = "P",
      effect = "external",
    },
    {
      id = "marked_fetch",
      label = "Fetch",
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
    action({
      id = "actions_stage_hunk",
      label = "Stage Hunk",
      group = "hunks",
      rtxt = "sh",
      context = { "line", "file" },
      requires = WITH_GITSIGNS,
    }),
    action({
      id = "actions_reset_hunk",
      label = "Reset Hunk",
      group = "hunks",
      rtxt = "rh",
      context = { "line", "file" },
      requires = WITH_GITSIGNS,
    }),
    action({
      id = "actions_stage_buffer",
      label = "Stage Buffer",
      group = "hunks",
      rtxt = "sb",
      requires = WITH_GITSIGNS,
    }),
    action({
      id = "actions_reset_buffer",
      label = "Reset Buffer",
      group = "hunks",
      rtxt = "rb",
      requires = WITH_GITSIGNS,
    }),
    action({
      id = "actions_preview_hunk",
      label = "Preview Hunk",
      group = "hunks",
      rtxt = "hp",
      effect = "view",
      context = { "line", "file" },
      note = "falls back to `:Git diff head` (diff.nvim) without gitsigns",
    }),
    action({
      id = "actions_blame_line",
      label = "Blame Line",
      group = "blame",
      rtxt = "b",
      effect = "view",
      context = { "line", "file" },
    }),
    action({
      id = "actions_blame_toggle",
      label = "Toggle Current Line Blame",
      group = "blame",
      rtxt = "tb",
      effect = "view",
    }),
    action({
      id = "actions_diff_head",
      label = "Diff Against HEAD",
      group = "diff",
      effect = "view",
      cross = { "diff" },
      note = "the diff view is diff.nvim's",
    }),
    action({
      id = "actions_diff_last",
      label = "Diff Last Commit",
      group = "diff",
      effect = "view",
      cross = { "diff" },
    }),
    action({
      id = "actions_toggle_deleted",
      label = "Toggle Deleted",
      group = "diff",
      rtxt = "td",
      effect = "view",
      requires = WITH_GITSIGNS,
    }),
    action({
      id = "actions_conflict_ours",
      label = "Keep Ours",
      group = "conflict",
      rtxt = "co",
      context = { "line", "file" },
      note = "only while the buffer has conflict marks; the key shows where the conflict scan mapped it",
    }),
    action({
      id = "actions_conflict_theirs",
      label = "Keep Theirs",
      group = "conflict",
      rtxt = "ct",
      context = { "line", "file" },
      note = "only while the buffer has conflict marks; the key shows where the conflict scan mapped it",
    }),
    action({
      id = "actions_conflict_both",
      label = "Keep Both",
      group = "conflict",
      rtxt = "cb",
      context = { "line", "file" },
      note = "only while the buffer has conflict marks; the key shows where the conflict scan mapped it",
    }),
    action({
      id = "actions_conflict_none",
      label = "Keep None",
      group = "conflict",
      rtxt = "c0",
      context = { "line", "file" },
      note = "only while the buffer has conflict marks; the key shows where the conflict scan mapped it",
    }),
    action({
      id = "actions_conflict_next",
      label = "Next Conflict",
      group = "conflict",
      rtxt = "]x",
      effect = "navigate",
      note = "only while the buffer has conflict marks",
    }),
    action({
      id = "actions_browse_file",
      label = "Open File on Web",
      group = "browse",
      effect = "external",
      cross = { "open" },
      requires = { plugins = { "gitsuite", "open" }, tools = { "git" } },
      note = "`:Git browse file`; open.nvim opens the URL, without it the group is left out",
    }),
    action({
      id = "actions_browse_repo",
      label = "Open Repository on Web",
      group = "browse",
      effect = "external",
      cross = { "open" },
      requires = { plugins = { "gitsuite", "open" }, tools = { "git" } },
      note = "`:Git browse repo`",
    }),
  },
}
