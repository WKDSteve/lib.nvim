---@module 'lib.nvim.patterns.throttle'
--- Throttle: at most one call per `ms`. Debounce waits for quiet; throttle keeps a steady rate under a
--- constant stream of calls (scroll, cursor moves, progress updates).
---
--- `M.new(fn, ms, opts)` returns `{ call, cancel, flush }`.
---   * `opts.leading` (default true): the first call of a burst runs at once.
---   * `opts.trailing` (default true): calls made during the pause run once more with the *latest*
---     arguments when the pause ends.
--- Leading calls run on the caller's thread; trailing calls are scheduled onto the main loop
--- (`vim.schedule`) because libuv timer callbacks are not safe for `vim.api`.
---
--- ```lua
--- local throttle = require("lib.nvim.patterns.throttle")
--- local t = throttle.new(function(line) update_preview(line) end, 100)
--- vim.api.nvim_create_autocmd("CursorMoved", { callback = function() t.call(vim.fn.line(".")) end })
--- ```

require("lib.nvim.patterns.throttle.@types")

local uv = vim.uv or vim.loop

local M = {}

-- LuaJIT (Neovim's Lua runtime) only has the global `unpack`; `table.unpack` is Lua 5.2+.
---@diagnostic disable-next-line: deprecated
local unpack = table.unpack or unpack

---`table.pack` is missing on plain LuaJIT.
local function pack(...)
  return { n = select("#", ...), ... }
end

---@param fn fun(...:any)
---@param ms integer
---@param opts Lib.Patterns.Throttle.Opts|nil
---@return Lib.Patterns.Throttle.Handle
function M.new(fn, ms, opts)
  if type(fn) ~= "function" then
    error("throttle.new: fn must be a function", 2)
  end
  if type(ms) ~= "number" or ms ~= ms or ms < 0 or ms == math.huge then
    error("throttle.new: ms must be a finite number >= 0", 2)
  end
  opts = opts or {}
  local leading = opts.leading ~= false
  local trailing = opts.trailing ~= false

  local timer = nil
  local pending = nil ---@type { n: integer, [integer]: any }|nil
  local gen = 0

  local function close_timer()
    if timer then
      pcall(timer.stop, timer)
      pcall(timer.close, timer)
      timer = nil
    end
  end

  local start_pause

  local function on_pause_end(my_gen)
    vim.schedule(function()
      if my_gen ~= gen then
        return
      end
      close_timer()
      if trailing and pending then
        local args = pending
        pending = nil
        start_pause()
        fn(unpack(args, 1, args.n))
      end
    end)
  end

  start_pause = function()
    close_timer()
    gen = gen + 1
    local my_gen = gen
    timer = uv.new_timer()
    if not timer then
      return
    end
    local started = pcall(timer.start, timer, ms, 0, function()
      on_pause_end(my_gen)
    end)
    if not started then
      -- never keep a handle that never started: it would hold the throttle in "paused" forever
      close_timer()
    end
  end

  ---@param ... any
  local function call(...)
    if timer then
      if trailing then
        pending = pack(...)
      end
      return
    end
    if leading then
      start_pause()
      fn(...)
    else
      pending = trailing and pack(...) or nil
      start_pause()
    end
  end

  local function cancel()
    gen = gen + 1
    pending = nil
    close_timer()
  end

  ---Run the pending trailing call now (if any) and end the pause.
  local function flush()
    local args = pending
    cancel()
    if args then
      fn(unpack(args, 1, args.n))
    end
  end

  return { call = call, cancel = cancel, flush = flush }
end

return M
