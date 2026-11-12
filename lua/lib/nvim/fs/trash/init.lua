---@module 'lib.nvim.fs.trash'
--- Cross-platform "send to trash/recycle bin" (not a permanent delete).
---
--- Dispatches to the OS-native trash mechanism: `Microsoft.VisualBasic
--- .FileIO.FileSystem` via PowerShell on native Windows, Finder via
--- `osascript` on macOS, and `gio trash` / `trash-put` on Linux (and WSL,
--- when a Linux desktop trash implementation is available). When none of
--- those are available on Linux, falls back to moving the entry into the
--- XDG trash directory directly — see the `M.trash`/`M.trash_blocking` docs
--- below for the limitation that entails.
---
---```lua
--- local trash = require("lib.nvim.fs.trash")
---
--- trash.trash("/tmp/some_file.txt", function(ok, err)
---   if not ok then vim.notify(err, vim.log.levels.ERROR) end
--- end)
---
--- local ok, err = trash.trash_blocking("/tmp/some_dir")
---```

require("lib.nvim.fs.trash.@types")

local run = require("lib.nvim.cross.run")
local is_windows = require("lib.nvim.cross.platform.is_windows")
local is_macos = require("lib.nvim.cross.platform.is_macos")
local is_linux = require("lib.nvim.cross.platform.is_linux")
local is_wsl = require("lib.nvim.cross.platform.is_wsl")

local ps_escape = require("lib.nvim.cross.powershell").escape_single

local uv = vim.uv or vim.loop

local M = {}

---@internal
---Escape `str` for embedding in a single-quoted POSIX shell argument.
---@param str string
---@return string
local function sh_quote(str)
  return "'" .. str:gsub("'", "'\\''") .. "'"
end

