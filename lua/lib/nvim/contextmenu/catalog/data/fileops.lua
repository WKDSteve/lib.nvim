---@module 'lib.nvim.contextmenu.catalog.data.fileops'
---Entries of `fileops.integrations.menu`: the `:File` commands on the file of the current
---buffer. The file entries are hidden for an unnamed buffer.
---@type Lib.ContextMenu.Catalog.Block
return {
  plugin = "fileops",
  source = "fileops.integrations.menu",
  defaults = {
    context = { "file", "buffer" },
    needs = { "path", "buffer" },
    requires = { plugins = { "fileops", "ui.contextmenu" } },
    effect = "modify",
  },
  entries = {
    { id = "rename", label = "Rename file…", group = "file", desc = "Runs `:File rename`." },
    {
      id = "duplicate",
      label = "Duplicate file…",
      group = "file",
      desc = "Runs `:File duplicate`.",
    },
    {
      id = "delete",
      label = "Delete file",
      group = "file",
      cross = { "filetree" },
      desc = "Runs `:File delete`.",
      note = "asks the reference engine of filetree.nvim whether orphaned assets remain",
    },
    {
      id = "copy_path",
      label = "Copy path",
      group = "info",
      effect = "copy",
      desc = "Runs `:File path`.",
    },
    {
      id = "info",
      label = "Show file info",
      group = "info",
      effect = "view",
      desc = "Runs `:File info`.",
    },
    {
      id = "next",
      label = "Next file in directory",
      group = "navigate",
      needs = { "buffer" },
      effect = "navigate",
      desc = "Runs `:File next`.",
    },
    {
      id = "prev",
      label = "Previous file in directory",
      group = "navigate",
      needs = { "buffer" },
      effect = "navigate",
      desc = "Runs `:File prev`.",
    },
  },
}
