-- TESTS/dev_pattern_usage_spec.lua — lib.nvim.dev.pattern_usage: the "Used by"
-- column of docs/patterns.md. The docmap join itself is docmap's; this checks the
-- cell text, the table rewrite (idempotent, header and separator widened) and
-- that the committed catalogue carries the column on every row.

return function(H)
  local eq, ok = H.eq, H.ok
  local pu = require("lib.nvim.dev.pattern_usage")

  local usage = {
    ["lib.nvim.debounce"] = { kind = "external", consumers = { "a.nvim", "b.nvim" } },
    ["lib.lua.memo"] = { kind = "external", consumers = { "c.nvim" } },
    ["lib.nvim.cache"] = { kind = "external", consumers = { "a.nvim" } },
    ["lib.lua.patterns.x"] = { kind = "internal", consumers = {} },
    ["lib.lua.patterns.y"] = { kind = "unreferenced", consumers = {} },
    ["lib.nvim.big"] = {
      kind = "external",
      consumers = { "1.nvim", "2.nvim", "3.nvim", "4.nvim", "5.nvim" },
    },
  }

  eq(pu.cell({ "lib.nvim.debounce" }, usage), "a, b", "names lose the .nvim suffix")
  eq(pu.cell({ "lib.lua.memo", "lib.nvim.cache" }, usage), "a, c", "several modules are merged")
  eq(pu.cell({ "lib.lua.patterns.x" }, usage), "lib.nvim only", "internal use is named")
  eq(pu.cell({ "lib.lua.patterns.y" }, usage), "—", "unreferenced is a dash")
  eq(pu.cell({ "lib.not.in.map" }, usage), "—", "an unknown module is a dash")
  eq(pu.cell({}, usage), "—", "a row without a module is a dash")
  eq(pu.cell({ "lib.nvim.big" }, usage), "5 repos (1, 2, 3, …)", "long lists are counted")

  eq(
    table.concat(
      pu.row_modules("[`lib.lua.patterns.x`](../x.md) — see also `lib.nvim.other`"),
      ","
    ),
    "lib.lua.patterns.x",
    "the see-also module is not credited"
  )
  eq(
    table.concat(pu.row_modules("`lib.lua.memo`, `lib.nvim.cache`"), ","),
    "lib.lua.memo,lib.nvim.cache"
  )

  local doc = {
    "| `reuse` | legend | row |",
    "| Pattern | Stage | Module | In Lua | Seen |",
    "| --- | --- | --- | --- | --- |",
    "| debounce | `reuse` | `lib.nvim.debounce` | Collapse. | `x.lua:1` |",
    "| x | `impl` | [`lib.lua.patterns.x`](../x.md) | Thing. | `y.lua:2` |",
    "",
    "text | with | pipes",
  }
  local out, rows = pu.sync_lines(doc, usage)
  eq(rows, 2, "two catalogue rows get a cell")
  eq(out[1], doc[1], "tables without a Pattern header are untouched")
  eq(out[2], "| Pattern | Stage | Module | In Lua | Seen | Used by |")
  eq(out[3], "| --- | --- | --- | --- | --- | --- |")
  eq(out[4], "| debounce | `reuse` | `lib.nvim.debounce` | Collapse. | `x.lua:1` | a, b |")
  eq(
    out[5],
    "| x | `impl` | [`lib.lua.patterns.x`](../x.md) | Thing. | `y.lua:2` | lib.nvim only |"
  )
  eq(out[7], doc[7], "prose is untouched")

  local _, no_rows = pu.sync_lines({ "# no table here", "text" }, usage)
  eq(no_rows, 0, "a document without catalogue tables has no rows")

  local again = pu.sync_lines(out, usage)
  eq(table.concat(again, "|"), table.concat(out, "|"), "a second run changes nothing")
  usage["lib.nvim.debounce"].consumers = { "z.nvim" }
  eq(
    pu.sync_lines(out, usage)[4],
    "| debounce | `reuse` | `lib.nvim.debounce` | Collapse. | `x.lua:1` | z |"
  )

  -- The committed catalogue carries the column on every row.
  local lines = vim.fn.readfile("docs/patterns.md")
  local tables, count, in_table = 0, 0, false
  for i, line in ipairs(lines) do
    if line:find("^| Pattern |") then
      tables, in_table = tables + 1, true
      ok(line:find("| Used by |$") ~= nil, "every catalogue table has the Used by column")
    elseif not line:find("^| ") then
      in_table = false
    elseif in_table and not line:find("^| %-%-%-") then
      count = count + 1
      local cells = #vim.split(line:match("^| (.*) |$"), " | ", { plain = true })
      eq(cells, 6, "row " .. i .. " has six cells")
    end
  end
  eq(tables, 4, "four catalogue tables")
  eq(count, 43, "43 catalogue rows")
end
