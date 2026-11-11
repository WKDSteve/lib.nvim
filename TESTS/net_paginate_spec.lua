-- TESTS/net_paginate_spec.lua — lib.nvim.net.paginate

return function(H)
  local eq, ok = H.eq, H.ok
  local paginate = require("lib.nvim.net.paginate")

  ---@param pages table<integer, any> page -> list | { err = "..." } | "throw"
  local function run(pages, opts)
    local calls, res, n_done = {}, nil, 0
    paginate(vim.tbl_extend("force", {
      fetch = function(page, done)
        calls[#calls + 1] = page
        local p = pages[page]
        if p == "throw" then
          error("boom")
        end
        if p == nil then
          done({}, nil)
        elseif p.err then
          done(nil, p.err)
        else
          done(p, nil, p.last)
        end
      end,
      on_done = function(r)
        res, n_done = r, n_done + 1
      end,
    }, opts or {}))
    return res, calls, n_done
  end

  -- a short page is the last one: no extra request
  local r, calls = run({ { 1, 2 }, { 3 } }, { per_page = 2 })
  eq(table.concat(r.items, ","), "1,2,3", "short last page: items merged")
  eq(#calls, 2, "short last page: no request past it")
  ok(r.ok and not r.partial and not r.truncated, "short last page: clean result")
  eq(r.pages, 2, "short last page: page count")

  -- without per_page an empty page ends the run
  r, calls = run({ { 1 }, { 2 } })
  eq(table.concat(r.items, ","), "1,2", "empty page ends: items")
  eq(#calls, 3, "empty page ends: the empty page was requested")

  -- the source says last
  r, calls = run({ { 1, 2, last = true } }, { per_page = 2 })
  eq(#calls, 1, "last = true stops")
  eq(#r.items, 2, "last = true: items kept")

  -- a later page fails: partial, what arrived is kept
  r = run({ { 1, 2 }, { 3, 4 }, { err = "rate limited" } }, { per_page = 2 })
  eq(r.partial, true, "failure after page 2: partial")
  eq(r.ok, false, "failure after page 2: not ok")
  eq(r.err, "rate limited", "failure after page 2: err")
  eq(table.concat(r.items, ","), "1,2,3,4", "failure after page 2: earlier pages kept")
  eq(r.pages, 2, "failure after page 2: pages")

  -- the first page fails: not partial, nothing in hand
  r = run({ { err = "offline" } })
  eq(r.partial, false, "first page fails: not partial")
  eq(#r.items, 0, "first page fails: no items")
  eq(r.err, "offline", "first page fails: err")

  -- a throwing fetch is a failed page
  r = run({ { 1, 2 }, "throw" }, { per_page = 2 })
  eq(r.partial, true, "throw: partial")
  ok(tostring(r.err):find("boom"), "throw: message kept: " .. tostring(r.err))

  -- cap
  r, calls = run({ { 1, 2 }, { 3, 4 }, { 5, 6 } }, { per_page = 2, max_pages = 2 })
  eq(r.truncated, true, "cap: truncated")
  eq(#calls, 2, "cap: no request past the cap")
  eq(#r.items, 4, "cap: items so far")
  eq(r.ok, true, "cap: not an error")

  -- on_done exactly once, a second done is ignored
  local seen = 0
  paginate({
    fetch = function(_, done)
      done({ 1 }, nil, true)
      done({ 2 }, nil, true)
    end,
    on_done = function(res)
      seen = seen + 1
      eq(#res.items, 1, "double done: second answer ignored")
    end,
  })
  eq(seen, 1, "on_done runs once")

  -- async fetch
  local async_res
  paginate({
    per_page = 1,
    fetch = function(page, done)
      vim.schedule(function()
        done(page <= 2 and { page } or {}, nil)
      end)
    end,
    on_done = function(res)
      async_res = res
    end,
  })
  vim.wait(2000, function()
    return async_res ~= nil
  end, 5)
  ok(async_res and #async_res.items == 2, "async fetch: pages chained")
end
