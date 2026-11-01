---@module 'lib.nvim.cache.disk'
--- Persistent JSON disk cache with TTL, keyed by a simple `namespace` string.
---
--- Complements the in-memory-only `lib.lua.memo` / `lib.lua.memo.lru` and the
--- sibling `lib.nvim.cache.memory` for callers that need a cache to survive
--- across Neovim restarts. Each namespace is one JSON file under
--- `vim.fn.stdpath("cache") .. "/lib.nvim/cache/<namespace>.json"` by
--- default (override via `opts.dir`), holding `{ saved_at, data }`.
---
--- Usage:
--- ```lua
--- local disk = require("lib.nvim.cache.disk")
---
--- disk.save("github_issues", { { id = 1, title = "..." } })
--- local data, err = disk.load("github_issues", { ttl_seconds = 3600 })
--- -- data is nil if missing, unreadable, or older than ttl_seconds; err is
--- -- set only when a file exists but could not be read or decoded
---
--- disk.clear("github_issues")
--- local stats = disk.stats("github_issues")
--- ```

local uv = vim.uv or vim.loop

local M = {}

---@internal
---@param opts Lib.Cache.Opts|nil
---@return string
local function cache_dir(opts)
  return (opts and opts.dir) or (vim.fn.stdpath("cache") .. "/lib.nvim/cache")
end

---@internal
---@param namespace string
---@param opts Lib.Cache.Opts|nil
---@return string
local function cache_path(namespace, opts)
  return cache_dir(opts) .. "/" .. namespace .. ".json"
end

---@internal
---Read and JSON-decode the cache file for `namespace`, if any.
---
---A decode failure on non-empty content is not the same situation as no
---file existing at all: every `M.save` call overwrites the WHOLE file, so a
---caller built on top of this module (e.g. `lib.nvim.store.project`, whose
---own docs describe holding curated per-project state like anchors, not
---just regenerable cache entries) can easily have a load-modify-save cycle
---where a decode failure collapses straight to an empty/default in-memory
---value -- and the very next unrelated write then silently replaces the
---corrupt file with that near-empty value, destroying whatever real data
---was in it with no trace it ever existed. The original bytes are backed up
---once per corruption (a `.corrupt` file next to the cache file, not
---re-written if it already exists — so a caller retrying a decode after an
---earlier backup does not clobber it with, say, an even-more-truncated
---read), so "the file was briefly unreadable" never turns into "the data is
---gone". Bug pattern found and fixed the same way three times already
---across the plugin fleet before landing here at the shared root.
---
---The second return value is what lets a caller tell the two apart: `nil`
---when there simply is no file (first run, cleared), a reason when a file
---exists but could not be read or decoded. A load-modify-save consumer
---that ignores it would overwrite real data with its empty default on a
---transient read error, and the backup above only covers the decode case.
---@param namespace string
---@param opts Lib.Cache.Opts|nil
---@return { saved_at: integer, data: any }|nil entry
---@return string|nil err `nil` when no file exists; the failure otherwise.
local function read_entry(namespace, opts)
  local path = cache_path(namespace, opts)

  if uv.fs_stat(path) == nil then
    return nil, nil
  end

  local ok_read, content, read_err = pcall(function()
    local file, open_err = io.open(path, "r")
    if not file then
      return nil, open_err
    end
    local text, err = file:read("*a")
    file:close()
    return text, err
  end)
  if not ok_read then
    return nil, "read failed: " .. tostring(content)
  end
  if not content then
    return nil, "read failed: " .. tostring(read_err or path)
  end

  local ok_decode, decoded = pcall(vim.json.decode, content)
  if not ok_decode or type(decoded) ~= "table" then
    local backup_path = path .. ".corrupt"
    -- The message below must only claim a backup exists when one actually
    -- does: an empty file has nothing worth backing up (there are no bytes
    -- to keep), and a write failure (e.g. permission denied on the backup
    -- path) must not be swallowed into a false "kept at ..." claim -- a
    -- caller like frecency forwards this string verbatim to `vim.notify`.
    local backed_up = false
    if content ~= "" then
      if uv.fs_stat(backup_path) ~= nil then
        backed_up = true
      else
        local fh = io.open(backup_path, "wb")
        if fh then
          fh:write(content)
          fh:close()
          backed_up = true
        end
      end
    end
    if backed_up then
      return nil, "invalid json: original kept at " .. backup_path
    end
    if content == "" then
      return nil, "invalid json: file is empty, nothing to back up"
    end
    return nil,
      "invalid json: backup to " .. backup_path .. " failed, original left in place at " .. path
  end

  return decoded, nil
