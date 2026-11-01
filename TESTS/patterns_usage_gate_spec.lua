-- TESTS/patterns_usage_gate_spec.lua — the gate of docs/patterns.md: a pattern module that is
-- `impl` has a consumer (the generated "Used by" column is not a dash); a pattern nobody uses is
-- `idea`. The column is committed, so this needs neither docmap nor the sibling repositories.

return function(H)
  local eq, ok = H.eq, H.ok
  local pu = require("lib.nvim.dev.pattern_usage")

  local fixture = {
    "| Pattern | Stage | Module | In Lua | Seen | Used by |",
    "| --- | --- | --- | --- | --- | --- |",
    "| [used](https://x) | `impl` | [`lib.lua.patterns.used`](a.md) | Thing. | `a.lua:1` | gopath, my |",
    "| [own](https://x) | `impl` | [`lib.lua.patterns.own`](a.md) | Thing. | `a.lua:1` | lib.nvim only |",
    "| [lonely](https://x) | `impl` | [`lib.lua.patterns.lonely`](a.md) | Thing. | `a.lua:1` | — |",
    "| [pool](https://x) | `idea` | [`lib.lua.patterns.pool`](a.md) | Thing. | `a.lua:1` | — |",
    "| debounce | `reuse` | `lib.nvim.debounce` | Collapse. | `x.lua:1` | — |",
    "| bare | `impl` | `lib.lua.patterns.bare` | Thing. | `a.lua:1` | — |",
    "| `impl` | legend | row |",
  }
  local names, rows = pu.impl_without_consumer(fixture)
  eq(rows, 4, "only impl rows with six cells are checked")
  eq(table.concat(names, ","), "lonely,bare", "an impl dash is reported, idea and reuse are not")

  local lines = vim.fn.readfile("docs/patterns.md")
  local bad, checked = pu.impl_without_consumer(lines)
  ok(checked > 0, "the committed catalogue has impl rows")
  eq(
    table.concat(bad, ", "),
    "",
    "impl patterns without a consumer (set them to idea, or use them): " .. table.concat(bad, ", ")
  )
end
