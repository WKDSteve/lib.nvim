---@module 'lib.nvim.contextmenu.catalog.data.ui'
---The menus ui.nvim builds itself (drawn by `ui.contextmenu`), four sources:
---
---* `ui.menu.sections`: the general sections of the right-click menu (Code, Clipboard, File,
---  Delete, Tools). Each entry has an opt-out in `menu.entries`; Delete All and Delete File are
---  off by default.
---* `ui.menu.contributors`: one fly-out per installed sister plugin (its `submenu()`), the
---  filetree row and the user's own rows (`menu.extra`). The fly-outs bring in another plugin's
---  menu, so they are cross-plugin entries; the label is the plugin's own.
---* `ui.statusline.menu`: the menu of a clicked statusline module (remove it, add another,
---  save the layout).
---* `ui.tabline.menu`: the menu of a buffer chip in the tab bar.
---
---`ui.menu` itself is off until `menu = { … }` is set in ui.nvim's setup (it takes over the
---global `<RightMouse>`).

---@param source string
---@param defaults table
---@return fun(e: table): table
local function from(source, defaults)
  return function(e)
    e.source = source
    for k, v in pairs(defaults) do
      if e[k] == nil then
        e[k] = v
      end
    end
    return e
  end
end

local section = from("ui.menu.sections", {
  context = { "buffer" },
  needs = { "buffer" },
  effect = "modify",
})

local contributor = from("ui.menu.contributors", {
  context = { "buffer" },
  needs = { "buffer" },
  effect = "view",
  group = "integrations",
})

---A sister plugin's fly-out: its `<module>.integrations.menu` `submenu()`, shown when the plugin
---is installed, not switched off on either side (`menu.integrations.<name>`, the plugin's own
---`integrations.ui_menu`).
---@param id string
---@param label string
---@param plugin string
---@param note? string
---@return table
local function flyout(id, label, plugin, note)
  return contributor({
    id = "integration_" .. id,
    label = label,
    cross = { plugin },
    requires = { plugins = { "ui", plugin } },
    note = note or "fly-out with the plugin's own entries (its `submenu()`)",
  })
end

local statusline = from("ui.statusline.menu", {
  context = { "statusline-module" },
  needs = {},
  effect = "modify",
  group = "statusline",
})

local tabline = from("ui.tabline.menu", {
  context = { "tabline-chip" },
  needs = { "buffer" },
  effect = "modify",
})

