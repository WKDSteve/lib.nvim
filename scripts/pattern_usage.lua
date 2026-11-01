-- scripts/pattern_usage.lua — refresh the "Used by" column of docs/patterns.md.
--
--   nvim --headless -u NONE -l scripts/pattern_usage.lua [--check]
--
-- Reads lib.nvim's own module map (docs/map/module_map.json) and the maps of the
-- sibling repos through docmap.nvim (a checkout beside lib.nvim), see
-- lib.nvim.dev.pattern_usage. Generate the maps first when they are stale.
-- `--check` writes nothing and exits 1 when the column is out of date.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)

local check = false
for _, a in ipairs(arg or {}) do
  check = check or a == "--check"
end

local result, err = require("lib.nvim.dev.pattern_usage").sync({ root = root, check = check })
if not result then
  io.stderr:write("pattern_usage: " .. err .. "\n")
  os.exit(2)
end
io.write(
  ("pattern_usage: %d rows, %d maps read, %s\n"):format(
    result.rows,
    result.maps,
    result.changed and (check and "OUT OF DATE" or "updated") or "up to date"
  )
)
os.exit((check and result.changed) and 1 or 0)
