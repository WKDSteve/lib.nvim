---@module 'lib.nvim.fs.listing'
--- The order of a directory listing, written once: folders first, then by name without regard to
--- case, and names that differ in case only by their bytes. And what counts as a folder: a link to a
--- directory is one.
---
--- Pure but for `is_dir`, which asks the disk once when the kind alone does not say.
---
--- - `compare(a, b)`: the order by name, ascending; for `table.sort`
--- - `sorter(opts)`: the same with `descending`, or with a key of the caller before the name (a size,
---   a time), the name being the tie-break
--- - `is_dir(path, kind)`: is this entry of a `fs_scandir` a folder

local uv = vim.uv

local M = {}

---@class Lib.Fs.Listing.Entry
---@field name string
---@field is_dir boolean

---@class Lib.Fs.Listing.SorterOpts
---@field descending? boolean  By name from z to a (folders stay first, case-only twins stay in byte order).
---@field first? fun(a: Lib.Fs.Listing.Entry, b: Lib.Fs.Listing.Entry): boolean|nil  Asked after "folders first" and before the name: true or false decides, nil leaves it to the name.

---A comparator for `table.sort`. It remembers the lower-cased name of every entry it saw (weakly, by
---the entry table), so make one per sort, or keep one for entries that stay.
---@param opts? Lib.Fs.Listing.SorterOpts
---@return fun(a: Lib.Fs.Listing.Entry, b: Lib.Fs.Listing.Entry): boolean
function M.sorter(opts)
  opts = opts or {}
  local descending, first = opts.descending == true, opts.first
  local lowered = setmetatable({}, { __mode = "k" })
  ---@param entry Lib.Fs.Listing.Entry
  ---@return string
  local function low(entry)
    local value = lowered[entry]
    if not value then
      value = entry.name:lower()
      lowered[entry] = value
    end
    return value
  end
  return function(a, b)
    local a_dir, b_dir = a.is_dir == true, b.is_dir == true
    if a_dir ~= b_dir then
      return a_dir
    end
    if first then
      local decided = first(a, b)
      if decided ~= nil then
        return decided
      end
    end
    local la, lb = low(a), low(b)
    if la ~= lb then
      if descending then
        return la > lb
      end
      return la < lb
    end
    return a.name < b.name
  end
end

---The order by name, ascending: folders first, then without regard to case, case-only twins by
---their bytes.
---@param a Lib.Fs.Listing.Entry
---@param b Lib.Fs.Listing.Entry
---@return boolean
function M.compare(a, b)
  local a_dir, b_dir = a.is_dir == true, b.is_dir == true
  if a_dir ~= b_dir then
    return a_dir
  end
  local la, lb = a.name:lower(), b.name:lower()
  if la ~= lb then
    return la < lb
  end
  return a.name < b.name
end

---Is an entry of a directory a folder? `kind` is what `uv.fs_scandir_next` said: "directory" and
---"file" are taken as they are, everything else (a link, or a file system that does not say) is
---asked with one `fs_stat`, which follows links.
---@param path string
---@param kind? string
---@return boolean is_dir
---@return boolean exists  false for a link whose target does not resolve; true when nothing was asked.
function M.is_dir(path, kind)
  if kind == "directory" then
    return true, true
  end
  if kind == "file" then
    return false, true
  end
  local stat = uv.fs_stat(path)
  return stat ~= nil and stat.type == "directory", stat ~= nil
end

return M
