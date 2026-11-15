-- TESTS/tree_gaps_spec.lua — lib.nvim.tree: what the own tree of filetree.nvim had to work around.
-- An empty folder that can be opened, a lazy root, `merge_children` that reports only the rows that
-- changed (and mixes whole subtrees with `deep`), `reload` of a lazy node, `push` that takes a field
-- away, and the cost of renumbering rows after a splice at the top.

return function(H)
  local ok = H.ok
  local tree = require("lib.nvim.tree")

  -- the harness compares with `==`: lists are compared by what they hold
  local function eq(got, want, msg)
    if type(got) == "table" or type(want) == "table" then
      return H.eq(vim.inspect(got), vim.inspect(want), msg)
    end
    return H.eq(got, want, msg)
  end

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

  -- an empty folder is still a folder when the node says so
  do
    local t = tree.new({
      root = {
        id = "r",
        label = "r",
        children = {
          { id = "empty", label = "empty", expandable = true, children = {} },
          { id = "plain", label = "plain", children = {} },
          { id = "leafy", label = "leafy", expandable = true },
        },
      },
      hide_root = true,
    })
    ok(t:row(1).expandable, "expandable = true: a node with no children can be opened")
    ok(not t:row(2).expandable, "... without it an empty list is no branch, as before")
    ok(t:row(3).expandable, "... also a node that carries no children at all")
    local mirror = ids(t)
    apply(mirror, t, t:expand("empty"))
    ok(t:is_expanded("empty") and t:row(1).expanded, "it opens (and shows nothing below)")
    same(mirror, t, "empty folder opened")
    apply(mirror, t, t:collapse("empty"))
    ok(not t:row(1).expanded, "... and closes")
    same(mirror, t, "empty folder closed")
  end

  -- a lazy root is asked when the tree is made
  do
    local asked = 0
    local t = tree.new({
      root = {
        id = "r",
        label = "r",
        children = function(_, cb)
          asked = asked + 1
          cb({ { id = "x", label = "x" }, { id = "y", label = "y" } })
        end,
      },
      hide_root = true,
    })
    eq(asked, 1, "lazy root: the loader is called once, by new()")
    eq(table.concat(ids(t), ","), "x,y", "... and its answer is the first level")
    local shown = tree.new({
      root = {
        id = "r",
        label = "r",
        children = function(_, cb)
          cb({ { id = "x", label = "x" } })
        end,
      },
    })
    eq(
      table.concat(ids(shown), ","),
      "r,x",
      "lazy root with its own row: the root, then its answer"
    )
    ok(shown:row(1).expanded and not shown:row(1).loading, "... open, not loading")

    -- an answer that comes later arrives through on_change
    local later, reported = nil, nil
    local slow
    slow = tree.new({
      root = {
        id = "r",
        label = "r",
        children = function(_, cb)
          later = cb
        end,
      },
      hide_root = true,
      on_change = function(changes)
        reported = changes
      end,
    })
    eq(slow:count(), 0, "lazy root, slow answer: no rows yet")
    local mirror = ids(slow)
    later({ { id = "x", label = "x" } })
    ok(reported ~= nil, "... the answer is reported through on_change")
    apply(mirror, slow, reported)
    same(mirror, slow, "lazy root answered later")
    local failing = tree.new({
      root = {
        id = "r",
        label = "r",
        children = function()
          error("no disk")
        end,
      },
    })
    ok(failing:row(1).error ~= nil, "a lazy root that fails shows its error on the root row")
  end

  -- merge_children reports only the rows that changed
  do
    local function leaf(id, label)
      return { id = id, label = label or id }
    end
    local function folder(id, kids)
      return { id = id, label = id, children = kids }
    end
    local function list(...)
      return { ... }
    end
    local t = tree.new({
      root = folder(
        "r",
        list(
          folder("a", list(leaf("a/1"), leaf("a/2"))),
          leaf("b"),
          leaf("c"),
          leaf("d"),
          leaf("e")
        )
      ),
      hide_root = true,
    })
    t:expand("a")
    local mirror = ids(t)
    local function merged(msg, nodes, want_from, want_old, want_new)
      local changes = t:merge_children("r", nodes)
      apply(mirror, t, changes)
      same(mirror, t, msg)
      local last = changes[#changes]
      if want_from == nil then
        eq(#changes, 0, msg .. ": nothing reported")
      else
        eq(
          { last and last.from, last and last.old_count, last and last.new_count },
          { want_from, want_old, want_new },
          msg .. ": the splice"
        )
      end
    end
    local function now(...)
      local out = { folder("a", list(leaf("a/1"), leaf("a/2"))) }
      for _, id in ipairs({ ... }) do
        out[#out + 1] = type(id) == "table" and id or leaf(id)
      end
      return out
    end
    merged("the same list again", now("b", "c", "d", "e"), nil)
    merged("one new entry in the middle", now("b", "c", "c2", "d", "e"), 6, 0, 1)
    merged("one entry gone", now("b", "c", "d", "e"), 6, 1, 0)
    merged("a new entry at the end", now("b", "c", "d", "e", "f"), 8, 0, 1)
    merged("a new entry at the start, before an open folder", {
      leaf("0"),
      folder("a", list(leaf("a/1"), leaf("a/2"))),
      leaf("b"),
      leaf("c"),
      leaf("d"),
      leaf("e"),
      leaf("f"),
    }, 1, 0, 1)
    merged("... and gone again", now("b", "c", "d", "e", "f"), 1, 1, 0)
    merged("one entry looks different", now("b", leaf("c", "C!"), "d", "e", "f"), 5, 1, 1)
    eq(t:node("c").label, "C!", "... the kept node took the new field")
    merged(
      "two entries far apart changed: from the first to the last",
      now(leaf("b", "B!"), leaf("c", "C!"), "d", leaf("e", "E!"), "f"),
      4,
      4,
      4
    )
    merged(
      "the order changed",
      now("f", leaf("e", "E!"), "d", leaf("c", "C!"), leaf("b", "B!")),
      4,
      5,
      5
    )
    merged("the open folder at the top is gone, its rows with it", {
      leaf("f"),
      leaf("e", "E!"),
      leaf("d"),
      leaf("c", "C!"),
      leaf("b", "B!"),
    }, 1, 3, 0)
    merged("everything gone", {}, 1, 5, 0)
    merged("into an empty folder", { leaf("x"), leaf("y") }, 1, 0, 2)
    merged(
      "a leaf became a branch under the same id",
      { folder("x", list(leaf("x/1"))), leaf("y") },
      1,
      1,
      1
    )
    ok(t:row(1).expandable, "... its row is the new one")

    -- a folder with its own row that gains and loses its last child
    local own = tree.new({ root = folder("r", list(folder("d", list(leaf("d/1"))), leaf("z"))) })
    own:expand("d")
    local own_mirror = ids(own)
    local function own_merged(msg, nodes)
      local changes = own:merge_children("d", nodes)
      apply(own_mirror, own, changes)
      same(own_mirror, own, msg)
      return changes
    end
    own_merged("the last child of an open folder is gone", {})
    ok(not own:row(2).expandable, "... the folder's own row lost its expander")
    own_merged("... and one comes back", { leaf("d/2") })
    ok(own:row(2).expandable, "... and got it back")
    eq(table.concat(ids(own), ","), "r,d,d/2,z", "... below its own row, before the next sibling")
    own:collapse("d")
    own_mirror = ids(own)
    local closed =
      own_merged("a closed folder: no row of a child is reported", { leaf("d/2"), leaf("d/3") })
    eq(table.concat(ids(own), ","), "r,d,z", "... the rows are the ones there were")
    local only_rows_in_place = true
    for _, c in ipairs(closed) do
      only_rows_in_place = only_rows_in_place and c.old_count == 1 and c.new_count == 1
    end
    ok(
      only_rows_in_place,
      "... only rows redrawn in place (its own, an ancestor whose count changed)"
    )

    -- ten thousand entries, one new
    local many = {}
    for i = 1, 10000 do
      many[i] = leaf(("f%05d"):format(i))
    end
    local big = tree.new({ root = folder("r", many), hide_root = true })
    local again = {}
    for i = 1, 10000 do
      again[i] = leaf(("f%05d"):format(i))
    end
    table.insert(again, 5000, leaf("f04999x"))
    local t0 = vim.uv.hrtime()
    local changes = big:merge_children("r", again)
    local took = (vim.uv.hrtime() - t0) / 1e6
    eq(#changes, 1, "10k entries, one new: one splice")
    eq(
      { changes[1].from, changes[1].old_count, changes[1].new_count },
      { 5000, 0, 1 },
      "... of one row"
    )
    eq(big:row_of("f04999x"), 5000, "... at its place")
    eq(big:row_of("f10000"), 10001, "... and the rows after it moved along")
    ok(took < 200, ("... in %.1f ms"):format(took))
  end

  -- merge_children, deep: a whole tree that was built again
  do
    local function build(extra, b_label)
      return {
        {
          id = "a",
          label = "a",
          children = {
            {
              id = "a/x",
              label = "x",
              children = {
                { id = "a/x/1", label = "1", status = "passed" },
                extra and { id = "a/x/2", label = "2", status = "failed" } or nil,
              },
            },
            { id = "a/y", label = "y", status = "passed" },
          },
        },
        { id = "b", label = b_label or "b", status = "passed" },
      }
    end
    local t =
      tree.new({ root = { id = "r", label = "r", children = build(false) }, hide_root = true })
    t:expand("a")
    t:expand("a/x")
    local mirror = ids(t)
    local changes = t:merge_children("r", build(true, "b2"), { deep = true })
    apply(mirror, t, changes)
    same(mirror, t, "deep merge")
    eq(table.concat(ids(t), ","), "a,a/x,a/x/1,a/x/2,a/y,b", "deep: a node two levels down arrived")
    ok(
      t:is_expanded("a") and t:is_expanded("a/x"),
      "deep: what was open stays open, on every level"
    )
    eq(t:agg("a").status, "failed", "deep: the aggregates follow from the bottom up")
    eq(t:agg("r").counts.failed, 1, "... up to the root")
    eq(t:node("b").label, "b2", "deep: a kept node takes its new fields")
    changes = t:merge_children("r", build(false), { deep = true })
    apply(mirror, t, changes)
    same(mirror, t, "deep merge back")
    eq(t:row_of("a/x/2"), nil, "deep: a node two levels down is gone again")
    eq(t:agg("r").counts.failed, nil, "... and its status with it")
    -- without deep the level below is left alone, as it always was
    local shallow =
      tree.new({ root = { id = "r", label = "r", children = build(false) }, hide_root = true })
    shallow:expand("a")
    shallow:expand("a/x")
    shallow:merge_children("r", build(true))
    eq(shallow:row_of("a/x/2"), nil, "shallow: the children of a kept child are not touched")
    -- a kept lazy child takes the new loader with deep
    local which = "old"
    local lazy = tree.new({
      root = {
        id = "r",
        label = "r",
        children = {
          {
            id = "l",
            label = "l",
            children = function(_, cb)
              cb({ { id = "l/" .. which, label = which } })
            end,
          },
        },
      },
      hide_root = true,
    })
    lazy:expand("l")
    eq(table.concat(ids(lazy), ","), "l,l/old", "(a lazy child, read)")
    lazy:merge_children("r", {
      {
        id = "l",
        label = "l",
        children = function(_, cb)
          cb({ { id = "l/new", label = "new" } })
        end,
      },
    }, { deep = true })
    eq(table.concat(ids(lazy), ","), "l,l/old", "deep: a kept lazy child keeps what it read")
    local mirror2 = ids(lazy)
    apply(mirror2, lazy, lazy:reload("l"))
    same(mirror2, lazy, "reload after a deep merge")
    eq(table.concat(ids(lazy), ","), "l,l/new", "... and reload asks the loader it was handed last")
  end

  -- reload: ask a lazy node again
  do
    local round = 0
    local pending = nil
    local reported = {}
    local t
    t = tree.new({
      root = {
        id = "r",
        label = "r",
        children = {
          {
            id = "d",
            label = "d",
            children = function(_, cb)
              round = round + 1
              if round == 4 then
                pending = cb
                return
              end
              if round == 5 then
                cb(nil, "gone")
                return
              end
              local kids =
                { { id = "d/sub", label = "sub", children = { { id = "d/sub/1", label = "1" } } } }
              for i = 1, round do
                kids[#kids + 1] = { id = "d/" .. i, label = tostring(i) }
              end
              cb(kids)
            end,
          },
          { id = "leaf", label = "leaf" },
        },
      },
      hide_root = true,
      on_change = function(changes)
        reported[#reported + 1] = changes
      end,
    })
    eq(#t:reload("d"), 0, "reload of a node that was never read does nothing")
    eq(round, 0, "... and does not call the loader")
    eq(#t:reload("leaf"), 0, "reload of a leaf does nothing")
    eq(#t:reload("nope"), 0, "reload of an unknown id does nothing")
    t:expand("d")
    t:expand("d/sub")
    local mirror = ids(t)
    eq(table.concat(mirror, ","), "d,d/sub,d/sub/1,d/1,leaf", "(read once)")
    apply(mirror, t, t:reload("d"))
    same(mirror, t, "reload")
    eq(
      table.concat(ids(t), ","),
      "d,d/sub,d/sub/1,d/1,d/2,leaf",
      "reload: the loader's new answer is mixed in"
    )
    ok(t:is_expanded("d/sub"), "reload: a folder that was open below stays open")
    t:reload("d")
    mirror = ids(t)
    eq(round, 3, "(the loader was asked three times)")
    -- an answer that comes later
    eq(#t:reload("d"), 0, "reload with a slow loader returns nothing yet")
    local before_reports = #reported
    pending({ { id = "d/late", label = "late" } })
    eq(#reported, before_reports + 1, "... the answer arrives through on_change")
    apply(mirror, t, reported[#reported])
    same(mirror, t, "slow reload")
    eq(table.concat(ids(t), ","), "d,d/late,leaf", "... and is what is shown")
    -- a failing loader leaves what is shown
    eq(#t:reload("d"), 0, "reload with a failing loader reports nothing")
    eq(table.concat(ids(t), ","), "d,d/late,leaf", "... and what was shown stays")
    ok(not t:row(1).error, "... without an error on the row")
  end

  -- push: take a field away
  do
    local t = tree.new({
      root = {
        id = "r",
        label = "r",
        children = { { id = "n", label = "n", columns = { "3" }, status = "failed", icon = "x" } },
      },
      hide_root = true,
    })
    t:push({ id = "n", columns = nil })
    eq(t:node("n").columns[1], "3", "push: a field that is nil in the update stays (as before)")
    local changes = t:push({ id = "n", label = "n2", clear = { "columns", "status" } })
    eq(t:node("n").columns, nil, "push with clear: the field is gone")
    eq(t:node("n").status, nil, "... every field named")
    eq(
      { t:node("n").label, t:node("n").icon },
      { "n2", "x" },
      "... the others are set or left as they were"
    )
    eq(t:node("n").clear, nil, "... and `clear` itself is no field of the node")
    eq(t:agg("r").counts.failed, nil, "... a cleared status leaves the aggregates")
    ok(#changes >= 1, "... and the row is reported")
    t:push({ id = "n", clear = { "id", "children" } })
    eq(t:node("n").id, "n", "push with clear cannot take the id away")
  end

  -- id -> row after a splice at the top of 10 000 rows: measured, see the task
  do
    local kids = {}
    for i = 1, 10000 do
      kids[i] = { id = "k" .. i, label = "k" }
    end
    local t = tree.new({ root = { id = "r", label = "r", children = kids }, hide_root = true })
    local best = math.huge
    for round = 1, 9 do
      local t0 = vim.uv.hrtime()
      t:merge_children(
        "r",
        (function()
          local out = { { id = "new" .. round, label = "n" } }
          for i = 1, 10000 do
            out[#out + 1] = kids[i]
          end
          return out
        end)()
      )
      best = math.min(best, (vim.uv.hrtime() - t0) / 1e6)
      t:remove("new" .. round)
    end
    eq(t:row_of("k1"), 1, "after the rounds the first row is the first again")
    ok(
      best < 50,
      ("a new row at the top of 10k rows (merge and renumbering): %.2f ms at best"):format(best)
    )
    io.stdout:write(
      ("      tree: a new row at the top of 10k rows %.2f ms at best"):format(best),
      "\n"
    )
  end
end
