---@module 'lib.nvim.contextmenu.catalog.data.casedesk'
---Entries of `casedesk.logview.integrations.menu`: the read-only copy of a log (Lesekopie).
---Labels are German on purpose (the plugin's own UI language); the key shown is the logview
---keymap of the same action.
---@type Lib.ContextMenu.Catalog.Block
return {
  plugin = "casedesk",
  source = "casedesk.logview.integrations.menu",
  defaults = {
    context = { "line", "buffer" },
    needs = { "buffer" },
    requires = { plugins = { "casedesk", "ui.contextmenu" } },
    effect = "view",
  },
  entries = {
    { id = "toggle", label = "Auf-/zuklappen", group = "fold" },
    { id = "open_all", label = "Alle Einträge aufklappen", group = "fold" },
    { id = "close_all", label = "Alles zuklappen", group = "fold" },
    { id = "mode", label = "Seitenquelltext: nächster Modus", group = "fold" },
    { id = "next_error", label = "Nächster Fehler", group = "navigate", effect = "navigate" },
    { id = "original", label = "Original an dieser Zeile", group = "navigate", effect = "open" },
    { id = "errors", label = "Fehler in die Quickfix", group = "navigate", effect = "open" },
    {
      id = "entries",
      label = "Eintrag suchen (Picker)",
      group = "navigate",
      effect = "navigate",
      cross = { "pickers" },
    },
    {
      id = "known_case",
      label = "Bekannte Meldungen im Fall",
      group = "navigate",
      cross = { "pickers" },
    },
    { id = "mark", label = "Eintrag für Diff markieren", group = "compare" },
    { id = "diff", label = "Markierte Einträge vergleichen", group = "compare" },
    {
      id = "spotlight",
      label = "Token als Spotlight",
      group = "compare",
      context = { "selection", "line" },
    },
    {
      id = "spotlight_qf",
      cross = { "spotlight" },
      label = "Spotlight-Treffer in die Quickfix",
      group = "compare",
      effect = "open",
    },
    {
      id = "task",
      label = "Eintrag als Folge-Task des Falls",
      group = "compare",
      cross = { "tasks" },
      effect = "modify",
    },
    { id = "timeline", label = "Zeitstrahl erzeugen", group = "output" },
    { id = "range", label = "Zeitraum eingrenzen", group = "output" },
    {
      id = "live",
      label = "Live im Browser (mdview)",
      group = "output",
      effect = "external",
      cross = { "mdview" },
    },
    {
      id = "md_case",
      label = "Als Markdown in den Fall (Research/)",
      group = "output",
      effect = "modify",
    },
    {
      id = "md_temp",
      label = "Als Markdown in eine Temp-Datei",
      group = "output",
      effect = "modify",
    },
  },
}
