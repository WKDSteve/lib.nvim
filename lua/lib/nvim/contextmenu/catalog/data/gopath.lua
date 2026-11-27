---@module 'lib.nvim.contextmenu.catalog.data.gopath'
---Entries of `gopath.integrations.menu`: "contributes only", the host composes them. They act
---on whatever gopath resolves under the cursor or in a single-line selection.
---@type Lib.ContextMenu.Catalog.Block
return {
  plugin = "gopath",
  source = "gopath.integrations.menu",
  defaults = {
    context = { "path-under-cursor", "selection" },
    needs = { "text" },
    requires = { plugins = { "gopath", "ui.contextmenu" } },
    effect = "open",
  },
  entries = {
    {
      id = "open",
      label = "Open",
      group = "paths",
      desc = "Opens the resolved path, URL, module, help tag or commit.",
    },
    {
      id = "reveal_fm",
      label = "Reveal in File Manager",
      group = "paths",
      effect = "external",
      note = "only for a local path the resolver confirmed to exist",
    },
    {
      id = "reveal_filetree",
      label = "Reveal in filetree.nvim",
      group = "paths",
      requires = { plugins = { "gopath", "ui.contextmenu", "filetree" } },
      note = "only for a local path the resolver confirmed to exist",
    },
  },
}
