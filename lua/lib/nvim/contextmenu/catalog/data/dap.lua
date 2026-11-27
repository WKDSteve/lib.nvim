---@module 'lib.nvim.contextmenu.catalog.data.dap'
---Entries of `wkddap.integrations.menu` (dap.nvim): debugger control. All run in any buffer;
---the key shown comes from the dap keymaps.
---@type Lib.ContextMenu.Catalog.Block
return {
  plugin = "dap",
  source = "wkddap.integrations.menu",
  defaults = {
    context = { "line", "buffer" },
    needs = { "buffer" },
    requires = { plugins = { "wkddap", "ui.contextmenu" } },
    effect = "navigate",
  },
  entries = {
    { id = "continue", label = "Continue", group = "run", effect = "external" },
    { id = "step_over", label = "Step Over", group = "run" },
    { id = "step_into", label = "Step Into", group = "run" },
    { id = "step_out", label = "Step Out", group = "run" },
    { id = "terminate", label = "Terminate", group = "run", effect = "external" },
    { id = "restart", label = "Restart", group = "run", effect = "external" },
    {
      id = "toggle_breakpoint",
      label = "Toggle Breakpoint",
      group = "breakpoints",
      needs = { "buffer", "line" },
      effect = "modify",
    },
    {
      id = "conditional_breakpoint",
      label = "Conditional Breakpoint…",
      group = "breakpoints",
      needs = { "buffer", "line" },
      effect = "modify",
    },
    {
      id = "log_point",
      label = "Log Point…",
      group = "breakpoints",
      needs = { "buffer", "line" },
      effect = "modify",
    },
    { id = "list_breakpoints", label = "List Breakpoints", group = "breakpoints", effect = "view" },
    { id = "toggle_ui", label = "Toggle DAP UI", group = "ui", effect = "view" },
    {
      id = "eval",
      label = "Evaluate Expression / Selection",
      group = "ui",
      context = { "selection", "line" },
      needs = { "buffer" },
      effect = "view",
    },
  },
}