end

---Persist `data` under `namespace`.
---@param namespace string
---@param data any
---@param opts? Lib.Cache.SaveOpts
---@return boolean ok
---@return string|nil err
function M.save(namespace, data, opts)
  opts = opts or {}
  local path = cache_path(namespace, opts)

  -- The parent of the *file*, not the cache root. A namespace may contain
  -- slashes to group related entries ("myplugin/anchors" — the form this
  -- module's own callers document), and that subdirectory has to exist or
  -- `io.open(…, "w")` fails with ENOENT. Creating only the cache root left
  -- every nested namespace silently unwritable.
  local dir = vim.fn.fnamemodify(path, ":h")

  local ok_mkdir = pcall(vim.fn.mkdir, dir, "p")
  if not ok_mkdir then
    return false, "mkdir failed: " .. dir
  end

  local entry = { saved_at = os.time(), data = data }
  local ok_encode, encoded = pcall(vim.json.encode, entry)
  if not ok_encode then
    return false, "json encode failed"
  end

  -- Temp file, flushed, renamed over the target: a crash or power loss leaves the old content or the new, never the
  -- zero-filled file `io.open(path, "w")` (truncate in place, write later) leaves on NTFS -- 29 telemetry caches were
  -- found like that, all from the same minute, each read back as "corrupt" and the counts started again.
  local ok_write, write_err = require("lib.nvim.fs.write.atomic")(path, encoded)
  if not ok_write then
    return false, "write failed: " .. tostring(write_err or path)
  end

  return true, nil
end

---Load the cached value for `namespace`, or `nil` if missing, unreadable, or
---expired (per `opts.ttl_seconds`).
---
---`err` is `nil` for the two harmless kinds of `nil` (no file yet, expired)
---and a reason when a file exists but could not be read or decoded, so a
---caller holding data that cannot be regenerated can refuse to write its
---empty default over it.
---@param namespace string
---@param opts? Lib.Cache.LoadOpts|Lib.Cache.Opts
---@return any|nil data
---@return string|nil err
function M.load(namespace, opts)
  opts = opts or {}
  local entry, err = read_entry(namespace, opts)
  if not entry then
    return nil, err
  end

  if opts.ttl_seconds then
    local saved_at = entry.saved_at or 0
    if os.time() - saved_at > opts.ttl_seconds then
      return nil, nil
    end
  end

  return entry.data, nil
end

---Remove the cache file for `namespace`.
---@param namespace string
---@param opts? Lib.Cache.Opts
---@return boolean ok
function M.clear(namespace, opts)
  local path = cache_path(namespace, opts)
  if uv.fs_stat(path) == nil then
    return true
  end
  local ok = os.remove(path)
  return ok ~= nil
end

---Report on-disk state for `namespace` without decoding the full `data` payload.
---@param namespace string
---@param opts? Lib.Cache.Opts
---@return Lib.Cache.Stats
function M.stats(namespace, opts)
  local path = cache_path(namespace, opts)

  local stat = uv.fs_stat(path)
  if not stat then
    return { exists = false, saved_at = nil, age_seconds = nil, size_bytes = nil }
  end

  -- Simplicity over micro-optimization: full-decode to read `saved_at`
  -- rather than hand-parsing the JSON header.
  local entry = read_entry(namespace, opts)
  local saved_at = entry and entry.saved_at or nil

  return {
    exists = true,
    saved_at = saved_at,
    age_seconds = saved_at and (os.time() - saved_at) or nil,
    size_bytes = stat.size,
  }
end

---@type Lib.Cache.Disk
return M
