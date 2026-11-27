---@module 'lib.nvim.contextmenu.catalog'
---@brief Catalogue of the context-menu entries the plugins of this ecosystem offer.
---@description
--- One structured list of every menu action a plugin provides: what it is called, where it
--- applies (`context`), what it takes (`needs`), what must be installed (`requires`: plugins,
--- CLI tools, Neovim version) and what it does (`effect`). A plugin author who builds a new
--- menu asks the catalogue what already exists instead of searching every repository:
--- >
---   local catalog = require("lib.nvim.contextmenu.catalog")
---   -- every action that works on a path and a line and is usable on this machine
---   for _, e in ipairs(catalog.list({ provides = { "path", "line" }, available = true })) do
---     print(e.id, e.label)
---   end
--- <
--- The catalogue holds metadata only. The actions stay in their plugins; `source` names the
--- module that builds the real entry. lib.nvim never requires a plugin except to ask whether
--- it is installed (`requires.plugins`). Built-in data lives in `catalog/data/<plugin>.lua`;
--- a plugin can add its own at runtime with `register`.
---
--- `catalog.markdown()` renders the overview kept in `CATALOG.md` (a spec keeps it in sync).

local M = {}

local EFFECTS = {
  open = true,
  copy = true,
  modify = true,
  external = true,
  view = true,
  navigate = true,
}

local BUILTIN = { "filetree", "gopath", "markdown", "pickers" }

---@type table<string, Lib.ContextMenu.Catalog.Entry>
local by_id = {}
---@type string[]  ids in registration order, for a stable listing
local order = {}
local builtin_loaded = false

