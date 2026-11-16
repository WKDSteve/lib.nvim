---@module 'lib.nvim.cross.fs.lock'
--- Diagnose *who* is holding a file open on Windows — the counterpart to
--- `lib.nvim.cross.fs.mutate`, which can only tell you *that* a mutation
--- failed with `EBUSY`/`EPERM`/`EACCES`.
---
--- Those codes are libuv's rendering of `ERROR_SHARING_VIOLATION`: some
--- process has the file open without `FILE_SHARE_DELETE`. The code alone is a
--- dead end for a user, and the usual suspicion — "my editor has the file
--- open" — is wrong: Neovim closes a file after reading it and keeps only its
--- swap file open. So this module answers the question directly, via the
--- Windows Restart Manager (`rstrtmgr.dll`), the same API installers use to
--- ask "please close these applications first". It needs no administrator
--- rights.
---
--- The query is a PowerShell process, so it is asynchronous by nature and
--- every entry point that needs it takes a callback.

local M = {}

local uv, fn = vim.uv or vim.loop, vim.fn
local mkdirp = require("lib.nvim.fs.mkdirp")

---@internal
---@return boolean
local function is_windows()
  return fn.has("win32") == 1 or fn.has("win64") == 1
end

-- P/Invoke shim for the Restart Manager, compiled per call by `Add-Type`.
-- Shipped as a file rather than a `-Command` string: the C# is full of quotes
-- that would otherwise need escaping through two layers.
local PS_SCRIPT = [==[
param([Parameter(Mandatory=$true)][string]$Path)

Add-Type -ErrorAction Stop @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class RmLock {
  [StructLayout(LayoutKind.Sequential)]
  struct RM_UNIQUE_PROCESS { public int dwProcessId; public System.Runtime.InteropServices.ComTypes.FILETIME ProcessStartTime; }

  const int CCH_RM_MAX_APP_NAME = 255;
  const int CCH_RM_MAX_SVC_NAME = 63;

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct RM_PROCESS_INFO {
    public RM_UNIQUE_PROCESS Process;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_APP_NAME + 1)] public string strAppName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCH_RM_MAX_SVC_NAME + 1)] public string strServiceShortName;
    public int ApplicationType;
    public uint AppStatus;
    public uint TSSessionId;
    [MarshalAs(UnmanagedType.Bool)] public bool bRestartable;
  }

  [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
  static extern int RmStartSession(out uint pSessionHandle, int dwSessionFlags, string strSessionKey);
  [DllImport("rstrtmgr.dll")]
  static extern int RmEndSession(uint pSessionHandle);
  [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
  static extern int RmRegisterResources(uint pSessionHandle, uint nFiles, string[] rgsFilenames,
    uint nApplications, [In] RM_UNIQUE_PROCESS[] rgApplications, uint nServices, string[] rgsServiceNames);
  [DllImport("rstrtmgr.dll")]
  static extern int RmGetList(uint dwSessionHandle, out uint pnProcInfoNeeded, ref uint pnProcInfo,
    [In, Out] RM_PROCESS_INFO[] rgAffectedApps, ref uint lpdwRebootReasons);

  public static List<string> Who(string path) {
    var result = new List<string>();
    uint handle; uint res;
    if (RmStartSession(out handle, 0, Guid.NewGuid().ToString()) != 0) throw new Exception("RmStartSession failed");
    try {
      if (RmRegisterResources(handle, 1, new string[] { path }, 0, null, 0, null) != 0)
        throw new Exception("RmRegisterResources failed");
      uint pnProcInfo = 0, pnProcInfoNeeded = 0, rebootReasons = 0;
      res = (uint)RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, null, ref rebootReasons);
      if (res == 234 /* ERROR_MORE_DATA */) {
        var info = new RM_PROCESS_INFO[pnProcInfoNeeded];
        pnProcInfo = pnProcInfoNeeded;
        if (RmGetList(handle, out pnProcInfoNeeded, ref pnProcInfo, info, ref rebootReasons) == 0) {
          for (int i = 0; i < pnProcInfo; i++) {
            int pid = info[i].Process.dwProcessId;
            string name = info[i].strAppName;
            try { name = System.Diagnostics.Process.GetProcessById(pid).ProcessName; } catch {}
            result.Add(pid + "\t" + name + "\t" + info[i].strAppName);
          }
        }
      } else if (res != 0) throw new Exception("RmGetList failed with " + res);
    } finally { RmEndSession(handle); }
    return result;
  }
}
'@

$holders = [RmLock]::Who($Path)
if ($holders.Count -eq 0) { "NO_HOLDER" } else { $holders }
]==]

---Whether holder lookup is available on this platform. `probe` works
---everywhere; only `who`/`report`'s holder list is Windows-only.
---@return boolean
function M.supported()
  return is_windows()
end

---@internal
---Materialize the helper script under `stdpath("cache")`, once per session.
---
---`stdpath("cache")` is where Neovim *would* keep its cache, not a directory
---it promises already exists: nothing creates it until something writes
---there, so on a fresh machine -- a CI runner, a first run after a clean
---install -- it is simply absent. `writefile` does not create parents, so it
---failed with `E482: Can't open file ... no such file or directory`, and
---`who`/`report` then reported "cannot write helper script" on a perfectly
---healthy Windows box. Creating the directory first is the whole fix.
---@return string|nil path
---@return string|nil err
local function ensure_script()
  local dir = fn.stdpath("cache")
  local path = dir .. "/lib_nvim_fs_lock.ps1"
  if fn.filereadable(path) == 1 then
    return path, nil
  end
  local made, mkerr = mkdirp(dir)
  if not made then
    return nil, tostring(mkerr)
  end
  local ok, err = pcall(fn.writefile, vim.split(PS_SCRIPT, "\n"), path)
  if not ok then
    return nil, tostring(err)
  end
  return path, nil
