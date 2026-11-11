---@module 'lib.nvim.cross.platform.case_blind'
--- Single-purpose module that exports exactly one function: does the default
--- file system of this platform ignore letter case in names?
--- The module returns the function itself (not a table).
---
--- True on native Windows (NTFS) and macOS (APFS/HFS+ in their default,
--- case-insensitive configuration). False on Linux and WSL, where the
--- Linux side is case-sensitive; a `/mnt/c` mount is the exception and is
--- not detected here, because the answer there depends on the directory.
---
--- This is a platform default, not a probe of one directory: a case-sensitive
--- APFS volume or an NTFS directory with the per-directory case flag still
--- answers true. Callers that need the truth for one path must test that path.

---@return boolean
return function()
  local is_windows = require("lib.nvim.cross.platform.is_windows")
  local is_macos = require("lib.nvim.cross.platform.is_macos")
  return is_windows() or is_macos()
end
