---@module 'lib.nvim.cross.run.env'
--- Spawn-environment builder for subprocesses started from Neovim.
---
--- A subprocess spawned via `vim.system()`, `vim.uv.spawn()` or `jobstart()`
--- inherits **Neovim's own process environment** — not the environment an
--- interactive login shell would have. When Neovim was itself started outside
--- a fully initialised login shell (window manager entry, dock, terminal
--- emulator without a login shell, CI runner), that environment has gaps:
---
---   A. `PATH` is shorter than in the interactive shell, so version-manager
---      binaries (`nvm`/`pyenv`/`rbenv`/`asdf`/`mise`, Homebrew, `~/.cargo/bin`)
---      are missing or resolve to the wrong version.
---   B. Session-bound authentication is unreachable: `gh`/`glab` read their
---      token from the OS keyring, whose reachability depends on variables an
---      interactive desktop session sets (`DBUS_SESSION_BUS_ADDRESS`,
---      `XDG_RUNTIME_DIR`, `SSH_AUTH_SOCK`, …).
---
--- This module builds a deliberately completed `env` table for such spawns,
--- so every plugin that needs it stops hand-rolling its own
--- `vim.tbl_extend("force", vim.fn.environ(), { … })`.

local M = {}

local uv = vim.uv or vim.loop

---@type string[]|nil
local cached_dirs
---@type table<string,string>|nil|false
local cached_login_env

local function is_windows()
  return require("lib.nvim.cross.platform.is_windows")()
end

local function list_sep()
  return is_windows() and ";" or ":"
end

local function home()
  return uv.os_homedir() or vim.env.HOME or vim.env.USERPROFILE
end

---@param p string
---@return boolean
local function is_dir(p)
  local st = uv.fs_stat(p)
  return st ~= nil and st.type == "directory"
end

---Dedup key for a PATH entry — case- and separator-insensitive on Windows.
---@param dir string
---@return string
local function path_key(dir)
  local key = dir:gsub("[/\\]+$", "")
  if is_windows() then
    key = key:gsub("/", "\\"):lower()
  end
  return key
end

