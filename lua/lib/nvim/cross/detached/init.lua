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
--- A pid is not an identity: the system hands it out again once the process ended (Windows quickly, and after a
--- reboot anything goes). So `track` also records when the process started (`start_time`), and `list` and `kill` only
--- accept an entry while a process with that pid *and* that start time runs (within `START_TOLERANCE` seconds). A
--- reused pid, an entry whose start time can not be read, and an entry from before this check (no `proc_start`) count
--- as ended: never listed, never killed. The owner is checked the same way, so a reused owner pid still leaves an
--- orphan. Entries older than `MAX_AGE_DAYS` are dropped as well, and `kill_orphans` still asks per entry.
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

---Seconds two readings of a start time may differ and still name the same process (Linux derives it from the boot
---time, which is whole seconds; `ps` prints whole seconds).
M.START_TOLERANCE = 2

---Windows: the creation time from `GetProcessTimes`, through LuaJIT's ffi (no PowerShell started per question).
---`PROCESS_QUERY_LIMITED_INFORMATION` is the least a handle can ask for, the same Task Manager uses.
---@param pid integer
---@return number|nil
local function start_time_windows(pid)
  local has_ffi, ffi = pcall(require, "ffi")
  if not has_ffi then
    return nil
  end
  -- The C declarations are one namespace per process: another plugin in this Neovim (testing.nvim's
  -- testing.child.winproc does) may have declared GetProcessTimes with a FILETIME struct of its own, and then a
  -- second plain declaration fails and the call with our struct throws. So the functions get names of our own and
  -- reach the real symbols through asm() redirection; nothing can collide either way.
  pcall(ffi.cdef, "typedef struct { uint32_t lo; uint32_t hi; } lib_nvim_detached_filetime;")
  pcall(
    ffi.cdef,
    'void* lib_nvim_detached_OpenProcess(uint32_t access, int inherit, uint32_t pid) asm("OpenProcess");'
  )
  pcall(ffi.cdef, 'int lib_nvim_detached_CloseHandle(void* h) asm("CloseHandle");')
  pcall(
    ffi.cdef,
    "int lib_nvim_detached_GetProcessTimes(void* h, lib_nvim_detached_filetime* c, lib_nvim_detached_filetime* e,"
      .. ' lib_nvim_detached_filetime* k, lib_nvim_detached_filetime* u) asm("GetProcessTimes");'
  )
  local ok, secs = pcall(function()
    local k32 = ffi.C
    local h = k32.lib_nvim_detached_OpenProcess(0x1000, 0, pid)
    if h == nil then
      return nil
    end
    local t = ffi.new("lib_nvim_detached_filetime[4]")
    local got = k32.lib_nvim_detached_GetProcessTimes(h, t[0], t[1], t[2], t[3])
    k32.lib_nvim_detached_CloseHandle(h)
    if got == 0 then
      return nil
    end
    -- 100 ns steps since 1601-01-01; a double keeps it to well under a millisecond
    return (tonumber(t[0].hi) * 4294967296 + tonumber(t[0].lo)) / 1e7 - 11644473600
  end)
  return ok and secs or nil
end

---Linux: field 22 of `/proc/<pid>/stat` (clock ticks since boot) plus `btime` from `/proc/stat`.
---@param pid integer
---@return number|nil
local function start_time_proc(pid)
  local f = io.open("/proc/" .. pid .. "/stat", "r")
  if not f then
    return nil
  end
  local stat = f:read("*l") or ""
  f:close()
  -- the command name (field 2) is in parentheses and may hold spaces or ")": count from the last one
  local rest = stat:match("^.*%)%s+(.*)$")
  if not rest then
    return nil
  end
  local fields = vim.split(rest, "%s+", { trimempty = true })
  local ticks = tonumber(fields[20]) -- field 3 is fields[1], so field 22 is fields[20]
  local sf = io.open("/proc/stat", "r")
  if not ticks or not sf then
    return nil
  end
  local btime = tonumber((sf:read("*a") or ""):match("\nbtime%s+(%d+)"))
  sf:close()
  if not btime then
    return nil
  end
  local hz = 100
  local has_ffi, ffi = pcall(require, "ffi")
  if has_ffi then
    -- a name of our own (see start_time_windows): a foreign `sysconf` declaration can not get in the way
    pcall(ffi.cdef, 'long lib_nvim_detached_sysconf(int name) asm("sysconf");')
    local ok, v = pcall(function()
      return tonumber(ffi.C.lib_nvim_detached_sysconf(2)) -- _SC_CLK_TCK
    end)
    if ok and v and v > 0 then
      hz = v
    end
  end
  return btime + ticks / hz
