---@module 'lib.nvim.cross.copy_to_clipboard.writer'
--- The asynchronous side of `copy_to_clipboard`: runs the external clipboard
--- tools without waiting for them, one write at a time.
---
--- A synchronous writer gave two promises for free that an asynchronous one
--- has to keep on purpose:
---   * order -- two quick copies must end with the second text on the
---     clipboard, not with whichever process happened to exit last. So at most
---     one write runs; a copy made meanwhile waits in `pending`, and a newer
---     one replaces it (the clipboard ends with the last text, and the callers
---     of the replaced copy get the answer of the write that replaced it).
---   * "done means done" -- a synchronous copy or `:qa` right after an
---     asynchronous one must not race it. `flush()` waits for the running
---     write and the one queued behind it; the synchronous API and
---     `VimLeavePre` call it, and it returns at once when nothing runs.

local M = {}

--- How long one tool may run before it is killed and counted as failed: a
--- hanging tool must not hold the queue (and every later copy) forever.
M.TIMEOUT_MS = 10000

---@class Lib.Clipboard.Write
---@field text string
---@field candidates string[][] argv of every tool to try, in order
---@field callbacks (fun(ok: boolean))[]

---@type Lib.Clipboard.Write|nil
local running = nil
---@type Lib.Clipboard.Write|nil
local pending = nil
local leave_hooked = false

---@internal
---@param callbacks (fun(ok: boolean))[]
---@param ok boolean
local function answer(callbacks, ok)
  for _, cb in ipairs(callbacks) do
    -- One failing caller must not keep the others from their answer, nor stop
    -- the queue (the next write starts after this).
    local okcb, err = pcall(cb, ok)
    if not okcb then
      vim.schedule(function()
        vim.notify("lib.nvim copy_to_clipboard callback: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  end
end

local start

---@internal
--- The write `w` is over: answer its callers, then start what queued behind it.
---@param w Lib.Clipboard.Write
---@param ok boolean
local function finish(w, ok)
  if running ~= w then
    return -- already finished (guard: exactly once per write)
  end
  running = nil
  local nxt = pending
  pending = nil
  -- Start the queued write before answering: a caller copying again from its
  -- callback then queues (or, blocking, waits) behind it instead of being
  -- overwritten by the older queued text a moment later.
  if nxt then
    start(nxt)
  end
  answer(w.callbacks, ok)
end

---@internal
--- Try `w.candidates[i]`, then the next one on failure.
---@param w Lib.Clipboard.Write
---@param i integer
local function try(w, i)
  local argv = w.candidates[i]
  if not argv then
    finish(w, false)
    return
  end
  local on_exit = function(obj)
    vim.schedule(function()
      if obj and obj.code == 0 then
        finish(w, true)
      else
        try(w, i + 1)
      end
    end)
  end
  -- `vim.system` raises when the program cannot be started at all.
  local ok = pcall(vim.system, argv, { stdin = w.text, timeout = M.TIMEOUT_MS }, on_exit)
  if not ok then
    try(w, i + 1)
  end
end

---@internal
---@param w Lib.Clipboard.Write
start = function(w)
  running = w
  if not leave_hooked then
    leave_hooked = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("lib_nvim_copy_to_clipboard", { clear = true }),
      desc = "lib.nvim: finish clipboard writes still running",
      callback = function()
        M.flush()
      end,
    })
  end
  try(w, 1)
end

--- Write `text` with the first tool in `candidates` that succeeds, without
--- waiting; `on_done(ok)` is called later, on the main loop.
---@param text string
---@param candidates string[][]
---@param on_done fun(ok: boolean)
function M.submit(text, candidates, on_done)
  if not vim.system or #candidates == 0 then
    vim.schedule(function()
      answer({ on_done }, false)
    end)
    return
  end
  if running then
    local callbacks = pending and pending.callbacks or {}
    callbacks[#callbacks + 1] = on_done
    pending = { text = text, candidates = candidates, callbacks = callbacks }
    return
  end
  start({ text = text, candidates = candidates, callbacks = { on_done } })
end

--- True while a write runs or waits.
---@return boolean
function M.busy()
  return running ~= nil or pending ~= nil
end

--- Wait until every write that runs or waits is over (at most `timeout_ms`,
--- default: long enough for two writes with every tool timing out once).
--- Returns at once when nothing runs. Not from a fast (luv) callback.
---@param timeout_ms? integer
---@return boolean done false when the time ran out first
function M.flush(timeout_ms)
  if not M.busy() then
    return true
  end
  return vim.wait(timeout_ms or (2 * M.TIMEOUT_MS + 1000), function()
    return not M.busy()
  end, 5)
end

return M
