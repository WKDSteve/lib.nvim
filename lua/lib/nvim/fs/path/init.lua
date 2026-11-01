---@module 'lib.nvim.fs.path'
--- Path helpers: repo-relative-to-absolute resolution, joining, and
--- ensuring a directory exists.

local unpack = require("lib.lua.functions.varargs").unpack

local M = {}

---@internal
--- True if `path` is already absolute (Windows drive, UNC, or POSIX root).
---@param path string
---@return boolean
local function is_absolute(path)
  return path:match("^%a:[\\/]") ~= nil -- C:\ or C:/
    or path:match("^[\\/][\\/]") ~= nil -- \\share or //share
    or path:match("^/") ~= nil -- /posix
end

--- Resolve a repository-root-relative path to an absolute one.
---
--- Tools like LazyGit hand back paths relative to the repository root
--- (forward slashes), which the caller (e.g. a Neovim instance driven via
--- `nvr`) must resolve itself. `raw` that is already absolute is returned
--- normalized as-is; otherwise the first readable candidate wins, trying
--- the Git root of the current working directory, then the cwd itself.
---@param raw string repo-root-relative (or absolute) path
---@return string absolute path with OS-native separators
function M.from_repo_relative(raw)
  if is_absolute(raw) then
    return vim.fn.fnamemodify(raw, ":p")
  end

  local candidates = {} ---@type string[]

  local repo_root = require("lib.nvim.git").repo_root()
  if repo_root and repo_root ~= "" then
    candidates[#candidates + 1] = repo_root .. "/" .. raw
  end

  candidates[#candidates + 1] = vim.fn.fnamemodify(raw, ":p")

  for _, cand in ipairs(candidates) do
    if vim.fn.filereadable(cand) == 1 then
      return cand
    end
  end

  return candidates[#candidates]
end

---@param parts string[]
---@return string
function M.joinpath(parts)
  if vim.fs and vim.fs.joinpath then
    return vim.fs.joinpath(unpack(parts))
  end

  -- Fallback: use platform separator
  local sep = package.config:sub(1, 1)
  return table.concat(parts, sep)
end

--- Ensure the *parent directory* of `path` exists, creating it (and any
--- missing ancestors) if needed.
---
--- Fast-event safe: `vim.fs.dirname` is pure Lua and `lib.nvim.fs.mkdirp` is
--- libuv-only, so this may be called from a `uv` timer, an `fs_event` watcher
--- or a subprocess stdout callback — the exact places a log sink needs it, and
--- the exact places the previous `vim.fn.mkdir`/`fnamemodify` implementation
--- aborted with `E5560: Vimscript function must not be called in a fast event
--- context`.
---@param path string A *file* path; its parent directory is created
---@return boolean ok
---@return string? err
function M.ensure_dir(path)
  if not path or path == "" then
    return false, "empty path"
  end

  local dir = vim.fs.dirname(path)
  if not dir or dir == "" or dir == "." then
    -- current directory; nothing to do
    return true
  end

  local uv = vim.uv or vim.loop
  -- If dir already exists, done.
  if uv.fs_stat(dir) then
    return true
  end

  return require("lib.nvim.fs.mkdirp")(dir)
end

---@type Lib.Fs.Path
return M
