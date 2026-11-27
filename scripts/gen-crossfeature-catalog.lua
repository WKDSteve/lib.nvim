-- Regenerates docs/CROSSFEATURE-CATALOG.md from lib.nvim.crossfeature.
--
--   nvim -n -i NONE --headless -u NONE -l scripts/gen-crossfeature-catalog.lua
--
-- The data itself (lua/lib/nvim/crossfeature/data.lua) is written by crossfeature.mjs of the
-- workshop vault from integrations.json. The spec TESTS/crossfeature_catalog_spec.lua fails when
-- this overview is out of date (also after a change of the context-menu catalogue: the overview
-- lists the menu entries of each connection).

local this = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.runtimepath:append(root)

local text = require("lib.nvim.crossfeature").markdown()
local path = root .. "/docs/CROSSFEATURE-CATALOG.md"
local lines = vim.split((text:gsub("\n+$", "")), "\n", { plain = true })
vim.fn.writefile(lines, path)
print("wrote " .. path .. " (" .. #lines .. " lines)")
