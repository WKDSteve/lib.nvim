---@meta
---@module 'lib.nvim.fs.trash.@types'

---@class Lib.Fs.Trash
---@field trash fun(path: string, cb: fun(ok: boolean, err: string|nil)) Send `path` to the OS trash/recycle bin, asynchronously.
---@field restore fun(path: string, cb: fun(ok: boolean, err: string|nil)) Put the newest trashed copy of `path` back, asynchronously (Windows, Linux XDG).
---@field restore_blocking fun(path: string): boolean, string|nil Put the newest trashed copy of `path` back, synchronously; never overwrites.
---@field trash_blocking fun(path: string): boolean, string|nil Send `path` to the OS trash/recycle bin, synchronously.

return {}
