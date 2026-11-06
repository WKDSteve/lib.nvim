---@module 'lib.nvim.buf_win_tab.tab_buffers'
--- The buffers of the current tab page in the order a user sees them, through a four-step fallback chain:
---
---   1. `vim.t.bufs`        -- what a tabline plugin keeps per tab (the user's own order), if one is running;
---   2. `tabpagebuflist()`  -- the buffers shown in this tab's windows;
---   3. the tab's windows   -- `nvim_win_get_buf` per window, window order;
---   4. `getbufinfo()`      -- every listed buffer.
---
--- The first step that yields at least one valid buffer wins; invalid buffer numbers (a stale `vim.t.bufs`
--- after `:bwipeout`) are dropped and duplicates removed, order kept. Pure reading, no side effect.
---
--- Extracted from a duplicated spot in the author's config (`buffer_jump`: `<leader>1`..`<leader>0`).
---
--- ```lua
--- local list, source = require("lib.nvim.buf_win_tab.tab_buffers").list()
--- -- list   = { 4, 7, 9 }
--- -- source = "vim.t.bufs" | "tabpagebuflist" | "windows" | "getbufinfo" | nil
--- ```

local M = {}

---@alias Lib.BufWinTab.TabBuffersSource "vim.t.bufs"|"tabpagebuflist"|"windows"|"getbufinfo"

---@param raw any
---@return integer[]
local function valid_unique(raw)
  local out, seen = {}, {}
  if type(raw) ~= "table" then
    return out
  end
  for _, b in ipairs(raw) do
    if type(b) == "number" and not seen[b] and vim.api.nvim_buf_is_valid(b) then
      seen[b] = true
      out[#out + 1] = b
    end
  end
  return out
end

---@return integer[]
local function from_vim_t_bufs()
  local ok, t = pcall(function()
    return vim.t.bufs
  end)
  return ok and valid_unique(t) or {}
end

---@return integer[]
local function from_tabpagebuflist()
  local ok, raw = pcall(vim.fn.tabpagebuflist) -- not `0`: before 0.12 that is no tab page, and answers 0
  if not ok then
    return {}
  end
  if type(raw) == "string" then
    -- (some hosts hand it back as text)
    local t = {}
    for num in raw:gmatch("%d+") do
      t[#t + 1] = tonumber(num)
    end
    raw = t
  end
  return valid_unique(raw)
end

---@return integer[]
local function from_windows()
  local ok, wins = pcall(vim.api.nvim_tabpage_list_wins, 0)
  if not ok or type(wins) ~= "table" then
    return {}
  end
  local bufs = {}
  for _, w in ipairs(wins) do
    local got, buf = pcall(vim.api.nvim_win_get_buf, w)
    if got then
      bufs[#bufs + 1] = buf
    end
  end
  return valid_unique(bufs)
end

---@return integer[]
local function from_getbufinfo()
  local ok, infos = pcall(vim.fn.getbufinfo, { buflisted = 1 })
  if not ok or type(infos) ~= "table" then
    return {}
  end
  local bufs = {}
  for _, info in ipairs(infos) do
    bufs[#bufs + 1] = info.bufnr
  end
  return valid_unique(bufs)
end

---The buffers of the current tab page and the step of the chain that answered.
---@return integer[] bufnrs  # Empty when no step yields one.
---@return Lib.BufWinTab.TabBuffersSource|nil source
function M.list()
  local steps = {
    { "vim.t.bufs", from_vim_t_bufs },
    { "tabpagebuflist", from_tabpagebuflist },
    { "windows", from_windows },
    { "getbufinfo", from_getbufinfo },
  }
  for _, step in ipairs(steps) do
    local bufs = step[2]()
    if #bufs > 0 then
      return bufs, step[1]
    end
  end
  return {}, nil
end

---The `n`-th buffer of `list()`, or nil (what a "jump to buffer 3" key needs).
---@param n integer
---@return integer|nil bufnr
function M.nth(n)
  if type(n) ~= "number" or n < 1 then
    return nil
  end
  return (M.list())[n]
end

return M
