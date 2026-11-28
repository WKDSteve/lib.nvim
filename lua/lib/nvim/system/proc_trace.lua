---@module 'lib.nvim.system.proc_trace'
--- Instrumentation for the process-spawning APIs (`vim.fn.system`,
--- `vim.fn.systemlist`, `vim.system`, `vim.fn.jobstart`): measures how long
--- each call takes and, for calls at/above a threshold, logs a stack
--- traceback pointing at the caller.
---
--- WHY THIS EXISTS
--- A UI freeze on the main thread is almost always a synchronous call to one
--- of these APIs (or the event-loop being busy processing a burst of async
--- ones) blocking for longer than expected — a hung external process, a slow
--- filesystem/network path, or simply too many spawns in a tight loop. This
--- module turns "something froze for a while" into "this exact call, from
--- this exact plugin, took this long" without needing a debugger attached.
---
---   local trace = require("lib.nvim.system.proc_trace")
---   trace.start({ threshold_ms = 200 })
---   -- ... reproduce the freeze ...
---   trace.stop()
---   -- inspect trace.log_path() for entries + tracebacks
---
--- HONEST LIMITS (read before relying on this alone)
--- - Only calls made through THESE api tables are seen. A caller that cached
---   a local reference before `start()` ran (`local system = vim.fn.system`)
---   bypasses the wrapper entirely — start as early as possible (first line
---   of init.lua) to minimize this.
---- - LSP clients and other C-internal spawns never go through `vim.fn.*` /
---   `vim.system` and are invisible here. For those, or to rule this module's
---   blind spots out entirely, pair this with an OS-level process monitor
---   (e.g. debugging.nvim's `:Debug proc watch`, which drives a bundled
---   external script) that observes every child process regardless of how
---   it was spawned.
--- - `vim.system(...): wait()` (synchronous use) is not separately timed here;
---   only the async `on_exit` path is wrapped. The dominant real-world use
---   (async with a callback) is covered.
---
--- Pure by default: nothing happens until `start()` is called, and `stop()`
--- fully restores the original functions — safe to leave wired into a
--- diagnostic command that a user reaches for only when something is slow.

require("lib.nvim.system.@types")

local notify = require("lib.nvim.notify").create("[lib.nvim.system.proc_trace]")

local M = {}

---@type Lib.System.ProcTrace.Saved|nil
local originals = nil
---@type string|nil
local active_log_path = nil
--- `uv.hrtime()` is nanoseconds as a plain number; `uv_hrtime` was a type
--- name that never existed.
---@type integer|nil
local t0 = nil

---@internal
---@param cmd string|string[]
---@return string
local function cmd_to_str(cmd)
  if type(cmd) == "table" then
    return table.concat(cmd, " ")
  end
  return tostring(cmd)
end

---@internal
---@return number
local function since_start_ms()
  local uv = vim.uv or vim.loop
  return (uv.hrtime() - (t0 or uv.hrtime())) / 1e6
end

---@internal
---@param fd file*
---@param kind string
---@param cmd_str string
---@param dur_ms number
---@param threshold_ms number
local function log_entry(fd, kind, cmd_str, dur_ms, threshold_ms)
  local line = ("[+%8.0fms] %-14s %7.0fms  %s"):format(
    since_start_ms(),
    kind,
    dur_ms,
    cmd_str:sub(1, 200)
  )
  fd:write(line .. "\n")

  if dur_ms >= threshold_ms then
    -- Skip this function's own frame; start the traceback at the caller.
    fd:write("    " .. debug.traceback("", 2):gsub("\n", "\n    ") .. "\n")
    fd:flush()
    vim.schedule(function()
      notify.warn(("SLOW %s %.0fms: %s"):format(kind, dur_ms, cmd_str:sub(1, 80)))
    end)
    return
  end
  fd:flush()
end

