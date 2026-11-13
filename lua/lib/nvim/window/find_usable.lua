---@module 'lib.nvim.window.find_usable'
--- Find a "normal" window to display content in — not a floating window,
--- not a sidebar-like window (fixed width/height, or a well-known sidebar
--- filetype). Useful for plugins that want to reuse an existing normal
--- split instead of always opening a new one.

local M = {}

local SIDEBAR_FILETYPES = {
  ["neo-tree"] = true,
  ["filetree"] = true,
  ["NvimTree"] = true,
  ["aerial"] = true,
  ["Outline"] = true,
  ["qf"] = true,
}

---True when `winid` is a normal, non-floating, non-sidebar window.
---@param winid integer
---@return boolean
function M.is_usable_window(winid)
  if not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, winid)
  if ok_cfg and cfg.relative ~= "" then
    return false -- floating window
  end
  local ok_buf, bufnr = pcall(vim.api.nvim_win_get_buf, winid)
  if not ok_buf then
    return false
  end
  local ok_ft, ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
  if ok_ft and SIDEBAR_FILETYPES[ft] then
    return false
  end
  return true
end

---Find the first usable normal window, preferring the current one.
---@param opts? { current_tab_only?: boolean }
---@return integer|nil winid
function M.target_window(opts)
  opts = opts or {}
  local cur = vim.api.nvim_get_current_win()
  if M.is_usable_window(cur) then
    return cur
  end
  local wins = opts.current_tab_only and vim.api.nvim_tabpage_list_wins(0)
    or vim.api.nvim_list_wins()
  for _, winid in ipairs(wins) do
    if M.is_usable_window(winid) then
      return winid
    end
  end
  return nil
end

---Find the window a link/text should be put into from a sidebar or float: the
---previous window (`:wincmd p`) when it is usable, else `target_window()`.
---The previous window is what "the window I came from" means to a user, which
---the first-usable-in-list-order fallback of `target_window()` does not.
---@param opts? { current_tab_only?: boolean }
---@return integer|nil winid
function M.previous_window(opts)
  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  if prev ~= 0 and prev ~= vim.api.nvim_get_current_win() and M.is_usable_window(prev) then
    return prev
  end
  return M.target_window(opts)
end

---Find the window a link/text should be inserted into: the CURRENT window when it
---is a normal editing window (a command typed in the editor), else the previous
---one (an action fired from a sidebar or float, see `previous_window`). Plain
---`previous_window()` is wrong for a `:Command` run from the editor itself: it
---would pick whichever split the user visited before.
---@param opts? { current_tab_only?: boolean }
---@return integer|nil winid
function M.insertion_window(opts)
  local cur = vim.api.nvim_get_current_win()
  if M.is_usable_window(cur) then
    return cur
  end
  return M.previous_window(opts)
end

---@class Lib.Window.BestTargetOpts
---@field source_win? integer         # Tried first: the window the action came from (e.g. a picker's origin).
---@field writable? boolean           # Require a normal, modifiable buffer (default true: the text is going to be inserted).
---@field current_tab_only? boolean   # The last resort looks at the current tab only.

---@param winid integer
---@param writable boolean
---@return boolean
local function fits(winid, writable)
  if type(winid) ~= "number" or not M.is_usable_window(winid) then
    return false
  end
  if not writable then
    return true
  end
  local buf = vim.api.nvim_win_get_buf(winid)
  return vim.bo[buf].buftype == "" and vim.bo[buf].modifiable
end

---The best window to put text into, by a fixed chain: `opts.source_win` -> the alternate window (`:wincmd p`)
---> the first usable window. Every step must be a normal, non-floating, non-sidebar window
---(`is_usable_window`) and, unless `writable = false`, one with a modifiable, normal buffer.
---
---Generalised from the target search of `recommender.nvim`'s float; unlike `insertion_window` it knows an
---explicit origin window (a float or picker stores where it was opened from).
---@param opts? Lib.Window.BestTargetOpts
---@return integer|nil winid
function M.best_target_window(opts)
  opts = opts or {}
  local writable = opts.writable ~= false

  if opts.source_win ~= nil and fits(opts.source_win, writable) then
    return opts.source_win
  end

  local alt = vim.fn.win_getid(vim.fn.winnr("#"))
  if alt ~= 0 and fits(alt, writable) then
    return alt
  end

  local wins = opts.current_tab_only and vim.api.nvim_tabpage_list_wins(0)
    or vim.api.nvim_list_wins()
  for _, winid in ipairs(wins) do
    if fits(winid, writable) then
      return winid
    end
  end
  return nil
end

return M
