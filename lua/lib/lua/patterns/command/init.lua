---@module 'lib.lua.patterns.command'
--- Command: an action as data, with undo and redo.
---
--- A command is `{ name, run = fn(...) -> undo_state, undo = fn(undo_state, ...) }`. `run` returns
--- whatever `undo` needs to take the effect back (the old value, a snapshot). A history executes commands
--- and keeps the undo and redo stacks.
---
--- ```lua
--- local command = require("lib.lua.patterns.command")
--- local h = command.history({ limit = 100 })
--- local set_title = {
---   name = "set title",
---   run = function(buf, title) local old = get(buf); put(buf, title); return old end,
---   undo = function(old, buf) put(buf, old) end,
--- }
--- h:run(set_title, 1, "New")
--- h:undo()  -- back to the old title
--- h:redo()
--- ```
---
--- For `:Command <sub>` routing of user commands see `lib.nvim.bindings.usercmd.composer`.

require("lib.lua.patterns.command.@types")

local M = {}

-- LuaJIT (Neovim's Lua runtime) only has the global `unpack`; `table.unpack` is Lua 5.2+.
---@diagnostic disable-next-line: deprecated
local unpack = table.unpack or unpack

---@class Lib.Patterns.CommandHistory
local H = {}
H.__index = H

---@param opts { limit: integer|nil }|nil
---@return Lib.Patterns.CommandHistory
function M.history(opts)
  local limit = opts and opts.limit
  if limit == nil then
    limit = 100
  end
  if type(limit) ~= "number" or limit ~= limit or limit < 1 or limit == math.huge then
    error("command.history: opts.limit must be a finite number >= 1", 2)
  end
  -- the undo stack is the window [first, last] of undo_stack: dropping the oldest entry at the limit is
  -- O(1) (table.remove(t, 1) would shift the whole array on every run)
  return setmetatable(
    { limit = math.floor(limit), undo_stack = {}, first = 1, last = 0, redo_stack = {} },
    H
  )
end

local function pack(...)
  return { n = select("#", ...), ... }
end

---@param self Lib.Patterns.CommandHistory
local function push_undo(self, entry)
  self.last = self.last + 1
  self.undo_stack[self.last] = entry
  if self.last - self.first + 1 > self.limit then
    self.undo_stack[self.first] = nil
    self.first = self.first + 1
  end
end

---@param self Lib.Patterns.CommandHistory
local function pop_undo(self)
  if self.last < self.first then
    return nil
  end
  local entry = self.undo_stack[self.last]
  self.undo_stack[self.last] = nil
  self.last = self.last - 1
  if self.last < self.first then
    self.first, self.last = 1, 0
  end
  return entry
end

---Execute `cmd` with `...`. A failing `run` raises and records nothing. Clears the redo stack.
---@param cmd Lib.Patterns.Command
---@param ... any
---@return any undo_state
function H:run(cmd, ...)
  if type(cmd) ~= "table" or type(cmd.run) ~= "function" then
    error("command.run: cmd needs a run function", 2)
  end
  local state = cmd.run(...)
  push_undo(self, { cmd = cmd, args = pack(...), state = state })
  self.redo_stack = {}
  return state
end

---@return boolean
function H:can_undo()
  return self.last >= self.first
end

---@return boolean
function H:can_redo()
  return #self.redo_stack > 0
end

---Take the last command back. Returns its name or `nil` when there is nothing to undo.
---The entry is taken off the stack before `undo` runs (so an `undo` that runs commands itself cannot
---corrupt the history) and is put back if `undo` raises.
---@return string|nil
function H:undo()
  local entry = pop_undo(self)
  if not entry then
    return nil
  end
  if entry.cmd.undo then
    local ok, err = pcall(entry.cmd.undo, entry.state, unpack(entry.args, 1, entry.args.n))
    if not ok then
      self.last = self.last + 1
      self.undo_stack[self.last] = entry
      error(err, 0)
    end
  end
  self.redo_stack[#self.redo_stack + 1] = entry
  return entry.cmd.name
end

---Run the last undone command again. Returns its name or `nil`.
---@return string|nil
function H:redo()
  local entry = table.remove(self.redo_stack)
  if not entry then
    return nil
  end
  local ok, state = pcall(entry.cmd.run, unpack(entry.args, 1, entry.args.n))
  if not ok then
    -- a raising run leaves the entry on the redo stack
    self.redo_stack[#self.redo_stack + 1] = entry
    error(state, 0)
  end
  entry.state = state
  push_undo(self, entry)
  return entry.cmd.name
end

---Names of the undoable commands, oldest first.
---@return string[]
function H:names()
  local out = {}
  for i = self.first, self.last do
    out[#out + 1] = self.undo_stack[i].cmd.name or "?"
  end
  return out
end

function H:clear()
  self.undo_stack, self.redo_stack = {}, {}
  self.first, self.last = 1, 0
end

return M
