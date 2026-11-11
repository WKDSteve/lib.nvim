---@meta
---@module 'lib.nvim.fs.@types.query'

---Options for `lib.nvim.fs.is_subpath`.
---
---Passing a table at all (even an empty one) switches both sides from a plain
---`vim.fs.normalize` to `lib.nvim.fs.normkey`, which also uppercases a Windows
---drive letter and collapses duplicate separators; a trailing separator is
---stripped afterwards (a bare root `/` or `C:/` keeps its slash), so `/v/` and
---`/v` are one spelling.
---@class Lib.Fs.IsSubpathOpts
---@field realpath? boolean Resolve symlinks and Windows 8.3 short names via `uv.fs_realpath`. Default true.
---@field ignore_case? boolean Compare case-insensitively (a file system that ignores case: Windows, default macOS), non-ASCII letters included (`vim.fn.tolower`, not NTFS's own table: `i`/`İ` and `ß`/`ẞ` compare equal). Default false. Like any opts table it switches to `normkey`; add `realpath = false` to stay off the disk.

---Options for `lib.nvim.fs.same_path`.
---@class Lib.Fs.SamePathOpts
---@field ignore_case? boolean Fold letter case before comparing. Default: `lib.nvim.cross.platform.case_blind()`.
---@field realpath? boolean Resolve symlinks and 8.3 names via `uv.fs_realpath`. Default false (no syscalls).

--- CDX: fictional grouping — there is no `lib.nvim.fs.query` module. Only the
--- CDX: stale `Lib.Fs` aggregate references it. `Lib.Fs.IsSubpathOpts` above
--- CDX: is real and stays.
---@class Lib.Fs.Query
---@field is_subpath fun(path: string, base: string, opts?: Lib.Fs.IsSubpathOpts): boolean
---@field is_dir fun(p: string): boolean
---@field find_upward_dir fun(names: string[], from: string): string|nil

return {}
