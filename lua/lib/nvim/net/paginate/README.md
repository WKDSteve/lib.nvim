# `lib.nvim.net.paginate`

Fetch a paginated list page by page and keep what arrived when a later page
fails. Transport-free: you supply `fetch(page, done)`; this module sequences the
pages, merges the items and decides when to stop.

```lua
local paginate = require("lib.nvim.net.paginate")

paginate({
  per_page = 100,   -- fewer items than this: last page, no extra request
  max_pages = 30,   -- cap; hitting it sets `truncated`
  fetch = function(page, done)
    github.request("/users/x/repos", { query = { per_page = "100", page = tostring(page) } },
      function(res, err) done(res and res.data, err) end)
  end,
  on_done = function(r)
    if r.partial then
      notify.warn(("only %d pages arrived: %s"):format(r.pages, r.err))
    end
    use(r.items)
  end,
})
```

## Result

| Field       | Meaning                                                           |
|-------------|-------------------------------------------------------------------|
| `items`     | every item fetched, in page order (empty if page 1 failed)        |
| `pages`     | pages that arrived                                                |
| `ok`        | no error                                                          |
| `partial`   | a page failed after at least one succeeded; `items` is incomplete |
| `truncated` | `max_pages` ended the run; the source may hold more               |
| `err`       | the failure message                                               |

`done(items, err, last)`: pass `last = true` when the response says so (a
`Link: rel="next"` header that is absent). An empty page also ends the run. A
second `done` call for one page is ignored, and a thrown error in `fetch` is a
failed page. `on_done` runs exactly once, on the same turn `fetch` answered.