---Split a `PATH`-style string into its entries (surrounding quotes stripped).
---@param value string|nil
---@return string[]
local function split_list(value)
  local out = {}
  if not value or value == "" then
    return out
  end
  for part in value:gmatch("([^" .. list_sep() .. "]+)") do
    part = part:gsub('^"(.*)"$', "%1")
    if part ~= "" then
      out[#out + 1] = part
    end
  end
  return out
end

---The key under which `env` stores `PATH`. Windows environments are
---case-insensitive and `vim.fn.environ()` reports `Path` there — writing a
---second `PATH` key would hand the child two conflicting entries.
---@param env table<string,string>
---@return string
local function env_path_key(env)
  for k in pairs(env) do
    if k:upper() == "PATH" then
      return k
    end
  end
  return "PATH"
end

--- Environment variables that carry desktop-session / keyring / agent state —
--- the ones whose absence makes an authenticated CLI report "not logged in"
--- even though the credential is still valid in the keyring.
--- Keyed by platform name as reported by `lib.nvim.cross.platform.is()`.
---@type table<string, string[]>
M.SESSION_VARS = {
  common = { "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TERM", "TMPDIR" },
  linux = {
    "DBUS_SESSION_BUS_ADDRESS",
    "XDG_RUNTIME_DIR",
    "XDG_SESSION_TYPE",
    "XDG_DATA_DIRS",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "GNOME_KEYRING_CONTROL",
    "KDE_FULL_SESSION",
    "SSH_AUTH_SOCK",
    "SSH_AGENT_PID",
    "GPG_TTY",
    "DISPLAY",
    "WAYLAND_DISPLAY",
    "XAUTHORITY",
  },
  macos = {
    "SSH_AUTH_SOCK",
    "SSH_AGENT_PID",
    "GPG_TTY",
    "__CF_USER_TEXT_ENCODING",
    "XPC_SERVICE_NAME",
    "XPC_FLAGS",
  },
  windows = {
    "USERPROFILE",
    "APPDATA",
    "LOCALAPPDATA",
    "ProgramData",
    "ProgramFiles",
    "ProgramFiles(x86)",
    "HOMEDRIVE",
    "HOMEPATH",
    "SystemRoot",
    "windir",
    "ComSpec",
    "PATHEXT",
    "TEMP",
    "TMP",
    "USERNAME",
    "USERDOMAIN",
    "SESSIONNAME",
    "PSModulePath",
  },
}
-- WSL is a Linux userland reached through the Windows host: it needs the
-- Linux session variables, not the Windows ones.
M.SESSION_VARS.wsl = M.SESSION_VARS.linux

---Known session/keyring variable names relevant on the current platform,
---`SESSION_VARS.common` first.
---@return string[]
function M.session_vars()
  local platform = require("lib.nvim.cross.platform.is")()
  local out = {}
  for _, name in ipairs(M.SESSION_VARS.common) do
    out[#out + 1] = name
  end
  for _, name in ipairs(M.SESSION_VARS[platform] or {}) do
    out[#out + 1] = name
  end
  return out
end

---Known session/keyring variables that are **missing** from Neovim's own
---environment — the diagnostic counterpart to `build()`. A non-empty result
---explains why a spawned CLI cannot reach the keyring: `build()` cannot
---invent a value Neovim never received (see `login_shell`).
---@return string[]
function M.missing()
  local out = {}
  for _, name in ipairs(M.session_vars()) do
    local v = vim.env[name]
    if v == nil or v == "" then
      out[#out + 1] = name
    end
  end
  return out
end

---Well-known binary directories for the current platform, in the order they
---should be consulted, filtered to those that actually exist. Cached; call
---`M.clear()` after installing a toolchain mid-session.
---@return string[]
function M.candidate_dirs()
  if cached_dirs then
    return cached_dirs
  end

  local h = home()
  local candidates = {}

  local function add(...)
    for _, p in ipairs({ ... }) do
      if p then
        candidates[#candidates + 1] = p
      end
    end
  end

  if is_windows() then
    local root = vim.env.SystemRoot or vim.env.windir or "C:\\Windows"
    local localapp = vim.env.LOCALAPPDATA or (h and h .. "\\AppData\\Local")
    local programdata = vim.env.ProgramData or "C:\\ProgramData"
    local programfiles = vim.env.ProgramFiles or "C:\\Program Files"
    if h then
      add(
        h .. "\\.cargo\\bin",
        h .. "\\go\\bin",
        h .. "\\.bun\\bin",
        h .. "\\.deno\\bin",
        h .. "\\scoop\\shims"
      )
    end
    add(
      localapp and localapp .. "\\Microsoft\\WindowsApps",
      programdata .. "\\chocolatey\\bin",
      programfiles .. "\\Git\\cmd",
      programfiles .. "\\PowerShell\\7",
      root .. "\\System32",
      root,
      root .. "\\System32\\Wbem",
      root .. "\\System32\\WindowsPowerShell\\v1.0",
      root .. "\\System32\\OpenSSH"
    )
  else
    if h then
      add(
        -- Version-manager shims first: their whole point is shadowing the
        -- system binary, and the interactive shell puts them in front too.
        h .. "/.local/share/mise/shims",
        h .. "/.asdf/shims",
        h .. "/.asdf/bin",
        h .. "/.pyenv/shims",
        h .. "/.pyenv/bin",
        h .. "/.rbenv/shims",
        h .. "/.rbenv/bin",
        h .. "/.volta/bin",
        h .. "/.local/bin",
        h .. "/bin",
        h .. "/.cargo/bin",
        h .. "/go/bin",
        h .. "/.bun/bin",
        h .. "/.deno/bin",
        h .. "/.yarn/bin",
        h .. "/.krew/bin",
        h .. "/.nix-profile/bin"
      )
    end
    add(
      "/opt/homebrew/bin",
      "/opt/homebrew/sbin",
      "/usr/local/bin",
      "/usr/local/sbin",
      "/opt/local/bin",
      "/nix/var/nix/profiles/default/bin",
      "/usr/bin",
      "/usr/sbin",
      "/bin",
      "/sbin",
      "/snap/bin"
    )
  end

  local existing, seen = {}, {}
  for _, dir in ipairs(candidates) do
    local key = path_key(dir)
    if not seen[key] and is_dir(dir) then
      seen[key] = true
      existing[#existing + 1] = dir
    end
  end

  cached_dirs = existing
  return existing
end

---The environment of a POSIX **login** shell (`$SHELL -lc env`, falling back
---to `sh`), i.e. the environment an interactive shell would have after running
---`.zprofile`/`.bash_profile`/`.profile`. This is the only way to recover state
---Neovim's own process never received.
---
---Blocking (up to `timeout_ms`, default 3000) and cached for the session.
---Returns `nil` on native Windows — Windows has no login-shell initialisation
---step; a Windows process gets its environment from the user profile at
---creation time, which Neovim already inherited.
---@param timeout_ms? integer
---@return table<string,string>|nil
function M.login_shell_env(timeout_ms)
  if cached_login_env ~= nil then
    return cached_login_env or nil
  end
  if is_windows() then
    cached_login_env = false
    return nil
  end

  local shell = vim.env.SHELL
  if not shell or shell == "" or vim.fn.executable(shell) ~= 1 then
    shell = "sh"
  end

  local argv = { shell, "-lc", "env" }
  local ok, out
  if vim.system then
    -- Prefer vim.system: it is the only path here that can bound the wait, and
    -- a login shell whose profile blocks (a prompt, a slow network mount)
    -- would otherwise hang Neovim outright.
    local sok, res = pcall(function()
      return vim.system(argv, { text = true }):wait(timeout_ms or 3000)
    end)
    ok, out = sok and res.code == 0, sok and (res.stdout or "") or ""
  else
    ok, out = require("lib.nvim.cross.run_argv").run_blocking_captured(argv)
  end

  if not ok or out == "" then
    cached_login_env = false
    return nil
  end

  local env, last = {}, nil
  for line in (out .. "\n"):gmatch("(.-)\n") do
    local name, value = line:match("^([%w_]+)=(.*)$")
    if name then
      env[name] = value
      last = name
    elseif last then
      -- Continuation of a multi-line value (`env` prints them raw).
      env[last] = env[last] .. "\n" .. line
    end
  end

  if next(env) == nil then
    cached_login_env = false
    return nil
  end

  cached_login_env = env
  return env
end

---A `PATH` string with every existing well-known binary directory guaranteed
---present, without reordering or dropping what is already inherited.
---
---Precedence: `opts.extra_paths` → inherited `PATH` → login-shell `PATH`
---(when `opts.login_shell`) → `M.candidate_dirs()`. Duplicates are dropped
---case-insensitively on Windows.
---@param opts? Lib.Cross.Run.Env.Opts
---@return string
function M.path(opts)
  opts = opts or {}

  local ordered, seen = {}, {}
  local function push(dir)
    if type(dir) ~= "string" or dir == "" then
      return
    end
    local key = path_key(dir)
    if not seen[key] then
      seen[key] = true
      ordered[#ordered + 1] = dir
    end
  end

  for _, dir in ipairs(opts.extra_paths or {}) do
    push(dir)
  end

  if opts.mason then
    local mason_bin = vim.fn.stdpath("data") .. "/mason/bin"
    if is_dir(mason_bin) then
      push(mason_bin)
    end
  end

  local base = opts.base
  local inherited = base and base[env_path_key(base)] or vim.env.PATH
  for _, dir in ipairs(split_list(inherited)) do
    push(dir)
  end

  if opts.login_shell then
    local login = M.login_shell_env(opts.timeout_ms)
    if login and login.PATH then
      for _, dir in ipairs(split_list(login.PATH)) do
        push(dir)
      end
    end
  end

  for _, dir in ipairs(M.candidate_dirs()) do
    push(dir)
  end

  return table.concat(ordered, list_sep())
end

---Build a completed environment table for a spawn call: Neovim's own
---environment, plus a guaranteed-complete `PATH`, plus known
---session/keyring variables filled in wherever they can be recovered.
---
---```lua
---vim.system({ "gh", "api", "/user" }, { env = require("lib.nvim.cross.run.env").build() }, cb)
---```
---
---Note what this cannot do: a variable that is missing from Neovim's *own*
---environment cannot be conjured up — pass `login_shell = true` to recover it
---from a login shell, or supply it via `vars`. `M.missing()` reports which
---known variables are absent.
---@param opts? Lib.Cross.Run.Env.Opts
---@return table<string,string>
function M.build(opts)
  opts = opts or {}

  local env = {}
  for k, v in pairs(opts.base or vim.fn.environ()) do
    env[k] = v
  end

  local names = M.session_vars()
  for _, name in ipairs(opts.passthrough or {}) do
    names[#names + 1] = name
  end

  local login = opts.login_shell and M.login_shell_env(opts.timeout_ms) or nil
  for _, name in ipairs(names) do
    if env[name] == nil or env[name] == "" then
      local value = vim.env[name]
      if (value == nil or value == "") and login then
        value = login[name]
      end
      if value ~= nil and value ~= "" then
        env[name] = value
      end
    end
  end

  env[env_path_key(env)] = M.path(vim.tbl_extend("force", opts, { base = env }))

  for k, v in pairs(opts.vars or {}) do
    env[k] = v
  end

  return env
end

---Build the completed environment as an array of `"KEY=VALUE"` strings,
---ready for `lib.nvim.cross.uv.spawn_capture`'s `opts.env`: raw libuv
---`uv.spawn` wants an array, but `build()` returns a `{ [key] = value }`
---dict (the shape `vim.system`/`jobstart` want), so this is the one place
---that does the dict -> array conversion instead of every `uv.spawn` caller
---hand-rolling it.
---
---Windows hidden variables (name starting with `=`, e.g. `=C:` for the
---per-drive cwd, set by cmd.exe) are kept as `=C:=C:\dir`: native process
---inheritance passes them on too, and libuv forwards them intact.
---@param vars? table<string, string> Explicit overrides, applied last
---@return string[]
function M.array(vars)
  local env = M.build({ vars = vars })
  local out = {}
  for k, v in pairs(env) do
    out[#out + 1] = k .. "=" .. v
  end
  return out
end

---Return a spawn options table with `env` filled in by `build()`, leaving
---every other key of `spawn_opts` untouched. Convenience for the common
---`vim.system(argv, env.apply({ cwd = … }))` shape; the input table is not
---mutated. An `env` already present in `spawn_opts` is used as the base, so
---caller-supplied variables survive.
--- testing-perf: conditional: only with `login_shell = true` (never on Windows)
---@param spawn_opts? table
---@param opts? Lib.Cross.Run.Env.Opts
---@return table
function M.apply(spawn_opts, opts)
  local out = vim.tbl_extend("force", {}, spawn_opts or {})
  local build_opts = vim.tbl_extend("force", {}, opts or {})
  if type(out.env) == "table" then
    build_opts.vars = vim.tbl_extend("force", out.env, build_opts.vars or {})
  end
  out.env = M.build(build_opts)
  return out
end

---Drop the cached directory scan and login-shell probe. Call after installing
---a toolchain or changing the shell profile inside a running session.
---@return nil
function M.clear()
  cached_dirs = nil
  cached_login_env = nil
end

---@type Lib.Cross.Run.Env
return M
