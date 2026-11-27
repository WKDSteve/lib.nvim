---@module 'lib.nvim.contextmenu.catalog.drift'
---@brief Checks the catalogue against the code of the plugins it describes.
---@description
--- A catalogue row is a claim: "plugin X offers this entry, built by module Y". This module
--- compares each row with the checkout of the plugin next to lib.nvim (`<repos>/<plugin>.nvim`)
--- and reports what no longer holds:
---   * `no-checkout`     the plugin's repository is not there (nothing to compare, not an error)
---   * `source-missing`  the module named in `source` has no file in the plugin
---   * `label-missing`   the label (without leading icon/space) occurs in none of the plugin's
---                       Lua files, i.e. the entry was renamed or removed
--- Rows whose label is a placeholder (`<state>`) are skipped: the real labels are built at click
--- time. The check reads files only, it never loads a plugin.

local M = {}

---@alias Lib.ContextMenu.Catalog.Finding { id: string, kind: "no-checkout"|"source-missing"|"label-missing", detail: string }

---@param path string
---@return string|nil
local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

---The label as it is written in code: no leading space or icon glyph, no trailing space.
---@param label string
---@return string
function M.bare_label(label)
  local s = label:gsub("^[^%w<]+", ""):gsub("%s+$", "")
  return s
end

---The strings to look for in code for one catalogue label. A label that names several states
---(`Mark / Unmark`) or a fly-out with its items (`Copy path ▸ Absolute / Relative`) is written
---as separate strings in code, so each part is searched alone. A placeholder part (`<state>`)
---is built at click time and is skipped.
---@param label string
---@return string[]
function M.label_parts(label)
  local out = {}
  local text = label:gsub(" ▸ ", " / ")
  for part in (text .. " / "):gmatch("(.-) / ") do
    part = M.bare_label(part)
    if part ~= "" and not part:find("<", 1, true) then
      out[#out + 1] = part
    end
  end
  return out
end

---@param root string  the repos directory
---@param plugin string
---@return string  `<root>/<plugin>.nvim`
local function plugin_dir(root, plugin)
  return root .. "/" .. plugin .. ".nvim"
end

---All Lua files of a plugin as one text (read once per plugin, plain search later).
---@param dir string
---@return string
local function plugin_text(dir)
  local parts = {}
  for _, f in ipairs(vim.fn.glob(dir .. "/lua/**/*.lua", true, true)) do
    parts[#parts + 1] = read(f) or ""
  end
  return table.concat(parts, "\n")
end

---@param dir string
---@param source string  Lua module name, `cascade.integrations.menu`
---@return boolean
local function source_exists(dir, source)
  local rel = dir .. "/lua/" .. source:gsub("%.", "/")
  return vim.fn.filereadable(rel .. ".lua") == 1 or vim.fn.filereadable(rel .. "/init.lua") == 1
end

---Compare every catalogue row with the plugin checkout under `root`.
---@param root string  directory holding the `<plugin>.nvim` checkouts
---@param entries? Lib.ContextMenu.Catalog.Entry[]  default: the whole catalogue
---@return Lib.ContextMenu.Catalog.Finding[] findings
---@return table<string, boolean> checked  plugins that had a checkout
function M.check(root, entries)
  entries = entries or require("lib.nvim.contextmenu.catalog").all()
  local findings, checked, texts = {}, {}, {}
  local reported_missing = {}
  for _, e in ipairs(entries) do
    local dir = plugin_dir(root, e.plugin)
    if vim.fn.isdirectory(dir) ~= 1 then
      if not reported_missing[e.plugin] then
        reported_missing[e.plugin] = true
        findings[#findings + 1] = {
          id = e.plugin,
          kind = "no-checkout",
          detail = dir .. " is not there",
        }
      end
    else
      checked[e.plugin] = true
      if e.source and not source_exists(dir, e.source) then
        findings[#findings + 1] = {
          id = e.id,
          kind = "source-missing",
          detail = ("module %s has no file in %s"):format(e.source, dir),
        }
      end
      -- where the label may be written: the owner, and the plugins a cross-feature row brings
      -- in (a fly-out's label comes from that plugin's own `submenu()`)
      local places = { e.plugin }
      for _, other in ipairs(e.cross or {}) do
        places[#places + 1] = other
      end
      for _, part in ipairs(M.label_parts(e.label)) do
        local found = false
        for _, place in ipairs(places) do
          local pdir = plugin_dir(root, place)
          if vim.fn.isdirectory(pdir) == 1 then
            texts[place] = texts[place] or plugin_text(pdir)
            if texts[place]:find(part, 1, true) then
              found = true
              break
            end
          end
        end
        if not found then
          findings[#findings + 1] = {
            id = e.id,
            kind = "label-missing",
            detail = ("label part %q is in no Lua file of %s"):format(
              part,
              table.concat(places, ", ")
            ),
          }
        end
      end
    end
  end
  return findings, checked
end

return M
