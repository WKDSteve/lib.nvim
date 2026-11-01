---@module 'lib.nvim.checkpoint'
--- Snapshot a set of files before a destructive multi-file operation, so it
--- can be undone byte-exact if something goes wrong — for tools that
--- rewrite/move/delete across a whole project (a search-and-replace,
--- a bulk rename, an API migration) rather than a single buffer edit.
---
--- This is the catalogue's memento (`docs/patterns.md`): the snapshot lives on disk and restores
--- files, so there is no separate `lib.lua.patterns.memento` to extract it into. It is not a
--- `command` either: there is no undo/redo stack of actions, one checkpoint is restored whole.
---
--- "Byte-exact" is the point of using `fs_copyfile` rather than reading
--- lines and writing them back: the latter can silently normalize line
--- endings or encoding on restore, which defeats the purpose of a backup.
---
--- Not transactional across a crash: the checkpoint's backup files live
--- under `stdpath("cache")`, so they survive the current session but are
--- not fsync'd/journaled. This covers "the operation went wrong, undo it"
--- (the common case), not "Neovim was killed mid-write".
---
--- Usage:
--- ```lua
--- local checkpoint = require("lib.nvim.checkpoint")
---
--- local cp, err = checkpoint.create({ "/proj/a.lua", "/proj/new.lua" })
--- if not cp then
---   vim.notify(err)
---   return
--- end
---
--- local ok = run_destructive_operation()
--- if ok then
---   checkpoint.discard(cp)
--- else
---   local restored, errors = checkpoint.restore(cp)
---   checkpoint.discard(cp)
--- end
--- ```

require("lib.nvim.checkpoint.@types")

local mutate = require("lib.nvim.cross.fs.mutate")
local token = require("lib.nvim.token")

local uv = vim.uv or vim.loop

local M = {}

---@internal
---@param opts Lib.Checkpoint.CreateOpts|nil
---@return string
local function root_dir(opts)
  return (opts and opts.dir) or (vim.fn.stdpath("cache") .. "/lib.nvim/checkpoints")
end

---Snapshot every existing file in `paths`. A path that does not yet exist
---is still tracked (as `existed = false`) so `M.restore` can delete it if
---the operation being guarded against goes on to create it.
---@param paths string[]
---@param opts? Lib.Checkpoint.CreateOpts
---@return Lib.Checkpoint|nil checkpoint
---@return string|nil err
function M.create(paths, opts)
  if type(paths) ~= "table" then
    return nil, "checkpoint: paths must be a table"
  end

  local id = token.gen_token(12)
  local dir = root_dir(opts) .. "/" .. id

  local ok_mkdir, err_mkdir = mutate.mkdir_p(dir)
  if not ok_mkdir then
    return nil, "checkpoint: failed to create '" .. dir .. "': " .. tostring(err_mkdir)
  end

  local entries = {}
  for i, path in ipairs(paths) do
    local stat = uv.fs_stat(path)
    if stat then
      local backup = dir .. "/" .. i .. ".bak"
      local ok_copy, err_copy = mutate.copy_file(path, backup)
      if not ok_copy then
        -- Don't leave a half-built checkpoint (already-copied backups, the
        -- directory itself) behind on disk when create() as a whole fails --
        -- the caller only gets `nil, err` back, no handle to clean it up.
        vim.fn.delete(dir, "rf")
        return nil, "checkpoint: failed to back up '" .. path .. "': " .. tostring(err_copy)
      end
      entries[i] = { path = path, backup = backup, existed = true, size = stat.size }
    else
      entries[i] = { path = path, backup = nil, existed = false }
    end
  end

  return {
    id = id,
    dir = dir,
    created_at = os.time(),
    entries = entries,
  }, nil
end

---Restore every file tracked by `checkpoint` to its state at `M.create`
---time: an existing file's bytes are copied back verbatim; a file that did
---not exist yet is deleted if the guarded operation went on to create it.
---
---Best-effort: one entry failing does not stop the rest from being
---attempted. Check `errors` (empty on full success) rather than only `ok`.
---@param checkpoint Lib.Checkpoint
---@return boolean ok
---@return Lib.Checkpoint.RestoreError[] errors
function M.restore(checkpoint)
  local errors = {}

  for _, entry in ipairs(checkpoint.entries) do
    if entry.existed then
      local ok, err = mutate.copy_file(entry.backup, entry.path)
      if not ok then
        errors[#errors + 1] = { path = entry.path, err = err }
      end
    elseif uv.fs_stat(entry.path) ~= nil then
      local ok, err = mutate.delete_file(entry.path)
      if not ok then
        errors[#errors + 1] = { path = entry.path, err = err }
      end
    end
  end

  return #errors == 0, errors
end

---Stop tracking `path`: a later `restore` neither overwrites nor deletes it. For a file the guarded operation did not
---touch after all -- it was created or rewritten by someone else in between (another process finished the same job
---first), so the snapshot of it is stale and the restore would destroy THEIR result.
---@param checkpoint Lib.Checkpoint
---@param path string
---@return boolean dropped Whether an entry for `path` was tracked.
function M.forget(checkpoint, path)
  local dropped = false
  for i = #checkpoint.entries, 1, -1 do
    local entry = checkpoint.entries[i]
    if entry.path == path then
      if entry.backup then
        mutate.delete_file(entry.backup)
      end
      table.remove(checkpoint.entries, i)
      dropped = true
    end
  end
  return dropped
end

---Delete `checkpoint`'s backup files. Call this once the guarded operation
---either succeeded (backups no longer needed) or was already restored.
---
---Idempotent: discarding an already-discarded (or never-materialized)
---checkpoint is a no-op success, not a failure -- the desired end state (no
---backup directory) already holds. Goes through `cross.fs.mutate` for every
---file/directory removal, same as `M.create`/`M.restore`, so a backup file
---transiently locked by an AV scanner or indexer (plausible here: these
---files were just written moments earlier) gets the same retry treatment as
---everywhere else in this library, not a bare `vim.fn.delete`.
---@param checkpoint Lib.Checkpoint
---@return boolean ok
function M.discard(checkpoint)
  if uv.fs_stat(checkpoint.dir) == nil then
    return true
  end

  local all_ok = true
  for _, entry in ipairs(checkpoint.entries) do
    if entry.backup and uv.fs_stat(entry.backup) ~= nil then
      if not mutate.delete_file(entry.backup) then
        all_ok = false
      end
    end
  end

  if not all_ok then
    return false
  end

  local ok = mutate.rmdir(checkpoint.dir)
  return ok or uv.fs_stat(checkpoint.dir) == nil
end

---@type Lib.Checkpoint.Module
return M
