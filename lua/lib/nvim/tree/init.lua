---@module 'lib.nvim.tree'
--- Pure tree core: node model, fold state, flatten to visible rows, aggregation over children, id <-> row
--- mapping and incremental invalidation. No `vim.api` call anywhere in this module: a window, a buffer or a
--- renderer is the consumer's business (a sidebar, a test explorer, a picker).
---
--- A node is a table `{ id, label, kind?, status?, icon?, columns?, children? }`. `children` is a list of nodes,
--- or a function `children(node, cb)` that answers `cb(list)` / `cb(nil, err)` (lazy: read when first expanded,
--- sync or async). A node without `children` is a leaf.
---
--- Everything that changes the visible rows answers a list of **splices** `{ from, old_count, new_count }` (1-based
--- row numbers, applied in order to the consumer's own line array): replace `old_count` rows from `from` by
--- `new_count` rows read back with `tree:row(i)`. Nothing is re-flattened outside the touched subtree.
---
---```lua
--- local tree = require("lib.nvim.tree")
--- local t = tree.new({ root = { id = "/", label = "repo", children = { ... } }, hide_root = true })
--- for i = 1, t:count() do draw(t:row(i)) end
--- local changes = t:toggle("/src")          -- splices to apply to the drawn lines
--- changes = t:push({ id = "/src/a.lua", status = "failed" })   -- row + the aggregated parents
---```
---
--- Aggregation: the default rule gives every branch `{ status = worst status of its descendants, counts =
--- per-status counts of its leaves, total = number of leaves }`; `opts.severity` orders the statuses worst-first.
--- `opts.aggregate(node, child_aggs, default)` replaces it. After a change only the path to the root is
--- recomputed, and it stops at the first ancestor whose aggregate did not change.
---
--- See @types/init.lua for Lib.Tree.*.

require("lib.nvim.tree.@types")

local M = {}

local Tree = {}
Tree.__index = Tree

---@param a table|nil
---@param b table|nil
---@return boolean
local function agg_equal(a, b)
  if a == b then
    return true
  end
  if not a or not b or a.status ~= b.status or a.total ~= b.total then
    return false
  end
  for k, v in pairs(a.counts) do
    if b.counts[k] ~= v then
      return false
    end
  end
  for k in pairs(b.counts) do
    if a.counts[k] == nil then
      return false
    end
  end
  return true
end

---@param self Lib.Tree
---@param status string|nil
---@return integer rank higher = worse; unknown statuses rank below every listed one
local function rank_of(self, status)
  return self._rank[status] or 0
end

---@param self Lib.Tree
---@param node Lib.Tree.Node
---@param child_aggs Lib.Tree.Agg[]
---@return Lib.Tree.Agg
local function default_aggregate(self, node, child_aggs)
  if #child_aggs == 0 then
    local st = node.status
    return { status = st, counts = st and { [st] = 1 } or {}, total = 1 }
  end
  local counts, total, worst, worst_rank = {}, 0, nil, -1
  for _, a in ipairs(child_aggs) do
    total = total + a.total
    for st, n in pairs(a.counts) do
      counts[st] = (counts[st] or 0) + n
    end
    if a.status ~= nil then
      local r = rank_of(self, a.status)
      if r > worst_rank then
        worst, worst_rank = a.status, r
      end
    end
  end
  return { status = worst, counts = counts, total = total }
end

---@param self Lib.Tree
---@param e Lib.Tree.Entry
local function compute_agg(self, e)
  local aggs = {}
  if e.kids then
    for _, kid in ipairs(e.kids) do
      aggs[#aggs + 1] = self._by_id[kid].agg
    end
  end
  local default = default_aggregate(self, e.node, aggs)
  if self._aggregate then
    local ok, custom = pcall(self._aggregate, e.node, aggs, default)
    if ok and type(custom) == "table" then
      custom.counts = custom.counts or {}
      custom.total = custom.total or default.total
      e.agg = custom
      return
    end
  end
  e.agg = default
end

---@param self Lib.Tree
---@param node Lib.Tree.Node
---@param parent_id string|nil
---@param depth integer
---@return Lib.Tree.Entry
local function register(self, node, parent_id, depth)
  assert(type(node) == "table" and node.id ~= nil, "tree: a node needs an id")
  local id = node.id
  assert(self._by_id[id] == nil, "tree: duplicate node id " .. tostring(id))
  local e = { id = id, node = node, parent = parent_id, depth = depth, state = "leaf" }
  self._by_id[id] = e
  self._size = self._size + 1
  local src = node.children
  if type(src) == "table" then
    e.state = "loaded"
    e.kids = {}
    for _, child in ipairs(src) do
      e.kids[#e.kids + 1] = register(self, child, id, depth + 1).id
    end
  elseif type(src) == "function" then
    e.state = "lazy"
  end
  compute_agg(self, e)
  return e
end

---@param self Lib.Tree
---@param id any
local function unregister(self, id)
  local e = self._by_id[id]
  if not e then
    return
  end
  if e.kids then
    for _, kid in ipairs(e.kids) do
      unregister(self, kid)
    end
  end
  self._by_id[id] = nil
  self._expanded[id] = nil
  self._size = self._size - 1
end

---@param self Lib.Tree
---@param e Lib.Tree.Entry
---@return boolean
local function expandable(self, e)
  return e.state == "lazy"
    or e.state == "loading"
    or e.state == "error"
    or (e.kids ~= nil and #e.kids > 0)
end

---@param self Lib.Tree
---@param e Lib.Tree.Entry
---@return Lib.Tree.Row
local function make_row(self, e)
  return {
    id = e.id,
    node = e.node,
    depth = e.depth - self._shift,
    expandable = expandable(self, e),
    expanded = self._expanded[e.id] == true,
    loading = e.state == "loading",
    error = e.err,
    agg = e.agg,
  }
end

---Append the rows of `e` and, when it is open and loaded, of its visible descendants.
---@param self Lib.Tree
---@param e Lib.Tree.Entry
---@param out Lib.Tree.Row[]
---@param skip_self boolean|nil
local function flatten_into(self, e, out, skip_self)
  if not skip_self then
    out[#out + 1] = make_row(self, e)
  end
  if (skip_self or self._expanded[e.id]) and e.kids then
    for _, kid in ipairs(e.kids) do
      flatten_into(self, self._by_id[kid], out)
    end
  end
end

---@param self Lib.Tree
---@param from integer
local function reindex(self, from)
  local rows, row_of = self._rows, self._row_of
  for i = from, #rows do
    row_of[rows[i].id] = i
  end
end

---Replace `old_n` rows from `from` by `new_rows`, keeping the id -> row map right.
---@param self Lib.Tree
---@param from integer
---@param old_n integer
---@param new_rows Lib.Tree.Row[]
local function splice(self, from, old_n, new_rows)
  local rows, row_of = self._rows, self._row_of
  local n, new_n = #rows, #new_rows
  for i = from, from + old_n - 1 do
    row_of[rows[i].id] = nil
  end
  if new_n > old_n then
    local shift = new_n - old_n
    for i = n, from + old_n, -1 do
      rows[i + shift] = rows[i]
    end
  elseif new_n < old_n then
    local shift = old_n - new_n
    for i = from + old_n, n do
      rows[i - shift] = rows[i]
    end
    for i = n - shift + 1, n do
      rows[i] = nil
    end
  end
  for i = 1, new_n do
    rows[from + i - 1] = new_rows[i]
  end
  if new_n ~= old_n then
    reindex(self, from)
  else
    for i = from, from + new_n - 1 do
      row_of[rows[i].id] = i
    end
  end
end

---How many rows the subtree of the row at `r` takes (the row itself included).
---@param self Lib.Tree
---@param r integer
---@return integer
local function span(self, r)
  local rows = self._rows
  local depth = rows[r].depth
  local i = r + 1
  while rows[i] and rows[i].depth > depth do
    i = i + 1
  end
  return i - r
end

---Re-flatten the subtree of `e` if it is visible; a splice, or nil when it is not shown.
---@param self Lib.Tree
---@param e Lib.Tree.Entry
---@param changes Lib.Tree.Splice[]
local function refresh_subtree(self, e, changes)
  local r = self._row_of[e.id]
  if not r then
    return
  end
  local old_n = span(self, r)
  local fresh = {}
  flatten_into(self, e, fresh)
  splice(self, r, old_n, fresh)
  changes[#changes + 1] = { from = r, old_count = old_n, new_count = #fresh }
end

---Rebuild the aggregate of `e` and then of its ancestors, stopping at the first one that did not change.
---Visible rows of the changed ancestors come back as 1:1 splices.
---@param self Lib.Tree
---@param e Lib.Tree.Entry
---@param changes Lib.Tree.Splice[]
local function propagate(self, e, changes)
  local cur = e
  while cur do
    local before = cur.agg
    compute_agg(self, cur)
    local r = self._row_of[cur.id]
    if r and cur ~= e then
      if not agg_equal(before, cur.agg) then
        self._rows[r] = make_row(self, cur)
        changes[#changes + 1] = { from = r, old_count = 1, new_count = 1 }
      end
    end
    if cur ~= e and agg_equal(before, cur.agg) then
      break
    end
    cur = cur.parent and self._by_id[cur.parent] or nil
  end
end

---@param opts Lib.Tree.Opts
---@return Lib.Tree
function M.new(opts)
  assert(type(opts) == "table" and opts.root, "tree.new: opts.root is required")
  local self = setmetatable({
    _by_id = {},
    _size = 0,
    _expanded = {},
    _rows = {},
    _row_of = {},
    _aggregate = opts.aggregate,
    _on_change = opts.on_change,
    _hide_root = opts.hide_root == true,
    _shift = opts.hide_root == true and 1 or 0,
    _rank = {},
  }, Tree)
  local sev = opts.severity
    or { "error", "failed", "fail", "running", "pending", "warn", "skipped", "passed", "ok" }
  for i, st in ipairs(sev) do
    self._rank[st] = #sev - i + 1
  end
  local root = register(self, opts.root, nil, 0)
  self._root = root.id
  self._expanded[root.id] = true
  for id in pairs(opts.expanded or {}) do
    if self._by_id[id] then
      self._expanded[id] = true
    end
  end
  self:refresh()
  return self
end

---Flatten everything from scratch (the constructor and the bulk operations do this; single changes never do).
function Tree:refresh()
  local rows = {}
  flatten_into(self, self._by_id[self._root], rows, self._hide_root)
  self._rows, self._row_of = rows, {}
  reindex(self, 1)
end

---@return integer
function Tree:count()
  return #self._rows
end

---@param i integer
---@return Lib.Tree.Row|nil
function Tree:row(i)
  return self._rows[i]
end

---@return Lib.Tree.Row[] rows the live list; do not modify it
function Tree:rows()
  return self._rows
end

---@param id any
---@return integer|nil row nil when the node does not exist or is hidden by a closed ancestor
function Tree:row_of(id)
  return self._row_of[id]
end

---@param id any
---@return Lib.Tree.Node|nil
function Tree:node(id)
  local e = self._by_id[id]
  return e and e.node or nil
end

---@param id any
---@return Lib.Tree.Agg|nil
function Tree:agg(id)
  local e = self._by_id[id]
  return e and e.agg or nil
end

---@param id any
---@return any|nil
function Tree:parent(id)
  local e = self._by_id[id]
  return e and e.parent or nil
end

---@return integer nodes number of nodes in the model, visible or not
function Tree:size()
  return self._size
end

---@param id any
---@return boolean
function Tree:is_expanded(id)
  return self._expanded[id] == true
end

---@param self Lib.Tree
---@param e Lib.Tree.Entry
---@param changes Lib.Tree.Splice[]
---@param async boolean  true when called back later: report through `on_change`
local function finish_load(self, e, list, err, changes, async)
  if e.state ~= "loading" then
    return
  end
  if err ~= nil or type(list) ~= "table" then
    e.state, e.err = "error", tostring(err or "no children returned")
  else
    e.state, e.err, e.kids = "loaded", nil, {}
    for _, child in ipairs(list) do
      e.kids[#e.kids + 1] = register(self, child, e.id, e.depth + 1).id
    end
  end
  local own = {}
  propagate(self, e, own)
  refresh_subtree(self, e, own)
  for _, c in ipairs(own) do
    changes[#changes + 1] = c
  end
  if async and self._on_change and #own > 0 then
    pcall(self._on_change, own)
  end
end

---@param self Lib.Tree
---@param e Lib.Tree.Entry
---@param changes Lib.Tree.Splice[]
local function start_load(self, e, changes)
  e.state = "loading"
  local sync = true
  local called = false
  local ok, thrown = pcall(e.node.children, e.node, function(list, err)
    if called then
      return
    end
    called = true
    finish_load(self, e, list, err, changes, not sync)
  end)
  sync = false
  if not ok and not called then
    called = true
    finish_load(self, e, nil, thrown, changes, false)
  end
end

---Open `id`. A lazy node starts loading (the row shows `loading` until the answer arrives; async answers
---come through `opts.on_change`).
---@param id any
---@return Lib.Tree.Splice[]
function Tree:expand(id)
  local changes = {}
  local e = self._by_id[id]
  if not e or self._expanded[id] or not expandable(self, e) then
    return changes
  end
  self._expanded[id] = true
  if e.state == "lazy" or e.state == "error" then
    start_load(self, e, changes)
  end
  if #changes == 0 then
    -- still loading, or already loaded: redraw the node with its new open state
    refresh_subtree(self, e, changes)
  end
  return changes
end

---@param id any
---@return Lib.Tree.Splice[]
function Tree:collapse(id)
  local changes = {}
  local e = self._by_id[id]
  if not e or not self._expanded[id] or id == self._root and self._hide_root then
    return changes
  end
  self._expanded[id] = nil
  refresh_subtree(self, e, changes)
  return changes
end

---@param id any
---@return Lib.Tree.Splice[]
function Tree:toggle(id)
  if self._expanded[id] then
    return self:collapse(id)
  end
  return self:expand(id)
end

---Open every ancestor of `id` so that its row exists (a lazy one loads first, then the next level continues).
---@param id any
---@return Lib.Tree.Splice[]
function Tree:reveal(id)
  local changes = {}
  local chain = {}
  local e = self._by_id[id]
  while e and e.parent do
    e = self._by_id[e.parent]
    table.insert(chain, 1, e)
  end
  for _, anc in ipairs(chain) do
    for _, c in ipairs(self:expand(anc.id)) do
      changes[#changes + 1] = c
    end
  end
  return changes
end

---Close everything (the root stays open).
---@return Lib.Tree.Splice[]
function Tree:collapse_all()
  local old = #self._rows
  self._expanded = { [self._root] = true }
  self:refresh()
  return { { from = 1, old_count = old, new_count = #self._rows } }
end

---Open every loaded node above depth `n` and close the rest (`n = 1`: the root's children are shown).
---@param n integer
---@return Lib.Tree.Splice[]
function Tree:set_depth(n)
  local old = #self._rows
  self._expanded = { [self._root] = true }
  for id, e in pairs(self._by_id) do
    if e.depth < n and e.state == "loaded" and e.kids and #e.kids > 0 then
      self._expanded[id] = true
    end
  end
  self:refresh()
  return { { from = 1, old_count = old, new_count = #self._rows } }
end

---Replace the children of `id` (or turn a leaf into a branch).
---@param id any
---@param list Lib.Tree.Node[]
---@return Lib.Tree.Splice[]
function Tree:set_children(id, list)
  local changes = {}
  local e = self._by_id[id]
  if not e then
    return changes
  end
  if e.kids then
    for _, kid in ipairs(e.kids) do
      unregister(self, kid)
    end
  end
  e.kids, e.state, e.err = {}, "loaded", nil
  e.node.children = list
  for _, child in ipairs(list) do
    e.kids[#e.kids + 1] = register(self, child, id, e.depth + 1).id
  end
  propagate(self, e, changes)
  refresh_subtree(self, e, changes)
  return changes
end

---Remove a node (and its subtree) from the model.
---@param id any
---@return Lib.Tree.Splice[]
function Tree:remove(id)
  local changes = {}
  local e = self._by_id[id]
  if not e or not e.parent then
    return changes
  end
  local parent = self._by_id[e.parent]
  for i, kid in ipairs(parent.kids) do
    if kid == id then
      table.remove(parent.kids, i)
      break
    end
  end
  local r = self._row_of[id]
  if r then
    local n = span(self, r)
    splice(self, r, n, {})
    changes[#changes + 1] = { from = r, old_count = n, new_count = 0 }
  end
  unregister(self, id)
  local rest = {}
  propagate(self, parent, rest)
  -- the parent's own row (state of `expandable`) may have changed too
  local pr = self._row_of[parent.id]
  if pr then
    self._rows[pr] = make_row(self, parent)
    rest[#rest + 1] = { from = pr, old_count = 1, new_count = 1 }
  end
  for _, c in ipairs(rest) do
    changes[#changes + 1] = c
  end
  return changes
end

---Merge an update into a node: `{ id = ..., label?, status?, icon?, columns?, kind?, children? }`. Only fields
---present are changed. A `children` list replaces the subtree; a status change rebuilds the aggregates up the
---path to the root and reports only the rows that really changed.
---@param update Lib.Tree.Update
---@return Lib.Tree.Splice[]
function Tree:push(update)
  local changes = {}
  local e = update and self._by_id[update.id]
  if not e then
    return changes
  end
  for k, v in pairs(update) do
    if k ~= "id" and k ~= "children" then
      e.node[k] = v
    end
  end
  if update.children ~= nil then
    return self:set_children(update.id, update.children)
  end
  local r = self._row_of[e.id]
  if r then
    self._rows[r] = make_row(self, e)
    changes[#changes + 1] = { from = r, old_count = 1, new_count = 1 }
  end
  propagate(self, e, changes)
  return changes
end

---A node changed behind the tree's back (the consumer edited the table): re-read it, its aggregate and its
---ancestors. With `deep`, also re-flatten its subtree.
---@param id any
---@param deep boolean|nil
---@return Lib.Tree.Splice[]
function Tree:invalidate(id, deep)
  local changes = {}
  local e = self._by_id[id]
  if not e then
    return changes
  end
  if deep then
    return self:set_children(id, type(e.node.children) == "table" and e.node.children or {})
  end
  return self:push({ id = id })
end

return M
