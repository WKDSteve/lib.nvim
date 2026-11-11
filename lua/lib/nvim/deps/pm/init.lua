---@module 'lib.nvim.deps.pm'
--- OS package-manager detection and install-command composition.
---
--- Answers "which package manager does this host have" and "what would the
--- command to install these packages look like on it" — nothing more. This
--- module never executes anything; `lib.nvim.deps.install` is what puts a
--- composed command in front of the user, and even that only ever hands it
--- to a terminal buffer the user submits themselves.
---
--- Two deliberate omissions, both safety-motivated:
---
--- * **No `-y`/`--noconfirm`.** The composed commands keep the package
---   manager's own confirmation prompt. The user is going to run this in a
---   visible terminal anyway; letting apt/dnf/pacman show what they're about
---   to pull in is strictly better than suppressing it for tidiness.
--- * **No elevation logic beyond prefixing `sudo`.** On Linux that prefix is
---   the whole mechanism; on Windows, elevation is the package manager's own
---   business (winget's UAC prompt, choco's elevated-shell requirement) and
---   this module does not try to arrange it.

local core = require("lib.nvim.core")
local platform_is_windows = require("lib.nvim.cross.platform.is_windows")
local platform_is_macos = require("lib.nvim.cross.platform.is_macos")

local M = {}

--- Known package managers, keyed by id. `install` is the argv *after* the
--- binary; `multi` says whether one invocation accepts several packages
--- (winget does not — it treats extra tokens as query terms, so it gets one
--- command per package instead).
---@type table<string, Lib.Deps.Manager>
local MANAGERS = {
  apt = { id = "apt", bin = "apt", install = { "install" }, needs_root = true, multi = true },
  dnf = { id = "dnf", bin = "dnf", install = { "install" }, needs_root = true, multi = true },
  pacman = {
    id = "pacman",
    bin = "pacman",
    install = { "-S", "--needed" },
    needs_root = true,
    multi = true,
  },
  zypper = {
    id = "zypper",
    bin = "zypper",
    install = { "install" },
    needs_root = true,
    multi = true,
  },
  apk = { id = "apk", bin = "apk", install = { "add" }, needs_root = true, multi = true },
  brew = { id = "brew", bin = "brew", install = { "install" }, needs_root = false, multi = true },
  winget = {
    id = "winget",
    bin = "winget",
    install = { "install" },
    needs_root = false,
    multi = false,
  },
  scoop = { id = "scoop", bin = "scoop", install = { "install" }, needs_root = false, multi = true },
  choco = { id = "choco", bin = "choco", install = { "install" }, needs_root = false, multi = true },
}

--- Language-level managers: not an OS package manager, so never what
--- `detect()` answers, but a tool that exists only as a Python package
--- (`whisper-ctranslate2`) declares `pkg = { pipx = "..." }` or `{ pip = "..." }`.
--- `resolve` uses them only when the OS manager has no package for the tool.
--- `pipx` is preferred: it isolates the tool; `pip --user` is the fallback.
---@type table<string, Lib.Deps.Manager>
local LANG_MANAGERS = {
  pipx = { id = "pipx", bin = "pipx", install = { "install" }, needs_root = false, multi = true },
  pip = {
    id = "pip",
    bin = "pip",
    install = { "install", "--user" },
    needs_root = false,
    multi = true,
  },
}
local LANG_ORDER = { "pipx", "pip" }

