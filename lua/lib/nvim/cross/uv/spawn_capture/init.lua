---@module 'lib.nvim.cross.uv.spawn_capture'
--- Async spawn of an argv command with buffered stdout/stderr capture and an
--- optional timeout. Complements `cross.run`/`cross.run_argv` (blocking /
--- shell-string async) and `cross.uv.spawn_command`/`spawn_shell_command`
--- (fire-and-inherit-stdio): none of those cover "spawn argv, buffer output,
--- invoke a callback once, with an optional kill-on-timeout".

---@internal
---@return uv
local function uv()
  return vim.uv or vim.loop
end

local unpack_fn = require("lib.lua.functions.varargs").unpack

---@param argv string[] Command and arguments, e.g. { "curl", "-sS", url }
---@param opts? { timeout_ms?: integer, cwd?: string, env?: string[], stdin?: string } `env`,
---like libuv's own spawn `env` option, is an array of `"KEY=VALUE"` strings —
---not a `{ [key] = value }` dict. Passed straight through, unconverted.
---
---`stdin` is written to the child and the pipe is then closed, so a command
---that reads until EOF (`curl -K -`, `rg --file -`) terminates. It exists for
---the case where a value must not appear in argv: a process's command line is
---readable by any other process on the machine, which makes it the wrong place
---for a credential. Without `stdin` the child gets no stdin at all, as before.
---@param on_done fun(result: Lib.Cross.Uv.SpawnCapture.Result)
return function(argv, opts, on_done)
  opts = opts or {}
  local loop = uv()

  local stdin_pipe = opts.stdin and loop.new_pipe(false) or nil
  local stdout_pipe = loop.new_pipe(false)
  local stderr_pipe = loop.new_pipe(false)
  local stdout_chunks, stderr_chunks = {}, {}
  local handle
  local timer
  local done = false

  ---@internal
  --- Report a failure that happened before the child was running, in the
  --- shape a finished run reports, and close whatever was already opened.
  ---@param err string
  local function fail(err)
    if stdin_pipe then
      pcall(stdin_pipe.close, stdin_pipe)
    end
    if stdout_pipe then
      pcall(stdout_pipe.close, stdout_pipe)
    end
    if stderr_pipe then
      pcall(stderr_pipe.close, stderr_pipe)
    end
    vim.schedule(function()
      on_done({
        ok = false,
        code = -1,
        signal = 0,
        stdout = "",
        stderr = err,
        timed_out = false,
      })
    end)
  end

  -- libuv returns nil instead of raising when it cannot allocate a handle.
  if not stdout_pipe or not stderr_pipe or (opts.stdin and not stdin_pipe) then
    fail("failed to create a pipe for: " .. tostring(argv[1]))
    return
  end

  local function finish(code, signal, timed_out)
    if done then
      return
    end
    done = true
    if timer then
      pcall(timer.stop, timer)
      pcall(timer.close, timer)
      timer = nil
    end
    if stdin_pipe then
      pcall(stdin_pipe.close, stdin_pipe)
    end
    pcall(stdout_pipe.close, stdout_pipe)
    pcall(stderr_pipe.close, stderr_pipe)
    if handle then
      pcall(handle.close, handle)
    end
    local result = {
      ok = (not timed_out) and code == 0,
      code = code or -1,
      signal = signal or 0,
      stdout = table.concat(stdout_chunks),
      stderr = table.concat(stderr_chunks),
      timed_out = timed_out or false,
    }
    vim.schedule(function()
      on_done(result)
    end)
  end

  local spawn_opts = {
    args = { unpack_fn(argv, 2) },
    stdio = { stdin_pipe, stdout_pipe, stderr_pipe },
    cwd = opts.cwd,
    env = opts.env,
  }

  handle = loop.spawn(argv[1], spawn_opts, function(code, signal)
    finish(code, signal, false)
  end)

  if not handle then
    fail("failed to spawn: " .. argv[1])
    return
  end

  -- Written after the spawn, and closed straight after: the child is reading
  -- until EOF, so leaving the pipe open would hang it.
  if stdin_pipe then
    stdin_pipe:write(opts.stdin, function()
      pcall(stdin_pipe.shutdown, stdin_pipe)
    end)
  end

  stdout_pipe:read_start(function(err, data)
    if not err and data then
      stdout_chunks[#stdout_chunks + 1] = data
    end
  end)
  stderr_pipe:read_start(function(err, data)
    if not err and data then
      stderr_chunks[#stderr_chunks + 1] = data
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
end
