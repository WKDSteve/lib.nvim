---@module 'lib.nvim.view_file'
--- The shape of a saved view: a small Markdown file with frontmatter that holds a selection, a grouping and a way to
--- draw it, and no data of its own.
---
--- Extracted from `rules.nvim` (`rules.views`) and `tasks.nvim` (`tasks_nvim.views`), which kept the same view in two
--- copies: checking a view as a caller gives it (`normalize`), the frontmatter it is written as (`pairs_of`) and the
--- file text read back as a view (`parse_text`). What stays with the plugin: where the files live, the id, the
--- file system (lock, atomic write, symbolic links) and the errors of saving and deleting; those differ for good.
---
--- What differs between plugins is a parameter of `new`: the ways to draw (`displays`), the fields to group by
--- (`is_field`, with a `fields_hint` for the message), the selection (`select`: `{ name, key }` each, the key being
--- the frontmatter key) and whether an entry of a list may be empty (`allow_empty_word`).
---
--- ```lua
--- local view_file = require("lib.nvim.view_file").new({
---   displays = { "list", "matrix" },
---   is_field = function(field) return field == "status" or field == "prio" end,
---   fields_hint = "status, prio",
---   select = { { name = "statuses", key = "sel_statuses" } },
--- })
--- local view, err = view_file.normalize({ title = "Open", display = "list", group_by = "status" })
--- local pairs = view_file.pairs_of(view, { created = "2026-01-01", updated = "2026-01-01" }, false)
--- ```

local fm = require("lib.nvim.markdown.frontmatter")

local M = {}

---Most entries of a list of the selection, and of the folded groups.
M.MAX_LIST = 100
---Longest entry, title or query, in characters.
M.MAX_ENTRY = 300

---@class Lib.ViewFile.Config
---@field displays string[]                                   # The ways to draw a view; `matrix` needs a second field.
---@field is_field fun(field: any): boolean                   # Whether a value is a field a view can group by.
---@field fields_hint string                                  # Said in the message when `group_by` is not a field.
---@field select { name: string, key: string }[]              # The lists of the selection: their name and frontmatter key.
---@field allow_empty_word? boolean                           # An empty string is a word of a list (default false).
---@field max_list? integer                                   # Default `M.MAX_LIST`.
---@field max_entry? integer                                  # Default `M.MAX_ENTRY`.

---@class Lib.ViewFile
---@field normalize fun(def: table): table|nil, string|nil
---@field pairs_of fun(view: table, dates: { created?: string, updated: string }, patch: boolean): table[]
---@field parse_text fun(text: string, default_title: string): table|nil, string|nil

---@param s any
---@return boolean
local function has_control(s)
  return type(s) == "string" and s:find("[%c]") ~= nil
end

