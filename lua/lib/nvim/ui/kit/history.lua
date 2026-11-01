---@module 'lib.nvim.ui.kit.history'
--- A back/forward trail of positions, the way a browser keeps one: a pure data
--- structure, no window, no keymap, no `vim` call.
---
--- Generalised from documentation.nvim's browser (`docmap.editor.browse`, its
--- `go`/`CLEAR`/`history_step`). The model, and why it is this one:
---
---   * The trail holds every position **including the current one**, and the
---     index points at it. A new history therefore starts with one entry (where
---     the view is now), so `index()` always addresses a real entry and a step
---     is a plain bounds check. Recording only *past* positions is what the
---     browser did first, and it cannot work: after a move the index addressed
---     the entry before the current one, so the first Back fell off the front
---     and the second landed one stop too far back.
---   * A move (`go`) truncates any forward history, as a browser does.
---   * A move that changes none of the tracked keys is not a stop (`dedupe`,
---     on by default): a Back that visibly does nothing reads as a broken
---     history, not as a no-op key.
---   * A patch cannot say "clear this field" with `nil` (`pairs` never yields a
---     key whose value is nil, so `{ sha = nil }` *is* the empty table and the
---     move silently keeps the old value). `history.CLEAR` is the sentinel for
---     that.
---
--- Why this is not built on `lib.lua.patterns.command`: that one keeps stacks of *actions* with an
--- inverse (`run` returns what `undo` needs). This trail keeps *positions* (snapshots of the tracked
--- keys), jumps by any delta, truncates the forward part on a move and drops a move that changes
--- nothing -- a cursor over a list, not an undo log. Expressing it as commands would need a
--- "navigate" command per move whose undo restores the old snapshot, i.e. the same list again.
---
--- The consumer keeps its own state table; the history snapshots the `keys`
--- it was given out of it (shallow: a table value is shared between the state
--- and the entries, so treat such values as immutable) and writes them back
--- on a step.
---
---   local history = require("lib.nvim.ui.kit.history")
---   local h = history.new({ state = st, keys = { "mode", "id", "fn", "cursor" } })
---   h:go(st, { id = node.parent, fn = history.CLEAR })  -- a move
---   h:back(st)                                          -- <C-o>
---   h:forward(st)                                       -- <C-i>

local M = {}

--- The "clear this field" sentinel for `apply`, `go` and `patch`.
---@type table
M.CLEAR = setmetatable({}, {
  __tostring = function()
    return "<clear>"
  end,
  __newindex = function()
    error("lib.nvim.ui.kit.history.CLEAR is read-only", 2)
  end,
})

--- Apply `patch` to `target` in place: `CLEAR` removes the field, any other
--- value is set. Returns `target`.
---@param target table
---@param patch table
---@return table target
function M.apply(target, patch)
  for k, v in pairs(patch) do
    if v == M.CLEAR then
      target[k] = nil
    else
      target[k] = v
    end
  end
  return target
end

---@class Lib.UI.Kit.History
---@field package _keys string[]
---@field package _max integer|nil
---@field package _dedupe boolean
---@field package _entries table[]
---@field package _index integer
local History = {}
History.__index = History

---@param self Lib.UI.Kit.History
---@param state table
---@return table
local function snapshot(self, state)
  local snap = {}
  for _, k in ipairs(self._keys) do
    snap[k] = state[k]
  end
  return snap
end

---@param self Lib.UI.Kit.History
---@param a table
---@param b table
---@return boolean
local function same(self, a, b)
  for _, k in ipairs(self._keys) do
    if a[k] ~= b[k] then
      return false
    end
  end
  return true
end

---@param state any
---@param fn string
local function check_state(state, fn)
  if type(state) ~= "table" then
    error(("lib.nvim.ui.kit.history: %s: state must be a table, got %s"):format(fn, type(state)), 3)
  end
end

--- Create a history whose first entry is `opts.state` as it is now.
---@param opts Lib.UI.Kit.HistoryOpts
---@return Lib.UI.Kit.History
function M.new(opts)
  if type(opts) ~= "table" then
    error("lib.nvim.ui.kit.history.new: opts must be a table", 2)
  end
  local keys = opts.keys
  if type(keys) ~= "table" or #keys == 0 then
    error("lib.nvim.ui.kit.history.new: opts.keys must be a non-empty list of field names", 2)
  end
  local own = {}
  for i, k in ipairs(keys) do
    if type(k) ~= "string" then
      error(("lib.nvim.ui.kit.history.new: opts.keys[%d] must be a string"):format(i), 2)
    end
    own[i] = k
  end
  local max = opts.max
  if max ~= nil and (type(max) ~= "number" or max < 1 or max % 1 ~= 0) then
    error("lib.nvim.ui.kit.history.new: opts.max must be a positive integer", 2)
  end
  if type(opts.state) ~= "table" then
    error("lib.nvim.ui.kit.history.new: opts.state must be a table", 2)
  end
  local self = setmetatable({
    _keys = own,
    _max = max,
    _dedupe = opts.dedupe ~= false,
    _entries = {},
    _index = 1,
  }, History)
  self._entries[1] = snapshot(self, opts.state)
  return self