---Why `e` is not a valid entry, or nil.
---@param e any
---@return string|nil
function M.validate(e)
  if type(e) ~= "table" then
    return "entry must be a table"
  end
  if type(e.id) ~= "string" or not e.id:match("^[%w_%-]+%.[%w_%.%-]+$") then
    return "id must be '<plugin>.<action>'"
  end
  if type(e.plugin) ~= "string" or e.plugin == "" then
    return "plugin is required"
  end
  if e.id:sub(1, #e.plugin + 1) ~= e.plugin .. "." then
    return ("id '%s' must start with '%s.'"):format(e.id, e.plugin)
  end
  if type(e.label) ~= "string" or e.label == "" then
    return "label is required"
  end
  if type(e.group) ~= "string" or e.group == "" then
    return "group is required"
  end
  if type(e.context) ~= "table" or #e.context == 0 then
    return "context needs at least one value"
  end
  if not EFFECTS[e.effect] then
    return "effect must be one of open/copy/modify/external/view/navigate"
  end
  if e.needs ~= nil and type(e.needs) ~= "table" then
    return "needs must be a list"
  end
  local r = e.requires
  if r ~= nil then
    if type(r) ~= "table" then
      return "requires must be a table"
    end
    for _, k in ipairs({ "plugins", "tools" }) do
      if r[k] ~= nil and type(r[k]) ~= "table" then
        return ("requires.%s must be a list"):format(k)
      end
    end
    if r.nvim ~= nil and type(r.nvim) ~= "string" then
      return "requires.nvim must be a string"
    end
  end
  return nil
end

---Add (or replace, by `id`) one entry or a list of entries. Invalid entries raise.
---@param entries Lib.ContextMenu.Catalog.Entry|Lib.ContextMenu.Catalog.Entry[]
function M.register(entries)
  if type(entries) == "table" and entries.id ~= nil then
    entries = { entries }
  end
  for _, e in ipairs(entries) do
    local err = M.validate(e)
    if err then
      error(("contextmenu.catalog: %s (%s)"):format(err, tostring(e and e.id)), 2)
    end
    if not by_id[e.id] then
      order[#order + 1] = e.id
    end
    by_id[e.id] = e
  end
end

---Expand a built-in block: `defaults` and the block's `plugin`/`source` go into every entry.
---@param block Lib.ContextMenu.Catalog.Block
---@return Lib.ContextMenu.Catalog.Entry[]
function M.expand(block)
  local out = {}
  for _, raw in ipairs(block.entries) do
    local e = vim.tbl_deep_extend("force", {}, block.defaults or {}, raw)
    e.plugin = block.plugin
    e.source = e.source or block.source
    e.id = block.plugin .. "." .. raw.id
    out[#out + 1] = e
  end
  return out
end

local function load_builtin()
  if builtin_loaded then
    return
  end
  builtin_loaded = true
  for _, name in ipairs(BUILTIN) do
    local ok, block = pcall(require, "lib.nvim.contextmenu.catalog.data." .. name)
    if ok and type(block) == "table" then
      -- a runtime `register` that came first wins over the built-in row with the same id
      for _, e in ipairs(M.expand(block)) do
        if not by_id[e.id] then
          M.register(e)
        end
      end
    end
  end
end

---Drop everything registered at runtime and reload the built-in data on the next query.
function M.reset()
  by_id, order, builtin_loaded = {}, {}, false
end

---@return Lib.ContextMenu.Catalog.Entry[]
function M.all()
  load_builtin()
  local out = {}
  for _, id in ipairs(order) do
    out[#out + 1] = by_id[id]
  end
  return out
end

---@param id string
---@return Lib.ContextMenu.Catalog.Entry|nil
function M.get(id)
  load_builtin()
  return by_id[id]
end

---Compare "0.10" with the running Neovim.
---@param min string
---@return boolean
local function nvim_at_least(min)
  local want = {}
  for n in min:gmatch("%d+") do
    want[#want + 1] = tonumber(n)
  end
  local v = vim.version()
  local have = { v.major, v.minor, v.patch }
  for i = 1, #want do
    if have[i] ~= want[i] then
      return have[i] > want[i]
    end
  end
  return true
end

---Whether the entry can be offered on this machine, and what is missing when not.
---A plugin counts as there when its main module `require`s; a tool when it is executable.
---@param e Lib.ContextMenu.Catalog.Entry|string  the entry or its id
---@return boolean ok
---@return { plugins: string[], tools: string[], nvim: string|nil } missing
function M.available(e)
  if type(e) == "string" then
    e = M.get(e)
  end
  local missing = { plugins = {}, tools = {} }
  if not e then
    return false, missing
  end
  local r = e.requires or {}
  for _, mod in ipairs(r.plugins or {}) do
    if not pcall(require, mod) then
      missing.plugins[#missing.plugins + 1] = mod
    end
  end
  for _, tool in ipairs(r.tools or {}) do
    if vim.fn.executable(tool) ~= 1 then
      missing.tools[#missing.tools + 1] = tool
    end
  end
  if r.nvim and not nvim_at_least(r.nvim) then
    missing.nvim = r.nvim
  end
  return #missing.plugins == 0 and #missing.tools == 0 and missing.nvim == nil, missing
end

---@param list string[]|nil
---@param value string
local function has(list, value)
  for _, v in ipairs(list or {}) do
    if v == value then
      return true
    end
  end
  return false
end

---Entries matching all given conditions.
---   plugin     owning plugin
---   context    the entry applies in this context
---   group      menu group
---   effect     what it does
---   provides   inputs the caller can supply: only entries whose `needs` are all in there
---   available  true: only entries usable on this machine (plugins, tools, Neovim)
---@param filter? { plugin?: string, context?: string, group?: string, effect?: string, provides?: string[], available?: boolean }
---@return Lib.ContextMenu.Catalog.Entry[]
function M.list(filter)
  filter = filter or {}
  local out = {}
  for _, e in ipairs(M.all()) do
    local keep = (not filter.plugin or e.plugin == filter.plugin)
      and (not filter.context or has(e.context, filter.context))
      and (not filter.group or e.group == filter.group)
      and (not filter.effect or e.effect == filter.effect)
    if keep and filter.provides then
      for _, need in ipairs(e.needs or {}) do
        if not has(filter.provides, need) then
          keep = false
          break
        end
      end
    end
    if keep and filter.available then
      keep = (M.available(e))
    end
    if keep then
      out[#out + 1] = e
    end
  end
  return out
end

---The plugins that have entries, sorted.
---@return string[]
function M.plugins()
  local seen, out = {}, {}
  for _, e in ipairs(M.all()) do
    if not seen[e.plugin] then
      seen[e.plugin] = true
      out[#out + 1] = e.plugin
    end
  end
  table.sort(out)
  return out
end

---@param list string[]|nil
---@return string
local function join(list)
  return (list and #list > 0) and table.concat(list, ", ") or "-"
end

---@param r Lib.ContextMenu.Catalog.Requires|nil
---@return string
local function requires_text(r)
  if not r then
    return "-"
  end
  local parts = {}
  for _, p in ipairs(r.plugins or {}) do
    parts[#parts + 1] = p
  end
  for _, t in ipairs(r.tools or {}) do
    parts[#parts + 1] = "`" .. t .. "`"
  end
  if r.nvim then
    parts[#parts + 1] = "nvim>=" .. r.nvim
  end
  return #parts > 0 and table.concat(parts, ", ") or "-"
end

---The overview of every entry as Markdown, one table per plugin (what `CATALOG.md` holds).
---@return string
function M.markdown()
  local lines = {
    "# Context-menu catalogue",
    "",
    "Generated by `lib.nvim.contextmenu.catalog` (`catalog.markdown()`), do not edit by hand:",
    "change the data in `lua/lib/nvim/contextmenu/catalog/data/` and run",
    "`nvim -n -i NONE --headless -u NONE -l scripts/gen-contextmenu-catalog.lua`.",
    "",
    "Columns: **context** where it applies, **needs** what the action takes, **requires** what",
    "must be installed (plugins by module name, CLI tools in backticks), **effect** what it does.",
    "",
  }
  for _, plugin in ipairs(M.plugins()) do
    lines[#lines + 1] = "## " .. plugin
    lines[#lines + 1] = ""
    lines[#lines + 1] = "| id | label | group | context | needs | requires | effect |"
    lines[#lines + 1] = "|---|---|---|---|---|---|---|"
    for _, e in ipairs(M.list({ plugin = plugin })) do
      lines[#lines + 1] = ("| `%s` | %s | %s | %s | %s | %s | %s |"):format(
        e.id,
        e.label,
        e.group,
        join(e.context),
        join(e.needs),
        requires_text(e.requires),
        e.effect
      )
    end
    lines[#lines + 1] = ""
  end
  return table.concat(lines, "\n")
end

return M
