-- Regenerates docs/CONTEXTMENU-CATALOG.md from lib.nvim.contextmenu.catalog.
--
--   nvim -n -i NONE --headless -u NONE -l scripts/gen-contextmenu-catalog.lua
--
-- The spec TESTS/contextmenu_catalog_spec.lua fails when the file is out of date.

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.runtimepath:append(root)

local text = require("lib.nvim.contextmenu.catalog").markdown()
local path = root .. "/docs/CONTEXTMENU-CATALOG.md"
local lines = vim.split((text:gsub("\n+$", "")), "\n", { plain = true })
vim.fn.writefile(lines, path)
print("wrote " .. path .. " (" .. #lines .. " lines)")