end

--- Start over: the trail becomes the single entry `state`.
---@param state table
function History:reset(state)
  check_state(state, "reset")
  self._entries = { snapshot(self, state) }
  self._index = 1
end

--- Overwrite the current entry with `state`'s tracked keys -- keep the entry
--- for the position being left in step with the view (the cursor row a user
--- moved to, a filter typed in place) so coming back restores where they were,
--- not where they arrived. `go` and `step` call it first.
---@param state table
function History:record(state)
  check_state(state, "record")
  self._entries[self._index] = snapshot(self, state)
end

--- Change `state` in place without making a stop (`apply` `fields`, then
--- `record`) -- for state that travels *with* a position but is not one
--- itself, such as a filter narrowing the current list: Back away and Forward
--- again finds the list narrowed the same way, and Back does not undo the
--- filter as if it had been a move.
---@param state table
---@param fields table
function History:patch(state, fields)
  check_state(state, "patch")
  M.apply(state, fields or {})
  self:record(state)
end

--- Make `state` a new stop after the current one, dropping any forward
--- history. With `dedupe` (the default) a `state` equal to the current entry
--- makes no stop and keeps the forward history. Over `max` the oldest entry
--- goes. Returns whether a stop was made.
---@param state table
---@return boolean pushed
function History:push(state)
  check_state(state, "push")
  local snap = snapshot(self, state)
  if self._dedupe and same(self, snap, self._entries[self._index]) then
    return false
  end
  for i = #self._entries, self._index + 1, -1 do
    self._entries[i] = nil
  end
  self._entries[#self._entries + 1] = snap
  if self._max and #self._entries > self._max then
    table.remove(self._entries, 1)
  end
  self._index = #self._entries
  return true
end

--- A move: `record` the position being left, `apply` `changes` to `state`,
--- then `push` it. Returns whether a stop was made (`state` is changed
--- either way).
---@param state table
---@param changes table
---@return boolean pushed
function History:go(state, changes)
  check_state(state, "go")
  self:record(state)
  M.apply(state, changes or {})
  return self:push(state)
end

--- Move `delta` entries (negative = back) and write that entry's keys into
--- `state` (a key the entry does not hold becomes nil). The position being
--- left is `record`ed first. A target outside the trail changes nothing and
--- returns false; a `delta` that is not an integer raises before anything moves.
---@param state table
---@param delta integer
---@return boolean moved
function History:step(state, delta)
  check_state(state, "step")
  delta = delta or 0
  if type(delta) ~= "number" or delta % 1 ~= 0 then
    -- Checked before anything moves: a fractional target passes the bounds check, and the
    -- record/index update would then leave the trail pointing at no entry.
    error(
      ("lib.nvim.ui.kit.history: step: delta must be an integer, got %s"):format(tostring(delta)),
      2
    )
  end
  local target = self._index + delta
  if target == self._index or target < 1 or target > #self._entries then
    return false
  end
  self:record(state)
  self._index = target
  local entry = self._entries[target]
  for _, k in ipairs(self._keys) do
    state[k] = entry[k]
  end
  return true
end

--- `step(state, -(count or 1))`.
---@param state table
---@param count? integer
---@return boolean moved
function History:back(state, count)
  return self:step(state, -(count or 1))
end

--- `step(state, count or 1)`.
---@param state table
---@param count? integer
---@return boolean moved
function History:forward(state, count)
  return self:step(state, count or 1)
end

--- The current entry (live: change it through `patch` or `record`).
---@return table
function History:current()
  return self._entries[self._index]
end

--- Position of the current entry, 1-based.
---@return integer
function History:index()
  return self._index
end

--- Number of entries, the current one included.
---@return integer
function History:len()
  return #self._entries
end

---@return boolean
function History:can_back()
  return self._index > 1
end

---@return boolean
function History:can_forward()
  return self._index < #self._entries
end

--- A copy of the entry list, oldest first (the entries themselves are shared).
---@return table[]
function History:entries()
  local out = {}
  for i, e in ipairs(self._entries) do
    out[i] = e
  end
  return out
end

return M