---@internal
---Escape `str` for embedding in a double-quoted AppleScript string literal.
---@param str string
---@return string
local function osa_quote(str)
  return (str:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

---@internal
---@param path string
---@return string
local function windows_cmd(path)
  local is_dir = vim.fn.isdirectory(path) == 1
  local method = is_dir and "DeleteDirectory" or "DeleteFile"
  return "Add-Type -AssemblyName Microsoft.VisualBasic; "
    .. "[Microsoft.VisualBasic.FileIO.FileSystem]::"
    .. method
    .. "('"
    .. ps_escape(path)
    .. "','OnlyErrorDialogs','SendToRecycleBin')"
end

---@internal
---@param path string
---@return string
local function macos_cmd(path)
  return 'osascript -e \'tell application "Finder" to delete POSIX file "'
    .. osa_quote(path)
    .. "\"'"
end

---@internal
---Directory that holds trashed files for the XDG fallback.
---@return string
local function xdg_trash_files_dir()
  local xdg = vim.env.XDG_DATA_HOME
  local base = (xdg ~= nil and xdg ~= "") and xdg or (vim.env.HOME .. "/.local/share")
  return base .. "/Trash/files"
end

---@internal
---Fallback: move `path` into the XDG trash directory via `fs_rename`.
---NOTE: this does not write the accompanying `.trashinfo` metadata that real
---trash implementations use, so "restore from trash" UIs may not show the
---original path — an accepted limitation of this fallback path only.
---@param path string
---@return boolean ok
---@return string|nil err
local function xdg_fallback_blocking(path)
  local trash_dir = xdg_trash_files_dir()
  local ok_mkdir, err_mkdir = pcall(vim.fn.mkdir, trash_dir, "p")
  if not ok_mkdir then
    return false, "mkdir failed: " .. tostring(err_mkdir)
  end

  local dest = trash_dir .. "/" .. vim.fn.fnamemodify(path, ":t")
  local ok, err = uv.fs_rename(path, dest)
  if not ok then
    return false, "fs_rename failed: " .. tostring(err)
  end
  return true, nil
end

---@internal
---Fallback: move `path` into the XDG trash directory, asynchronously.
---@param path string
---@param cb fun(ok: boolean, err: string|nil)
local function xdg_fallback_async(path, cb)
  local trash_dir = xdg_trash_files_dir()
  local ok_mkdir, err_mkdir = pcall(vim.fn.mkdir, trash_dir, "p")
  if not ok_mkdir then
    vim.schedule(function()
      cb(false, "mkdir failed: " .. tostring(err_mkdir))
    end)
    return
  end

  local dest = trash_dir .. "/" .. vim.fn.fnamemodify(path, ":t")
  uv.fs_rename(path, dest, function(err)
    vim.schedule(function()
      cb(err == nil, err)
    end)
  end)
end

---@internal
---Build the Linux trash command to run, or `nil` if only the fallback applies.
---@param path string
---@return string|nil cmd
local function linux_cmd(path)
  if vim.fn.executable("gio") == 1 then
    return "gio trash -- " .. sh_quote(path)
  end
  if vim.fn.executable("trash-put") == 1 then
    return "trash-put -- " .. sh_quote(path)
  end
  return nil
end

---Send `path` to the OS trash/recycle bin, asynchronously.
---@param path string
---@param cb fun(ok: boolean, err: string|nil)
function M.trash(path, cb)
  if is_windows() and not is_wsl() then
    run.run(windows_cmd(path), function(ok, res)
      cb(ok, ok and nil or (res.stderr ~= "" and res.stderr or "trash failed"))
    end)
    return
  end

  if is_macos() then
    run.run(macos_cmd(path), function(ok, res)
      cb(ok, ok and nil or (res.stderr ~= "" and res.stderr or "trash failed"))
    end)
    return
  end

  if is_linux() or is_wsl() then
    local cmd = linux_cmd(path)
    if cmd then
      run.run(cmd, function(ok, res)
        cb(ok, ok and nil or (res.stderr ~= "" and res.stderr or "trash failed"))
      end)
      return
    end
    xdg_fallback_async(path, cb)
    return
  end

  cb(false, "unsupported platform")
end

---Send `path` to the OS trash/recycle bin, synchronously.
---@param path string
---@return boolean ok
---@return string|nil err
function M.trash_blocking(path)
  if is_windows() and not is_wsl() then
    local res = run.run_blocking(windows_cmd(path))
    if res.code == 0 then
      return true, nil
    end
    return false, (res.stderr ~= "" and res.stderr) or "trash failed"
  end

  if is_macos() then
    local res = run.run_blocking(macos_cmd(path))
    if res.code == 0 then
      return true, nil
    end
    return false, (res.stderr ~= "" and res.stderr) or "trash failed"
  end

  if is_linux() or is_wsl() then
    local cmd = linux_cmd(path)
    if cmd then
      local res = run.run_blocking(cmd)
      if res.code == 0 then
        return true, nil
      end
      return false, (res.stderr ~= "" and res.stderr) or "trash failed"
    end
    return xdg_fallback_blocking(path)
  end

  return false, "unsupported platform"
end

---@internal
---PowerShell that puts the newest recycle-bin entry deleted from `path` back.
---
---Locale independent on purpose: the bin is read through `Shell.Application`
---(`NameSpace(10)`) and each entry through the canonical property names
---`System.Recycle.DeletedFrom` / `System.Recycle.DateDeleted`, never through
---the localized column headers or the localized "Restore" verb. The entry is
---restored by moving its `$R...` payload to the original path and deleting
---the `$I...` metadata twin, which is what Explorer does. Refuses to
---overwrite.
---@param path string
---@return string
local function windows_restore_cmd(path)
  local script = [[
$ErrorActionPreference = 'Stop'
try {
  $orig = '__PATH__'
  $dir = [IO.Path]::GetDirectoryName($orig)
  $longDir = '__LONGDIR__'
  $leaf = [IO.Path]::GetFileName($orig)
  if (Test-Path -LiteralPath $orig) { throw "destination exists: $orig" }
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { throw "parent directory is gone: $dir" }
  $bin = (New-Object -ComObject Shell.Application).NameSpace(10)
  $best = $null; $bestDate = [datetime]::MinValue
  foreach ($it in $bin.Items()) {
    $from = $it.ExtendedProperty('System.Recycle.DeletedFrom')
    if (-not $from) { continue }
    $from = $from.TrimEnd('\')
    if ($from -ine $dir.TrimEnd('\') -and $from -ine $longDir.TrimEnd('\')) { continue }
    $ext = [IO.Path]::GetExtension($it.Path)
    $name = $it.Name
    if ($ext -and -not $name.EndsWith($ext, [StringComparison]::OrdinalIgnoreCase)) { $name += $ext }
    if ($name -ine $leaf) { continue }
    $when = $it.ExtendedProperty('System.Recycle.DateDeleted')
    if ($null -eq $best -or $when -gt $bestDate) { $best = $it; $bestDate = $when }
  }
  if ($null -eq $best) { throw "not in the recycle bin: $orig" }
  $payload = $best.Path
  $meta = Join-Path (Split-Path $payload) ('$I' + (Split-Path $payload -Leaf).Substring(2))
  Move-Item -LiteralPath $payload -Destination $orig
  Remove-Item -LiteralPath $meta -Force -ErrorAction SilentlyContinue
} catch {
  [Console]::Error.WriteLine($_.Exception.Message)
  exit 1
}
]]
  -- The bin records the long form of the folder (`C:\Users\runneradmin\...`);
  -- `path` may carry an 8.3 short name (`C:\Users\RUNNER~1\...`, what
  -- `tempname()` gives on some machines). fs_realpath resolves the folder to
  -- its long form; both forms are accepted.
  local parent = vim.fs.dirname(path)
  local long_dir = (parent and uv.fs_realpath(parent)) or parent or ""
  return (
    script
      :gsub("__PATH__", function()
        return ps_escape(path)
      end)
      :gsub("__LONGDIR__", function()
        return ps_escape(long_dir)
      end)
  )
end

---@internal
---Restore from the XDG trash (`files/` + `info/*.trashinfo`): the newest entry
---whose `Path=` is `path`. Entries the fallback above wrote have no
---`.trashinfo` and cannot be found.
---@param path string
---@return boolean ok
---@return string|nil err
local function xdg_restore_blocking(path)
  local xdg = vim.env.XDG_DATA_HOME
  local base = (xdg ~= nil and xdg ~= "") and xdg or (vim.env.HOME .. "/.local/share")
  local info_dir, files_dir = base .. "/Trash/info", base .. "/Trash/files"
  local wanted = vim.fs.normalize(path)

  local best, best_date
  for name, kind in vim.fs.dir(info_dir) do
    if kind == "file" and name:match("%.trashinfo$") then
      local lines = vim.fn.readfile(info_dir .. "/" .. name)
      local orig, date
      for _, line in ipairs(lines) do
        local p = line:match("^Path=(.*)$")
        if p then
          -- the spec percent-encodes the path
          orig = vim.fs.normalize((p:gsub("%%(%x%x)", function(h)
            return string.char(tonumber(h, 16))
          end)))
        end
        date = line:match("^DeletionDate=(.*)$") or date
      end
      if orig == wanted and (best == nil or (date or "") > (best_date or "")) then
        best, best_date = name:gsub("%.trashinfo$", ""), date
      end
    end
  end
  if not best then
    return false, "not in the trash: " .. path
  end
  if uv.fs_stat(path) then
    return false, "destination exists: " .. path
  end
  local ok, err = uv.fs_rename(files_dir .. "/" .. best, path)
  if not ok then
    return false, "fs_rename failed: " .. tostring(err)
  end
  vim.fn.delete(info_dir .. "/" .. best .. ".trashinfo")
  return true, nil
end

---Put the newest trashed copy of `path` back at `path`, synchronously: the
---counterpart of `trash_blocking`. Windows (recycle bin, any system language)
---and Linux (XDG trash with `.trashinfo`). Never overwrites: an existing
---`path` is an error. macOS has no scriptable restore and answers
---"unsupported platform".
---@param path string absolute original path
---@return boolean ok
---@return string|nil err
function M.restore_blocking(path)
  if is_windows() and not is_wsl() then
    local res = run.run_blocking(windows_restore_cmd(path))
    if res.code == 0 then
      return true, nil
    end
    return false, vim.trim(res.stderr or "") ~= "" and vim.trim(res.stderr) or "restore failed"
  end
  if is_linux() or is_wsl() then
    return xdg_restore_blocking(path)
  end
  return false, "unsupported platform"
end

---Asynchronous `restore_blocking`; `cb` runs on the main loop.
---@param path string
---@param cb fun(ok: boolean, err: string|nil)
function M.restore(path, cb)
  if is_windows() and not is_wsl() then
    run.run(windows_restore_cmd(path), function(ok, res)
      local err = vim.trim(res.stderr or "")
      cb(ok, ok and nil or (err ~= "" and err or "restore failed"))
    end)
    return
  end
  local ok, err = M.restore_blocking(path)
  vim.schedule(function()
    cb(ok, err)
  end)
end

---@type Lib.Fs.Trash
return M