---A view-file model for one plugin.
---@param cfg Lib.ViewFile.Config
---@return Lib.ViewFile
function M.new(cfg)
  local max_list = cfg.max_list or M.MAX_LIST
  local max_entry = cfg.max_entry or M.MAX_ENTRY
  local display_set = {}
  for _, v in ipairs(cfg.displays) do
    display_set[v] = true
  end

  ---A list of short single-line words (the entries of the selection, the folded groups).
  ---@param value any
  ---@param what string
  ---@return string[]|nil list
  ---@return string|nil err
  local function words(value, what)
    if value == nil or value == vim.NIL then
      return {}, nil
    end
    if type(value) ~= "table" then
      return nil, what .. " must be a list of words"
    end
    if #value > max_list then
      return nil, ("%s has more than %d entries"):format(what, max_list)
    end
    local out, seen = {}, {}
    for _, v in ipairs(value) do
      if type(v) ~= "string" or (v == "" and not cfg.allow_empty_word) or has_control(v) then
        return nil, what .. " holds an entry that is not a word"
      end
      if vim.fn.strchars(v) > max_entry then
        return nil, ("%s holds an entry longer than %d characters"):format(what, max_entry)
      end
      if not seen[v] then
        seen[v] = true
        out[#out + 1] = v
      end
    end
    return out, nil
  end

  local self = {}

  ---Check a view as a caller gives it and put it in the shape the file and the document have.
  ---@param def table  `{ title, display, group_by, group_by2?, collapsed?, select? }`
  ---@return table|nil view
  ---@return string|nil err
  function self.normalize(def)
    if type(def) ~= "table" then
      return nil, "a view must be an object"
    end
    if type(def.title) ~= "string" or vim.trim(def.title) == "" then
      return nil, "a view needs a title"
    end
    if has_control(def.title) then
      return nil, "title contains a control character"
    end
    if vim.fn.strchars(def.title) > max_entry then
      return nil, ("title is longer than %d characters"):format(max_entry)
    end
    if not display_set[def.display] then
      return nil,
        ("display '%s' is unknown (expected %s)"):format(
          tostring(def.display),
          table.concat(cfg.displays, ", ")
        )
    end
    if not cfg.is_field(def.group_by) then
      return nil,
        ("group_by '%s' is not a field to group by (expected %s)"):format(
          tostring(def.group_by),
          cfg.fields_hint
        )
    end
    local second = def.group_by2
    if second == vim.NIL then
      second = nil
    end
    if second ~= nil then
      if def.display ~= "matrix" then
        return nil, "group_by2 is for a matrix only"
      end
      if not cfg.is_field(second) then
        return nil, ("group_by2 '%s' is not a field to group by"):format(tostring(second))
      end
      if second == def.group_by then
        return nil, "group_by2 must be another field than group_by"
      end
    elseif def.display == "matrix" then
      return nil, "a matrix needs group_by2"
    end
    local view = {
      title = vim.trim(def.title),
      display = def.display,
      group_by = def.group_by,
      group_by2 = second,
      select = {},
    }
    local collapsed, cerr = words(def.collapsed, "collapsed")
    if not collapsed then
      return nil, cerr
    end
    view.collapsed = collapsed
    local select = def.select
    if select ~= nil and select ~= vim.NIL and type(select) ~= "table" then
      return nil, "select must be an object"
    end
    select = (select ~= vim.NIL and select) or {}
    for key in pairs(select) do
      local known = key == "query"
      for _, s in ipairs(cfg.select) do
        known = known or s.name == key
      end
      if not known then
        return nil, ("select: unknown entry '%s'"):format(tostring(key))
      end
    end
    for _, s in ipairs(cfg.select) do
      local list, err = words(select[s.name], "select." .. s.name)
      if not list then
        return nil, err
      end
      view.select[s.name] = list
    end
    local query = select.query
    if query ~= nil and query ~= vim.NIL then
      if type(query) ~= "string" or has_control(query) or vim.fn.strchars(query) > max_entry then
        return nil, "select.query must be one line of text"
      end
      view.select.query = vim.trim(query) ~= "" and vim.trim(query) or nil
    end
    return view, nil
  end

  ---The frontmatter of a view, as `{ key, value }` pairs in the order the file has them; a key a view does not have is
  ---`frontmatter.REMOVE` when `patch` (a change of a file that exists), left out when new.
  ---@param view table
  ---@param dates { created?: string, updated: string }
  ---@param patch boolean
  ---@return table[]
  function self.pairs_of(view, dates, patch)
    local out =
      { { "title", view.title }, { "display", view.display }, { "group_by", view.group_by } }
    local function optional(key, value)
      if value ~= nil then
        out[#out + 1] = { key, value }
      elseif patch then
        out[#out + 1] = { key, fm.REMOVE }
      end
    end
    optional("group_by2", view.group_by2)
    optional("collapsed", #view.collapsed > 0 and view.collapsed or nil)
    for _, s in ipairs(cfg.select) do
      local list = view.select[s.name]
      optional(s.key, list and #list > 0 and list or nil)
    end
    optional("sel_query", view.select.query)
    if dates.created then
      out[#out + 1] = { "created", dates.created }
    end
    out[#out + 1] = { "updated", dates.updated }
    return out
  end

  ---A view file's text read as a view (without what the plugin adds: its id, version and place).
  ---@param text string
  ---@param default_title string  # The title of a file that has none (its name).
  ---@return table|nil view  # With `created` and `updated` as the file has them.
  ---@return string|nil problem
  function self.parse_text(text, default_title)
    local parsed, perr = fm.parse(text)
    if not parsed then
      return nil, "frontmatter unreadable: " .. tostring(perr)
    end
    local function get(key)
      return fm.get(parsed, key)
    end
    local function list(key)
      local v = get(key)
      if v == nil then
        return {}
      end
      return type(v) == "table" and v or { v }
    end
    local select = {}
    for _, s in ipairs(cfg.select) do
      select[s.name] = list(s.key)
    end
    select.query = get("sel_query")
    local view, err = self.normalize({
      title = get("title") or default_title,
      display = get("display"),
      group_by = get("group_by"),
      group_by2 = get("group_by2"),
      collapsed = list("collapsed"),
      select = select,
    })
    if not view then
      return nil, err
    end
    view.created = get("created")
    view.updated = get("updated")
    return view, nil
  end

  return self
end

return M
