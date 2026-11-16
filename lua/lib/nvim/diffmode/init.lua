---@module 'lib.nvim.diffmode'
--- Native diffmode orchestration: put N buffers side by side (or stacked, or in a tab) and switch `'diff'` on
--- in every window.
---
--- Generalized from `diff.nvim` (`core/render.lua`: `three_way`, `side_by_side`). Neovim's diffmode already diffs
--- three or more windows against each other; what is needed is the layout and the discipline around it:
---
--- * **`'diff'` is set window-locally**, together with what `:diffthis` sets around it (`scrollbind`, `cursorbind`,
---   `foldmethod=diff`, `foldenable`, `nowrap`); turning it off puts those back like `:diffoff`.
---   `vim.wo[win].diff = v` behaves like `:set`: it also writes the *global* value, which every window opened
---   afterwards inherits, so the next `:tabnew` would sit in diffmode long after the diff. `set()` writes with
---   `scope = "local"`.
--- * **A split that failed is not trusted.** `:split | buffer N` can abort half way (E36, or E86 for a wiped
---   buffer); the current window then shows something else, and enabling diffmode on *that* shows the wrong
---   content. Every new window's buffer is verified, and a failure unwinds everything this call opened.
--- * **Only windows this call opened are returned as `opened`.** An `origin_win` the user was working in is part
---   of the diff but never part of what a caller may close afterwards.
---
---```lua
--- local dm = require("lib.nvim.diffmode")
--- local res, err = dm.open_n_way({ ours, base, theirs }, "vsplit", { origin_win = vim.api.nvim_get_current_win() })
--- -- res.windows: every window in the diff, left to right;  res.opened: the ones opened here
--- dm.close(res)                                              -- turns diff off and closes res.opened
---```
---
--- See @types/init.lua for Lib.Diffmode.*.

require("lib.nvim.diffmode.@types")

local api = vim.api

local M = {}

-- What `:diffthis` sets besides `'diff'`, and the value it sets. All window-local.
local BOUND = {
  { "scrollbind", true },
  { "cursorbind", true },
  { "foldmethod", "diff" },
  { "foldenable", true },
  { "wrap", false },
}

-- win -> the values of BOUND before `set(win, true)`, put back by `set(win, false)` (like `:diffoff`)
local saved = {}

---Turn diffmode on or off for `win`, window-locally, the way `:diffthis` / `:diffoff` do: on also sets
---`'scrollbind'`, `'cursorbind'`, `'foldmethod'=diff`, `'foldenable'` and `'nowrap'` (the panes scroll together and
---unchanged text folds away), off puts back the values the window had before. A second `set(win, true)` keeps the
---first saved values. An invalid window is ignored: callers are cleanup loops and render paths where a window may
---have been closed in the meantime.
---@param win integer
---@param on boolean
function M.set(win, on)
  for w in pairs(saved) do
    if not api.nvim_win_is_valid(w) then
      saved[w] = nil
    end
  end
  if type(win) ~= "number" or not api.nvim_win_is_valid(win) then
    return
  end
  local wo = { win = win, scope = "local" }
  if on then
    if not saved[win] then
      local before = {}
      for _, o in ipairs(BOUND) do
        before[o[1]] = api.nvim_get_option_value(o[1], wo)
      end
      saved[win] = before
    end
    for _, o in ipairs(BOUND) do
      pcall(api.nvim_set_option_value, o[1], o[2], wo)
    end
  else
    local before = saved[win]
    saved[win] = nil
    if before then
      for _, o in ipairs(BOUND) do
        pcall(api.nvim_set_option_value, o[1], before[o[1]], wo)
      end
    end
  end
  pcall(api.nvim_set_option_value, "diff", on, wo)
end

---@param win integer|nil
---@return boolean
local function win_valid(win)
  return type(win) == "number" and api.nvim_win_is_valid(win)
end

---Open `buf` in a new split of the current window and answer that window, or nil when it could not be done.
---@param cmd "split"|"vsplit"
---@param buf integer
---@return integer|nil
local function split_into(cmd, buf)
  -- `rightbelow`: the order of the windows must not depend on the user's 'splitright'/'splitbelow'
  if not pcall(vim.cmd, ("silent! rightbelow %s | buffer %d"):format(cmd, buf)) then
    return nil
  end
  local win = api.nvim_get_current_win()
  if not win_valid(win) or api.nvim_win_get_buf(win) ~= buf then
    return nil
  end
  return win
