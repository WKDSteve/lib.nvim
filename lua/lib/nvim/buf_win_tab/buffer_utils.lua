---@module 'lib.nvim.buf_win_tab.buffer_utils'
--- Utility library for inspecting and reacting to Neovim buffers.

local notify = require("lib.nvim.notify").create("[lib.nvim.buf_win_tab.buffer_utils]")

local M = {}

-- Default filetypes and buffer-name fragments to exclude when deciding whether
-- a buffer counts as a "real" user buffer.
---@type string[]
M.DEFAULT_EXCLUDE_FILETYPES = {
  "neo-tree", -- neo-tree.nvim / Neotree
  "filetree", -- filetree.nvim's own tree
  "NvimTree", -- older nvim-tree identifiers
  "qf", -- quickfix
  "TelescopePrompt", -- telescope prompt
  "alpha", -- dashboard/alpha
  "startify", -- startify
  "packer", -- plugin manager UI
  "help", -- help buffers
  "notify", -- notify windows
}

-- Local helpers and types -----------------------------------------------------

---@internal
-- Utility: check if a value exists in list
---@param list string[] list to check
---@param v string value to look for
---@return boolean
local function contains(list, v)
  for i = 1, #list do
    if list[i] == v then
      return true
    end
  end
  return false
end

---@internal
--- `getbufinfo()` does not report a filetype -- it never has, for any of
--- the shapes it returns. Reading `b.filetype` off one of its entries was
--- therefore always nil, which silently turned every filetype exclusion
--- below into a no-op. Read the option off the buffer instead.
---@param bufnr integer
---@return string
local function buf_filetype(bufnr)
  local ok, ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
  return ok and ft or ""
end

-- Get info for all listed buffers and return their count.
---@return integer
function M.count_listed_buffers()
  -- Using getbufinfo({buflisted=1}) returns only listed buffers.
  local listed = vim.fn.getbufinfo({ buflisted = 1 })
  -- Debug notification is useful during development; this can be silenced by user.
  notify.debug("Listed buffer: " .. tostring(#listed))
  return #listed
end

-- PUBLIC BUFFER UTILS API -------------------------------------------------

-- Count listed buffers excluding ephemeral/plugin buffers by filetype/name heuristics.
---@param exclude_filetypes string[]|nil optional list of filetypes to exclude; defaults used if nil
---@return integer
function M.count_real_listed_buffers(exclude_filetypes)
  exclude_filetypes = exclude_filetypes or M.DEFAULT_EXCLUDE_FILETYPES
  local listed = vim.fn.getbufinfo({ buflisted = 1 })
  local cnt = 0
  for _, b in ipairs(listed) do
    local ft = buf_filetype(b.bufnr)
    local name = b.name or ""
    if not contains(exclude_filetypes, ft) and name ~= "" then
      cnt = cnt + 1
    else
      -- If needed, one can log which buffers are excluded for debugging:
      -- vim.notify(string.format("excl: id=%d ft=%s name=%s", b.bufnr, ft, name), vim.log.levels.DEBUG)
    end
  end
  return cnt
end

-- Return a table with metadata for a single buffer id.
---@param bufnr number
---@return table
function M.get_buffer_info(bufnr)
  -- Use pcall for APIs that may error on unloaded/invalid buffers
  local ok_name, name = pcall(vim.api.nvim_buf_get_name, bufnr)
  if not ok_name then
    name = ""
  end
  local ok_ft, ft = pcall(vim.api.nvim_get_option_value, "filetype", { buf = bufnr })
  if not ok_ft then
    ft = ""
  end
  local ok_listed, buflisted = pcall(vim.fn.buflisted, bufnr)
  if not ok_listed then
    buflisted = 0
  end
  local ok_mod, modified = pcall(vim.api.nvim_get_option_value, "modified", { buf = bufnr })
  if not ok_mod then
    modified = false
  end
  local ok_lines, line_count = pcall(vim.api.nvim_buf_line_count, bufnr)
  if not ok_lines then
    line_count = 0
  end

  -- collect windows that currently display this buffer
  local wins = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local ok_buf, b = pcall(vim.api.nvim_win_get_buf, win)
    if ok_buf and b == bufnr then
      table.insert(wins, win)
    end
  end

  return {
    id = bufnr,
    name = name,
    filetype = ft,
    buflisted = (buflisted == 1),
    modified = modified,
    lines = line_count,
    windows = wins,
  }
end

-- Gather detailed info for all buffers (both listed and unlisted).
---@return table[] list of buffer info tables
function M.list_all_buffers_info()
  local bufs = vim.api.nvim_list_bufs()
  local out = {}
  for i = 1, #bufs do
    local info = M.get_buffer_info(bufs[i])
    table.insert(out, info)
  end
  return out
end

-- Gather info only for listed buffers.
---@return table[] list of buffer info tables for listed buffers
function M.list_listed_buffers_info()
  local listed = vim.fn.getbufinfo({ buflisted = 1 })
  local out = {}
  for i = 1, #listed do
    local b = listed[i]
    -- normalize to the same shape as get_buffer_info output
    table.insert(out, {
      id = b.bufnr,
      name = b.name or "",
      filetype = buf_filetype(b.bufnr),
      buflisted = true,
      modified = b.changed == 1,
      lines = b.linecount or 0,
      windows = b.windows or {},
    })
  end
  return out
end

-- Format a list of buffer-info tables into a human-readable multi-line string.
---@param buftable table[] list of buffer info
---@return string formatted text
function M.format_buffers_table(buftable)
  local lines = {}
  -- header
  table.insert(
    lines,
    string.format("%-6s %-8s %-6s %-7s %s", "bufnr", "ft", "listed", "modified", "name")
  )
  table.insert(lines, string.rep("-", 80))

  for i = 1, #buftable do
    local b = buftable[i]
    local ft = b.filetype ~= "" and b.filetype or "<noft>"
    local listed = b.buflisted and "yes" or "no"
    local mod = b.modified and "*" or " "
    local name = b.name ~= "" and b.name or "[no name]"
    table.insert(lines, string.format("%-6d %-8s %-6s %-7s %s", b.id, ft, listed, mod, name))
  end

  return table.concat(lines, "\n")
end

-- Print a buffer table to the command line.
---@param buftable table[] list of buffer info
function M.print_buffers_table(buftable)
  local s = M.format_buffers_table(buftable)
  -- ensure trailing newline
  vim.api.nvim_echo({ { s .. "\n" } }, true, { err = false })
end

-- High-level collector that gathers listed buffers, all buffers, counts and a formatted summary.
---@return table
function M.collect_all_buffer_info()
  local collected = {}
  collected.listed_count = M.count_listed_buffers()
  collected.real_listed_count = M.count_real_listed_buffers()
  collected.listed = M.list_listed_buffers_info()
  collected.all = M.list_all_buffers_info()
  collected.formatted_listed = M.format_buffers_table(collected.listed)
  return collected
end

-- Convenience wrapper: print a compact summary of current buffers to the command line.
---@return nil
function M.print_summary()
  local coll = M.collect_all_buffer_info()
  vim.api.nvim_echo({
    { string.format("Listed: %d  RealListed: %d\n", coll.listed_count, coll.real_listed_count) },
    { "Listed buffers:\n" },
    { coll.formatted_listed .. "\n" },
  }, true, { err = false })
end

---@type Lib.BufWinTab.BufferUtils
return M
