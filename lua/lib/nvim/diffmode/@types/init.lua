---@meta
---@module 'lib.nvim.diffmode.@types'

---@class Lib.Diffmode.Opts
---@field origin_win? integer the window that already shows `bufs[1]`; it joins the diff but is never in `opened`

---@class Lib.Diffmode.Result
---@field windows integer[] every window in the diff, in the order of the buffers
---@field opened integer[] the windows this call opened (what a caller may close)
---@field origin_win? integer

---@class Lib.Diffmode
---@field set fun(win: integer, on: boolean)
---@field open_n_way fun(bufs: integer[], view: "vsplit"|"split"|"tab", opts?: Lib.Diffmode.Opts): Lib.Diffmode.Result|nil, string|nil
---@field close fun(res: Lib.Diffmode.Result|nil)

return {}
