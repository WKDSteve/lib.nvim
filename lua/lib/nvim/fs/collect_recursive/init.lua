---@module 'lib.nvim.fs.collect_recursive'
--- Recursive directory walker built on `fs_scandir`/`fs_scandir_next`.
---
--- Returns a flat array of absolute paths under `root`. An optional
--- `ignore(abs_path, is_dir)` predicate can prune whole subtrees (returning
--- `true` for a directory skips both the directory entry itself and
--- everything under it).
---
---```lua
--- local collect_recursive = require("lib.nvim.fs.collect_recursive")
--- local all = collect_recursive.collect("/repo", { kind = "files" })
--- local files = collect_recursive.files("/repo", { ignore = function(p) return p:match("/%.git$") ~= nil end })
--- local dirs = collect_recursive.dirs("/repo")
---
--- -- Non-blocking counterpart, same options, for large trees (node_modules-
--- -- sized) where the synchronous walk above would stall the main loop:
--- local cancel = collect_recursive.collect_async("/repo", { kind = "files" }, function(paths)
---   -- called once, vim.schedule-dispatched
--- end)
---```

require("lib.nvim.fs.collect_recursive.@types")

local uv = vim.uv or vim.loop

local M = {}

---@internal
---Classify one scanned entry without ever following a symlink into a
---directory recursion: `is_dir` says whether it should be listed/filtered
---as a directory (a symlink pointing at a directory still counts, so
---callers collecting "dirs" still see it), `is_symlink` says whether the
---entry itself is a symlink -- see the ERR-34 note on `walk` below for why
---that second flag exists.
---@param abs_path string
---@param kind_hint string|nil
---@return boolean is_dir
---@return boolean is_symlink
local function classify(abs_path, kind_hint)
  if kind_hint == "directory" then
    return true, false
  elseif kind_hint == "file" then
    return false, false
  elseif kind_hint == "link" then
    -- `fs_stat` follows the symlink, purely to classify what it points at;
    -- the caller must not use that to recurse (see `walk`).
    local st = uv.fs_stat(abs_path)
    return (st and st.type == "directory") or false, true
  end

  -- `kind_hint` isn't always reliable across platforms/filesystems (missing
  -- on some, e.g. older XFS/NFS without dirent d_type support). `fs_lstat`
  -- reports the entry's own type without following it, so a symlink is
  -- still caught here rather than silently falling through to `fs_stat`.
  local lst = uv.fs_lstat(abs_path)
  if lst and lst.type == "link" then
    local st = uv.fs_stat(abs_path)
    return (st and st.type == "directory") or false, true
  end
  return (lst and lst.type == "directory") or false, false
end