--- Wrap `vim.fn.system`/`vim.fn.systemlist`, `vim.system`, and
--- `vim.fn.jobstart` to log their duration (and a traceback for slow calls).
--- Idempotent: calling `start()` while already active is a no-op that
--- returns the existing log path.
--- testing-perf: conditional: installs wrappers; the starts that pass through them are other callers'
---@param opts? Lib.System.ProcTrace.StartOptions
---@return Lib.System.ProcTrace.Result
function M.start(opts)
  if originals then
    return { path = active_log_path, active = true }
  end

  opts = opts or {}
  local threshold_ms = opts.threshold_ms or 200
  local path = opts.path or (vim.fn.stdpath("state") .. "/proc_trace.log")
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

  local fd, open_err = io.open(path, "w")
  if not fd then
    notify.error("cannot open log file: " .. tostring(open_err))
    return { path = path, active = false }
  end

  local uv = vim.uv or vim.loop
  t0 = uv.hrtime()
  active_log_path = path
  fd:write(("proc_trace active since %s — threshold %dms\n"):format(os.date(), threshold_ms))
  fd:flush()

  originals = {
    fn_system = vim.fn.system,
    fn_systemlist = vim.fn.systemlist,
    vim_system = vim.system,
    fn_jobstart = vim.fn.jobstart,
  }

  for _, name in ipairs({ "system", "systemlist" }) do
    local orig = vim.fn[name]
    vim.fn[name] = function(cmd, ...)
      local start = uv.hrtime()
      local res = orig(cmd, ...)
      log_entry(fd, "fn." .. name, cmd_to_str(cmd), (uv.hrtime() - start) / 1e6, threshold_ms)
      return res
    end
  end

  local orig_system = vim.system
  if orig_system then
    -- Replacing a stdlib function is what this module is: the original is
    -- saved above and restored by `stop()`.
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(cmd, sopts, on_exit)
      local start = uv.hrtime()
      local wrapped_on_exit = on_exit
      if type(on_exit) == "function" then
        wrapped_on_exit = function(obj)
          log_entry(fd, "vim.system", cmd_to_str(cmd), (uv.hrtime() - start) / 1e6, threshold_ms)
          return on_exit(obj)
        end
      end
      return orig_system(cmd, sopts, wrapped_on_exit)
    end
  end

  local orig_jobstart = vim.fn.jobstart
  -- Same deliberate replacement as `vim.system` above.
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.jobstart = function(cmd, jopts)
    jopts = jopts or {}
    local start = uv.hrtime()
    local user_on_exit = jopts.on_exit
    jopts.on_exit = function(id, code, event)
      log_entry(fd, "jobstart", cmd_to_str(cmd), (uv.hrtime() - start) / 1e6, threshold_ms)
      if type(user_on_exit) == "function" then
        return user_on_exit(id, code, event)
      end
    end
    return orig_jobstart(cmd, jopts)
  end

  -- Keep the handle reachable for stop() without leaking it as module state
  -- consumers could mutate.
  originals.__fd = fd

  notify.info("active → " .. path)
  return { path = path, active = true }
end

--- Restore the original functions. Safe to call when not active (no-op).
---@return Lib.System.ProcTrace.Result
function M.stop()
  if not originals then
    return { path = active_log_path, active = false }
  end

  vim.fn.system = originals.fn_system
  vim.fn.systemlist = originals.fn_systemlist
  vim.fn.jobstart = originals.fn_jobstart
  if originals.vim_system then
    vim.system = originals.vim_system
  end

  local fd = originals.__fd
  local path = active_log_path
  originals = nil

  if fd then
    pcall(function()
      fd:write(("proc_trace stopped at %s\n"):format(os.date()))
      fd:close()
    end)
  end

  notify.info("stopped (log: " .. tostring(path) .. ")")
  return { path = path, active = false }
end

--- Whether tracing is currently active.
---@return boolean
function M.is_active()
  return originals ~= nil
end

--- Path of the active (or last used) log file, if any.
---@return string|nil
function M.log_path()
  return active_log_path
end

---@type Lib.System.ProcTrace
return M
