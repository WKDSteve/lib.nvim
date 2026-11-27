---@module 'lib.nvim.crossfeature'
---@brief Catalogue of the cross-features: the connections between the plugins and apps of this ecosystem.
---@description
--- Every connection where one repo uses another, as a list to ask: which side uses which
--- (`from`, `to`), how (`kind`), whether it exists (`status`: present, planned, idea), one
--- sentence what it does (`text`), the file that shows it (`evidence`), and the ideas and tasks
--- it came from. Plugins carry the names of the context-menu catalogue (`images` for
--- images.nvim), apps their repository name.
--- >
---   local cf = require("lib.nvim.crossfeature")
---   -- what does images.nvim give and take?
---   for _, e in ipairs(cf.list({ plugin = "images" })) do print(e.id, e.text) end
---   -- which planned connections would work on this machine once built?
---   cf.list({ status = "planned", available = true })
--- <
--- The built-in data is GENERATED from `integrations.json` of the workshop vault (the one
--- source; `crossfeature.mjs` there writes `crossfeature/data.lua`). A plugin can add its own
--- entries at runtime with `register`. lib.nvim never requires a plugin except to ask whether
--- it is installed (`available`).
---
--- `crossfeature.markdown()` renders the published overview `docs/CROSSFEATURE-CATALOG.md`
--- (without private repos; a spec keeps it in sync).

local M = {}

local STATUSES = { present = true, planned = true, idea = true }

---@type table<string, Lib.CrossFeature.Entry>
local by_id = {}
---@type string[]  ids in registration order, for a stable listing
local order = {}
---@type table<string, Lib.CrossFeature.Repo>|nil
local repos_by_name
---@type Lib.CrossFeature.Repo[]
local repo_list = {}
local builtin_loaded = false

---@param v any
---@return boolean
local function is_name_list(v)
  if type(v) ~= "table" then
    return false
  end
  for _, x in ipairs(v) do
    if type(x) ~= "string" or x == "" then
      return false
    end
  end
  return true
end

