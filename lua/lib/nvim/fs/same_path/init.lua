---@module 'lib.nvim.fs.same_path'
--- Do two path strings name the same location, on this platform's file system?
---
--- Thin layer over `lib.nvim.fs.normkey`: both sides are canonicalized (forward
--- slashes, drive letter, duplicate separators, optional symlink/8.3 resolution)
--- and compared byte for byte, after lowercasing both when the file system
--- ignores case (`lib.nvim.cross.platform.case_blind`).
---
--- It does not touch the disk unless `opts.realpath` is true (the default of
--- `normkey` is a realpath; this module defaults it to false, because a
--- comparison in a hot path must not stat). Use `realpath = true` when one side
--- comes from a foreign source (`tempname()`, an LSP root).

local normkey = require("lib.nvim.fs.normkey")
local case_blind = require("lib.nvim.cross.platform.case_blind")

-- `string.lower` folds ASCII only; anything with a high byte goes through
-- `vim.fn.tolower` (same rule as `lib.nvim.fs.is_subpath`).
---@param s string
---@return string
local function lower(s)
  if not s:find("[\128-\255]") then
    return s:lower()
  end
  return vim.fn.tolower(s)
end

-- Strip trailing separators so `/v/` and `/v` are one spelling; a bare root
-- keeps its slash.
---@param p string
---@return string
local function trim(p)
  if #p > 1 and not p:match("^%a:/$") then
    return (p:gsub("(.)/+$", "%1"))
  end
  return p
end

---@param a string
---@param b string
---@param opts? Lib.Fs.SamePathOpts
---@return boolean
return function(a, b, opts)
  if type(a) ~= "string" or type(b) ~= "string" then
    return false
  end
  opts = opts or {}
  local k = { realpath = opts.realpath == true }
  a, b = trim(normkey(a, k)), trim(normkey(b, k))
  local fold = opts.ignore_case
  if fold == nil then
    fold = case_blind()
  end
  if fold then
    a, b = lower(a), lower(b)
  end
  return a == b
end
