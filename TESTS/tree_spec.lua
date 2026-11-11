-- TESTS/tree_spec.lua — lib.nvim.tree (pure tree core)

return function(H)
  local eq, ok = H.eq, H.ok
  local tree = require("lib.nvim.tree")

  -- A screen mirror: apply the returned splices to a list of ids and compare with the tree's rows.
  local function ids(t)
    local out = {}
    for i = 1, t:count() do
      out[i] = t:row(i).id
    end
    return out
  end
  local function apply(mirror, t, changes)
    for _, c in ipairs(changes) do
      for _ = 1, c.old_count do
        table.remove(mirror, c.from)
      end
      for k = c.new_count, 1, -1 do
        table.insert(mirror, c.from, t:row(c.from + k - 1).id)
      end
    end
  end
  local function same(mirror, t, msg)
    eq(table.concat(mirror, ","), table.concat(ids(t), ","), msg .. ": screen == rows")
    for i = 1, t:count() do
      eq(t:row_of(t:row(i).id), i, msg .. ": row_of")
    end
  end

  local function sample()
    return {
      id = "root",
      label = "root",
      children = {
        {
          id = "a",
          label = "a",
          children = {
            { id = "a1", label = "a1", status = "passed" },
            { id = "a2", label = "a2", status = "passed" },
          },
        },
        {
          id = "b",
          label = "b",
          children = {
            { id = "b1", label = "b1", status = "skipped" },
            {
              id = "b2",
              label = "b2",
              children = { { id = "b21", label = "b21", status = "passed" } },
            },
          },
        },
        { id = "c", label = "c", status = "failed" },
      },
    }
  end

  -- flatten, hidden root, fold
  local t = tree.new({ root = sample(), hide_root = true })
  eq(table.concat(ids(t), ","), "a,b,c", "hide_root: the root's children are the first level")
  eq(t:row(1).depth, 0, "first visible level has depth 0")
  eq(t:size(), 9, "size counts hidden nodes too")
  ok(t:row(1).expandable and not t:row(1).expanded, "a branch is expandable and closed")
  ok(not t:row(3).expandable, "a leaf is not expandable")
  eq(t:row_of("a1"), nil, "a hidden node has no row")

  local mirror = ids(t)
  local ch = t:expand("a")
  apply(mirror, t, ch)
  eq(table.concat(ids(t), ","), "a,a1,a2,b,c", "expand shows the children")
  eq(#ch, 1, "expand is one splice")
  eq(ch[1].from, 1, "...from the node's row")
  eq(ch[1].old_count, 1, "...replacing its own row")
  eq(ch[1].new_count, 3, "...by it and its two children")
  same(mirror, t, "after expand")
  eq(t:row(2).depth, 1, "children are one level deeper")

  ch = t:expand("b")
  apply(mirror, t, ch)
  ch = t:expand("b2")
  apply(mirror, t, ch)
  eq(table.concat(ids(t), ","), "a,a1,a2,b,b1,b2,b21,c", "nested expand")
  same(mirror, t, "nested")

  ch = t:collapse("b")
  apply(mirror, t, ch)
  eq(table.concat(ids(t), ","), "a,a1,a2,b,c", "collapse drops the whole visible subtree")
  eq(ch[1].old_count, 4, "collapse splice removes b's visible subtree")
  same(mirror, t, "collapse")
  eq(#t:expand("b"), 1, "re-expanding keeps the inner open state")
  eq(table.concat(ids(t), ","), "a,a1,a2,b,b1,b2,b21,c", "b2 is still open")
  eq(#t:expand("b"), 0, "expanding an open node changes nothing")
  eq(#t:expand("c"), 0, "a leaf cannot be expanded")
  eq(#t:expand("nope"), 0, "an unknown id changes nothing")

  -- bulk
  mirror = ids(t)
  apply(mirror, t, t:collapse_all())
  eq(table.concat(ids(t), ","), "a,b,c", "collapse_all")
  same(mirror, t, "collapse_all")
  apply(mirror, t, t:set_depth(2))
  eq(table.concat(ids(t), ","), "a,a1,a2,b,b1,b2,c", "set_depth(2) opens the loaded levels above 2")
  same(mirror, t, "set_depth")

  -- reveal
  t:collapse_all()
  mirror = ids(t)
  apply(mirror, t, t:reveal("b21"))
  ok(t:row_of("b21") ~= nil, "reveal opens every ancestor")
  same(mirror, t, "reveal")

  -- aggregation: worst status, counts, total
  t = tree.new({ root = sample() })
  local agg = t:agg("a")
  eq(agg.status, "passed", "a: all passed")
  eq(agg.total, 2, "a: two leaves")
  agg = t:agg("root")
  eq(agg.status, "failed", "root: the worst status of any leaf")
  eq(agg.counts.passed, 3, "root: passed leaves counted")
  eq(agg.counts.failed, 1, "root: failed leaves counted")
  eq(agg.counts.skipped, 1, "root: skipped leaves counted")
  eq(agg.total, 5, "root: five leaves")

  -- push: the row and exactly the ancestors whose aggregate changed
  t = tree.new({ root = sample(), hide_root = true, expanded = { a = true, b = true } })
  mirror = ids(t)
  ch = t:push({ id = "a1", status = "failed" })
  apply(mirror, t, ch)
  local froms = {}
  for _, c in ipairs(ch) do
    froms[#froms + 1] = c.from
    eq(c.old_count, 1, "push splices are 1:1")
  end
  table.sort(froms)
  eq(table.concat(froms, ","), "1,2", "push: a1's row and a's row (aggregate passed -> failed)")
  eq(t:agg("a").status, "failed", "a aggregates the new status")
  same(mirror, t, "push")

  -- ... the counts are part of the aggregate: a2 failing too changes a's counts, so a's row is redrawn as well
  ch = t:push({ id = "a2", status = "failed" })
  eq(#ch, 2, "a2 failing too: its row and a's row (counts changed), nothing above")
  ch = t:push({ id = "a1", label = "renamed" })
  eq(#ch, 1, "a label change touches one row")
  eq(t:node("a1").label, "renamed", "the node table was updated")

  -- push of an unknown id, hidden node
  eq(#t:push({ id = "nope", status = "x" }), 0, "unknown id: no change")
  ch = t:push({ id = "b21", status = "failed" })
  ok(t:row_of("b21") == nil, "b21 is hidden (b2 is closed)")
  eq(t:agg("b").status, "failed", "...but its aggregate reached b")
  eq(#ch, 2, "hidden node: the visible ancestors b2 and b are redrawn")

  -- set_children / remove
  mirror = ids(t)
  ch = t:set_children("a", { { id = "n1", label = "n1", status = "passed" } })
  apply(mirror, t, ch)
  same(mirror, t, "set_children")
  eq(t:node("a1"), nil, "replaced children leave the model")
  eq(t:size(), 9 - 2 + 1, "size follows")
  ch = t:remove("n1")
  apply(mirror, t, ch)
  same(mirror, t, "remove")
  eq(t:node("n1"), nil, "removed")
  ok(not t:row_of("a") or not t:row(t:row_of("a")).expandable, "a is a leaf row again")
  eq(#t:remove("root"), 0, "the root cannot be removed")

  -- custom aggregation
  local sum = tree.new({
    root = {
      id = "r",
      label = "r",
      children = {
        { id = "x", label = "x", status = "1" },
        { id = "y", label = "y", status = "2" },
      },
    },
    aggregate = function(node, kids, default)
      local s = 0
      for _, k in ipairs(kids) do
        s = s + (tonumber(k.status) or 0)
      end
      default.status = #kids > 0 and tostring(s) or node.status
      return default
    end,
  })
  eq(sum:agg("r").status, "3", "a custom rule replaces the default")

  -- lazy children: sync
  local calls = 0
  local lazy = tree.new({
    root = {
      id = "r",
      label = "r",
      children = {
        {
          id = "d",
          label = "d",
          children = function(_, cb)
            calls = calls + 1
            cb({ { id = "d1", label = "d1", status = "failed" }, { id = "d2", label = "d2" } })
          end,
        },
      },
    },
    hide_root = true,
  })
  ok(lazy:row(1).expandable, "a lazy node is expandable before it is loaded")
  eq(lazy:agg("r").status, nil, "an unloaded lazy node adds no status")
  mirror = ids(lazy)
  apply(mirror, lazy, lazy:expand("d"))
  eq(table.concat(ids(lazy), ","), "d,d1,d2", "sync lazy: children appear in the same call")
  same(mirror, lazy, "sync lazy")
  eq(lazy:agg("r").status, "failed", "the loaded children reach the aggregate")
  lazy:collapse("d")
  lazy:expand("d")
  eq(calls, 1, "a loaded node is not loaded again")

  -- lazy children: async, with loading state and on_change
  local pending
  local seen
  local async = tree.new({
    root = {
      id = "r",
      label = "r",
      children = {
        {
          id = "d",
          label = "d",
          children = function(_, cb)
            pending = cb
          end,
        },
      },
    },
    hide_root = true,
    on_change = function(c)
      seen = c
    end,
  })
  ch = async:expand("d")
  ok(async:row(1).loading, "async lazy: the row says loading")
  eq(#ch, 1, "async lazy: the node's own row is redrawn")
  mirror = ids(async)
  pending({ { id = "k", label = "k" } })
  ok(seen ~= nil, "async lazy: on_change reports the arrival")
  apply(mirror, async, seen)
  eq(table.concat(ids(async), ","), "d,k", "async lazy: children shown after the answer")
  ok(not async:row(1).loading, "async lazy: loading is over")

  -- lazy failure and retry
  local fail_once = true
  local flaky = tree.new({
    root = {
      id = "r",
      label = "r",
      children = {
        {
          id = "d",
          label = "d",
          children = function(_, cb)
            if fail_once then
              cb(nil, "no access")
            else
              cb({ { id = "k", label = "k" } })
            end
          end,
        },
      },
    },
    hide_root = true,
  })
  flaky:expand("d")
  eq(flaky:row(1).error, "no access", "a failed load shows its error")
  flaky:collapse("d")
  fail_once = false
  flaky:expand("d")
  eq(table.concat(ids(flaky), ","), "d,k", "the next expand retries")
  ok(flaky:row(1).error == nil, "...and the error is gone")

  -- a loader that throws is a failed load
  local boom = tree.new({
    root = {
      id = "r",
      label = "r",
      children = {
        {
          id = "d",
          label = "d",
          children = function()
            error("kaputt")
          end,
        },
      },
    },
    hide_root = true,
  })
  boom:expand("d")
  ok(tostring(boom:row(1).error):find("kaputt"), "a throwing loader is reported")

  -- duplicate ids are refused
  ok(
    not pcall(
      tree.new,
      { root = { id = "x", label = "x", children = { { id = "x", label = "dup" } } } }
    ),
    "duplicate id"
  )

  -- the core touches no editor API
  local f = assert(io.open(debug.getinfo(tree.new, "S").source:sub(2), "rb"))
  local source = f:read("*a")
  f:close()
  ok(
    not source:find("vim%.api%.") and not source:find("vim%.fn%.") and not source:find("vim%.cmd"),
    "no editor call in the core"
  )

  -- performance: 10k nodes flatten, a leaf update in 1.5k nodes
  local function wide(n_dirs, per_dir)
    local dirs = {}
    for d = 1, n_dirs do
      local kids = {}
      for k = 1, per_dir do
        kids[k] = { id = ("d%d/%d"):format(d, k), label = "leaf", status = "passed" }
      end
      dirs[d] = { id = "d" .. d, label = "dir", children = kids }
    end
    return { id = "root", label = "root", children = dirs }
  end
  local t0 = vim.uv.hrtime()
  local big = tree.new({ root = wide(100, 100), hide_root = true })
  big:set_depth(2)
  local flat_ms = (vim.uv.hrtime() - t0) / 1e6
  eq(big:count(), 100 + 100 * 100, "10k leaves flattened")
  ok(flat_ms < 2000, ("10k nodes build and flatten in %d ms"):format(flat_ms))

  local mid = tree.new({ root = wide(15, 100), hide_root = true })
  mid:set_depth(2)
  eq(mid:size(), 1 + 15 + 1500, "1.5k node tree")
  local best = math.huge
  for i = 1, 20 do
    local s = vim.uv.hrtime()
    mid:push({ id = "d7/50", status = (i % 2 == 0) and "passed" or "failed" })
    best = math.min(best, (vim.uv.hrtime() - s) / 1e6)
  end
  ok(best < 5, ("a one-node update in 1.5k nodes: %.2f ms"):format(best))
end
