---@module 'lib.nvim.ui.kit.modal'
--- Which modal kit dialogs are open right now, and a way to be told when none is.
---
--- A dialog that takes the keyboard (confirm, input, select, sheet, ...) registers its surface
--- through `surface.open{ modal = true }`; the registry forgets it when the float closes, for any
--- cause. `kit.ask` uses it to wait for a free moment without looking again every few hundred
--- milliseconds: it subscribes once with `on_free` and is called when the last modal dialog went.
---
--- A dialog that has gone but whose answer is still on its way (confirm answers an externally
--- closed float on the next loop iteration) holds the registry busy with `hold()` until it has
--- been delivered, so a waiting question never opens between the close and that answer.
---
--- Not built on `lib.lua.listeners`: those are standing subscriptions, these are one-shot waiters. The
--- list is drained when it is due and put back ahead of newer ones when a dialog opened meanwhile, which
--- a list that keeps its entries cannot express.
---
--- Nothing here owns a window or a keymap. A float closed without `WinClosed` (never in practice)
--- is dropped from `busy()` as soon as it is looked at, and the subscribers are woken by the next
--- close.

local M = {}

---@type Lib.UI.Kit.Surface[]
local open = {}

--- Answers that are still on their way (see `hold`).
local held = 0

---@class Lib.UI.Kit.ModalListener
---@field fn fun()
---@field cancelled boolean

---@type Lib.UI.Kit.ModalListener[]
local listeners = {}

--- Forget surfaces whose window is gone.
local function prune()
  for i = #open, 1, -1 do
    if not open[i]:is_valid() then
      table.remove(open, i)
    end
  end
end

--- Whether a modal dialog is open, or one has gone with its answer still to come.
---@return boolean
function M.busy()
  prune()
  return #open > 0 or held > 0
end

--- Wake the subscribers when nothing is open. Each is called once, in the order it subscribed, on
--- the next loop iteration (a close runs inside `WinClosed`, where opening a float is restricted).
--- The check is made again when they run: something may have opened or been held in between, and
--- then they stay subscribed, ahead of anyone who subscribed since.
local function wake()
  if M.busy() or #listeners == 0 then
    return
  end
  local due = listeners
  listeners = {}
  vim.schedule(function()
    if M.busy() then
      vim.list_extend(due, listeners)
      listeners = due
      return
    end
    for _, l in ipairs(due) do
      if not l.cancelled then
        local ok, err = pcall(l.fn)
        if not ok then
          vim.notify(
            "lib.nvim.ui.kit.modal: a waiting caller failed: " .. tostring(err),
            vim.log.levels.ERROR
          )
        end
      end
    end
  end)
end

--- Register a surface as an open modal dialog. Idempotent per surface.
---@param surf Lib.UI.Kit.Surface
function M.enter(surf)
  for _, s in ipairs(open) do
    if s == surf then
      return
    end
  end
  open[#open + 1] = surf
  surf:on_close(function()
    for i, s in ipairs(open) do
      if s == surf then
        table.remove(open, i)
        break
      end
    end
    wake()
  end)
end

--- Keep `busy()` true until the returned function is called (once; more calls do nothing). For
--- an answer that is delivered a moment after its dialog went.
---@return fun() release
function M.hold()
  held = held + 1
  local released = false
  return function()
    if released then
      return
    end
    released = true
    held = held - 1
    wake()
  end
end

--- Call `fn` once, after the next moment no modal dialog is open (not before the current call
--- has returned: an `fn` registered while nothing is open is called on the next loop iteration).
--- Returns a function that withdraws it; that works until `fn` has been called, also when it is
--- already scheduled.
---@param fn fun()
---@return fun() cancel
function M.on_free(fn)
  local l = { fn = fn, cancelled = false }
  listeners[#listeners + 1] = l
  wake()
  return function()
    l.cancelled = true
    for i, x in ipairs(listeners) do
      if x == l then
        table.remove(listeners, i)
        return
      end
    end
  end
end

return M