---@internal
---Recursively walk `dir`, appending matching absolute paths into `out`.
---
---ERR-34: a symlinked directory is listed like any other directory (so
---"collect dirs" callers still see it) but the walk never recurses into
---it -- a symlink can point at an ancestor (or itself), and following it
---would recurse forever (bounded in practice only by OS path-length limits
---or a Lua stack overflow, both bad outcomes, not a real base case).
---
---A directory that cannot be opened is recorded in `errors` and skipped,
---never treated as empty: "this tree has no files" and "this tree could
---not be read" are different answers, and only the caller knows whether
---an unreadable subdirectory is acceptable.
---@param dir string
---@param opts Lib.Fs.CollectRecursive.Opts
---@param out string[]
---@param errors string[]
local function walk(dir, opts, out, errors)
  local handle, scandir_err = uv.fs_scandir(dir)
  if not handle then
    errors[#errors + 1] = dir .. ": " .. tostring(scandir_err or "scandir failed")
    return
  end

  while true do
    local name, kind_hint = uv.fs_scandir_next(handle)
    if not name then
      break
    end

    local abs_path = dir .. "/" .. name
    local is_dir, is_symlink = classify(abs_path, kind_hint)

    if is_dir then
      local ignored = opts.ignore ~= nil and opts.ignore(abs_path, true) or false
      if not ignored then
        if opts.kind ~= "files" then
          out[#out + 1] = abs_path
        end
        if not is_symlink then
          walk(abs_path, opts, out, errors)
        end
      end
    else
      local ignored = opts.ignore ~= nil and opts.ignore(abs_path, false) or false
      if not ignored and opts.kind ~= "dirs" then
        out[#out + 1] = abs_path
      end
    end
  end
end

---Recursively collect absolute paths under `root`.
---
---`errors` is `nil` when every directory could be read, otherwise one
---`"<dir>: <reason>"` per directory that could not be opened (the root
---itself included) — the paths list is then whatever was reachable.
---@param root string
---@param opts? Lib.Fs.CollectRecursive.Opts
---@return string[] paths
---@return string[]|nil errors
function M.collect(root, opts)
  opts = opts or {}
  opts.kind = opts.kind or "all"

  local out, errors = {}, {}
  walk(root, opts, out, errors)
  return out, (#errors > 0) and errors or nil
end

---Convenience: collect only files.
---@param root string
---@param opts? Lib.Fs.CollectRecursive.Opts
---@return string[] paths
---@return string[]|nil errors
function M.files(root, opts)
  return M.collect(root, vim.tbl_extend("force", opts or {}, { kind = "files" }))
end

---Convenience: collect only directories.
---@param root string
---@param opts? Lib.Fs.CollectRecursive.Opts
---@return string[] paths
---@return string[]|nil errors
function M.dirs(root, opts)
  return M.collect(root, vim.tbl_extend("force", opts or {}, { kind = "dirs" }))
end

---An `ignore` predicate that skips folders by name while walking, so their contents are never read. The
---names default to the canonical list of `lib.nvim.fs.ignore.list` (`basenames`: `.git`, `node_modules`,
---`.claude`, `target`, `build`, ...), the one list the pickers, the trees and LSP already share.
---
---This is what `vim.fn.globpath(root, "**/*.ext")` should be replaced with: `globpath` also never shows a
---hidden entry, but it walks into `node_modules` and is slow on Windows (1.1 s on lib.nvim, 7.3 s on a
---vault of 7 000 files, measured 2026-11-17, against 75 and 400 ms for this walk). With `hidden = false`
---the walk shows what `globpath` shows, minus the folders in `dirs`.
---
---```lua
--- local md = collect_recursive.files(cwd, { ignore = collect_recursive.skip({ hidden = false }) })
---```
---@param opts? { dirs?: string[], hidden?: boolean } `dirs`: folder names to skip, compared literally (default: `lib.nvim.fs.ignore.list.basenames`); `hidden = false` also skips every file and folder whose name starts with a dot (default: hidden ones are kept)
---@return fun(abs_path: string, is_dir: boolean): boolean ignore
function M.skip(opts)
  opts = opts or {}
  local names = {}
  for _, name in ipairs(opts.dirs or require("lib.nvim.fs.ignore.list").basenames) do
    names[name] = true
  end
  local keep_hidden = opts.hidden ~= false
  return function(abs_path, is_dir)
    local name = abs_path:match("[^/\\]+$") or abs_path
    if not keep_hidden and name:sub(1, 1) == "." then
      return true
    end
    return is_dir and names[name] == true
  end
end

---Every file below `root` whose extension is one of `exts` (case-insensitive, without the dot), walked
---with `skip(skip_opts)`: the replacement for one `globpath(root, "**/*.<ext>")` per extension.
---@param root string
---@param exts string[] e.g. `{ "md" }` or `{ "lua", "vim" }`
---@param skip_opts? { dirs?: string[], hidden?: boolean } passed to `skip()`; default `{ hidden = false }` (what `globpath` shows)
---@return string[] paths
---@return string[]|nil errors
function M.files_with_ext(root, exts, skip_opts)
  local wanted = {}
  for _, e in ipairs(exts) do
    wanted[e:lower()] = true
  end
  local files, errors = M.files(root, { ignore = M.skip(skip_opts or { hidden = false }) })
  local out = {}
  for _, path in ipairs(files) do
    local ext = path:match("%.([^./\\]+)$")
    if ext and wanted[ext:lower()] then
      out[#out + 1] = path
    end
  end
  return out, errors
end

-- Async walk — same result as `collect()`, without blocking the main loop on
-- a large tree (a `node_modules`, a monorepo). `walk_async` below mirrors the
-- synchronous `walk()` structurally: plain recursive calls, one `await()` per
-- libuv call, with `lib.nvim.async` yielding to the event loop at each await
-- instead of nesting raw callbacks.

local async = require("lib.nvim.async")
local await = async.await

---@internal
---Async classify, mirroring `classify()` above: every stat call is
---awaited instead of blocking. See `classify()` for the ERR-34 rationale.
---@param abs_path string
---@param kind_hint string|nil
---@return boolean is_dir
---@return boolean is_symlink
local function classify_async(abs_path, kind_hint)
  if kind_hint == "directory" then
    return true, false
  elseif kind_hint == "file" then
    return false, false
  elseif kind_hint == "link" then
    local _, st = await(function(resume)
      uv.fs_stat(abs_path, resume)
    end)
    return (st and st.type == "directory") or false, true
  end

  local _, lst = await(function(resume)
    uv.fs_lstat(abs_path, resume)
  end)
  if lst and lst.type == "link" then
    local _, st = await(function(resume)
      uv.fs_stat(abs_path, resume)
    end)
    return (st and st.type == "directory") or false, true
  end
  return (lst and lst.type == "directory") or false, false
end

---@internal
---Async counterpart to `walk()`. Same traversal/ignore/kind semantics,
---including never recursing into a symlinked directory (ERR-34) -- every
---`uv.fs_scandir`/`uv.fs_stat`/`uv.fs_lstat` call is awaited instead of
---blocking.
---@param dir string
---@param opts Lib.Fs.CollectRecursive.Opts
---@param out string[]
---@param errors string[]
---@param is_cancelled fun(): boolean
local function walk_async(dir, opts, out, errors, is_cancelled)
  if is_cancelled() then
    return
  end

  local scandir_err, handle = await(function(resume)
    uv.fs_scandir(dir, resume)
  end)
  if scandir_err or not handle then
    errors[#errors + 1] = dir .. ": " .. tostring(scandir_err or "scandir failed")
    return
  end

  while true do
    if is_cancelled() then
      return
    end

    local name, kind_hint = uv.fs_scandir_next(handle)
    if not name then
      break
    end

    local abs_path = dir .. "/" .. name
    local is_dir, is_symlink = classify_async(abs_path, kind_hint)

    if is_dir then
      local ignored = opts.ignore ~= nil and opts.ignore(abs_path, true) or false
      if not ignored then
        if opts.kind ~= "files" then
          out[#out + 1] = abs_path
        end
        if not is_symlink then
          walk_async(abs_path, opts, out, errors, is_cancelled)
        end
      end
    else
      local ignored = opts.ignore ~= nil and opts.ignore(abs_path, false) or false
      if not ignored and opts.kind ~= "dirs" then
        out[#out + 1] = abs_path
      end
    end
  end
end

---Async counterpart to `collect()`: same result, without blocking the main
---loop while it walks. `on_done(paths, errors)` fires exactly once,
---`vim.schedule`-dispatched — never for a cancelled walk. `errors` carries
---the same "<dir>: <reason>" list `collect()` returns, or `nil`.
---
---This walks one directory at a time (async, not blocking, but not
---parallel either) — the fix for main-loop stalls on a large tree, not a
---wall-clock speedup; concurrent sibling scanning was left out to keep the
---coroutine driver simple.
---@param root string
---@param opts? Lib.Fs.CollectRecursive.Opts
---@param on_done fun(paths: string[], errors: string[]|nil)
---@return fun() cancel Stop after the current in-flight libuv call settles; `on_done` will not fire.
function M.collect_async(root, opts, on_done)
  opts = opts or {}
  opts.kind = opts.kind or "all"

  local cancelled = false
  local function is_cancelled()
    return cancelled
  end

  async.run(function()
    local out, errors = {}, {}
    walk_async(root, opts, out, errors, is_cancelled)
    return out, (#errors > 0) and errors or nil
  end, function(out, errors)
    if not cancelled then
      on_done(out, errors)
    end
  end, { tag = "lib.nvim.fs.collect_recursive" })

  return function()
    cancelled = true
  end
end

---Async convenience: collect only files.
---@param root string
---@param opts? Lib.Fs.CollectRecursive.Opts
---@param on_done fun(paths: string[], errors: string[]|nil)
---@return fun() cancel
function M.files_async(root, opts, on_done)
  return M.collect_async(root, vim.tbl_extend("force", opts or {}, { kind = "files" }), on_done)
end

---Async convenience: collect only directories.
---@param root string
---@param opts? Lib.Fs.CollectRecursive.Opts
---@param on_done fun(paths: string[], errors: string[]|nil)
---@return fun() cancel
function M.dirs_async(root, opts, on_done)
  return M.collect_async(root, vim.tbl_extend("force", opts or {}, { kind = "dirs" }), on_done)
end

---@type Lib.Fs.CollectRecursive
return M
