---@module 'lib.nvim.cross.uv.spawn_stream'
--- Async spawn of an argv command with **line-by-line** streaming of
--- stdout/stderr and an optional timeout.
---
--- Sibling of `cross.uv.spawn_capture`, which buffers everything and calls a
--- single callback at exit. Use this one when output must be consumed while
--- the process is still running: a long `rg` scan that fills a picker
--- incrementally, a dev server whose log lines are relayed to a buffer, a
--- build whose progress is reported live.
---
--- Compared to the `vim.system`-based approach plugins usually reach for:
---   * argv, not a shell string — no quoting or interpolation hazard
---   * async — unlike `cross.run_argv`, which blocks
---   * streaming — unlike `cross.uv.spawn_capture`, which buffers
---   * no version fallback needed — `vim.uv`/`vim.loop` exists since 0.5,
---     so there is no `vim.system`-vs-`jobstart` branch to maintain
---
--- Line callbacks run in a **fast event context** (they are driven straight
--- from the libuv read callback). Most of `vim.fn`/`vim.api` is off-limits in
--- there — use `vim.schedule` before touching buffers, or reach for
--- `lib.nvim.fs.mkdirp` instead of `vim.fn.mkdir`. `on_exit` is dispatched via
--- `vim.schedule` and has no such restriction.
---
--- See @types/init.lua for the Lib.Cross.Uv.SpawnStream.* shapes.

require("lib.nvim.cross.uv.spawn_stream.@types")

---@internal
---@return uv
local function uv()
  return vim.uv or vim.loop
end

local unpack_fn = require("lib.lua.functions.varargs").unpack

---@internal
---Build a chunk consumer that emits complete lines and keeps the trailing
---partial line in a closure until more data (or EOF) arrives.
---@param emit fun(line: string)|nil
---@return fun(chunk: string) feed
---@return fun() flush Emit any unterminated remainder
local function line_splitter(emit)
  local pending = ""

  local function feed(chunk)
    if not emit then
      return
    end
    pending = pending .. chunk
    local search_from = 1
    while true do
      local nl = pending:find("\n", search_from, true)
      if not nl then
        break
      end
      local line = pending:sub(search_from, nl - 1)
      -- Strip the CR of a CRLF pair (Windows tooling, and any process whose
      -- stdout was routed through a Windows console).
      if line:sub(-1) == "\r" then
        line = line:sub(1, -2)
      end
      emit(line)
      search_from = nl + 1
    end
    pending = pending:sub(search_from)
  end

  local function flush()
    if emit and pending ~= "" then
      local line = pending
      if line:sub(-1) == "\r" then
        line = line:sub(1, -2)
      end
      pending = ""
      emit(line)
    end
  end

  return feed, flush
end

---@param argv string[] Command and arguments, e.g. { "rg", "--json", pattern }
---@param opts? Lib.Cross.Uv.SpawnStream.Opts
---@param on_line fun(line: string) Called once per complete stdout line, without the newline
---@param on_exit? fun(result: Lib.Cross.Uv.SpawnStream.Result)
---@return fun()|nil kill Kills the process; nil when the spawn failed outright
return function(argv, opts, on_line, on_exit)
  opts = opts or {}
  local loop = uv()

  local stdout_pipe = loop.new_pipe(false)
  local stderr_pipe = loop.new_pipe(false)
  -- libuv returns nil instead of raising when it cannot allocate a handle.
  -- Same answer as a failed spawn: no kill function, and `on_exit` told why.
  if not stdout_pipe or not stderr_pipe then
    if stdout_pipe then
      pcall(stdout_pipe.close, stdout_pipe)
    end
    if stderr_pipe then
      pcall(stderr_pipe.close, stderr_pipe)
    end
    if on_exit then
      vim.schedule(function()
        on_exit({
          ok = false,
          code = -1,
          signal = 0,
          timed_out = false,
          spawn_error = "failed to create a pipe for: " .. tostring(argv[1]),
        })
      end)
    end
    return nil
  end
  local handle
  local timer
  local done = false

  local feed_out, flush_out = line_splitter(on_line)
  local feed_err, flush_err = line_splitter(opts.on_stderr_line)

  -- The process-exit callback can fire while the stdout/stderr pipes still
  -- hold unread data, so exit alone is not a safe point to stop reading —
  -- doing that truncates the tail of a chatty process. Settle only once the
  -- child exited *and* both pipes reported EOF (a `nil` chunk). A timeout
  -- forces settlement regardless.
  local exited, out_eof, err_eof = false, false, false
  local exit_code, exit_signal

  local finish

  local function settle()
    if exited and out_eof and err_eof then
      finish(exit_code, exit_signal, false)
    end
  end

  function finish(code, signal, timed_out)
    if done then
      return
    end
    done = true

    -- Emit trailing partial lines before tearing anything down: a process
    -- that exits without a final newline still has meaningful last output.
    pcall(flush_out)
    pcall(flush_err)

    if timer then
      pcall(timer.stop, timer)
      pcall(timer.close, timer)
      timer = nil
    end
    pcall(stdout_pipe.close, stdout_pipe)
    pcall(stderr_pipe.close, stderr_pipe)
    if handle then
      pcall(handle.close, handle)
    end

    if not on_exit then
      return
    end
    local result = {
      ok = (not timed_out) and code == 0,
      code = code or -1,
      signal = signal or 0,
      timed_out = timed_out or false,
    }
    vim.schedule(function()
      on_exit(result)
    end)
  end

  local spawn_opts = {
    args = { unpack_fn(argv, 2) },
    stdio = { nil, stdout_pipe, stderr_pipe },
    cwd = opts.cwd,
    env = opts.env,
  }

  handle = loop.spawn(argv[1], spawn_opts, function(code, signal)
    exited, exit_code, exit_signal = true, code, signal
    settle()
  end)

  if not handle then
    pcall(stdout_pipe.close, stdout_pipe)
    pcall(stderr_pipe.close, stderr_pipe)
    done = true
    if on_exit then
      vim.schedule(function()
        on_exit({
          ok = false,
          code = -1,
          signal = 0,
          timed_out = false,
          spawn_error = "failed to spawn: " .. tostring(argv[1]),
        })
      end)
    end
    return nil
  end

  -- `data == nil` (with no error) is EOF; an error on the pipe is treated as
  -- EOF too, since nothing further will arrive on it either way.
  stdout_pipe:read_start(function(err, data)
    if data and not err then
      feed_out(data)
    else
      out_eof = true
      settle()
    end
  end)
  stderr_pipe:read_start(function(err, data)
    if data and not err then
      feed_err(data)
    else
      err_eof = true
      settle()
    end
  end)

  if opts.timeout_ms then
    timer = loop.new_timer()
    -- No timer means no timeout: the child is already running, and killing a
    -- working process because libuv ran out of handles would be the worse
    -- outcome of the two.
    if timer then
      timer:start(opts.timeout_ms, 0, function()
        if not done and handle then
          pcall(handle.kill, handle, "sigkill")
          finish(-1, 0, true)
        end
      end)
    end
  end

  return function()
    if not done and handle then
      pcall(handle.kill, handle, opts.kill_signal or "sigterm")
    end
  end
end
