---@module 'lib.nvim.contextmenu.catalog.data.cascade'
---Entries of `cascade.integrations.menu`: list editing in a Markdown/text buffer. Each entry
---follows `features.<name>` of the cascade config (a feature switched off hides it); the key
---shown is what `keymaps.list` made of it.
---@type Lib.ContextMenu.Catalog.Block
return {
  plugin = "cascade",
  source = "cascade.integrations.menu",
  defaults = {
    context = { "line", "buffer" },
    needs = { "buffer" },
    requires = { plugins = { "cascade", "ui.contextmenu" } },
    effect = "modify",
  },
  entries = {
    {
      id = "toggle_checkbox",
      label = "Toggle checkbox",
      group = "checkbox",
      rtxt = "<leader>cx",
      context = { "markdown-checkbox", "line" },
    },
    {
      id = "cycle_type",
      label = "Cycle list marker type",
      group = "checkbox",
      rtxt = "<leader>ct",
    },
    {
      id = "cycle_type_back",
      label = "Cycle list marker type back",
      group = "checkbox",
      rtxt = "<leader>cT",
    },
    { id = "renumber", label = "Renumber list", group = "list", rtxt = "<leader>cr" },
    { id = "rotate_form", label = "Rotate list form", group = "list", rtxt = "<leader>cl" },
    { id = "sort", label = "Sort list A-Z", group = "list", rtxt = "<leader>cs" },
    { id = "reverse", label = "Reverse list order", group = "list", rtxt = "<leader>cv" },
    {
      id = "strip_checkboxes",
      label = "Strip checkboxes",
      group = "checkbox-bulk",
      rtxt = "<leader>cX",
      context = { "selection", "line" },
    },
  },
}