end

local MONTHS = {
  Jan = 1,
  Feb = 2,
  Mar = 3,
  Apr = 4,
  May = 5,
  Jun = 6,
  Jul = 7,
  Aug = 8,
  Sep = 9,
  Oct = 10,
  Nov = 11,
  Dec = 12,
}

---macOS and the BSDs: `ps -o lstart=` ("Wed Nov 18 19:00:00 2026", local time, read back with `os.time`).
---@param pid integer
---@return number|nil
local function start_time_ps(pid)
  local ok, res = pcall(function()
    return vim
      .system({ "ps", "-o", "lstart=", "-p", tostring(pid) }, { text = true, env = { LC_ALL = "C" } })
      :wait(5000)
  end)
  if not ok or not res or res.code ~= 0 then
    return nil
  end
  local mon, day, h, mi, s, y = (res.stdout or ""):match(
    "%a+%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)%s+(%d+)"
  )
  if not mon or not MONTHS[mon] then
    return nil
  end
  return os.time({
    year = tonumber(y) --[[@as integer]],
    month = MONTHS[mon],
    day = tonumber(day) --[[@as integer]],
    hour = tonumber(h) --[[@as integer]],
    min = tonumber(mi) --[[@as integer]],
    sec = tonumber(s) --[[@as integer]],
  })
end

---When the process with this pid started, in seconds since the epoch; nil when there is none or it can not be read
---(then nothing about that pid is trusted).
---@param pid integer
---@return number|nil
function M.start_time(pid)
  if type(pid) ~= "number" or pid <= 0 then
    return nil
  end
  if vim.fn.has("win32") == 1 then
    return start_time_windows(pid)
  end
  if uv.fs_stat("/proc/self/stat") then
    return start_time_proc(pid)
  end
  return start_time_ps(pid)
end

---Is the process this pid names now the one that started at `recorded`? Unknown either way is a no.
---@param pid integer
---@param recorded number|nil
---@return boolean
local function same_process(pid, recorded)
  if type(recorded) ~= "number" or not M.is_alive(pid) then
    return false
  end
  local now = M.start_time(pid)
  return now ~= nil and math.abs(now - recorded) <= M.START_TOLERANCE
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
  local owner = uv.os_getpid()
  entries[#entries + 1] = {
    pid = pid,
    owner = owner,
    name = info.name or "",
    cmd = info.cmd or "",
    started = os.time(),
    proc_start = M.start_time(pid),
    owner_start = M.start_time(owner),
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

---Is the owning Neovim still the one that registered? Without a recorded start time (it could not be read) only
---the pid is asked.
---@param e Lib.Cross.Detached.Entry
---@return boolean
local function owner_is_alive(e)
  if type(e.owner_start) == "number" then
    return same_process(e.owner, e.owner_start)
  end
  return M.is_alive(e.owner)
end

---The registered processes that are still running: same pid and same start time. A dead one, a reused pid, one
---without a start time, and one past `MAX_AGE_DAYS` drop out of the register on the way.
---@param opts? { orphans?: boolean }  orphans: only those whose owning Neovim is gone
---@return Lib.Cross.Detached.Listed[]
function M.list(opts)
  opts = opts or {}
  local entries = load()
  local now = os.time()
  local keep, out = {}, {}
  for _, e in ipairs(entries) do
    local fresh = (now - (e.started or 0)) <= M.MAX_AGE_DAYS * 86400
    if fresh and same_process(e.pid, e.proc_start) then
      keep[#keep + 1] = e
      local owner_alive = owner_is_alive(e)
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

---End a registered process and its children. A pid that is not in the register is refused, and so is one whose
---running process did not start when the entry says (a reused pid, or no start time to compare): that entry is
---dropped, the process left alone.
---@param pid integer
---@return boolean ok
---@return string|nil err
function M.kill(pid)
  ---@type Lib.Cross.Detached.Entry|nil
  local entry
  for _, e in ipairs(load()) do
    if e.pid == pid then
      entry = e
    end
  end
  if not entry then
    return false, "pid " .. tostring(pid) .. " is not in the register"
  end
  if not M.is_alive(pid) then
    M.untrack(pid)
    return true, nil
  end
  if not same_process(pid, entry.proc_start) then
    M.untrack(pid)
    return false,
      "pid "
        .. tostring(pid)
        .. " is not the registered process any more (its start time differs or can not be read): not ended"
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
