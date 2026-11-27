-- TESTS/sheets/catalog-available-user-config.sheet.lua -- a sheet of testing.nvim (docs/SHEETS.md) on the
-- installed config: asking the two catalogues which entries are available here must not load a plugin
-- lazy.nvim has not loaded yet (lib.nvim.require.installed reads lazy's registry instead of `require`).
-- `config = "user"` starts the real config read only; where there is none (CI) the sheet is a skip.
-- The config loads its own lib.nvim checkout: the sheet checks the code that checkout has.
local LOADED = [[(function()
  local out = {}
  for _, p in ipairs(require('lazy').plugins()) do
    if p._.loaded then out[#out + 1] = p.name end
  end
  table.sort(out)
  return out
end)()]]

return {
  id = "lib.catalog-available-user-config",
  title = "Catalogue queries for available entries load no plugin",
  task = "lib.nvim/katalog-available-ohne-laden-lazy-nvim-fragen-statt-require",
  config = "user",
  steps = {
    { wait = "package.loaded['lazy'] ~= nil", timeout = 60000, note = "lazy.nvim has started" },
    {
      wait = "require('lazy').stats().startuptime > 0",
      timeout = 60000,
      note = "lazy.nvim's start is done",
    },
    { steady = 3000, timeout = 60000, note = "VeryLazy and the deferred loads are over" },
    { lua = "_G.LIB_SHEET_BEFORE = " .. LOADED, note = "the plugins loaded before the queries" },
    {
      lua = "_G.LIB_SHEET_CF = #require('lib.nvim.crossfeature').list({ available = true })",
      timeout = 30000,
      note = "crossfeature: the connections installed here",
    },
    {
      lua = "_G.LIB_SHEET_MENU = #require('lib.nvim.contextmenu.catalog').list({ available = true })",
      timeout = 30000,
      note = "context-menu catalogue: the entries usable here",
    },
    { expect = "_G.LIB_SHEET_CF > 0", note = "some connection counts as installed" },
    { expect = "_G.LIB_SHEET_MENU > 0", note = "some menu entry counts as usable" },
    {
      expect = "vim.deep_equal(_G.LIB_SHEET_BEFORE, " .. LOADED .. ")",
      note = "no plugin was loaded by the two queries (:Lazy shows the same loaded plugins)",
    },
  },
}
