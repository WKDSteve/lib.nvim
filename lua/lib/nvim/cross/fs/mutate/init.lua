---@module 'lib.nvim.cross.fs.mutate'
--- Injection-safe file mutation primitives, built directly on libuv (no shell
--- involved) — safe to use with untrusted/user-controlled paths.
---
--- Every mutation is routed through `M.retry`, which re-attempts the operation
--- when libuv reports a *transient sharing* error (`EPERM`/`EACCES`/`EBUSY`).
--- On Windows those are routinely returned for a file that is perfectly
--- deletable a few milliseconds later: an open directory watcher, the search
--- indexer, OneDrive or an AV scanner still holds a handle. A single immediate
--- failure is therefore not evidence that the operation is impossible.
--- On POSIX these errors mean what they say, so retrying is off by default
--- there (`M.defaults.attempts` is 1) and this stays a plain passthrough.

local retry_backoff = require("lib.nvim.patterns.retry_backoff")

local M = {}

---@internal
---@return uv
local function uv()
  return vim.uv or vim.loop
end

---@internal
---Local, matching the precedent in `lib.nvim.buf_win_tab.windows_utils`.
---@return boolean
local function is_windows()
  return vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

-- ── Retry ─────────────────────────────────────────────────────────────────────

---libuv surfaces errors as `"EPERM: operation not permitted"`, so match on the
---code prefix rather than the whole string.
---@type table<string, true>
local TRANSIENT = {
  EPERM = true, -- Windows: handle open elsewhere (watcher, indexer, AV)
  EACCES = true, -- Windows: same cause, different libuv mapping
  EBUSY = true, -- Windows: file mapped/in use; POSIX: mountpoint busy
}

---@internal
---@param err string|nil
---@return boolean
local function is_transient(err)
  if type(err) ~= "string" then
    return false
  end
  local code = err:match("^(%u+):") or err
  return TRANSIENT[code] == true
end

---@type Lib.Cross.Fs.Mutate.RetryOpts
M.defaults = {
  -- Retrying only pays off where the errors are spurious. See module header.
  attempts = is_windows() and 3 or 1,
  backoff_ms = 50,
  on_retry = nil,
}

---Run `op` until it succeeds or its error stops looking transient.
---
---Waits with `vim.wait` rather than `uv.sleep`: the delay is only useful if the
---event loop keeps running during it, since that is what lets pending libuv
---handle-close callbacks actually complete and release the very handle that
---caused the failure. `uv.sleep` would block the loop and guarantee the retry
---hits the identical state.
---
---@param op fun(): boolean|nil, string|nil  Returns libuv-style ok, err.
---@param opts? Lib.Cross.Fs.Mutate.RetryOpts
---@return boolean ok
---@return string|nil err  Error of the final attempt.
function M.retry(op, opts)
  local cfg = vim.tbl_extend("force", M.defaults, opts or {})
  local attempts = math.max(1, cfg.attempts or 1)
  local backoff_ms = cfg.backoff_ms or 50

  local ok, err
  for attempt = 1, attempts do
    ok, err = op()
    if ok then
      return true, nil
    end
    if not is_transient(err) then
      return false, err
    end
    if attempt < attempts then
      -- Give a consumer the chance to release its own handles on the path
      -- before we try again — a retry alone does not help if *we* are the
      -- process holding it open.
      if cfg.on_retry then
        pcall(cfg.on_retry, attempt, err)
      end
      -- Escalating backoff: 50ms, 100ms, 200ms, … An AV scan or an indexer
      -- pass takes longer than a watcher close, so a flat delay would either
      -- be wastefully long for the common case or too short for the rare one.
      vim.wait(
        retry_backoff.delay(attempt, { base_ms = backoff_ms, factor = 2, max_ms = math.huge })
      )
    end
  end
  return false, err
end

-- ── Primitives ────────────────────────────────────────────────────────────────

---@param path string
---@param opts? Lib.Cross.Fs.Mutate.RetryOpts
---@return boolean ok
---@return string|nil err
function M.delete_file(path, opts)
  return M.retry(function()
    return uv().fs_unlink(path)
  end, opts)
end

---@param src string
---@param dst string
---@param opts? Lib.Cross.Fs.Mutate.RetryOpts
---@return boolean ok
---@return string|nil err
function M.copy_file(src, dst, opts)
  return M.retry(function()
    return uv().fs_copyfile(src, dst)
  end, opts)
end