--- Preference order per OS. First one found on PATH wins. WSL is deliberately
--- treated as plain Linux: the package-manager question ("what installs
--- software into this userspace") is orthogonal to the render-target question
--- other WSL branches in the ecosystem solve, and inside WSL the distro's own
--- manager is the correct answer.
---@type table<string, string[]>
local ORDER = {
  windows = { "winget", "scoop", "choco" },
  macos = { "brew" },
  linux = { "apt", "dnf", "pacman", "zypper", "apk" },
}

---@internal
---@return "windows"|"macos"|"linux"
local function os_key()
  if platform_is_windows() then
    return "windows"
  end
  if platform_is_macos() then
    return "macos"
  end
  return "linux"
end

---Definition of a package manager by id, whether or not it is installed.
---@param id string
---@return Lib.Deps.Manager|nil
function M.get(id)
  return MANAGERS[id] or LANG_MANAGERS[id]
end

---Every known package-manager id, unordered.
---@return string[]
function M.ids()
  local ids = vim.tbl_keys(MANAGERS)
  for _, id in ipairs(LANG_ORDER) do
    ids[#ids + 1] = id
  end
  return ids
end

---Every package manager present on this host, in this OS's preference order.
---@return Lib.Deps.Manager[]
function M.available()
  local found = {}
  for _, id in ipairs(ORDER[os_key()]) do
    if core.has_exec(MANAGERS[id].bin) then
      found[#found + 1] = MANAGERS[id]
    end
  end
  return found
end

---The package manager to use on this host: the first one found in this OS's
---preference order, or nil when none of them are installed.
---@return Lib.Deps.Manager|nil
function M.detect()
  return M.available()[1]
end

---Which manager installs `tool`, and under which package name.
---
---The host's OS manager (`os_manager`, default `detect()`) wins when the tool
---declares a package for it. Otherwise the first language-level manager
---(`pipx`, then `pip`) that the tool declares AND that is on PATH answers.
---Returns nil when neither does. Pure lookup; nothing is run.
---@param tool Lib.Deps.Tool
---@param os_manager? Lib.Deps.Manager|false # false: skip the OS manager (tests)
---@return Lib.Deps.Manager|nil manager
---@return string|nil pkg
function M.resolve(tool, os_manager)
  local pkgs = tool.pkg or {}
  if os_manager == nil then
    os_manager = M.detect()
  end
  if os_manager and pkgs[os_manager.id] then
    return os_manager, pkgs[os_manager.id]
  end
  for _, id in ipairs(LANG_ORDER) do
    if pkgs[id] and core.has_exec(LANG_MANAGERS[id].bin) then
      return LANG_MANAGERS[id], pkgs[id]
    end
  end
  return nil, nil
end

---True when the current process is already root, so `sudo` would be noise.
---`getuid` is absent on Windows, where the question doesn't arise. Exported
---(not just internal) because `deps.view` needs the same answer to decide
---whether a tool can be installed inline (no interactive stdin available for
---a password prompt) or needs the terminal handoff — see `M.needs_terminal`.
---@return boolean
function M.is_root()
  local uv = vim.uv or vim.loop
  return type(uv.getuid) == "function" and uv.getuid() == 0
end

---Compose the install command(s) for `packages` on `manager`, as argv lists.
---
---Returns a *list* of commands, not one: a manager that can't take several
---packages per invocation (winget) gets one command each, while everything
---else gets a single combined command. Callers should render/run each in
---order rather than assuming there is exactly one.
---
---A `sudo` prefix is added only when the manager needs root, the process
---isn't already root, and `sudo` is actually on PATH — a machine without
---`sudo` gets the bare command rather than one that would fail with
---"sudo: not found".
---@param manager Lib.Deps.Manager
---@param packages string[]
---@return string[][] commands argv lists; empty when `packages` is empty
function M.commands(manager, packages)
  if #packages == 0 then
    return {}
  end

  ---@param pkgs string[]
  ---@return string[]
  local function one(pkgs)
    local argv = {}
    if manager.needs_root and not M.is_root() and core.has_exec("sudo") then
      argv[#argv + 1] = "sudo"
    end
    argv[#argv + 1] = manager.bin
    for _, part in ipairs(manager.install) do
      argv[#argv + 1] = part
    end
    for _, pkg in ipairs(pkgs) do
      argv[#argv + 1] = pkg
    end
    return argv
  end

  if manager.multi then
    return { one(packages) }
  end

  local commands = {}
  for _, pkg in ipairs(packages) do
    commands[#commands + 1] = one({ pkg })
  end
  return commands
end

---True when installing via `manager` needs an interactive terminal (a
---privilege-elevation prompt this process cannot answer on its own) rather
---than a plain backgrounded job. Used by `deps.view` to decide whether a
---single-tool inline install is safe, or must fall back to
---`deps.install.run`'s confirm-then-terminal handoff.
---@param manager Lib.Deps.Manager
---@return boolean
function M.needs_terminal(manager)
  return manager.needs_root and not M.is_root()
end

---Render an argv list as a copy-pasteable shell string, quoting only the
---tokens that need it. Display/paste only — `lib.nvim.deps.install` sends
---this text to a terminal for the user to submit, it is never handed to a
---shell by this library.
---@param argv string[]
---@return string
function M.render(argv)
  local parts = {}
  for _, token in ipairs(argv) do
    if token:match("^[%w%._%-/:=+@]+$") then
      parts[#parts + 1] = token
    else
      parts[#parts + 1] = '"' .. token:gsub('"', '\\"') .. '"'
    end
  end
  return table.concat(parts, " ")
end

---@type Lib.Deps.Pm
return M
