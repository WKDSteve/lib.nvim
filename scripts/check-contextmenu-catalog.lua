-- Compares the context-menu catalogue with the plugin checkouts next to lib.nvim and prints
-- what no longer matches (a renamed or removed entry, a moved module).
--
--   nvim -n -i NONE --headless -u NONE -l scripts/check-contextmenu-catalog.lua [repos-dir]
--
-- Exit 1 when a row has no counterpart in the code, else 0.

local this = debug.getinfo(1, "S").source:sub(2)
local lib_root = vim.fn.fnamemodify(this, ":p:h:h")
vim.opt.runtimepath:append(lib_root)

local root = arg and arg[1] or vim.env.REPOS_DIR or vim.fn.fnamemodify(lib_root, ":h")
local findings, checked = require("lib.nvim.contextmenu.catalog.drift").check(root)

local bad = 0
for _, f in ipairs(findings) do
  if f.kind ~= "no-checkout" then
    bad = bad + 1
  end
  print(("%-15s %-34s %s"):format(f.kind, f.id, f.detail))
end
print(
  ("checked %d plugin(s) under %s, %d finding(s) to fix"):format(vim.tbl_count(checked), root, bad)
)
os.exit(bad == 0 and 0 or 1)
