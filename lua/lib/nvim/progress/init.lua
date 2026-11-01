---@module 'lib.nvim.progress'
---Cross-platform progress indicator, decoupled from any single UI.
---
---Usage: >lua
---
---  local h = require("lib.nvim.progress").create({ title = "[replacer]" })
---  h:update({ text = "searching", current = 12, total = 128 })
---  h:finish("128 matches in 19 files")
---
---`style` ("auto" | "notify" | "statusline" | "echo" | "fidget" | "float" | "kit")
---only changes *how* the same calls render; callers never touch a style
---implementation directly. See `lib.nvim.progress.styles.*` to add a new
---renderer. `style` also accepts a list (e.g. `{"statusline", "echo"}`) to
---run several renderers in parallel for one handle.
---
---The "float" style owns an interactive window: focus it deliberately and
---press <Esc> (normal mode) to ask for cancellation via `request_cancel()`.
---Since that keymap is buffer-local, nothing happens while any other window
---is focused — the operation is never interrupted by accident.
---
---A handle stays invisible until `delay_ms` has elapsed (default 150ms), so a
---fast operation never flashes UI. If `finish`/`cancel` runs before that,
---nothing is ever rendered.
---
---Only `vim.uv`/`vim.api`/`vim.notify` are used — no OS-specific calls, so
---this behaves identically on Linux, macOS and Windows.

require("lib.nvim.progress.@types")

local resolve_style = require("lib.nvim.progress.resolve_style")
local notify = require("lib.nvim.notify").create("[lib.nvim.progress]")
local composite = require("lib.lua.patterns.composite")

local M = {}

local DEFAULT_DELAY_MS = 150

---@internal
---@param prefix string|nil
---@return string
local function normalize_title(prefix)
  if type(prefix) ~= "string" or prefix == "" then
    return ""
  end
  if not prefix:match("%s$") then
    return prefix .. " "
  end
  return prefix
end

---Best-effort cleanup for a style whose `update`/`finish`/`cancel` just
---raised: retries the style's own `cancel` on the next main-loop tick, so a
---window `start` already opened doesn't outlive the failure that disabled
---the style -- without this, a style whose only error was a transient
---fast-event-context throw (see `lib.nvim.progress.styles.kit`) permanently
---orphans its chip, since `finish`/`cancel` both skip any style already
---marked `style_failed`. Wrapped in `vim.schedule` + `pcall`: even if this
---retry itself fails (state already gone, or the failure wasn't
---context-related), it's a silent no-op rather than a second uncaught error.
---@internal
---@param style Lib.Progress.StyleImpl
---@param state any
---@param fail_spec Lib.Progress.Spec
---@param opts Lib.Progress.Opts
local function schedule_cleanup(style, state, fail_spec, opts)
  vim.schedule(function()
    pcall(style.cancel, state, fail_spec, opts)
  end)
end

---Safely stop+close a uv timer exactly once (same idempotent pattern as
---`lib.nvim.buf_win_tab.capture`).
---@internal
---@param t uv.uv_timer_t|nil
local function safe_close_timer(t)
  if not t then
    return
  end
  t:stop()
  local uv = vim.uv or vim.loop
  if not uv.is_closing(t) then
    t:close()
  end
end

