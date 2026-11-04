-- Startup hook of `lib.nvim.ui.kit.theme`: `:colorscheme` clears every user highlight group, so the
-- Kit* groups are defined again afterwards. Here, not in the module: open surfaces need it whether or
-- not anyone called `setup()`, and a hook created on first use would be state left behind by whichever
-- caller happened to be first. Nothing is loaded for it: without the module there are no groups yet.
if vim.g.loaded_lib_ui_kit_theme == 1 then
  return
end
vim.g.loaded_lib_ui_kit_theme = 1

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("lib_ui_kit_theme", { clear = true }),
  desc = "lib.nvim.ui.kit: refresh theme highlight groups",
  callback = function()
    local theme = package.loaded["lib.nvim.ui.kit.theme"]
    if theme then
      theme.refresh()
    end
  end,
})
