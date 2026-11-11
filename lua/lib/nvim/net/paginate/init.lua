---@module 'lib.nvim.net.paginate'
--- Fetch a paginated list one page after another and hand back what arrived,
--- even when a later page fails.
---
--- Generalized from `github_stats.nvim` (`api.fetch_user_repos`): a user with
--- 400 repos is 4 pages, and a rate limit on page 3 should not throw away the
--- 200 repos already in hand. The result says so (`partial = true`, `err` set)
--- instead of pretending the list is complete or empty.
---
--- Transport-free: `fetch(page, done)` does the request, however it wants
--- (`lib.nvim.net.github`, `curl`, a test double). This module only sequences
--- the pages, merges the items and decides when to stop.
---
---```lua
--- paginate({
---   per_page = 100,
---   max_pages = 30,
---   fetch = function(page, done)
---     github.request("/users/x/repos", { query = { per_page = "100", page = tostring(page) } },
---       function(res, err)
---         done(res and res.data, err)
---       end)
---   end,
---   on_done = function(r)
---     -- r.items, r.pages, r.ok, r.partial, r.truncated, r.err
---   end,
--- })
---```

local M = {}

---@param opts Lib.Net.Paginate.Opts
function M.run(opts)
  assert(type(opts) == "table", "paginate: opts must be a table")
  assert(type(opts.fetch) == "function", "paginate: opts.fetch must be a function")
  assert(type(opts.on_done) == "function", "paginate: opts.on_done must be a function")

  local max_pages = opts.max_pages or 100
  local per_page = opts.per_page
  ---@type any[]
  local items = {}
  local pages = 0
  local finished = false

  ---@param err string|nil
  ---@param truncated boolean|nil
  local function finish(err, truncated)
    if finished then
      return
    end
    finished = true
    opts.on_done({
      items = items,
      pages = pages,
      ok = err == nil,
      -- an error AFTER at least one page: `items` is what arrived before it
      partial = err ~= nil and pages > 0,
      -- the page cap, not the data, ended the run: there may be more
      truncated = truncated == true,
      err = err,
    })
  end

  local function fetch_page(page)
    if page > max_pages then
      finish(nil, true)
      return
    end

    local answered = false
    ---@param got any[]|nil
    ---@param err string|nil
    ---@param last boolean|nil # the source says this was the last page
    local function done(got, err, last)
      if answered or finished then
        return
      end
      answered = true
      if err ~= nil or type(got) ~= "table" then
        finish(err ~= nil and tostring(err) or ("page " .. page .. ": no list returned"))
        return
      end
      pages = pages + 1
      vim.list_extend(items, got)
      if last or #got == 0 or (per_page and #got < per_page) then
        finish(nil)
        return
      end
      fetch_page(page + 1)
    end

    local ok, thrown = pcall(opts.fetch, page, done)
    if not ok then
      done(nil, "page " .. page .. ": " .. tostring(thrown))
    end
  end

  fetch_page(1)
end

---@type Lib.Net.Paginate
return setmetatable(M, {
  __call = function(_, opts)
    return M.run(opts)
  end,
})