---Why `e` is not a valid entry, or nil.
---@param e any
---@return string|nil
function M.validate(e)
  if type(e) ~= "table" then
    return "entry must be a table"
  end
  if type(e.id) ~= "string" or e.id == "" then
    return "id is required"
  end
  for _, k in ipairs({ "from", "to", "kind", "text" }) do
    if type(e[k]) ~= "string" or e[k] == "" then
      return k .. " is required"
    end
  end
  if e.from == e.to then
    return "from and to must name two repos"
  end
  if not STATUSES[e.status] then
    return "status must be one of present/planned/idea"
  end
  for _, k in ipairs({ "ideas", "tasks" }) do
    if e[k] ~= nil and not is_name_list(e[k]) then
      return k .. " must be a list of strings"
    end
  end
  if e.status == "planned" and not (e.tasks and #e.tasks > 0) then
    return "a planned entry names the task that builds it"
  end
  local ev = e.evidence
  if ev ~= nil and (type(ev) ~= "table" or type(ev.file) ~= "string" or ev.file == "") then
    return "evidence must be { repo, file }"
  end
  return nil
end

---Add (or replace, by `id`) one entry or a list of entries. Invalid entries raise.
---An entry without `id` gets `from>to`.
---@param entries Lib.CrossFeature.Entry|Lib.CrossFeature.Entry[]
function M.register(entries)
  if type(entries) == "table" and (entries.id ~= nil or entries.from ~= nil) then
    entries = { entries }
  end
  for _, e in ipairs(entries) do
    if
      type(e) == "table"
      and e.id == nil
      and type(e.from) == "string"
      and type(e.to) == "string"
    then
      e.id = e.from .. ">" .. e.to
    end
    local err = M.validate(e)
    if err then
      error(("crossfeature: %s (%s)"):format(err, tostring(type(e) == "table" and e.id or e)), 2)
    end
    if not by_id[e.id] then
      order[#order + 1] = e.id
    end
    by_id[e.id] = e
  end
end

local function load_builtin()
  if builtin_loaded then
    return
  end
  builtin_loaded = true
  repos_by_name = {}
  repo_list = {}
  ---@type boolean, Lib.CrossFeature.Data
  local ok, data = pcall(require, "lib.nvim.crossfeature.data")
  if not ok or type(data) ~= "table" then
    return
  end
  for _, r in ipairs(data.repos or {}) do
    repos_by_name[r.name] = r
    repo_list[#repo_list + 1] = r
  end
  -- a runtime `register` that came first wins over the built-in entry with the same id
  for _, e in ipairs(data.entries or {}) do
    if not by_id[e.id] then
      M.register(e)
    end
  end
end

---Drop everything registered at runtime and reload the built-in data on the next query.
function M.reset()
  by_id, order, builtin_loaded, repos_by_name, repo_list = {}, {}, false, nil, {}
end

---@return Lib.CrossFeature.Entry[]
function M.all()
  load_builtin()
  local out = {}
  for _, id in ipairs(order) do
    out[#out + 1] = by_id[id]
  end
  return out
end

---@param id string
---@return Lib.CrossFeature.Entry|nil
function M.get(id)
  load_builtin()
  return by_id[id]
end

---The entry itself, or the entry with that id.
---@param e Lib.CrossFeature.Entry|string|nil
---@return Lib.CrossFeature.Entry|nil
function M.resolve(e)
  if type(e) == "string" then
    return M.get(e)
  end
  return e
end

---The repos the built-in data names, sorted by name.
---@return Lib.CrossFeature.Repo[]
function M.repos()
  load_builtin()
  return vim.list_extend({}, repo_list)
end

---@param name string  catalogue name, `images`
---@return Lib.CrossFeature.Repo|nil
function M.repo(name)
  load_builtin()
  return repos_by_name and repos_by_name[name] or nil
end

---Whether a side of the entry is a private repo (never named in a published overview).
---@param e Lib.CrossFeature.Entry
---@return boolean
function M.is_private(e)
  if e.visibility == "private" then
    return true
  end
  local a, b = M.repo(e.from), M.repo(e.to)
  return (a ~= nil and a.visibility == "private") or (b ~= nil and b.visibility == "private")
end

---Whether one side is installed: a plugin when its main module `require`s (a repo the data does
---not know counts as a plugin whose module is its name), an app when its command is executable
---(the native apps install a command of their own name).
---@param name string
---@param memo? table<string, boolean>
---@return boolean
function M.installed(name, memo)
  if memo and memo[name] ~= nil then
    return memo[name]
  end
  local r = M.repo(name)
  local ok
  if r == nil or r.kind == "plugin" then
    local mod = (r and r.module) or name
    ok = package.loaded[mod] ~= nil or (pcall(require, mod))
  else
    ok = vim.fn.executable(r.name) == 1
  end
  if memo then
    memo[name] = ok
  end
  return ok
end

---Whether both sides are installed here, and which are not.
---@param e Lib.CrossFeature.Entry|string  the entry or its id
---@param memo? table<string, boolean>  answers of `installed` to reuse within one query
---@return boolean ok
---@return string[] missing  the names of the sides that are not installed
function M.available(e, memo)
  local entry = M.resolve(e)
  if not entry then
    return false, {}
  end
  local missing = {}
  for _, side in ipairs({ entry.from, entry.to }) do
    if not M.installed(side, memo) then
      missing[#missing + 1] = side
    end
  end
  return #missing == 0, missing
end

---@param list string[]|nil
---@param value string
---@return boolean
local function has(list, value)
  for _, v in ipairs(list or {}) do
    if v == value then
      return true
    end
  end
  return false
end

---Entries matching all given conditions (see `Lib.CrossFeature.Filter`).
---@param filter? Lib.CrossFeature.Filter
---@return Lib.CrossFeature.Entry[]
function M.list(filter)
  filter = filter or {}
  local memo = {}
  local out = {}
  for _, e in ipairs(M.all()) do
    local keep = (not filter.plugin or e.from == filter.plugin or e.to == filter.plugin)
      and (not filter.from or e.from == filter.from)
      and (not filter.to or e.to == filter.to)
      and (not filter.kind or e.kind == filter.kind)
      and (not filter.status or e.status == filter.status)
      and (not filter.idea or has(e.ideas, filter.idea))
      and (not filter.task or has(e.tasks, filter.task))
    if keep and filter.visibility ~= nil then
      keep = M.is_private(e) == (filter.visibility == "private")
    end
    if keep and filter.available then
      keep = (M.available(e, memo))
    end
    if keep then
      out[#out + 1] = e
    end
  end
  return out
end

---The context-menu entries that bring this connection into a menu: an entry of one side whose
---`cross` names the other (`lib.nvim.contextmenu.catalog`).
---@param e Lib.CrossFeature.Entry|string  the entry or its id
---@return Lib.ContextMenu.Catalog.Entry[]
function M.menu_entries(e)
  local entry = M.resolve(e)
  if not entry then
    return {}
  end
  local from, to = entry.from, entry.to
  local out = {}
  for _, m in ipairs(require("lib.nvim.contextmenu.catalog").list({ cross = true })) do
    if (m.plugin == from and has(m.cross, to)) or (m.plugin == to and has(m.cross, from)) then
      out[#out + 1] = m
    end
  end
  return out
end

---The connections behind a context-menu entry with `cross`: for each plugin it brings in, the
---entries between the owner and that plugin (either way round), present ones first.
---@param m Lib.ContextMenu.Catalog.Entry|string  the menu entry or its id
---@return Lib.CrossFeature.Entry[]
function M.for_menu(m)
  ---@type Lib.ContextMenu.Catalog.Entry|nil
  local menu
  if type(m) == "string" then
    menu = require("lib.nvim.contextmenu.catalog").get(m)
  else
    menu = m
  end
  if not menu or not menu.cross then
    return {}
  end
  local owner = menu.plugin
  local present, other = {}, {}
  for _, e in ipairs(M.all()) do
    for _, c in ipairs(menu.cross) do
      if (e.from == owner and e.to == c) or (e.from == c and e.to == owner) then
        local into = e.status == "present" and present or other
        into[#into + 1] = e
        break
      end
    end
  end
  return vim.list_extend(present, other)
end

---The menu entries with `cross` that name a plugin without a present connection to their owner:
---each is a gap in `integrations.json` (the same question as `menu-cross.mjs --check` of the vault).
---@return { id: string, plugin: string, cross: string }[]
function M.unlinked_menu_entries()
  local linked = {}
  for _, e in ipairs(M.list({ status = "present" })) do
    linked[e.from .. ">" .. e.to] = true
    linked[e.to .. ">" .. e.from] = true
  end
  local out = {}
  for _, m in ipairs(require("lib.nvim.contextmenu.catalog").list({ cross = true })) do
    for _, c in ipairs(m.cross) do
      if not linked[m.plugin .. ">" .. c] then
        out[#out + 1] = { id = m.id, plugin = m.plugin, cross = c }
      end
    end
  end
  return out
end

---@param s string
---@return string
local function cell(s)
  return (s:gsub("|", "\\|"):gsub("\n", " "))
end

---@param list string[]|nil
---@param code? boolean  wrap each item in backticks
---@return string
local function join(list, code)
  if not list or #list == 0 then
    return "-"
  end
  local parts = {}
  for i, v in ipairs(list) do
    parts[i] = code and ("`" .. v .. "`") or v
  end
  return table.concat(parts, ", ")
end

local SECTIONS = {
  { status = "present", title = "Present", about = "Connections that exist." },
  {
    status = "planned",
    title = "Planned",
    about = "Connections an open task builds (the tasks of the workshop vault).",
  },
  { status = "idea", title = "Ideas", about = "Proposed connections without an open task." },
}

---The published overview as Markdown, one table per status (what `docs/CROSSFEATURE-CATALOG.md`
---holds). Connections with a private side are left out, only counted.
---@return string
function M.markdown()
  local lines = {
    "# Cross-feature catalogue",
    "",
    "Generated by `lib.nvim.crossfeature` (`crossfeature.markdown()`), do not edit by hand. The data",
    "comes from `integrations.json` of the workshop vault (`crossfeature.mjs` writes",
    "`lua/lib/nvim/crossfeature/data.lua`); then run",
    "`nvim -n -i NONE --headless -u NONE -l scripts/gen-crossfeature-catalog.lua`.",
    "",
    "Columns: **from** uses **to**; **kind** how (`requires`, `optional`: a guarded require,",
    "`event`, `menu`, `reads`, ...); **proof** the file that shows it; **menu** the context-menu",
    "entries that bring it in (`lib.nvim.contextmenu.catalog`, field `cross`); **ideas** the numbers",
    "of the cross-feature analysis of 2026-11-17 (`1`..`10`, `K-n`).",
    "",
  }
  local hidden = #M.list({ visibility = "private" })
  if hidden > 0 then
    lines[#lines + 1] = ("%d connections with a private repo are not listed here."):format(hidden)
    lines[#lines + 1] = ""
  end
  for _, s in ipairs(SECTIONS) do
    local rows = M.list({ status = s.status, visibility = "public" })
    lines[#lines + 1] = ("## %s (%d)"):format(s.title, #rows)
    lines[#lines + 1] = ""
    lines[#lines + 1] = s.about
    lines[#lines + 1] = ""
    if #rows > 0 then
      if s.status == "present" then
        lines[#lines + 1] = "| id | from | to | kind | text | proof | menu | ideas |"
        lines[#lines + 1] = "|---|---|---|---|---|---|---|---|"
      else
        lines[#lines + 1] = "| id | from | to | kind | text | ideas | tasks |"
        lines[#lines + 1] = "|---|---|---|---|---|---|---|"
      end
      for _, e in ipairs(rows) do
        local head = ("| `%s` | %s | %s | %s | %s |"):format(
          e.id,
          e.from,
          e.to,
          e.kind,
          cell(e.text)
        )
        if s.status == "present" then
          local menu = {}
          for _, m in ipairs(M.menu_entries(e)) do
            menu[#menu + 1] = m.id
          end
          local proof = e.evidence and ("`%s/%s`"):format(e.evidence.repo, e.evidence.file) or "-"
          lines[#lines + 1] = ("%s %s | %s | %s |"):format(
            head,
            cell(proof),
            join(menu, true),
            join(e.ideas)
          )
        else
          lines[#lines + 1] = ("%s %s | %s |"):format(head, join(e.ideas), join(e.tasks, true))
        end
      end
      lines[#lines + 1] = ""
    end
  end
  return table.concat(lines, "\n")
end

return M
