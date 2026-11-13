# `lib.nvim.tree`

A pure tree core: node model, fold state, flatten to the visible rows,
aggregation over children, id <-> row mapping and incremental invalidation.
**No `vim.api` call** in the module; a window or buffer is the consumer's job
(a file-tree sidebar, a test explorer, a picker).

```lua
local tree = require("lib.nvim.tree")

local t = tree.new({
  root = { id = "root", label = "project", children = {
    { id = "a", label = "a_spec", children = {
      { id = "a1", label = "case 1", status = "passed" },
      { id = "a2", label = "case 2", status = "failed" },
    } },
    { id = "dir", label = "lazy dir", children = function(node, cb) cb({ { id = "d1", label = "x" } }) end },
  } },
  hide_root = true,
})

for i = 1, t:count() do render(t:row(i)) end      -- visible rows: id, node, depth, expanded, agg, ...
local changes = t:toggle("a")                      -- { { from, old_count, new_count } ... }
changes = t:push({ id = "a2", status = "passed" }) -- the row and the parents whose aggregate changed
```

## Model

A node is `{ id, label, kind?, status?, icon?, columns?, children? }`. `children` is a list, or
`function(node, cb)` that answers `cb(list)` or `cb(nil, err)` (lazy: read on the first expand; sync or async). A
node without `children` is a leaf. Ids are unique; the tree keeps your node tables and merges updates into them.

## Changes are splices

Every operation that changes what is visible returns a list of `{ from, old_count, new_count }` (1-based rows):
replace `old_count` lines from `from` by `new_count` rows read with `t:row(i)`. They are meant to be applied in
order to the consumer's own line array. Only the touched subtree is re-flattened, never the whole tree; the
exceptions are `collapse_all`, `set_depth` and `refresh`, which say so by returning one big splice.

| Call | What it does |
|---|---|
| `expand(id)` / `collapse(id)` / `toggle(id)` | fold state, per tree instance |
| `reveal(id)` | open every ancestor (lazy ones load first) |
| `collapse_all()` / `set_depth(n)` | bulk fold |
| `push({ id, status?, label?, ..., children? })` | merge an update; a `children` list replaces the subtree |
| `set_children(id, list)` / `remove(id)` | structure changes |
| `invalidate(id, deep?)` | a node was edited behind the tree's back |
| `row(i)` / `rows()` / `row_of(id)` / `count()` | the visible lines and the id <-> row map |
| `node(id)` / `agg(id)` / `parent(id)` / `size()` | the model |

## Aggregation

Default: a branch gets `{ status = worst status of its leaves, counts = leaves per status, total }`, the order of
`opts.severity` (worst first; default `error, failed, fail, running, pending, warn, skipped, passed, ok`).
`opts.aggregate(node, child_aggs, default)` replaces the rule. After a change only the path to the root is rebuilt,
and it **stops at the first ancestor whose aggregate did not change**.

## Lazy children

Expanding a lazy node marks the row `loading`; a synchronous answer comes back in the splices, an asynchronous one
through `opts.on_change(changes)`. A failed load shows `row.error` and is tried again on the next expand.

## Cost

Flatten is O(visible rows); a single change is O(touched subtree) plus an O(rows) renumbering of the id -> row
map after a splice that changes the row count. Measured by the spec: 10 000 nodes flatten in well under a second,
a one-node status update in a 1 500 node tree under 5 ms.

## Registry

[`lib.nvim.tree.registry`](registry/README.md) is where plugins announce sources, decorators and actions for a
tree view, without loading the plugin that draws it.