---@param src string
---@param dst string
---@param opts? Lib.Cross.Fs.Mutate.RetryOpts
---@return boolean ok
---@return string|nil err
function M.rename_file(src, dst, opts)
  return M.retry(function()
    return uv().fs_rename(src, dst)
  end, opts)
end

---@internal
---The deepest part of `path` that exists, if it is a directory.
---@param path string
---@return string|nil dir  nil when the deepest existing part is not a directory (a file in the way); `""` when
---  nothing of `path` exists.
local function deepest_existing(path)
  local cur = path
  while true do
    local stat = uv().fs_stat(cur)
    if stat then
      return stat.type == "directory" and cur or nil
    end
    local parent = vim.fn.fnamemodify(cur, ":h")
    if parent == cur or parent == "" or parent == "." then
      return ""
    end
    cur = parent
  end
end

---Create `path` and all missing parent directories (`mkdir -p` semantics),
---without invoking a shell.
---@param path string
---@param opts? Lib.Cross.Fs.Mutate.RetryOpts
---@return boolean ok
---@return string|nil err
function M.mkdir_p(path, opts)
  return M.retry(function()
    -- vim.fn.mkdir raises instead of returning an error, so normalize it to
    -- the libuv-style (ok, err) contract M.retry expects. Note that Vim's
    -- message (`Vim:E739: Cannot create directory: …`) carries no libuv error
    -- code, so is_transient never matches and this in practice does not retry
    -- — it goes through M.retry for a uniform signature, not for the retry.
    local ok, err = pcall(vim.fn.mkdir, path, "p")
    if ok then
      return true, nil
    end
    -- Two processes that make the same folder at once (the temp folder `nvim`, say) race: the one that loses
    -- gets E739 "file already exists" although the folder is there and is what was asked for. The race can also
    -- be lost on a parent (`~/.cache/nvim` made by the other process while this one made the chain below it), and
    -- with many processes it is lost again on a deeper link. Every lost race leaves one more link made, so try
    -- again as long as the chain grew; that ends after at most as many tries as the path has links.
    local reached = nil
    for _ = 1, select(2, path:gsub("[/\\]", "")) + 1 do
      local stat = uv().fs_stat(path)
      if stat and stat.type == "directory" then
        return true, nil
      end
      local now = deepest_existing(path)
      if now == nil or (reached ~= nil and #now <= #reached) then
        -- A file in the way, or no new link since the last try: a real failure, not a race.
        break
      end
      reached = now
      ok, err = pcall(vim.fn.mkdir, path, "p")
      if ok then
        return true, nil
      end
    end
    local stat = uv().fs_stat(path)
    if stat and stat.type == "directory" then
      return true, nil
    end
    return false, tostring(err)
  end, opts)
end

---Remove an empty directory.
---@param path string
---@param opts? Lib.Cross.Fs.Mutate.RetryOpts
---@return boolean ok
---@return string|nil err
function M.rmdir(path, opts)
  return M.retry(function()
    return uv().fs_rmdir(path)
  end, opts)
end

---Create a symbolic link at `link_path` pointing to `target`. `target` is
---stored verbatim (relative or absolute) — resolve it to an absolute path
---before calling this if the link must not depend on `link_path`'s location.
---"Verbatim" is a POSIX guarantee only: Windows canonicalizes the target when
---it writes the reparse point, so `fs_readlink` reads back an all-backslash
---path even for a target passed in with forward slashes. Compare read-back
---targets through `lib.nvim.cross.fs.separators.unify_slashes`.
---@param target string      What the link points to. Need not exist.
---@param link_path string   Where to create the link.
---@param is_dir? boolean    Windows needs to know upfront whether `target` is
---                          a directory (`uv_fs_symlink`'s `dir` flag); ignored
---                          on POSIX, where the same call handles both.
---@param opts? Lib.Cross.Fs.Mutate.RetryOpts
---@return boolean ok
---@return string|nil err
function M.symlink(target, link_path, is_dir, opts)
  return M.retry(function()
    return uv().fs_symlink(target, link_path, is_dir and { dir = true } or nil)
  end, opts)
end

---Create a hard link at `link_path` pointing to the existing file `target`.
---Files only: neither Windows nor POSIX allows an unprivileged hard link to a
---directory — use `M.symlink` for those.
---@param target string      Existing file to link to.
---@param link_path string   Where to create the link.
---@param opts? Lib.Cross.Fs.Mutate.RetryOpts
---@return boolean ok
---@return string|nil err
function M.hardlink(target, link_path, opts)
  return M.retry(function()
    return uv().fs_link(target, link_path)
  end, opts)
end

---@type Lib.Cross.Fs.Mutate
return M
