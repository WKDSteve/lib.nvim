---@module 'lib.nvim.cross.run'
--- Shell selection plus shell-string runners: pick a platform-appropriate
--- shell, then run a single command **string** through it — async (`run`),
--- blocking (`run_blocking`), or detached (`run_detached`). For argv-based
--- execution with no shell involved, see `lib.nvim.cross.run_argv`.

local M = {}

--- Pick a shell suitable for the platform.
---@return OsShell
function M.shell()
  if require("lib").is_windows() and not require("lib").is_wsl() then
    return {
      prog = "powershell",
      args = { "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command" },
      is_powershell = true,
    }
  end
  return { prog = "sh", args = { "-lc" }, is_powershell = false }
end

--- The argv `run`/`run_blocking` spawn for `cmd`: the shell, every one of
--- its arguments, then the command string. Appended rather than spread over
--- fixed positional slots, because `shell()` returns one argument on POSIX
--- and four on Windows -- a fixed spread dropped PowerShell's `-Command`
--- and relied on nil holes being compacted away on POSIX.
---@param cmd string
---@return string[]
function M.argv(cmd)
  local sh = M.shell()
  local argv = { sh.prog }
  vim.list_extend(argv, sh.args)
  argv[#argv + 1] = cmd
  return argv
end

---@internal
--- Resolve the `env` table to hand `vim.system`/`jobstart`. By default every
--- `run`/`run_blocking` call is enriched via `cross.run.env.build()` — a
--- guaranteed-complete `PATH` plus recoverable session/keyring variables —
--- so callers get that fix without doing anything (see
--- `docs/guides/subprocess-env.md`). `opts.env = false` opts a call back
--- out entirely, reverting to bare `vim.system`/`jobstart` inheritance (the
--- pre-existing behaviour); `opts.env` as a table is folded in as overrides
--- on top of the built environment, same precedence as `env.apply()`.
---@param opts Lib.Cross.Run.RunOpts
---@return table<string,string>|nil
local function resolve_env(opts)
  if opts.env == false then
    return nil
  end

  local build_opts = opts.env_opts or {}
  if type(opts.env) == "table" then
    build_opts = vim.tbl_extend(
      "force",
      build_opts,
      { vars = vim.tbl_extend("force", opts.env, build_opts.vars or {}) }
    )
  end

  return require("lib.nvim.cross.run.env").build(build_opts)
end

--- Async run using vim.system when available; falls back to jobstart.
---@param cmd string
---@param cb fun(ok:boolean, res:OsRunResult)
---@param opts? Lib.Cross.Run.RunOpts
---@return nil
function M.run(cmd, cb, opts)
  opts = opts or {}
  local sh = M.shell()
  local env = resolve_env(opts)
  local function pack(code, signal, stdout, stderr)
    return { code = code or 0, signal = signal or 0, stdout = stdout or "", stderr = stderr or "" }
  end

  if vim.system then
    vim.system(M.argv(cmd), { text = true, env = env }, function(obj)
      cb(obj.code == 0, pack(obj.code, obj.signal, obj.stdout, obj.stderr))
    end)
    return
  end

  -- Legacy fallback
  local full = sh.prog .. " " .. table.concat(sh.args, " ") .. " " .. cmd
  local stdout, stderr = {}, {}
  local jid = vim.fn.jobstart(full, {
    stdout_buffered = true,
    stderr_buffered = true,
    env = env,
    on_stdout = function(_, data)
      if data then
        stdout = data
      end
    end,
    on_stderr = function(_, data)
      if data then
        stderr = data
      end
    end,
    on_exit = function(_, code, signal)
      cb(code == 0, pack(code, signal, table.concat(stdout, "\n"), table.concat(stderr, "\n")))
    end,
  })
  if jid <= 0 then
    cb(false, pack(1, 0, "", "jobstart failed"))
  end
end

--- Blocking run (utility for quick conversions / probing).
---@param cmd string
---@param opts? Lib.Cross.Run.RunOpts
---@return OsRunResult
function M.run_blocking(cmd, opts)
  opts = opts or {}
  local sh = M.shell()
  local env = resolve_env(opts)
  if vim.system then
    local obj = vim.system(M.argv(cmd), { text = true, env = env }):wait()
    return {
      code = obj.code or 1,
      signal = obj.signal or 0,
      stdout = obj.stdout or "",
      stderr = obj.stderr or "",
    }
  end
  -- Minimal blocking fallback via systemlist(). systemlist() has no env
  -- parameter of its own; a caller relying on `opts.env`/enrichment here
  -- degrades silently to bare process inheritance on this legacy path.
  local full = sh.prog .. " " .. table.concat(sh.args, " ") .. " " .. cmd
  local ok, out = pcall(vim.fn.systemlist, full)
  local code = vim.v.shell_error or 1
  return {
    code = code,
    signal = 0,
    stdout = ok and table.concat(out, "\n") or "",
    stderr = ok and "" or "systemlist failed",
  }
end

--- Launch `argv` detached from Neovim (fire-and-forget, no output capture).
--- On Windows/WSL, GUI processes (e.g. `explorer.exe`, `notepad`) are launched
--- via `jobstart(..., { detach = true })` instead of `vim.system`, because
--- `vim.system`'s process detachment is unreliable for GUI processes on
--- those platforms — `jobstart` with `detach = true` handles it correctly.
--- Elsewhere, `vim.system(argv, { detach = true })` is used when available.
---
--- GUI processes only, on Windows. libuv's DETACHED_PROCESS leaves the child
--- without standard handles, and a CONSOLE program launched this way exits
--- before running anything: a detached `powershell.exe -Command Set-Content …`
--- returns a valid job id and never writes the file. A GUI process does not
--- care, which is why `explorer.exe` works here and PowerShell does not. For a
--- console helper, spawn it normally (`vim.system(argv, {})`) and simply don't
--- wait on it — see `lib.nvim.cross.reveal_in_fm`, which needs both.
---
--- `opts.track` (a name) records the process in `lib.nvim.cross.detached`, so a later session can list and end it if
--- this Neovim dies first. Off by default: nothing is registered unless the caller asks.
---@param argv string[]
---@param opts? { track?: string }
---@return boolean ok
---@return string|nil err
function M.run_detached(argv, opts)
  if type(argv) ~= "table" or not argv[1] then
    return false, "argv must be a non-empty string list"
  end

  ---@param pid integer|nil
  local function track(pid)
    if opts and opts.track and pid then
      pcall(function()
        require("lib.nvim.cross.detached").track(
          pid,
          { name = opts.track, cmd = table.concat(argv, " ") }
        )
      end)
    end
  end

  ---The pid behind a job id, only when it will be tracked. `jobpid` raises E900 for an id whose channel already
  ---closed (a process that exited at once) or never existed (a stubbed `jobstart`), so it is guarded.
  ---@param jid integer
  ---@return integer|nil
  local function pid_of(jid)
    if not (opts and opts.track) then
      return nil
    end
    local ok, pid = pcall(vim.fn.jobpid, jid)
    return ok and pid or nil
  end

  local is_windows = require("lib.nvim.cross.platform.is_windows")()
  local is_wsl = require("lib.nvim.cross.platform.is_wsl")()

  if is_windows or is_wsl then
    local jid = vim.fn.jobstart(argv, { detach = true })
    if jid <= 0 then
      return false, "jobstart failed"
    end
    track(pid_of(jid))
    return true, nil
  end

  if vim.system then
    local ok, res = pcall(vim.system, argv, { detach = true })
    if not ok then
      return false, tostring(res)
    end
    track(res and res.pid)
    return true, nil
  end

  local jid = vim.fn.jobstart(argv, { detach = true })
  if jid <= 0 then
    return false, "jobstart failed"
  end
  track(pid_of(jid))
  return true, nil
end

return M
