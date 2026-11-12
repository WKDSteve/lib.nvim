---@module 'lib.nvim.cross.detached'
--- A register of the processes a plugin started detached (fire-and-forget), so the ones a previous Neovim left behind
--- can be listed and ended.
---
--- A detached child does not die with the editor: a preview server, a watcher, a helper. When Neovim exits or
--- crashes, nothing remembers it, and the next session finds a busy port or a stray process in the task manager with
--- no hint where it came from. This module is the memory: `track` records the pid with the pid of the Neovim that
--- started it, `list` says which of those are still running and whose owner is gone (an *orphan*), `kill` ends one.
---
--- Opt-in by the caller (`run.run_detached(argv, { track = "name" })` records for it); a process that is not in the
--- register is never listed and never killed here, so this can not be turned on an arbitrary pid.
---
--- Limits, stated: a pid can be reused by the system after the process ended; entries older than `MAX_AGE_DAYS` are
--- dropped instead of listed, and a process is only reported while the pid answers a signal 0, but a reused pid that
--- is alive again is indistinguishable here. `kill` therefore asks first (`kill_orphans` takes a `confirm`).
---
---```lua
--- local detached = require("lib.nvim.cross.detached")
--- detached.track(pid, { name = "mdview-relay", cmd = "node relay.js" })
--- for _, e in ipairs(detached.list({ orphans = true })) do print(e.pid, e.name) end
--- detached.kill_orphans(function(e) return vim.fn.confirm("Kill " .. e.name .. "?", "&Yes\n&No", 2) == 1 end)
---```
---
--- See @types/init.lua for Lib.Cross.Detached.*.

require("lib.nvim.cross.detached.@types")

local uv = vim.uv or vim.loop

local M = {}

---Entries older than this are forgotten rather than listed: past it a pid has very likely been reused.
M.MAX_AGE_DAYS = 14

---@return string
local function register_path()
  return vim.fn.stdpath("state") .. "/lib.nvim/detached.json"
end

---Where the register lives (specs and tools).
---@return string
function M.path()
  return register_path()
end

---@return Lib.Cross.Detached.Entry[]
local function load()
  local json = require("lib.nvim.fs.json")
  local data = json.read(register_path())
  if type(data) ~= "table" or type(data.entries) ~= "table" then
    return {}
  end
  ---@type Lib.Cross.Detached.Entry[]
  local out = {}
  for _, e in ipairs(data.entries) do
    if type(e) == "table" and type(e.pid) == "number" and type(e.owner) == "number" then
      out[#out + 1] = e
    end
  end
  return out
end

---@param entries Lib.Cross.Detached.Entry[]
---@return boolean ok
local function save(entries)
  local path = register_path()
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local ok = require("lib.nvim.fs.json").write(path, { version = 1, entries = entries })
  return ok == true
end

---Does a process with this pid exist? Signal 0 only asks; `EPERM` means it exists but is not ours.
---@param pid integer
---@return boolean
function M.is_alive(pid)
  if type(pid) ~= "number" or pid <= 0 then
    return false
  end
  local ok, err = uv.kill(pid, 0)
  if ok == 0 then
    return true
  end
  return tostring(err or ""):find("EPERM", 1, true) ~= nil
end

---Record a detached process.
---@param pid integer
---@param info? { name?: string, cmd?: string }
---@return boolean ok
function M.track(pid, info)
  if type(pid) ~= "number" or pid <= 0 then
    return false
  end
  info = info or {}
  local entries = load()
  for i = #entries, 1, -1 do
    if entries[i].pid == pid then
      table.remove(entries, i)
    end
  end
  entries[#entries + 1] = {
    pid = pid,
    owner = uv.os_getpid(),
    name = info.name or "",
    cmd = info.cmd or "",
    started = os.time(),
  }
  return save(entries)
end

---Forget a process (it ended, or was ended).
---@param pid integer
---@return boolean removed
function M.untrack(pid)
  local entries = load()
  for i = #entries, 1, -1 do
    if entries[i].pid == pid then
      table.remove(entries, i)
      save(entries)
      return true
    end
  end
  return false
end

---The registered processes that are still running. A dead one, and one past `MAX_AGE_DAYS`, drops out of the
---register on the way.
---@param opts? { orphans?: boolean }  orphans: only those whose owning Neovim is gone
---@return Lib.Cross.Detached.Listed[]
function M.list(opts)
  opts = opts or {}
  local entries = load()
  local now = os.time()
  local keep, out = {}, {}
  for _, e in ipairs(entries) do
    local fresh = (now - (e.started or 0)) <= M.MAX_AGE_DAYS * 86400
    if fresh and M.is_alive(e.pid) then
      keep[#keep + 1] = e
      local owner_alive = e.owner == uv.os_getpid() or M.is_alive(e.owner)
      if not opts.orphans or not owner_alive then
        out[#out + 1] = vim.tbl_extend("force", e, { orphan = not owner_alive })
      end
    end
  end
  if #keep ~= #entries then
    save(keep)
  end
  return out
end

---End a registered process and its children. A pid that is not in the register is refused.
---@param pid integer
---@return boolean ok
---@return string|nil err
function M.kill(pid)
  local registered = false
  for _, e in ipairs(load()) do
    if e.pid == pid then
      registered = true
    end
  end
  if not registered then
    return false, "pid " .. tostring(pid) .. " is not in the register"
  end
  if not M.is_alive(pid) then
    M.untrack(pid)
    return true, nil
  end
  if vim.fn.has("win32") == 1 then
    local root = uv.os_getenv("SystemRoot") or uv.os_getenv("windir") or "C:/Windows"
    local exe = root .. "/System32/taskkill.exe"
    if not uv.fs_stat(exe) then
      exe = "taskkill"
    end
    local res = vim.system({ exe, "/T", "/F", "/PID", tostring(pid) }, { text = true }):wait(10000)
    if res.code ~= 0 and M.is_alive(pid) then
      return false, vim.trim(res.stderr or res.stdout or "taskkill failed")
    end
  else
    -- the child leads a session of its own (`detach`): the negative pid is its whole group
    local ok = uv.kill(-pid, "sigterm")
    if ok ~= 0 then
      uv.kill(pid, "sigterm")
    end
  end
  M.untrack(pid)
  return true, nil
end

---End every orphan, one question each.
---@param confirm fun(entry: Lib.Cross.Detached.Listed): boolean  asked per orphan; false skips it
---@return integer killed
function M.kill_orphans(confirm)
  local n = 0
  for _, e in ipairs(M.list({ orphans = true })) do
    if confirm(e) then
      local ok = M.kill(e.pid)
      if ok then
        n = n + 1
      end
    end
  end
  return n
end

return M
