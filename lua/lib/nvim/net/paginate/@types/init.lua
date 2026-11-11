---@meta
---@module 'lib.nvim.net.paginate.@types'

---@class Lib.Net.Paginate.Opts
---@field fetch fun(page: integer, done: fun(items: any[]|nil, err: string|nil, last: boolean|nil)) Fetch page `page` (1-based) and call `done` once. `last = true` says this was the final page. A thrown error counts as a failed page.
---@field on_done fun(result: Lib.Net.Paginate.Result) Called exactly once, after the last page or the first failure.
---@field per_page? integer A page with fewer items than this is the last one (no extra request for an empty page).
---@field max_pages? integer Page cap (default 100); hitting it sets `truncated`.

---@class Lib.Net.Paginate.Result
---@field items any[] Every item of every page fetched, in page order (empty after a failed first page).
---@field pages integer Pages that arrived.
---@field ok boolean No error.
---@field partial boolean A page failed after at least one succeeded: `items` is incomplete, `err` says why.
---@field truncated boolean `max_pages` stopped the run; the source may hold more.
---@field err? string The failure message.

---@class Lib.Net.Paginate
---@field run fun(opts: Lib.Net.Paginate.Opts)
---@overload fun(opts: Lib.Net.Paginate.Opts)

return {}
