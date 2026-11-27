-- Regenerates docs/CONTEXTMENU-CATALOG.md from lib.nvim.contextmenu.catalog, and with it
-- docs/CROSSFEATURE-CATALOG.md: that overview lists the menu entries of each connection, so a
-- change of the menu data changes it too.
--
--   nvim -n -i NONE --headless -u NONE -l scripts/gen-contextmenu-catalog.lua
--
-- TESTS/contextmenu_catalog_spec.lua and TESTS/crossfeature_catalog_spec.lua fail when a file
-- is out of date.

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.runtimepath:append(root)

---@param module string
---@param file string
local function write(module, file)
  local text = require(module).markdown()
  local path = root .. "/docs/" .. file
  local lines = vim.split((text:gsub("\n+$", "")), "\n", { plain = true })
  vim.fn.writefile(lines, path)
  print("wrote " .. path .. " (" .. #lines .. " lines)")
end

write("lib.nvim.contextmenu.catalog", "CONTEXTMENU-CATALOG.md")
write("lib.nvim.crossfeature", "CROSSFEATURE-CATALOG.md")
