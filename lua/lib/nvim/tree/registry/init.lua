---@module 'lib.nvim.tree.registry'
--- Where plugins announce what they add to a tree view: sources (they supply nodes), decorators (badges on
--- nodes) and actions (something to do with nodes). Three ordered lists and a change feed, nothing else.
---
--- Registering loads nothing and knows no reader: a plugin calls `source{}` when it is loaded, and a tree
--- view (filetree.nvim's own tree) reads the lists when it opens and follows `subscribe` for late arrivals.
--- With no reader installed the entries are never looked at, so a plugin needs no "is the tree there?" check
--- and never has to wait for another plugin to load.
---
--- What an entry means (when `root` is called, what a badge looks like, where an action applies) is the
--- reader's contract, not this module's: it checks only the few fields it needs to keep the lists sane.
---
--- ```lua
--- local registry = require("lib.nvim.tree.registry")
---
--- local remove = registry.decorator({
---   name = "tests",
---   get = function(path) return cache[path] end,          -- a lookup, no I/O
---   subscribe = function(emit) return store.subscribe(emit) end,
--- })
---
--- registry.list("decorator")              --> entries in registration order
--- registry.get("decorator", "tests")
--- local stop = registry.subscribe(function(ev) end)   -- ev = { kind, name, entry?, replaced? }
--- remove()                                -- only removes the entry it registered
--- ```

local registry = require("lib.nvim.registry")

local M = {}

---@type Lib.Tree.Registry.Kind[]
local KINDS = { "source", "decorator", "action" }

--- The functions an entry of a kind must carry, besides `name`.
---@type table<Lib.Tree.Registry.Kind, string[]>
local REQUIRED = {
  source = { "root" },
  decorator = { "get", "subscribe" },
  action = { "run" },
}

---@param kind Lib.Tree.Registry.Kind
---@return Lib.Registry
local function new_list(kind)
  return registry.new({
    name = "tree." .. kind,
    validate = function(name, entry)
      if type(name) ~= "string" or name == "" then
        return false, "name must be a non-empty string"
      end
      if type(entry) ~= "table" then
        return false, "the entry must be a table"
      end
      for _, field in ipairs(REQUIRED[kind]) do
        if type(entry[field]) ~= "function" then
          return false, ("a %s needs %s()"):format(kind, field)
        end
      end
      return true
    end,
  })
end

---@type table<Lib.Tree.Registry.Kind, Lib.Registry>
local lists = {}
for _, kind in ipairs(KINDS) do
  lists[kind] = new_list(kind)
end

---@type table<integer, fun(ev: Lib.Tree.Registry.Event)>
local subscribers = {}
local next_subscriber = 1

---@param kind any
---@return Lib.Registry
local function list_of(kind)
  local list = lists[kind]
  if not list then
    error(
      ("lib.nvim.tree.registry: unknown kind %s (source, decorator, action)"):format(tostring(kind)),
      3
    )
  end
  return list
end

--- Tell every subscriber. A subscriber that raises does not stop the others and does not fail the
--- registration it was told about: the plugin that registered is not the one with the bug.
---@param ev Lib.Tree.Registry.Event
local function publish(ev)
  local ids = vim.tbl_keys(subscribers)
  table.sort(ids)
  for _, id in ipairs(ids) do
    local fn = subscribers[id]
    if fn then
      local ok, err = pcall(fn, ev)
      if not ok then
        require("lib.nvim.notify")
          .create("[lib.nvim.tree.registry]")
          .error(("subscriber failed on %s %s: %s"):format(ev.kind, ev.name, tostring(err)))
      end
    end
  end
end

---@param kind Lib.Tree.Registry.Kind
---@param entry table
---@return fun(): boolean unregister
local function add(kind, entry)
  local list = lists[kind]
  local name = type(entry) == "table" and entry.name or nil
  local replaced = name ~= nil and list:has(name)
  local ok, err = pcall(list.register, list, name, entry)
  if not ok then
    -- level 2 is the plugin that registered: source()/decorator()/action() tail-call this function, so
    -- they have no frame of their own
    error(tostring(err), 2)
  end
  publish({ kind = kind, name = name, entry = entry, replaced = replaced or nil })
  return function()
    -- a later registration under the same name is somebody else's entry by now
    if list:get(name) ~= entry then
      return false
    end
    list:unregister(name)
    publish({ kind = kind, name = name })
    return true
  end
end

---Register a source: it supplies the nodes of one view. Needs `name` and `root()`.
---A second registration under the same name replaces the first and keeps its position.
---@param entry Lib.Tree.Registry.Source
---@return fun(): boolean unregister  # Removes this entry; false when it was replaced or removed already.
function M.source(entry)
  return add("source", entry)
end

---Register a decorator: badges on nodes, looked up by path or id. Needs `name`, `get()` and `subscribe()`.
---@param entry Lib.Tree.Registry.Decorator
---@return fun(): boolean unregister
function M.decorator(entry)
  return add("decorator", entry)
end

---Register an action: something to do with the node under the cursor or the selection. Needs `name` and `run()`.
---@param entry Lib.Tree.Registry.Action
---@return fun(): boolean unregister
function M.action(entry)
  return add("action", entry)
end

---The entries of one kind, in registration order (a copy of the list, the entries themselves are shared).
---@param kind Lib.Tree.Registry.Kind
---@return table[]
function M.list(kind)
  return list_of(kind):all()
end

---@param kind Lib.Tree.Registry.Kind
---@param name string
---@return table|nil
function M.get(kind, name)
  return list_of(kind):get(name)
end

---Follow registrations and removals. `ev.entry` is nil for a removal; `ev.replaced` is true when the name
---was taken before. Entries registered earlier are not replayed: read them with `list()` first.
---@param fn fun(ev: Lib.Tree.Registry.Event)
---@return fun() unsubscribe
function M.subscribe(fn)
  if type(fn) ~= "function" then
    error("lib.nvim.tree.registry: subscribe needs a function", 2)
  end
  local id = next_subscriber
  next_subscriber = id + 1
  subscribers[id] = fn
  return function()
    subscribers[id] = nil
  end
end

---Empty all three lists and drop every subscriber. For tests.
---@return nil
function M.reset()
  for _, kind in ipairs(KINDS) do
    lists[kind]:reset()
  end
  subscribers = {}
end

return M