end

---Attempt the very operation that fails in the wild — a rename — and undo it
---when it unexpectedly succeeds.
---
---A live probe beats reasoning about an error the user saw minutes ago: these
---locks are transient, and the question that matters is whether the file is
---*still* locked while you are looking at it. Renaming (rather than opening)
---is deliberate: it is the operation that actually trips over a missing
---`FILE_SHARE_DELETE`, so a reader-only lock that would never break a rename
---does not produce a false alarm.
---@param path string  Absolute path to test.
---@return boolean ok  True when the path could be renamed and restored.
---@return string|nil err  libuv error of the failed rename, or a restore failure.
function M.probe(path)
  local probe_path = path .. ".libnvim-lockprobe"
  local ok, err = uv.fs_rename(path, probe_path)
  if not ok then
    return false, tostring(err)
  end

  local back_ok, back_err = uv.fs_rename(probe_path, path)
  if not back_ok then
    -- Leaving the file parked under the probe name would be a far worse
    -- outcome than the lock we came to diagnose, so this must not be silent.
    return false,
      ("probe renamed the file but could not restore it — it is now at %s (%s)"):format(
        probe_path,
        tostring(back_err)
      )
  end
  return true, nil
end

---List the processes holding `path` open.
---
---Asynchronous: the lookup spawns PowerShell, which takes a moment to compile
---the shim. An empty list means nothing holds the file right now — for a lock
---that has already passed, that is the expected answer.
---
---The callback always comes: a lookup that does not finish within
---`opts.timeout` ms (default 60000, generous on purpose: a cold PowerShell on
---a loaded CI runner needs far longer than on a desktop) is killed and
---answered with `(nil, "holder lookup timed out ...")` instead of never.
---@param path string  Absolute path to query.
---@param cb fun(holders: Lib.Cross.Fs.Lock.Holder[]|nil, err: string|nil)
---@param opts? { timeout?: integer }
function M.who(path, cb, opts)
  if not is_windows() then
    cb(nil, "holder lookup is Windows-only (Restart Manager)")
    return
  end

  local script, serr = ensure_script()
  if not script then
    cb(nil, "cannot write helper script: " .. tostring(serr))
    return
  end

  local exe = (fn.executable("pwsh") == 1) and "pwsh" or "powershell"
  local timeout = (opts and opts.timeout) or 60000
  vim.system(
    { exe, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, "-Path", path },
    -- Its own working directory, not Neovim's: on Windows a process's cwd
    -- holds that folder, and the folder asked about is usually the one Neovim
    -- stands in (a move of it just failed). Inheriting it, the lookup itself
    -- held the folder for its whole run and made the user's retry fail too.
    { text = true, timeout = timeout, cwd = vim.fs.dirname(script) },
    vim.schedule_wrap(function(res)
      if res.code == 124 then -- vim.system reports its own timeout kill as 124
        cb(nil, ("holder lookup timed out after %d ms"):format(timeout))
        return
      end
      if res.code ~= 0 then
        cb(nil, vim.trim(res.stderr or "") ~= "" and vim.trim(res.stderr) or "query failed")
        return
      end
      local out = vim.trim(res.stdout or "")
      if out == "" or out == "NO_HOLDER" then
        cb({}, nil)
        return
      end
      ---@type Lib.Cross.Fs.Lock.Holder[]
      local holders = {}
      for _, line in ipairs(vim.split(out, "\n")) do
        local pid, name, app = vim.trim(line):match("^(%d+)\t([^\t]*)\t(.*)$")
        local pid_n = pid and tonumber(pid) or nil
        if pid_n then
          holders[#holders + 1] = { pid = pid_n, name = name, app = vim.trim(app) }
        end
      end
      cb(holders, nil)
    end)
  )
end

---Ready-made human-readable diagnosis: path facts, a live rename probe, and
---the holder list. Provided here so every consumer renders the same report
---instead of each inventing its own wording for the same three findings.
---@param path string  Absolute path to diagnose.
---@param cb fun(lines: string[])
function M.report(path, cb)
  local lines = {
    "path:   " .. path,
    "exists: " .. (fn.filereadable(path) == 1 and "yes" or "NO"),
  }

  local ok, err = M.probe(path)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "rename probe:"
  lines[#lines + 1] = ok and "  renameable right now (no lock at this moment)"
    or ("  NOT renameable: " .. tostring(err))

  if not is_windows() then
    cb(lines)
    return
  end

  M.who(path, function(holders, werr)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "handle holders (Windows Restart Manager):"
    if werr then
      lines[#lines + 1] = "  lookup failed: " .. werr
    elseif not holders or #holders == 0 then
      lines[#lines + 1] = "  none — no process holds this file open right now"
    else
      for _, h in ipairs(holders) do
        lines[#lines + 1] = ("  pid %d  %s  [%s]"):format(h.pid, h.name, h.app)
      end
    end
    cb(lines)
  end)
end

---@type Lib.Cross.Fs.Lock
return M
