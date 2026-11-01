---@module 'lib.nvim.dev.pattern_usage'
--- Who actually requires the modules of the pattern catalogue? A pattern
--- module nobody uses is documentation, not a building block, so
--- `docs/patterns.md` carries a generated "Used by" column.
---@description
--- Reads the join `docmap.core.consumers` builds from lib.nvim's own module map
--- and the committed/local maps of the sibling repos (`*/docs/map/module_map.json`):
---
---   * `external`     -- at least one sibling repo requires the module
---   * `internal`     -- only lib.nvim itself does
---   * `unreferenced` -- nobody
---
--- and writes one cell per catalogue row. docmap is a development dependency of
--- this tool only (it is looked up beside lib.nvim when it is not on the
--- runtimepath); nothing in lib.nvim's runtime requires it.
---
--- The column is a snapshot: it is only as complete as the maps on this machine.
--- "unreferenced" means "no map among those read", not dead code.
---
--- Run it with `nvim --headless -u NONE -l scripts/pattern_usage.lua [--check]`.

local M = {}

---@class Lib.Dev.PatternUsage.Entry
---@field kind "external"|"internal"|"unreferenced"
---@field consumers string[] Names of the sibling repos that require the module

---@class Lib.Dev.PatternUsage.Opts
---@field root? string lib.nvim checkout (default: this file's repository)
---@field dir? string Directory holding the sibling checkouts (default: parent of `root`)
---@field map? string lib.nvim's own map (default `<root>/docs/map/module_map.json`)
---@field docmap? string docmap.nvim checkout (default: `<dir>/docmap.nvim`)

local COLUMN = "Used by"
local SELF = "lib.nvim"
local MAX_NAMES = 4
local SHOWN_NAMES = 3

---@param path string
---@return string
local function normalize(path)
  return (path:gsub("\\", "/"):gsub("/+$", ""))
end

---@return string
local function default_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return normalize(vim.fn.fnamemodify(source, ":p:h:h:h:h:h"))
end

---Repository name without the `.nvim` suffix, to keep the cell short.
---@param name string
---@return string
local function short(name)
  return (name:gsub("%.nvim$", ""))
end

---The cell for one catalogue row.
---@param modules string[] The module paths the row stands for
---@param usage table<string, Lib.Dev.PatternUsage.Entry>
---@return string
function M.cell(modules, usage)
  local names, seen, internal, known = {}, {}, false, false
  for _, module in ipairs(modules) do
    local entry = usage[module]
    if entry then
      known = true
      internal = internal or entry.kind == "internal"
      for _, name in ipairs(entry.consumers) do
        if not seen[name] then
          seen[name] = true
          names[#names + 1] = short(name)
        end
      end
    end
  end
  if not known then
    return "—"
  end
  table.sort(names)
  if #names == 0 then
    return internal and SELF .. " only" or "—"
  end
  if #names <= MAX_NAMES then
    return table.concat(names, ", ")
  end
  return ("%d repos (%s, …)"):format(
    #names,
    table.concat(vim.list_slice(names, 1, SHOWN_NAMES), ", ")
  )
end

---The `lib.*` modules a catalogue row stands for: the backticked ones before the
---" — see also" part, so a related module is not credited to the pattern.
---@param module_cell string
---@return string[]
function M.row_modules(module_cell)
  local head = module_cell:match("^(.-) — ") or module_cell
  local out = {}
  for module in head:gmatch("`(lib%.[%w_.]+)`") do
    out[#out + 1] = module
  end
  return out
end

---@param row string
---@return string[]|nil cells nil when the row does not split into table cells
local function split_row(row)
  local body = row:match("^| (.*) |$")
  if not body then
    return nil
  end
  return vim.split(body, " | ", { plain = true })
end

---Adds or refreshes the "Used by" column of every `| Pattern |` table.
---@param lines string[]
---@param usage table<string, Lib.Dev.PatternUsage.Entry>
---@return string[] lines
---@return integer rows How many catalogue rows got a cell
function M.sync_lines(lines, usage)
  local out, rows, in_table = {}, 0, false
  for _, line in ipairs(lines) do
    local cells = line:sub(1, 1) == "|" and split_row(line) or nil
    if not cells then
      in_table = false
      out[#out + 1] = line
    elseif cells[1] == "Pattern" then
      in_table = true
      if cells[#cells] ~= COLUMN then
        cells[#cells + 1] = COLUMN
      end
      out[#out + 1] = "| " .. table.concat(cells, " | ") .. " |"
    elseif in_table and cells[1]:match("^%-%-%-") then
      out[#out + 1] = "| " .. table.concat(vim.fn["repeat"]({ "---" }, 6), " | ") .. " |"
    elseif in_table then
      if #cells >= 6 then
        cells[#cells] = nil
      end
      cells[#cells + 1] = M.cell(M.row_modules(cells[3] or ""), usage)
      rows = rows + 1
      out[#out + 1] = "| " .. table.concat(cells, " | ") .. " |"
    else
      out[#out + 1] = line
    end
  end
  return out, rows
end

---Usage of every module in lib.nvim's own map.
---@param opts? Lib.Dev.PatternUsage.Opts
---@return table<string, Lib.Dev.PatternUsage.Entry>|nil usage
---@return string|integer err_or_maps An error text when `usage` is nil, else the number of maps read
function M.usage(opts)
  opts = opts or {}
  local root = normalize(opts.root or default_root())
  local dir = normalize(opts.dir or vim.fs.dirname(root))

  local ok, consumers = pcall(require, "docmap.core.consumers")
  if not ok then
    local docmap = normalize(opts.docmap or (dir .. "/docmap.nvim"))
    if vim.fn.isdirectory(docmap) == 0 then
      return nil, "docmap.nvim not found (looked in " .. docmap .. ")"
    end
    vim.opt.runtimepath:prepend(docmap)
    ok, consumers = pcall(require, "docmap.core.consumers")
    if not ok then
      return nil, "docmap.core.consumers failed to load: " .. tostring(consumers)
    end
  end

  local map = opts.map or (root .. "/docs/map/module_map.json")
  local content = require("lib.nvim.fs.read")(map)
  if not content then
    return nil, "no module map at " .. map .. " (generate it with docmap first)"
  end
  local ir = require("docmap.core.artifact").decode(content)
  if not ir then
    return nil, "module map is not decodable: " .. map
  end

  local maps = consumers.load(dir, root)
  if #maps == 0 then
    return nil, "no consumer maps found under " .. dir
  end

  local usage = {}
  for _, e in ipairs(consumers.index(ir, maps).entries) do
    usage[e.module] = { kind = e.kind, consumers = e.consumers }
  end
  return usage, #maps
end

---Rewrites `path` (default `<root>/docs/patterns.md`) in place.
---@param opts? Lib.Dev.PatternUsage.Opts|{ path?: string, check?: boolean }
---@return { rows: integer, maps: integer, changed: boolean }|nil result
---@return string|nil err
function M.sync(opts)
  opts = opts or {}
  local root = normalize(opts.root or default_root())
  local path = opts.path or (root .. "/docs/patterns.md")
  local usage, maps = M.usage(opts)
  if not usage then
    return nil, tostring(maps)
  end
  local ok, before = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, "cannot read " .. path
  end
  local after, rows = M.sync_lines(before, usage)
  if rows == 0 then
    return nil, "no catalogue rows found in " .. path
  end
  local changed = not vim.deep_equal(before, after)
  if changed and not opts.check then
    vim.fn.writefile(after, path)
  end
  return {
    rows = rows,
    maps = maps --[[@as integer]],
    changed = changed,
  }
end

return M
