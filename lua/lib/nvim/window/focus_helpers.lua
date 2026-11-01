---@module 'lib.nvim.window.focus_helpers'
--- Small helpers for log/output-style floating or split windows: keeping the
--- view scrolled to the bottom as content streams in, and forcing focus onto
--- a window that may be behind another or momentarily non-focusable.
---
--- Every function validates its window/buffer handle before touching the
--- API and returns false/no-ops rather than raising -- callers often run
--- from deferred callbacks where the handle may have died in the meantime.

local retry_backoff = require("lib.nvim.patterns.retry_backoff")

local M = {}

---Whether `winid`'s cursor is already on its buffer's last line. An invalid
---window or buffer counts as "at bottom" (nothing left to catch up on).
---@param winid integer
---@return boolean
function M.is_at_bottom(winid)
  if not vim.api.nvim_win_is_valid(winid) then
    return true
  end
  local ok_buf, bufnr = pcall(vim.api.nvim_win_get_buf, winid)
  if not ok_buf or not vim.api.nvim_buf_is_valid(bufnr) then
    return true
  end
  local last = vim.api.nvim_buf_line_count(bufnr)
  local ok_cur, cursor = pcall(vim.api.nvim_win_get_cursor, winid)
  return not ok_cur or cursor[1] >= last
end

---Move the cursor to the last line of `winid`'s buffer.
---
---Two independent retry mechanisms, for two different reasons a single
---attempt can be too early:
---  - `opts.retries` (default 3): the window itself doesn't exist yet (e.g.
---    called right after creation) -- retried on the next scheduled tick.
---  - `opts.attempts` (default 1, i.e. off): the window exists, but more
---    content may still be streaming in, so the cursor isn't actually on
---    the last line yet even right after this move -- retried
---    `opts.retry_delay_ms` (default 60) apart, up to `opts.attempts`
---    times total.
---@param winid integer
---@param opts? { retries?: integer, attempts?: integer, retry_delay_ms?: integer }
function M.ensure_bottom(winid, opts)
  opts = opts or {}
  local retries = opts.retries or 3
  if not vim.api.nvim_win_is_valid(winid) then
    if retries > 0 then
      vim.schedule(function()
        M.ensure_bottom(winid, vim.tbl_extend("force", opts, { retries = retries - 1 }))
      end)
    end
    return
  end
  local ok_buf, bufnr = pcall(vim.api.nvim_win_get_buf, winid)
  if not ok_buf or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local last = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  pcall(vim.api.nvim_win_set_cursor, winid, { last, 0 })

  local attempts = opts.attempts or 1
  if attempts > 1 and not M.is_at_bottom(winid) then
    -- A flat delay (factor 1) and no cap: `attempts` total moves, `retry_delay_ms` apart. A window
    -- that died meanwhile counts as "at bottom", which ends the retry.
    retry_backoff.run(function(n, done)
      if n > 1 then
        M.ensure_bottom(winid, { retries = 0, attempts = 1 })
      end
      done(M.is_at_bottom(winid))
    end, {
      max_attempts = attempts,
      base_ms = opts.retry_delay_ms or 60,
      factor = 1,
      max_ms = math.huge,
    })
  end
end

---Make a window focusable if it was created with `focusable = false`.
---A no-op (and `false`) for a non-floating window -- `focusable` isn't a
---meaningful concept there, `nvim_set_current_win` works on it regardless.
---@param winid integer
---@return boolean ok
function M.make_focusable(winid)
  if not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  local ok, cfg = pcall(vim.api.nvim_win_get_config, winid)
  if not ok or cfg.relative == "" then
    return false -- not a floating window; focusability isn't configurable here
  end
  if cfg.focusable then
    return true
  end
  cfg.focusable = true
  return pcall(vim.api.nvim_win_set_config, winid, cfg)
end

---Force focus onto `winid`, making it focusable first if needed (ignoring
---whether that particular step succeeded -- a plain split has no
---`focusable` concept to flip but switches to it just fine), then flushing
---the switch to the screen so callers that check screen state right after
---(tests, scripted probes) see it reflected.
---@param winid integer
---@return boolean ok
function M.force_focus(winid)
  if not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  M.make_focusable(winid)
  local ok = pcall(vim.api.nvim_set_current_win, winid)
  if ok then
    vim.cmd("redraw")
  end
  return ok
end

---Force focus onto `winid` and scroll it to the bottom. Skips a window
---anchored to another window (`relative == "win"`) or degenerate in size
---(<=1 cell in either dimension) -- neither is a real log view worth
---revealing. Runs `normal! G` once focus actually lands: a plain cursor
---move alone can leave the viewport itself unscrolled for wrapped/long
---content, `G` is what visibly moves it. (`normal! G` acts on whichever
---window is current, not necessarily `winid` -- only run it once focus is
---confirmed to have actually landed there.)
---@param winid integer
---@param opts? { attempts?: integer, retry_delay_ms?: integer }
---@return boolean ok
function M.reveal_at_bottom(winid, opts)
  if not vim.api.nvim_win_is_valid(winid) then
    return false
  end
  local ok_cfg, cfg = pcall(vim.api.nvim_win_get_config, winid)
  if not ok_cfg or cfg.relative == "win" or cfg.width <= 1 or cfg.height <= 1 then
    return false
  end

  local focused = M.force_focus(winid)
  if not vim.api.nvim_win_is_valid(winid) then
    return false
  end

  local ok_buf, bufnr = pcall(vim.api.nvim_win_get_buf, winid)
  if ok_buf and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_win_set_cursor, winid, { vim.api.nvim_buf_line_count(bufnr), 0 })
  end
  if focused then
    vim.cmd("normal! G")
  end

  M.ensure_bottom(winid, opts)
  return focused
end

return M
