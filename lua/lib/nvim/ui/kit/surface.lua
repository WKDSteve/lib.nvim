---@module 'lib.nvim.ui.kit.surface'
--- A surface is one themed floating window plus a lifecycle handle. It hands
--- geometry/buffer creation to lib.nvim.window.make_scratch and then applies the
--- resolved theme; it does not re-implement float creation. A themed split (left, right or
--- bottom panel) is `lib.nvim.ui.kit.sidebar`, which reuses this handle's methods.

local make_scratch = require("lib.nvim.window.make_scratch")
local set_title = require("lib.nvim.window.set_title")
local theme = require("lib.nvim.ui.kit.theme")

local api = vim.api

---@class Lib.UI.Kit.Surface
---@field border string|string[]  # the resolved theme's border, so a caller doesn't have to theme.resolve() again to learn it
---@field package _on_close function[]
---@field package _closed boolean
---@field package _augroup integer|nil
local Surface = {}
Surface.__index = Surface

--- Replace the surface's buffer content, preserving `modifiable`.
---
--- `modifiable` is put back even when the API refuses the lines (a line with an
--- embedded "\n", which is how a NUL byte from `readfile()` arrives): the error
--- still reaches the caller, but a read-only pane does not stay writable.
---@param lines string[]
function Surface:set_lines(lines)
  if not api.nvim_buf_is_valid(self.bufnr) then
    return
  end
  local was_modifiable = api.nvim_get_option_value("modifiable", { buf = self.bufnr })
  api.nvim_set_option_value("modifiable", true, { buf = self.bufnr })
  local ok, err = pcall(api.nvim_buf_set_lines, self.bufnr, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", was_modifiable, { buf = self.bufnr })
  if not ok then
    error(err, 0)
  end
end

--- Replace only the buffer's last line, preserving `modifiable`. For a
--- streaming consumer that keeps its own line buffer and only extends the
--- line currently being written to, this avoids the full-buffer
--- `nvim_buf_set_lines` a repeated `set_lines` call would otherwise cost per
--- chunk. Pair with `append_lines` for newline-crossing chunks.
---@param text string
function Surface:set_last_line(text)
  if not api.nvim_buf_is_valid(self.bufnr) then
    return
  end
  local was_modifiable = api.nvim_get_option_value("modifiable", { buf = self.bufnr })
  api.nvim_set_option_value("modifiable", true, { buf = self.bufnr })
  -- -2/-1: the buffer's last line only (Neovim buffers always have >= 1
  -- line, so this range is always valid, even right after surface.open()).
  local ok, err = pcall(api.nvim_buf_set_lines, self.bufnr, -2, -1, false, { text })
  api.nvim_set_option_value("modifiable", was_modifiable, { buf = self.bufnr })
  if not ok then
    error(err, 0)
  end
end

--- Append `lines` after the buffer's current last line, preserving
--- `modifiable`. A no-op for an empty list. See `set_last_line`.
---@param lines string[]
function Surface:append_lines(lines)
  if #lines == 0 then
    return
  end
  if not api.nvim_buf_is_valid(self.bufnr) then
    return
  end
  local was_modifiable = api.nvim_get_option_value("modifiable", { buf = self.bufnr })
  api.nvim_set_option_value("modifiable", true, { buf = self.bufnr })
  local ok, err = pcall(api.nvim_buf_set_lines, self.bufnr, -1, -1, false, lines)
  api.nvim_set_option_value("modifiable", was_modifiable, { buf = self.bufnr })
  if not ok then
    error(err, 0)
  end
end

--- Update (or clear, with nil) the float's title.
---@param title string|nil
function Surface:set_title(title)
  if api.nvim_win_is_valid(self.winid) then
    set_title(self.winid, title)
  end
end

--- Move the cursor into this surface's window, if still valid.
function Surface:focus()
  if api.nvim_win_is_valid(self.winid) then
    api.nvim_set_current_win(self.winid)
  end
