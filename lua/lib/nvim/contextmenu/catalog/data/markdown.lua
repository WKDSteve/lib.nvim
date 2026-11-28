---@module 'lib.nvim.contextmenu.catalog.data.markdown'
---Entries of `markdown.integrations.menu`: "contributes only", for a Markdown buffer. The
---host renders them (context-menu entries), the actions stay in markdown.nvim.
---@type Lib.ContextMenu.Catalog.Block
return {
  plugin = "markdown",
  source = "markdown.integrations.menu",
  defaults = {
    context = { "markdown-doc", "buffer" },
    needs = { "buffer" },
    requires = { plugins = { "markdown" } },
    effect = "modify",
  },
  entries = {
    {
      id = "fold_toggle",
      label = "Fold / Unfold Heading",
      group = "fold",
      rtxt = "za",
      context = { "markdown-heading" },
      effect = "view",
    },
    {
      id = "fold_h2plus",
      label = "Fold below H2 (toggle)",
      group = "fold",
      rtxt = "zk",
      context = { "markdown-heading" },
      effect = "view",
    },
    { id = "unfold_all", label = "Unfold All", group = "fold", rtxt = "zu", effect = "view" },
    {
      id = "checkbox_cycle",
      label = "Cycle Checkbox",
      group = "checkbox",
      rtxt = "<C-CR>",
      context = { "markdown-checkbox", "line" },
    },
    {
      id = "checkbox_set",
      label = "Checkbox: <state>",
      group = "checkbox",
      context = { "markdown-checkbox", "line" },
      note = "one entry per state of the checkbox cycle (todo, done, ...)",
    },
    { id = "toc", label = "Insert / Refresh TOC", group = "document", rtxt = "<leader>toc" },
    { id = "sync_refs", label = "Sync References", group = "document" },
    {
      id = "mdview",
      label = "Preview in mdview",
      group = "document",
      effect = "external",
      cross = { "mdview" },
      requires = { plugins = { "markdown", "mdview" } },
      note = "runs `:Markdown mdview`; only with mdview.nvim (`:MDView`) and a buffer that has a file",
    },
    {
      id = "paste_image",
      label = "Paste image",
      group = "document",
      cross = { "images" },
      requires = { plugins = { "markdown", "images" } },
      note = "runs `:Markdown image paste` (images.nvim pastes the clipboard image)",
    },
  },
}
