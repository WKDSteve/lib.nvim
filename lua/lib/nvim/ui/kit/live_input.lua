---@module 'lib.nvim.ui.kit.live_input'
--- Live-incremental input: a single-line insert-mode prompt (like `kit.input`)
--- that additionally debounces keystrokes into `on_change(query)` as the user
--- types — for filter/search boxes that need to refresh a results list or
--- preview on every keystroke, not just on submit. This is the floating
--- prompt-buffer + `TextChangedI`-debounce pattern that got hand-rolled
--- independently in filetree.nvim's `features/search/live_search/init.lua`
--- and `features/search/filter/init.lua`. The debounce timer itself is the same
--- one `kit.picker`'s prompt slot uses internally.

local surface = require("lib.nvim.ui.kit.surface")
local input = require("lib.nvim.ui.kit.input")

local api = vim.api
local autocmd = require("lib.nvim.bindings.autocmd")
local debounce = require("lib.nvim.debounce")
-- A NUL byte in the title would raise E976 out of the width measured below.
local nul_safe = require("lib.lua.strings.core").nul_safe

local M = {}

--- Open a live-incremental input.
---@param opts table  # { title|prompt, default?, theme?, width?, relative?, row?, col?, debounce?, on_change(query: string), on_submit?(query: string), on_cancel?() }
---@return Lib.UI.Kit.Surface|nil
function M.open(opts)
  opts = opts or {}

  local title = opts.title or opts.prompt
  -- A float's title is drawn within its content width; a title longer than
  -- the default 40 cols gets silently truncated by Neovim (with a leading
  -- ellipsis) instead of wrapping, so widen the box to fit it.
  local title_width = title and vim.fn.strdisplaywidth(nul_safe(title)) or 0

  local surf = surface.open({
    modal = true,
    lines = { opts.default or "" },
    theme = opts.theme,
    title = title,
    width = opts.width or math.max(40, title_width),
    height = 1,
    relative = opts.relative or "cursor",
    row = opts.row,
    col = opts.col,
    enter = true,
    modifiable = true,
    filetype = opts.filetype or "lib-kit-live-input",
  })
  if not surf then
    -- `surface.open` failed to open the float -- a genuine break, not a
    -- user-driven cancel. Without this, on_cancel never fires and a
    -- caller waiting on it stalls silently.
    if opts.on_cancel then
      opts.on_cancel()
    end
    return nil
  end

  local bufnr = surf.bufnr
  local on_change = opts.on_change or function(_) end
  local debounce_ms = tonumber(opts.debounce) or 80
  local done = false

  local function query()
    if not api.nvim_buf_is_valid(bufnr) then
      return ""
    end
    return api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  end

  local change = debounce.new(function()
    if not done then
      on_change(query())
    end
  end, debounce_ms)
  local stop_timer = change.cancel

  local function schedule_change()
    change.call()
  end

  local function finish(submit)
    if done then
      return
    end
    done = true
    stop_timer()
    local line = query()
    -- Leave insert mode before closing to avoid a lingering mode state.
    pcall(function()
      vim.cmd("stopinsert")
    end)
    surf:close()
    if submit then
      if opts.on_submit then
        opts.on_submit(line)
      end
    elseif opts.on_cancel then
      opts.on_cancel()
    end
  end

  -- Buffer-local and in no group: one group shared by every live_input, cleared at each
  -- open, took the TextChanged hooks of the one that was already open away, and its
  -- `on_change` was never called again. The autocmd goes with the buffer (wiped when the
  -- float closes); `record = false` as for every throwaway hook of one float (see
  -- `lib.nvim.ui.kit.surface`).
  autocmd.create({ "TextChangedI", "TextChanged" }, schedule_change, {
    buffer = bufnr,
    record = false,
    desc = "lib.nvim.ui.kit.live_input: query changed",
  })

  vim.keymap.set({ "i", "n" }, "<CR>", function()
    finish(true)
  end, { buffer = bufnr, nowait = true })
  vim.keymap.set({ "i", "n" }, "<Esc>", function()
    finish(false)
  end, { buffer = bufnr, nowait = true })
  surf:on_close(function()
    stop_timer()
    finish(false)
  end)

  -- Place the cursor at end of the default text and enter insert mode.
  if surf:is_valid() then
    api.nvim_win_set_cursor(surf.winid, { 1, #(opts.default or "") })
    -- A prompt that closes while its callback opens this one must leave Insert mode on.
    input.mark_opened()
    vim.cmd("startinsert!")
  end

  return surf
end

return M
