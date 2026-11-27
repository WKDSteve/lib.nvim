---@module 'lib.nvim.contextmenu.catalog.data.images'
---Entries of `images.integrations.menu`. `items(bufnr)` serves a buffer, `items_for_path(path)`
---a host that already knows the file (a filetree node, open.nvim): every action then acts on
---`path`. The processing entries need ImageMagick (`magick`) or `tesseract` and are hidden
---without them.
---@type Lib.ContextMenu.Catalog.Block
return {
  plugin = "images",
  source = "images.integrations.menu",
  defaults = {
    context = { "image", "file" },
    needs = { "path" },
    requires = { plugins = { "images", "ui.contextmenu" } },
    effect = "view",
  },
  entries = {
    { id = "show", label = "Show image", group = "view", desc = "Shows `path` (items_for_path)." },
    {
      id = "hover",
      label = "Show image under cursor",
      group = "view",
      context = { "line", "buffer" },
      needs = { "buffer" },
    },
    {
      id = "gallery",
      label = "Gallery (every image in the buffer)",
      group = "view",
      context = { "buffer" },
      needs = { "buffer" },
    },
    {
      id = "next",
      label = "Next image",
      group = "view",
      context = { "buffer" },
      needs = { "buffer" },
      effect = "navigate",
    },
    {
      id = "prev",
      label = "Previous image",
      group = "view",
      context = { "buffer" },
      needs = { "buffer" },
      effect = "navigate",
    },
    {
      id = "paste",
      label = "Paste image from clipboard",
      group = "capture",
      context = { "buffer" },
      needs = { "buffer" },
      effect = "modify",
    },
    {
      id = "screenshot",
      label = "Take a screenshot",
      group = "capture",
      context = { "buffer" },
      needs = { "buffer" },
      effect = "external",
    },
    { id = "info", label = "Show image info", group = "info" },
    {
      id = "ocr",
      label = "Read text (OCR)",
      group = "process",
      requires = { plugins = { "images", "ui.contextmenu" }, tools = { "tesseract" } },
    },
    {
      id = "redact",
      label = "Redact (black out areas)",
      group = "process",
      effect = "modify",
      requires = { plugins = { "images", "ui.contextmenu" }, tools = { "magick" } },
    },
    { id = "export_pdf", label = "Export as PDF", group = "process", effect = "modify" },
    {
      id = "scale",
      label = "Scale copy…",
      group = "process",
      effect = "modify",
      requires = { plugins = { "images", "ui.contextmenu" }, tools = { "magick" } },
    },
    {
      id = "optimise",
      label = "Optimise copy",
      group = "process",
      effect = "modify",
      requires = { plugins = { "images", "ui.contextmenu" }, tools = { "magick" } },
    },
    {
      id = "convert",
      label = "Convert copy…",
      group = "process",
      effect = "modify",
      requires = { plugins = { "images", "ui.contextmenu" }, tools = { "magick" } },
    },
    { id = "zen", label = "Zen view", group = "process" },
    {
      id = "replace_clipboard",
      label = "Replace with clipboard image",
      group = "process",
      effect = "modify",
    },
    { id = "compare", label = "Compare two images…", group = "process" },
  },
}
