---@module 'lib.nvim.window.open_named_scratch'
--- Find-or-replace a named scratch buffer shown in a split (not a float).
--- Complements `make_scratch` (which always opens a floating window): this
--- is for plugins that want a dedicated, de-duplicated split — e.g. a log
--- viewer or a list view — identified by a stable buffer name so a second
--- call reuses the same buffer/window instead of piling up duplicates.
---
--- The name is matched exactly, never as a pattern: `bufnr(name)` would also
--- hand back a buffer whose name merely contains `name` (`x.log` finding
--- `x.log.1`) and reads `*`, `?`, `[`, `%`, `#` as wildcards (XP-01).

local api = vim.api

-- `bufadd(name)` without its side effects: the buffer whose full name is
-- `name`, resolved the way `nvim_buf_set_name` resolves it (cwd-relative
-- names, a kept `~`, `scheme://` names as given, `/` = `\` and folded case
-- where the file system wants it), or nil. `bufadd()` creates a buffer when
-- there is none; that one is wiped again, and 'eventignore' keeps the
-- BufNew/BufWipeout pair from reaching anyone.
---@param name string
---@return integer?
local function by_full_name(name)
  local before = {}
  for _, b in ipairs(api.nvim_list_bufs()) do
    before[b] = true
  end
  local ei = vim.o.eventignore
  vim.o.eventignore = "all"
  local ok, b = pcall(vim.fn.bufadd, name)
  if ok and not before[b] then
    pcall(api.nvim_buf_delete, b, { force = true })
    b = nil
  end
  vim.o.eventignore = ei
  return ok and b or nil
end

-- The buffer named exactly `name`, or nil, by Neovim's own name lookup
-- (`bufexists()`) rather than a pattern: first the full name, then -- as
-- Neovim does for a URL or 'nofile' buffer, whose short name survives a
-- `:cd` -- the short name compared byte for byte. A buffer this finds is
-- one `nvim_buf_set_name(name)` would refuse with E95 or that Neovim itself
-- calls `name`; a name that is only part of another never matches.
---@param name string
---@return integer?
local function find_buf(name)
  if vim.fn.bufexists(name) ~= 1 then
    return nil
  end
  local b = by_full_name(name)
  if b then
    return b
  end
  for _, x in ipairs(api.nvim_list_bufs()) do
    if vim.fn.bufname(x) == name then
      return x
    end
  end
  return nil
end

---@param name string Unique buffer name (e.g. "MyPlugin://log")
---@param lines? string[] Initial buffer content
---@param opts? { filetype?: string, split?: "above"|"below"|"left"|"right", size?: integer, modifiable?: boolean }
---@return integer bufnr
---@return integer winid
return function(name, lines, opts)
  if type(name) ~= "string" or name == "" then
    error("open_named_scratch: name must be a non-empty string", 2)
  end
  opts = opts or {}

  local bufnr = find_buf(name)
  if not bufnr then
    bufnr = api.nvim_create_buf(false, true)
    -- E95 here would mean `bufexists()` and the name check of
    -- `nvim_buf_set_name` disagree. Fail loudly rather than hand back, and
    -- overwrite, some other buffer; drop the new one.
    local ok, err = pcall(api.nvim_buf_set_name, bufnr, name)
    if not ok then
      pcall(api.nvim_buf_delete, bufnr, { force = true })
      error(("open_named_scratch: cannot name a buffer %q: %s"):format(name, err), 2)
    end
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
  end

  if opts.filetype then
    vim.bo[bufnr].filetype = opts.filetype
  end

  vim.bo[bufnr].modifiable = true
  if lines then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  end
  vim.bo[bufnr].modifiable = opts.modifiable ~= false

  -- Find an existing window already showing this buffer (any tab-visible window).
  local winid
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      winid = w
      break
    end
  end

  if not winid then
    local split = opts.split or "below"
    local cmd = ({
      above = "aboveleft split",
      below = "belowright split",
      left = "aboveleft vsplit",
      right = "belowright vsplit",
    })[split] or "belowright split"
    vim.cmd(cmd)
    winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
    if opts.size then
      if split == "left" or split == "right" then
        vim.api.nvim_win_set_width(winid, opts.size)
      else
        vim.api.nvim_win_set_height(winid, opts.size)
      end
    end
  else
    vim.api.nvim_set_current_win(winid)
  end

  return bufnr, winid
end
