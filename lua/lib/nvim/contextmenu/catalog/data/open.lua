---@module 'lib.nvim.contextmenu.catalog.data.open'
---Entries of `open.integrations.menu`: open what is under the cursor with the system. Each
---entry is hidden when the resolved target does not fit (a URL for the browser, a local path
---for the file manager and the terminal).
---@type Lib.ContextMenu.Catalog.Block
return {
  plugin = "open",
  source = "open.integrations.menu",
  defaults = {
    context = { "path-under-cursor", "selection" },
    needs = { "text" },
    requires = { plugins = { "open", "ui.contextmenu" } },
    effect = "external",
  },
  entries = {
    {
      id = "open",
      label = "Open",
      group = "open",
      desc = "Opens the target with the system default.",
    },
    {
      id = "browser",
      label = "Open in Browser",
      group = "open",
      note = "only for a URL",
    },
    {
      id = "reveal_fm",
      label = "Reveal in File Manager",
      group = "open",
      note = "only for a local path",
    },
    {
      id = "terminal",
      label = "Open in Terminal",
      group = "open",
      note = "only for a local path",
    },
    {
      id = "list_links",
      label = "List Links Here",
      group = "links",
      context = { "buffer" },
      needs = { "buffer" },
      effect = "view",
    },
  },
}