---Normalizes `opts.style` (a single style or a list) to a resolved style-
---implementation list. A bare string becomes a single-element list, so an
---existing caller passing `style = "notify"` sees no behavior change -- the
---loops below just run once.
---@internal
---@param want Lib.Progress.Style|Lib.Progress.Style[]|nil
---@return Lib.Progress.StyleImpl[]
local function resolve_styles(want)
  local wanted = want or "auto"
  if type(wanted) ~= "table" then
    wanted = { wanted }
  end
  local styles = {}
  for _, one in ipairs(wanted) do
    styles[#styles + 1] = resolve_style(one)
  end
  return styles
end

---@param opts? Lib.Progress.Opts
---@return Lib.Progress.Handle
function M.create(opts)
  opts = opts or {}
  local title = normalize_title(opts.title)
  local delay_ms = type(opts.delay_ms) == "number" and opts.delay_ms or DEFAULT_DELAY_MS
  local styles = resolve_styles(opts.style)

  ---@type Lib.Progress.Fields
  local fields = {}
  local started = false
  local done = false
  ---@type fun()[]
  local on_cancel_fns = {}
  local timer = nil ---@type uv.uv_timer_t|nil
  local handle ---@type Lib.Progress.Handle forward-declared: styles may call handle:request_cancel()

  ---@return Lib.Progress.Spec
  local function spec()
    return { title = title, text = fields.text, current = fields.current, total = fields.total }
  end

  local function request_cancel_cb()
    handle:request_cancel()
  end

  -- One adapter per style owns that style's state and its failed flag, and never raises: a style that
  -- raised once is skipped from then on, so one broken renderer (a third-party style, a closed window
  -- under "float"/"kit") cannot stop the others from rendering for this handle. The adapters are the
  -- children of a composite, which does the fan-out.
  ---@param i integer
  ---@param style Lib.Progress.StyleImpl
  local function adapter(i, style)
    local state, failed = nil, false
    return {
      start = function()
        local ok, result = pcall(style.start, spec(), opts, request_cancel_cb)
        if ok then
          state = result
        else
          failed = true
          notify.error(
            ("style #%d failed to start, disabling it for this handle: %s"):format(
              i,
              tostring(result)
            )
          )
        end
      end,
      update = function()
        if failed then
          return
        end
        local prior_state = state
        local ok, result = pcall(style.update, state, spec(), opts)
        if ok then
          state = result
        else
          failed = true
          notify.error(
            ("style #%d failed to update, disabling it for this handle: %s"):format(
              i,
              tostring(result)
            )
          )
          schedule_cleanup(style, prior_state, spec(), opts)
        end
      end,
      finish = function()
        if failed then
          return
        end
        local ok, err = pcall(style.finish, state, spec(), opts)
        if not ok then
          notify.error(("style #%d failed to finish: %s"):format(i, tostring(err)))
          schedule_cleanup(style, state, spec(), opts)
        end
      end,
      cancel = function()
        if failed then
          return
        end
        local ok, err = pcall(style.cancel, state, spec(), opts)
        if not ok then
          notify.error(("style #%d failed to cancel: %s"):format(i, tostring(err)))
          schedule_cleanup(style, state, spec(), opts)
        end
      end,
    }
  end

  local adapters = {}
  for i, style in ipairs(styles) do
    adapters[i] = adapter(i, style)
  end
  local group = composite.new(adapters)

  local function do_start()
    if started or done then
      return
    end
    started = true
    group:call("start")
  end

  if delay_ms > 0 then
    local uv = vim.uv or vim.loop
    timer = uv.new_timer()
    if timer then
      timer:start(
        delay_ms,
        0,
        vim.schedule_wrap(function()
          safe_close_timer(timer)
          do_start()
        end)
      )
    else
      do_start()
    end
  else
    do_start()
  end

  handle = {
    cancelled = false,

    update = function(_, new_fields)
      if done then
        return
      end
      new_fields = new_fields or {}
      if new_fields.text ~= nil then
        fields.text = new_fields.text
      end
      if new_fields.current ~= nil then
        fields.current = new_fields.current
      end
      if new_fields.total ~= nil then
        fields.total = new_fields.total
      end
      if started then
        group:call("update")
      end
    end,

    finish = function(_, text)
      if done then
        return
      end
      done = true
      safe_close_timer(timer)
      if text ~= nil then
        fields.text = text
      end
      if not started then
        return -- never became visible; a fast operation stays silent
      end
      group:call("finish")
    end,

    cancel = function(_, text)
      if done then
        return
      end
      done = true
      safe_close_timer(timer)
      if text ~= nil then
        fields.text = text
      end
      if not started then
        return
      end
      group:call("cancel")
    end,

    on_cancel = function(_, fn)
      on_cancel_fns[#on_cancel_fns + 1] = fn
    end,

    request_cancel = function(self)
      -- a cancel that comes after the end (the abort question was answered late) has nothing left to stop
      if self.cancelled or done then
        return
      end
      self.cancelled = true
      for _, fn in ipairs(on_cancel_fns) do
        local ok, err = pcall(fn)
        if not ok then
          notify.error("on_cancel callback failed: " .. tostring(err))
        end
      end
      self:cancel()
    end,
  }

  return handle
end

---@type Lib.Progress
return M