end

--- Register a callback to run when the surface closes (any cause). Multiple
--- callbacks may be registered; all run, in registration order.
---@param cb fun()
function Surface:on_close(cb)
  if type(cb) == "function" then
    self._on_close[#self._on_close + 1] = cb
  end
end

--- Whether the surface's window handle still refers to a live window.
---@return boolean
function Surface:is_valid()
  return api.nvim_win_is_valid(self.winid)
end

--- Run the close callbacks exactly once.
function Surface:fire_close()
  if self._closed then
    return
  end
  self._closed = true
  -- Window ids are never reused within a session, so leaving this augroup
  -- behind (its own `once = true` autocmd already gone) would otherwise
  -- accumulate one empty group per surface ever opened.
  if self._augroup then
    pcall(api.nvim_del_augroup_by_id, self._augroup)
    self._augroup = nil
  end
  for _, cb in ipairs(self._on_close) do
    pcall(cb)
  end
end

--- Close the underlying window (if still valid) and fire close callbacks.
function Surface:close()
  if api.nvim_win_is_valid(self.winid) then
    pcall(api.nvim_win_close, self.winid, true)
  end
  self:fire_close()
end

local M = {}

--- The handle class (its methods), for a module that builds another kind of surface on the same
--- methods: `lib.nvim.ui.kit.sidebar` (a themed split) inherits `set_lines`, `append_lines`,
--- `on_close`, ... from it and overrides what differs for a split.
M.Handle = Surface

--- The buffer variable that marks a buffer as one a secret is typed into (`kit.input` with
--- `secret = true`, a `kit.sheet` with a secret field). Anything that records or shows the
--- keys as they are typed -- `ui.screenkey`, a keycast overlay, a macro logger -- reads it
--- and leaves that buffer's keys out. The name is part of the kit's contract (`lib.nvim`'s
--- mirror copy -- kept in step by ui.nvim's `TESTS/kit_drift_spec.lua` -- uses the same one,
--- so a HUD from either side sees both).
---@type string
M.SECRET_VAR = "ui_kit_secret"

--- Mark `bufnr` as one a secret is typed into (see `SECRET_VAR`). The buffer is wiped with
--- its float, and the variable with it.
---@param bufnr integer
function M.mark_secret(bufnr)
  pcall(function()
    vim.b[bufnr][M.SECRET_VAR] = true
  end)
end

--- Is `bufnr` (the current buffer when omitted) marked as holding a secret? Cheap and
--- never raises: `ui.screenkey` asks it for every key.
---@param bufnr? integer
---@return boolean
function M.is_secret(bufnr)
  local ok, marked = pcall(function()
    return vim.b[bufnr or 0][M.SECRET_VAR]
  end)
  return ok and marked == true
end

--- The zindex of a float without an explicit one: the theme's level, raised above the float it is
--- opened from (the current window, and `win` it is anchored to). A dialog below such a float takes
--- the focus but cannot be seen: a snacks picker's floats sit at 52-55, above the popup level 50.
---@param z integer
---@param win? integer
---@return integer
local function above_opener(z, win)
  for _, w in ipairs({ api.nvim_get_current_win(), win }) do
    if w and w ~= 0 and api.nvim_win_is_valid(w) then
      local cfg = api.nvim_win_get_config(w)
      if cfg.relative ~= "" and (cfg.zindex or 0) >= z then
        z = cfg.zindex + 1
      end
    end
  end
  return z
end

--- Open a themed float and return its handle (or nil on failure).
---@param opts? Lib.UI.Kit.SurfaceOpts
---@return Lib.UI.Kit.Surface|nil
function M.open(opts)
  opts = opts or {}
  local resolved = theme.resolve(opts.theme)

  local winid, bufnr = make_scratch({
    lines = opts.lines,
    width = opts.width,
    height = opts.height,
    relative = opts.relative,
    win = opts.win,
    anchor = opts.anchor,
    row = opts.row,
    col = opts.col,
    border = resolved.border,
    title = opts.title,
    title_pos = opts.title_pos or resolved.title_pos,
    zindex = opts.zindex or above_opener(resolved.zindex.popup, opts.win),
    focusable = opts.focusable,
    enter = opts.enter,
    filetype = opts.filetype,
    modifiable = opts.modifiable,
    nice_quit = opts.nice_quit,
    -- A float lives and dies with its one buffer (`bufhidden = "wipe"`). A jump
    -- (`<C-o>`, `<C-^>`), `:bnext` or `:e` in a Normal-mode row would swap the user's
    -- file into it and wipe that buffer, stranding the component with its window
    -- still open and no callback ever fired. `winfixbuf` makes those fail with
    -- E1513 instead; a caller that wants the old behaviour passes `wo.winfixbuf = false`.
    wo = vim.tbl_extend("keep", opts.wo or {}, { winfixbuf = true }),
    bo = opts.bo,
  })

  if not winid or not bufnr then
    return nil
  end

  theme.apply(winid, resolved)

  -- Entering a window keeps the mode: a read-only float opened by an Insert-mode
  -- mapping (a picker's caller key showing details) would stand in Insert mode,
  -- where `q` is typed (E21) instead of closing it and `<Esc>` only gets back to
  -- Normal mode. `:stopinsert` takes effect once the mapping returns. A float
  -- that is typed into keeps Insert mode, as does one that is not entered.
  -- Only an explicit `enter = true`: a component that mounts several floats opens
  -- its helper panes with the default (they are entered on the way, `make_scratch`
  -- enters by default) and then focuses its prompt and starts Insert mode there --
  -- which `:startinsert` cannot do once a `:stopinsert` is pending (kit.compare).
  if opts.enter == true and opts.modifiable ~= true and api.nvim_get_current_win() == winid then
    local mode = api.nvim_get_mode().mode
    if mode:find("^[iR]") or mode:find("^ni") then
      vim.cmd("stopinsert")
    end
  end

  local self = setmetatable({
    winid = winid,
    bufnr = bufnr,
    -- Exposed so a caller that needs to know the resolved border (e.g.
    -- lib.nvim.ui.kit.toast, to know how many extra rows its box occupies when
    -- stacking) doesn't have to call theme.resolve(opts.theme) a second
    -- time itself. Deep-copied: a table-shaped border (the "ascii" preset,
    -- or any custom preset registered with one) is otherwise the exact
    -- same table object theme.lua's `presets` registry holds -- tbl_deep_extend
    -- doesn't copy a leaf value it takes wholesale from the override side --
    -- so an in-place edit through this public field would silently corrupt
    -- that preset for every window opened with it, for the rest of the
    -- session.
    border = vim.deepcopy(resolved.border),
    _on_close = {},
    _closed = false,
  }, Surface)

  -- A dialog that takes the keyboard registers itself, so `kit.ask` can wait for a free moment.
  if opts.modal then
    require("lib.nvim.ui.kit.modal").enter(self)
  end

  -- Fire on_close callbacks when the window closes for any reason.
  local autocmd = require("lib.nvim.bindings.autocmd")
  local group = autocmd.group("lib_ui_kit_surface_" .. winid, true)
  self._augroup = group
  autocmd.create("WinClosed", function()
    self:fire_close()
  end, {
    group = group,
    pattern = tostring(winid),
    once = true,
    -- `record = false`: a throwaway hook of one float. Its group is named after
    -- the window id -- new for every popup -- and lib.nvim's autocmd records are
    -- only dropped through `delete(id)` or by asking for the same group again,
    -- so recording it added one entry per popup for good (shortlist: five, with
    -- the ones below). Every kit popup that hooks a window does the same.
    record = false,
    desc = "lib.nvim.ui.kit.surface: lifecycle",
  })

  return self
end

return M
