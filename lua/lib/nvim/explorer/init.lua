---@module 'lib.nvim.explorer'
---@brief File-explorer adapters: which explorer owns a buffer, which path is under the cursor, how to reload.
---@description
--- A registry of explorer adapters (neo-tree, NvimTree, netrw, oil built in) on `lib.nvim.registry`, so a plugin
--- that reacts to "the file under the cursor in whatever explorer is open" or "the tree changed on disk" asks
--- here instead of branching on `filetype` itself.
---
---   local explorer = require("lib.nvim.explorer")
---   explorer.current()          --> "oil" (name of the adapter that owns the current buffer) or nil
---   explorer.current_path()     --> "C:/proj/src/a.lua" or nil
---   explorer.reload_all()       --> { "nvim-tree" } (the adapters that reloaded)
---   explorer.register({ name = "mine", filetypes = { "mine" }, current_path = function(buf) ... end })
---
--- Every call is soft: a missing plugin means "not recognised" (`nil` / `false`), never an error, and an adapter
--- that raises is skipped. Not a tree data structure (`lib.nvim.tree`) and not neo-tree internals
--- (`lib.nvim.neotree`); this module only answers detection, path and reload.

local registry = require("lib.nvim.registry")

local M = {}

---@class Lib.Explorer.Adapter
---@field name string                                       # Unique key; registering the same name replaces it.
---@field filetypes? string[]                               # Buffers with one of these filetypes belong to it.
---@field detect? fun(buf: integer): boolean                # Overrides `filetypes` when the filetype is not enough.
---@field module? string                                    # Plugin module; `reload` only runs once it is loaded.
---@field current_path? fun(buf: integer): string|nil       # Path under the cursor of an explorer buffer.
---@field reload? fun()                                     # Re-read the tree from disk.

---@param path string
---@param name string
---@return string
local function join(path, name)
  local sep = (path:sub(-1) == "/" or path:sub(-1) == "\\") and "" or "/"
  return path .. sep .. name
end

---@type Lib.Explorer.Adapter[]
local BUILTIN = {
  {
    name = "neo-tree",
    filetypes = { "neo-tree" },
    module = "neo-tree",
    current_path = function()
      local ok, manager = pcall(require, "neo-tree.sources.manager")
      if not ok then
        return nil
      end
      local state = manager.get_state_for_window()
      local node = state and state.tree and state.tree:get_node()
      return node and node:get_id() or nil
    end,
    reload = function()
      require("neo-tree.sources.manager").refresh("filesystem")
    end,
  },
  {
    name = "nvim-tree",
    filetypes = { "NvimTree" },
    module = "nvim-tree",
    current_path = function()
      local ok, api = pcall(require, "nvim-tree.api")
      if not ok then
        return nil
      end
      local node = api.tree.get_node_under_cursor()
      return node and node.absolute_path or nil
    end,
    reload = function()
      require("nvim-tree.api").tree.reload()
    end,
  },
  {
    name = "netrw",
    filetypes = { "netrw" },
    current_path = function(buf)
      local dir = vim.b[buf].netrw_curdir
      local file = vim.fn.expand("<cfile>")
      if type(dir) == "string" and dir ~= "" and file ~= "" then
        return join(dir, file)
      end
      return nil
    end,
    -- no reload: netrw re-reads a directory each time its buffer is entered.
  },
  {
    name = "oil",
    filetypes = { "oil" },
    module = "oil",
    current_path = function()
      local ok, oil = pcall(require, "oil")
      if not ok then
        return nil
      end
      local dir, entry = oil.get_current_dir(), oil.get_cursor_entry()
      if dir and entry and entry.name then
        return join(dir, entry.name)
      end
      return nil
    end,
    -- oil's refresh acts on the current buffer (and may ask about unsaved edits): only
    -- from an oil buffer. Elsewhere oil watches the disk itself.
    reload = function()
      if vim.bo.filetype == "oil" then
        require("oil.actions").refresh.callback()
      end
    end,
  },
}

local adapters = registry.new({
  name = "explorer",
  validate = function(_, adapter)
    if type(adapter) ~= "table" or type(adapter.name) ~= "string" or adapter.name == "" then
      return false, "an explorer adapter needs a name"
    end
    if adapter.filetypes == nil and adapter.detect == nil then
      return false, "an explorer adapter needs filetypes or detect"
    end
    return true
  end,
  loader = function()
    for _, adapter in ipairs(BUILTIN) do
      M.register(adapter)
    end
  end,
})

---Register an explorer adapter (replaces one of the same name, keeping its position).
---@param adapter Lib.Explorer.Adapter
---@return nil
function M.register(adapter)
  vim.validate("adapter", adapter, "table")
  adapters:register(adapter.name, adapter)
end

---Remove an adapter by name.
---@param name string
---@return boolean removed
function M.unregister(name)
  return adapters:unregister(name)
end

---Every adapter, in registration order.
---@return Lib.Explorer.Adapter[]
function M.adapters()
  return adapters:all()
end

---Back to the four built-in adapters (tests).
---@return nil
function M.reset()
  adapters:reset()
end

---@param adapter Lib.Explorer.Adapter
---@param buf integer
---@return boolean
local function owns(adapter, buf)
  if adapter.detect then
    local ok, res = pcall(adapter.detect, buf)
    return ok and res == true
  end
  local ft = vim.bo[buf].filetype
  return vim.tbl_contains(adapter.filetypes or {}, ft)
end

---The adapter that owns `buf` (default: the current buffer), or nil.
---@param buf? integer
---@return Lib.Explorer.Adapter|nil
function M.detect(buf)
  if buf == nil or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  for _, adapter in ipairs(M.adapters()) do
    if owns(adapter, buf) then
      return adapter
    end
  end
  return nil
end

---Name of the explorer that owns `buf`, or nil when it is not an explorer buffer.
---@param buf? integer
---@return string|nil
function M.current(buf)
  local adapter = M.detect(buf)
  return adapter and adapter.name or nil
end

---Path under the cursor when `buf` (default: current) is an explorer buffer shown in a window, else nil.
---@param buf? integer
---@return string|nil
function M.current_path(buf)
  if buf == nil or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  local adapter = M.detect(buf)
  if not adapter or not adapter.current_path then
    return nil
  end
  -- The adapters read the cursor of the *current* window: run them in a window that shows `buf`.
  local win = vim.api.nvim_get_current_buf() == buf and vim.api.nvim_get_current_win()
    or vim.fn.win_findbuf(buf)[1]
  if not win then
    return nil
  end
  local ok, path = pcall(vim.api.nvim_win_call, win, function()
    return adapter.current_path(buf)
  end)
  if ok and type(path) == "string" and path ~= "" then
    return path
  end
  return nil
end

---Reload every explorer whose plugin is loaded. A failing adapter does not stop the others.
---@return string[] reloaded # Adapter names whose reload ran without error.
function M.reload_all()
  local done = {}
  for _, adapter in ipairs(M.adapters()) do
    local active = adapter.module == nil or package.loaded[adapter.module] ~= nil
    if adapter.reload and active and pcall(adapter.reload) then
      done[#done + 1] = adapter.name
    end
  end
  return done
end

return M
