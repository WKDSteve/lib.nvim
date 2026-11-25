---@module 'lib.nvim.fs.norm'
--- One spelling for a path: `/`-separated, the drive letter in upper case, no trailing `/` (a bare
--- root keeps it: `/`, `C:/`). The spelling the tree views and `lib.nvim.fs.fast` use for keys.
---
--- A leaf with no requires, so a plugin can take it at load time. Pure string work: no `~`, no
--- symlinks, no `..` -- `lib.nvim.fs.normkey` is the one that touches the file system.

---@param path string
---@return string
return function(path)
  path = path:gsub("\\", "/")
  path = path:gsub("^(%a):", function(drive)
    return drive:upper() .. ":"
  end)
  if #path > 1 and path:sub(-1) == "/" and not path:match("^%a:/$") then
    path = path:sub(1, -2)
  end
  return path
end