---@type Lib.ContextMenu.Catalog.Block
return {
  plugin = "ui",
  defaults = {
    requires = { plugins = { "ui" } },
  },
  entries = {
    -- ui.menu.sections
    section({ id = "format", label = "Format Buffer", group = "code" }),
    section({
      id = "code_actions",
      label = "Code Actions",
      group = "code",
      note = "`vim.lsp.buf.code_action`",
    }),
    section({ id = "inspect", label = "Inspect", group = "code", effect = "view" }),
    section({ id = "copy_all", label = "Copy All (Buffer)", group = "clipboard", effect = "copy" }),
    section({
      id = "copy_marked",
      label = "Copy Marked/Selected",
      group = "clipboard",
      effect = "copy",
      context = { "selection", "buffer" },
      needs = { "text" },
    }),
    section({ id = "paste", label = "Paste Content", group = "clipboard" }),
    section({ id = "save", label = "Save", group = "file" }),
    section({ id = "save_all", label = "Save All", group = "file", needs = {} }),
    section({
      id = "delete_marked",
      label = "Delete Marked/Selected",
      group = "delete",
      context = { "selection", "buffer" },
      needs = { "text" },
    }),
    section({
      id = "delete_all",
      label = "Delete All (Clear Buffer)",
      group = "delete",
      note = "off by default (`menu.entries.delete_all`)",
    }),
    section({
      id = "delete_file",
      label = "Delete File",
      group = "delete",
      context = { "buffer", "file" },
      needs = { "path" },
      note = "off by default (`menu.entries.delete_file`)",
    }),
    section({
      id = "terminal",
      label = "Open in terminal",
      group = "tools",
      effect = "external",
      note = "a terminal buffer in the file's folder (ui.nvim's own, not terminal.nvim)",
    }),
    section({ id = "color_picker", label = "Color Picker", group = "tools", effect = "view" }),
    section({
      id = "unicode_table",
      label = "Unicode Table",
      group = "tools",
      effect = "view",
      cross = { "emojis" },
      requires = { plugins = { "ui", "emojis.unicode" } },
    }),
    section({
      id = "git_actions",
      label = "Git Actions",
      group = "tools",
      effect = "view",
      cross = { "gitsuite" },
      requires = { plugins = { "ui", "gitsuite" } },
      note = "one row; picked, it opens gitsuite's own menu (`gitsuite.integrations.menu`)",
    }),

    -- ui.menu.contributors
    flyout("markdown", "Markdown", "markdown", "only in a Markdown buffer"),
    flyout("open", "Open", "open"),
    flyout(
      "dap",
      "Debug",
      "dap",
      "one row from a static label; dap.nvim is loaded only when it is picked"
    ),
    flyout("cascade", "Cascade", "cascade"),
    flyout("fileops", "File", "fileops"),
    flyout("images", "Images", "images"),
    flyout("spotlight", "Spotlight", "spotlight"),
    flyout("color_my_ascii", "Color My ASCII", "color_my_ascii", "only in a Markdown buffer"),
    flyout("lsp", "LSP", "lsp"),
    flyout("gopath", "Paths", "gopath"),
    contributor({
      id = "filetree_window",
      label = "Open filetree / Close filetree",
      effect = "open",
      cross = { "filetree" },
      requires = { plugins = { "ui", "filetree" } },
      note = "filetree's `window_entry()`: reveals this file in the tree, or closes it",
    }),
    contributor({
      id = "extra",
      label = "<your own row>",
      group = "extra",
      effect = "modify",
      note = "`menu.extra`: rows of the user's config, one section per `section` name",
    }),

    -- ui.statusline.menu
    statusline({ id = "statusline_remove", label = "Remove <module>" }),
    statusline({
      id = "statusline_add",
      label = "Add module ▸ <module>",
      note = "one row per catalogued module that is not shown yet",
    }),
    statusline({
      id = "statusline_save_layout",
      label = "Save current layout",
      note = "writes the order to ui.statusline's state file; runtime changes are lost otherwise",
    }),
    statusline({ id = "statusline_clear_layout", label = "Clear saved layout" }),

    -- ui.tabline.menu
    tabline({ id = "tab_save", label = "Save", group = "tab" }),
    tabline({
      id = "tab_pin",
      label = "Pin / Unpin",
      group = "tab",
      note = "label follows the state",
    }),
    tabline({ id = "tab_close", label = "Close", group = "tab" }),
    tabline({
      id = "tab_close_others",
      label = "Close others",
      group = "close",
      note = "pinned tabs survive every close set",
    }),
    tabline({ id = "tab_close_left", label = "Close to the left", group = "close" }),
    tabline({ id = "tab_close_right", label = "Close to the right", group = "close" }),
    tabline({ id = "tab_close_saved", label = "Close saved", group = "close" }),
    tabline({ id = "tab_move_to", label = "Move to position…", group = "move" }),
    tabline({ id = "tab_move_left", label = "Move left", group = "move" }),
    tabline({ id = "tab_move_right", label = "Move right", group = "move" }),
    tabline({ id = "tab_move_start", label = "Move to start", group = "move" }),
    tabline({ id = "tab_move_end", label = "Move to end", group = "move" }),
    tabline({
      id = "tab_copy_path",
      label = "Copy path ▸ Absolute / Relative / File name",
      group = "buffer",
      effect = "copy",
      needs = { "path" },
    }),
    tabline({ id = "tab_split", label = "Open in split", group = "buffer", effect = "open" }),
    tabline({
      id = "tab_vsplit",
      label = "Open in vertical split",
      group = "buffer",
      effect = "open",
    }),
    tabline({ id = "tab_new_tabpage", label = "Move to new tab page", group = "buffer" }),
    tabline({
      id = "tab_reopen",
      label = "Reopen closed tab ▸ <file>",
      group = "buffer",
      effect = "open",
      needs = {},
      note = "one row per recently closed file",
    }),
  },
}