end

---@param wins integer[]
local function close_all(wins)
  for _, w in ipairs(wins) do
    if win_valid(w) then
      pcall(api.nvim_win_close, w, true)
    end
  end
end

---Open `bufs` (in order, left to right or top to bottom) in native diffmode.
---
---`view`: `"vsplit"` (side by side), `"split"` (stacked), `"tab"` (a fresh tab, side by side: the existing layout is
---not touched). With `opts.origin_win`, `bufs[1]` is expected to be shown there already (it stays the user's
---window: part of the diff, not part of `opened`); without it, `bufs[1]` gets a window of its own like the rest.
---On any failure everything this call opened is closed again and the answer is `nil, err`.
---@param bufs integer[] two or more valid buffers
---@param view "vsplit"|"split"|"tab"
---@param opts? Lib.Diffmode.Opts
---@return Lib.Diffmode.Result|nil
---@return string|nil err
function M.open_n_way(bufs, view, opts)
  opts = opts or {}
  if type(bufs) ~= "table" or #bufs < 2 then
    return nil, "diffmode: at least two buffers are needed"
  end
  for i, b in ipairs(bufs) do
    if type(b) ~= "number" or not api.nvim_buf_is_valid(b) then
      return nil, ("diffmode: buffer %d of the list is not valid"):format(i)
    end
  end
  if view ~= "vsplit" and view ~= "split" and view ~= "tab" then
    return nil, "diffmode: view must be vsplit, split or tab"
  end
  local origin = opts.origin_win
  if origin ~= nil and not win_valid(origin) then
    return nil, "diffmode: origin window is no longer valid"
  end

  local cmd = (view == "split") and "split" or "vsplit"
  local windows, opened = {}, {}
  local start_tab

  local function unwind(message)
    close_all(opened)
    if start_tab and api.nvim_tabpage_is_valid(start_tab) then
      pcall(api.nvim_set_current_tabpage, start_tab)
    end
    return nil, message
  end

  local first = 1
  if view == "tab" then
    local prev = api.nvim_get_current_tabpage()
    vim.cmd("tabnew")
    local new_tab = api.nvim_get_current_tabpage()
    start_tab = prev
    local left = api.nvim_get_current_win()
    if
      not pcall(vim.cmd, ("silent! buffer %d"):format(bufs[1]))
      or api.nvim_win_get_buf(left) ~= bufs[1]
    then
      pcall(vim.cmd, "silent! tabclose")
      if api.nvim_tabpage_is_valid(prev) then
        pcall(api.nvim_set_current_tabpage, prev)
      end
      return nil, "diffmode: could not open the first buffer"
    end
    -- the tab's own window is ours; abandoning the tab later closes it
    windows[1], opened[1] = left, left
    first = 2
    local function abandon(msg)
      if api.nvim_tabpage_is_valid(new_tab) then
        pcall(api.nvim_set_current_tabpage, new_tab)
        pcall(vim.cmd, "silent! tabclose")
      end
      if api.nvim_tabpage_is_valid(prev) then
        pcall(api.nvim_set_current_tabpage, prev)
      end
      return nil, msg
    end
    for i = first, #bufs do
      local w = split_into("vsplit", bufs[i])
      if not w then
        return abandon(("diffmode: could not open buffer %d of %d"):format(i, #bufs))
      end
      windows[#windows + 1], opened[#opened + 1] = w, w
    end
  else
    if origin then
      api.nvim_set_current_win(origin)
      windows[1] = origin
      first = 2
    end
    for i = first, #bufs do
      local w = split_into(cmd, bufs[i])
      if not w then
        return unwind(("diffmode: could not open buffer %d of %d"):format(i, #bufs))
      end
      windows[#windows + 1], opened[#opened + 1] = w, w
    end
  end

  for _, w in ipairs(windows) do
    M.set(w, true)
  end
  local focus = origin or windows[#windows]
  if win_valid(focus) then
    api.nvim_set_current_win(focus)
  end
  return { windows = windows, opened = opened, origin_win = origin }, nil
end

---Turn diffmode off in every window of a result and close the windows that were opened by `open_n_way`
---(never the origin window).
---@param res Lib.Diffmode.Result|nil
function M.close(res)
  if not res then
    return
  end
  for _, w in ipairs(res.windows) do
    M.set(w, false)
  end
  close_all(res.opened)
end

return M
