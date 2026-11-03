---@module 'lib.nvim.tree'
---@brief Pure tree core: nodes, fold state, flatten to rows, aggregation, incremental updates, lazy children.
---@description
--- A tree of plain node tables becomes a flat list of visible rows. The core owns no window and no buffer and
--- calls no `vim.api` function: a consumer (an explorer window, a picker, a quickfix-like list) binds the rows to
--- whatever it draws on, and redraws only the row ranges a change reports.
---
---   local tree = require("lib.nvim.tree")
---   local t = tree.new({ id = "root", label = "project", children = {
---     { id = "a", label = "a_spec.lua", children = {
---       { id = "a1", label = "works", status = "pass" },
---       { id = "a2", label = "breaks", status = "fail" },
---     } },
---   } })
---   t:expand("a")            --> { ranges = { { 2, 4 } }, resized = true, rows = 4 }
---   t:rows()[1].agg.status   --> "fail" (the worst status below the root)
---   t:push({ id = "a2", status = "pass" })  --> only the rows whose aggregate changed are reported
---
--- **Node shape** (the same fields a tree provider contract uses): `id` (unique string, required), `label`,
--- `kind`, `status?`, `icon?`, `columns?`, and `children` as a list of nodes, or as a function
--- `children(node, cb)` for lazy children (`cb(list)` or `cb(nil, err)`, called once, synchronous or later).
--- Any other field is the consumer's and is passed through untouched.
---
--- **Fold state** lives in the instance, keyed by id, so it survives a rebuild of a subtree. **Aggregation** is a
--- pluggable function `aggregate(node, child_aggs) -> agg`; the default gives `{ status, counts, total }`: the
--- worst status of the node and of everything below it (by `rank`), the count of leaf statuses and the number of
--- leaves with a status. After a change only the path from the changed node to the root is recomputed, and it
--- stops as soon as an aggregate comes out unchanged.
---
--- **Changes.** Every operation that can change the rows returns (and hands every subscriber) a change
--- `{ ranges = { { from, to }, ... }, resized = boolean, rows = N }`: the 1-based row ranges to redraw, sorted and
--- merged. When `resized` is true the last range runs to the end of the list, because rows after the change moved.
--- `nil` means nothing visible changed. The rows are shared with the tree: read them, never mutate them.

local M = {}

---Deepest nesting a tree may have; a deeper (or cyclic) structure is refused at build time.
---@type integer
M.MAX_DEPTH = 100
---Most nodes one tree may hold.
---@type integer
M.MAX_NODES = 200000

---Default severity of a status for the worst-of aggregation (higher is worse). Unknown statuses rank 0.
---@type table<string, number>
M.RANK = {
  error = 5,
  fail = 4,
  failed = 4,
  warn = 3,
  skip = 2,
  skipped = 2,
  pending = 1,
  pass = 0,
  passed = 0,
  ok = 0,
}

local Tree = {}
Tree.__index = Tree

---@param msg string
local function fail(msg)
  error("lib.nvim.tree: " .. msg, 0)
end

---Structural equality of small data tables (aggregates): scalars by `==`, tables key by key, bounded depth.
---@param a any
---@param b any
---@param depth? integer
---@return boolean
local function deep_equal(a, b, depth)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  depth = depth or 0
  if depth > 8 then
    return false
  end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k], depth + 1) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

---@param opt table|fun(status: any): number|nil
---@return fun(status: any): number
local function make_rank(opt)
  if type(opt) == "function" then
    return function(status)
      return opt(status) or 0
    end
  end
  local map = type(opt) == "table" and opt or M.RANK
  return function(status)
    return map[status] or 0
  end
end

---@param node table
---@return table
local function leaf_agg(node)
  local status = node.status
  if status == nil then
    return { counts = {}, total = 0 }
  end
  return { status = status, counts = { [status] = 1 }, total = 1 }
end

---@param rank fun(status: any): number
---@return fun(node: table, kids: table[]): table
local function default_aggregate(rank)
  return function(node, kids)
    local counts, total = {}, 0
    local worst = node.status
    local worst_rank = worst ~= nil and rank(worst) or nil
    for i = 1, #kids do
      local k = kids[i]
      total = total + (k.total or 0)
      if k.counts then
        for s, n in pairs(k.counts) do
          counts[s] = (counts[s] or 0) + n
        end
      end
      if k.status ~= nil then
        local r = rank(k.status)
        if worst == nil or r > worst_rank then
          worst, worst_rank = k.status, r
        end
      end
    end
    return { status = worst, counts = counts, total = total }
  end
end

---@param node any
local function check_node(node)
  if type(node) ~= "table" then
    fail("a node is not a table")
  end
  if type(node.id) ~= "string" or node.id == "" then
    fail("a node needs a non-empty string id")
  end
  local ch = node.children
  if ch ~= nil and type(ch) ~= "table" and type(ch) ~= "function" then
    fail(("node %q: children must be a list or a function"):format(node.id))
  end
end

---@param rec table
---@return boolean
local function has_children(rec)
  return rec.lazy == true or (rec.kids ~= nil and #rec.kids > 0)
end

---Merge row ranges: sorted, overlapping and adjacent ones joined.
---@param ranges integer[][]
---@return integer[][]
local function merge_ranges(ranges)
  if #ranges <= 1 then
    return ranges
  end
  table.sort(ranges, function(a, b)
    return a[1] < b[1]
  end)
  local out = { { ranges[1][1], ranges[1][2] } }
  for i = 2, #ranges do
    local last, cur = out[#out], ranges[i]
    if cur[1] <= last[2] + 1 then
      if cur[2] > last[2] then
        last[2] = cur[2]
      end
    else
      out[#out + 1] = { cur[1], cur[2] }
    end
  end
  return out
end

-- index and building -------------------------------------------------------------------------------------------

---@param self table
---@param rec table
local function unindex_subtree(self, rec)
  local stack = { rec }
  while #stack > 0 do
    local r = table.remove(stack)
    self.index[r.node.id] = nil
    self.count = self.count - 1
    r.token = nil
    if r.kids then
      for i = 1, #r.kids do
        stack[#stack + 1] = r.kids[i]
      end
    end
  end
end

---@param self table
---@param rec table
local function reindex_subtree(self, rec)
  local stack = { rec }
  while #stack > 0 do
    local r = table.remove(stack)
    self.index[r.node.id] = r
    self.count = self.count + 1
    if r.kids then
      for i = 1, #r.kids do
        stack[#stack + 1] = r.kids[i]
      end
    end
  end
end

---@param self table
---@param rec table
---@return table
local function recompute(self, rec)
  if rec.kids and #rec.kids > 0 then
    local aggs = {}
    for i = 1, #rec.kids do
      aggs[i] = rec.kids[i].agg
    end
    return self.aggregate(rec.node, aggs)
  end
  return self.leaf(rec.node)
end

local start_load

---@param self table
---@param node table
---@param parent table|nil
---@param depth integer
---@return table
local function build(self, node, parent, depth)
  check_node(node)
  if depth > M.MAX_DEPTH then
    fail(
      ("node %q is deeper than MAX_DEPTH (%d); a cyclic structure?"):format(node.id, M.MAX_DEPTH)
    )
  end
  local id = node.id
  if self.index[id] then
    fail(("duplicate node id %q"):format(id))
  end
  if self.count >= M.MAX_NODES then
    fail(("more than MAX_NODES (%d) nodes"):format(M.MAX_NODES))
  end
  local rec = { node = node, parent = parent, depth = depth }
  self.index[id] = rec
  self.count = self.count + 1
  local journal = self.journal
  if journal then
    journal[#journal + 1] = rec
  end
  local ch = node.children
  if type(ch) == "function" then
    rec.lazy = true
    rec.agg = self.leaf(node)
    if self.open[id] then
      start_load(self, rec)
    end
  else
    if type(ch) == "table" then
      local kids = {}
      for i = 1, #ch do
        kids[i] = build(self, ch[i], rec, depth + 1)
      end
      rec.kids = kids
    end
    rec.agg = recompute(self, rec)
  end
  return rec
end

---Replace the children of `rec` with `list`. A child that is the same node table as before keeps its record
---(and with it its loaded state and subtree). On an error the tree is left as it was.
---@param self table
---@param rec table
---@param list table[]
---@return boolean changed  whether the sequence of child records differs from before
local function set_children(self, rec, list)
  local old = rec.kids or {}
  local by_id = {}
  for i = 1, #old do
    by_id[old[i].node.id] = old[i]
  end
  local reuse, removed = {}, {}
  for i = 1, #list do
    local child = list[i]
    local o = type(child) == "table" and by_id[child.id] or nil
    if o and o.node == child then
      reuse[child.id] = o
    end
  end
  for i = 1, #old do
    if reuse[old[i].node.id] ~= old[i] then
      unindex_subtree(self, old[i])
      removed[#removed + 1] = old[i]
    end
  end
  local prev_journal = self.journal
  local journal = {}
  self.journal = journal
  local ok, kids = pcall(function()
    local out = {}
    for i = 1, #list do
      local child = list[i]
      check_node(child)
      local r = reuse[child.id]
      if r then
        reuse[child.id] = nil
        out[i] = r
      else
        out[i] = build(self, child, rec, rec.depth + 1)
      end
    end
    return out
  end)
  self.journal = prev_journal
  if not ok then
    for i = 1, #journal do
      local r = journal[i]
      if self.index[r.node.id] == r then
        self.index[r.node.id] = nil
        self.count = self.count - 1
      end
    end
    for i = 1, #removed do
      reindex_subtree(self, removed[i])
    end
    error(kids, 0)
  end
  local changed = #kids ~= #old
  if not changed then
    for i = 1, #kids do
      if kids[i] ~= old[i] then
        changed = true
        break
      end
    end
  end
  rec.kids = kids
  return changed
end

-- rows -----------------------------------------------------------------------------------------------------------

---@param self table
---@param rec table
---@return table
local function make_row(self, rec)
  local id = rec.node.id
  local kids = has_children(rec)
  return {
    id = id,
    node = rec.node,
    depth = rec.depth - self.base,
    has_children = kids,
    expanded = kids and self.open[id] == true or false,
    loading = rec.loading == true,
    error = rec.load_error,
    agg = rec.agg,
  }
end

---Append the rows of the visible descendants of `rec` (which must be expanded).
---@param self table
---@param rec table
---@param out table[]
local function emit(self, rec, out)
  local kids = rec.kids
  if not kids then
    return
  end
  local open = self.open
  for i = 1, #kids do
    local k = kids[i]
    out[#out + 1] = make_row(self, k)
    if k.kids and #k.kids > 0 and open[k.node.id] then
      emit(self, k, out)
    end
  end
end

---Rebuild the rows of `rec` (its own row and everything visible below it) in place.
---@param self table
---@param rec table
---@return integer|nil from
---@return integer|nil to
---@return boolean|nil resized
local function reflow(self, rec)
  local rows, pos = self.rows, self.pos
  local virtual = rec == self.root and self.virtual
  local n = #rows
  local first, old_end
  local base_depth
  if virtual then
    first, old_end, base_depth = 1, n, -1
  else
    first = pos[rec.node.id]
    if not first then
      return nil
    end
    base_depth = rows[first].depth
    old_end = first
    while old_end < n and rows[old_end + 1].depth > base_depth do
      old_end = old_end + 1
    end
  end
  local new = {}
  if not virtual then
    new[1] = make_row(self, rec)
  end
  if virtual or (rec.kids and #rec.kids > 0 and self.open[rec.node.id]) then
    emit(self, rec, new)
  end
  for i = first, old_end do
    pos[rows[i].id] = nil
  end
  local delta = #new - (old_end - first + 1)
  if delta > 0 then
    for i = n, old_end + 1, -1 do
      rows[i + delta] = rows[i]
    end
  elseif delta < 0 then
    for i = old_end + 1, n do
      rows[i + delta] = rows[i]
    end
    for i = n + delta + 1, n do
      rows[i] = nil
    end
  end
  for i = 1, #new do
    rows[first + i - 1] = new[i]
  end
  local last = delta == 0 and (first + #new - 1) or #rows
  for i = first, last do
    pos[rows[i].id] = i
  end
  return first, math.max(last, first), delta ~= 0
end

-- changes ---------------------------------------------------------------------------------------------------------

---Recompute the aggregate of `rec`, then of its ancestors, stopping when one comes out unchanged.
---@param self table
---@param rec table
---@param changed table[]  records whose aggregate (or own state) changed, appended
local function climb(self, rec, changed)
  local cur = rec
  while cur do
    local new = recompute(self, cur)
    local same = deep_equal(new, cur.agg)
    if not same then
      cur.agg = new
    end
    if cur == rec or not same then
      changed[#changed + 1] = cur
    end
    if same then
      break
    end
    cur = cur.parent
  end
end

---Replace the rows of the changed records that are visible, and return their ranges.
---@param self table
---@param changed table[]
---@param ranges integer[][]
local function refresh(self, changed, ranges)
  for i = 1, #changed do
    local r = self.pos[changed[i].node.id]
    if r then
      self.rows[r] = make_row(self, changed[i])
      ranges[#ranges + 1] = { r, r }
    end
  end
end

---@param self table
---@param ranges integer[][]
---@param resized boolean
---@return table|nil
local function emit_change(self, ranges, resized)
  if #ranges == 0 then
    return nil
  end
  local change = { ranges = merge_ranges(ranges), resized = resized, rows = #self.rows }
  local subs = {}
  for i = 1, #self.subs do
    subs[i] = self.subs[i]
  end
  for i = 1, #subs do
    subs[i](change)
  end
  return change
end

---A lazy node finished (or failed) loading: store the children, recompute the aggregates.
---@param self table
---@param rec table
---@return table[] changed
local function settle(self, rec, list, err)
  rec.loading = false
  rec.token = nil
  local changed = {}
  if err ~= nil or type(list) ~= "table" then
    rec.load_error = tostring(err or "the children callback returned no list")
  else
    local ok, e = pcall(set_children, self, rec, list)
    if ok then
      rec.loaded = true
      rec.load_error = nil
    else
      rec.load_error = tostring(e)
    end
  end
  climb(self, rec, changed)
  return changed
end

---@param self table
---@param rec table
start_load = function(self, rec)
  if rec.loaded or rec.loading then
    return
  end
  rec.loading = true
  rec.load_error = nil
  local token = {}
  rec.token = token
  local settled = false
  rec.starting = true
  local function done(list, err)
    if settled then
      return
    end
    settled = true
    if self.index[rec.node.id] ~= rec or rec.token ~= token then
      return
    end
    local changed = settle(self, rec, list, err)
    if rec.starting then
      rec.sync_changed = changed
      return
    end
    local ranges = {}
    local first, last, resized = reflow(self, rec)
    if first then
      ranges[1] = { first, last }
    end
    refresh(self, changed, ranges)
    emit_change(self, ranges, resized == true)
  end
  local ok, e = pcall(rec.node.children, rec.node, done)
  if not ok then
    done(nil, e)
  end
  rec.starting = nil
end

---Rows plus aggregate rows after a synchronous load inside an operation.
---@param rec table
---@param ranges integer[][]
---@param self table
local function take_sync(self, rec, ranges)
  local changed = rec.sync_changed
  rec.sync_changed = nil
  if changed then
    refresh(self, changed, ranges)
  end
end

-- public ----------------------------------------------------------------------------------------------------------

---@class Lib.Tree.Opts
---@field show_root? boolean  # show the root as the first row (default true); false: its children are the top level
---@field open? string[]  # ids expanded from the start
---@field rank? table<string, number>|fun(status: any): number  # severity of a status for the default aggregate
---@field aggregate? fun(node: table, kids: table[]): table  # replaces the default aggregate of an inner node
---@field leaf? fun(node: table): table  # aggregate of a node without children (default: status and its count)

---Build a tree from `root`. Errors (with a message starting `lib.nvim.tree:`) on a node without an id, a duplicate
---id, a cycle or too many nodes.
---@param root table
---@param opts? Lib.Tree.Opts
---@return table tree
function M.new(root, opts)
  opts = opts or {}
  local rank = make_rank(opts.rank)
  local self = setmetatable({
    index = {},
    open = {},
    rows = {},
    pos = {},
    subs = {},
    count = 0,
    base = 0,
    virtual = opts.show_root == false,
    aggregate = opts.aggregate or default_aggregate(rank),
    leaf = opts.leaf or leaf_agg,
  }, Tree)
  check_node(root)
  for _, id in ipairs(opts.open or {}) do
    if type(id) == "string" then
      self.open[id] = true
    end
  end
  if self.virtual then
    self.base = 1
    self.open[root.id] = true
  end
  self.root = build(self, root, nil, 0)
  if self.virtual then
    for i = 1, #(self.root.kids or {}) do
      -- top level rows start at depth 0
      self.root.kids[i].depth = self.root.kids[i].depth
    end
  end
  local rows = {}
  if self.virtual then
    emit(self, self.root, rows)
  else
    rows[1] = make_row(self, self.root)
    if self.open[root.id] and self.root.kids and #self.root.kids > 0 then
      emit(self, self.root, rows)
    end
  end
  self.rows = rows
  for i = 1, #rows do
    self.pos[rows[i].id] = i
  end
  return self
end

---The visible rows, in order. Shared with the tree: read only.
---@return table[]
function Tree:rows()
  return self.rows
end

---@return integer
function Tree:size()
  return #self.rows
end

---Number of nodes in the tree (visible or not, loaded children only).
---@return integer
function Tree:count_nodes()
  return self.count
end

---@param id string
---@return integer|nil
function Tree:row_of(id)
  return self.pos[id]
end

---@param row integer
---@return table|nil
function Tree:at(row)
  return self.rows[row]
end

---@param id string
---@return table|nil node
function Tree:get(id)
  local rec = self.index[id]
  return rec and rec.node or nil
end

---Aggregate of a node.
---@param id string
---@return table|nil
function Tree:agg(id)
  local rec = self.index[id]
  return rec and rec.agg or nil
end

---Id of the parent of a node, nil for the root or an unknown id.
---@param id string
---@return string|nil
function Tree:parent_id(id)
  local rec = self.index[id]
  return rec and rec.parent and rec.parent.node.id or nil
end

---@param id string
---@return boolean
function Tree:is_open(id)
  return self.open[id] == true
end

---Be told about every change. Returns the function that unsubscribes.
---@param fn fun(change: table)
---@return fun()
function Tree:subscribe(fn)
  self.subs[#self.subs + 1] = fn
  return function()
    for i = #self.subs, 1, -1 do
      if self.subs[i] == fn then
        table.remove(self.subs, i)
      end
    end
  end
end

---Expand a node; a lazy node starts loading its children.
---@param id string
---@return table|nil change
function Tree:expand(id)
  local rec = self.index[id]
  if not rec or not has_children(rec) or (self.virtual and rec == self.root) then
    return nil
  end
  local was_open = self.open[id] == true
  if was_open and not (rec.lazy and not rec.loaded and not rec.loading) then
    return nil
  end
  self.open[id] = true
  if rec.lazy and not rec.loaded then
    start_load(self, rec)
  end
  local ranges = {}
  local first, last, resized = reflow(self, rec)
  if first then
    ranges[1] = { first, last }
  end
  take_sync(self, rec, ranges)
  return emit_change(self, ranges, resized == true)
end

---@param id string
---@return table|nil change
function Tree:collapse(id)
  local rec = self.index[id]
  if not rec or self.open[id] ~= true or (self.virtual and rec == self.root) then
    return nil
  end
  self.open[id] = nil
  local first, last, resized = reflow(self, rec)
  if not first then
    return nil
  end
  return emit_change(self, { { first, last } }, resized == true)
end

---@param id string
---@return table|nil change
function Tree:toggle(id)
  if self.open[id] then
    return self:collapse(id)
  end
  return self:expand(id)
end

---Collapse everything.
---@return table|nil change
function Tree:collapse_all()
  return self:expand_to_depth(0)
end

---Fold to a level: every node whose row depth is below `n` is expanded (a lazy one starts loading), every node at
---`n` or deeper is collapsed. `0` collapses all (the root row stays when `show_root` is true).
---@param n integer
---@return table|nil change
function Tree:expand_to_depth(n)
  local before = #self.rows
  local sync = {}
  for id, rec in pairs(self.index) do
    if not (self.virtual and rec == self.root) then
      if has_children(rec) and rec.depth - self.base < n then
        self.open[id] = true
        if rec.lazy and not rec.loaded then
          start_load(self, rec)
          if rec.sync_changed then
            sync[#sync + 1] = rec
          end
        end
      else
        self.open[id] = nil
      end
    end
  end
  for i = 1, #sync do
    sync[i].sync_changed = nil
  end
  local first, last, resized = reflow(self, self.root)
  if not first then
    return nil
  end
  if not resized and before == #self.rows and first == 1 and last == 0 then
    return nil
  end
  return emit_change(self, { { first, last } }, resized == true)
end

---The owner changed `id`'s node table (or its children list) in place: re-read it, recompute the aggregates along
---the path to the root and report the rows to redraw.
---@param id string
---@return table|nil change
---@return string|nil err
function Tree:invalidate(id)
  local rec = self.index[id]
  if not rec then
    return nil, ("unknown id %q"):format(tostring(id))
  end
  local ch = rec.node.children
  local structural = false
  if type(ch) == "table" then
    if rec.lazy then
      rec.lazy, rec.loaded, rec.loading, rec.token = nil, nil, nil, nil
    end
    structural = set_children(self, rec, ch)
  elseif type(ch) == "function" then
    if not rec.lazy then
      if rec.kids then
        for i = 1, #rec.kids do
          unindex_subtree(self, rec.kids[i])
        end
      end
      rec.kids, rec.lazy, rec.loaded = nil, true, nil
      structural = true
    end
  elseif rec.kids or rec.lazy then
    if rec.kids then
      for i = 1, #rec.kids do
        unindex_subtree(self, rec.kids[i])
      end
    end
    rec.kids, rec.lazy, rec.loaded, rec.loading, rec.token = nil, nil, nil, nil, nil
    structural = true
  end
  local changed = {}
  climb(self, rec, changed)
  local ranges, resized = {}, false
  if structural then
    if rec.lazy and not rec.loaded and self.open[id] then
      start_load(self, rec)
    end
    local first, last, rs = reflow(self, rec)
    if first then
      ranges[1] = { first, last }
      resized = rs == true
    end
    take_sync(self, rec, ranges)
  end
  refresh(self, changed, ranges)
  return emit_change(self, ranges, resized), nil
end

---Merge fields into a node and invalidate it. `update.id` names the node; every other field (a new `status`, a new
---`children` list, ...) is written onto the node table.
---@param update table
---@return table|nil change
---@return string|nil err
function Tree:push(update)
  if type(update) ~= "table" or type(update.id) ~= "string" then
    return nil, "an update needs a string id"
  end
  local rec = self.index[update.id]
  if not rec then
    return nil, ("unknown id %q"):format(update.id)
  end
  for k, v in pairs(update) do
    if k ~= "id" then
      rec.node[k] = v
    end
  end
  return self:invalidate(update.id)
end

---Load the children of a lazy node again.
---@param id string
---@return table|nil change
---@return string|nil err
function Tree:reload(id)
  local rec = self.index[id]
  if not rec then
    return nil, ("unknown id %q"):format(tostring(id))
  end
  if not rec.lazy then
    return nil, ("%q has no lazy children"):format(id)
  end
  if rec.kids then
    for i = 1, #rec.kids do
      unindex_subtree(self, rec.kids[i])
    end
  end
  rec.kids, rec.loaded, rec.loading, rec.token = nil, nil, nil, nil
  rec.load_error = nil
  local changed = {}
  climb(self, rec, changed)
  if self.open[id] then
    start_load(self, rec)
  end
  local ranges = {}
  local first, last, resized = reflow(self, rec)
  if first then
    ranges[1] = { first, last }
  end
  take_sync(self, rec, ranges)
  refresh(self, changed, ranges)
  return emit_change(self, ranges, resized == true), nil
end

---Number of lazy nodes that are loading right now.
---@return integer
function Tree:pending()
  local n = 0
  for _, rec in pairs(self.index) do
    if rec.loading then
      n = n + 1
    end
  end
  return n
end

---Drop the subscribers and ignore callbacks of loads still running.
function Tree:destroy()
  self.subs = {}
  for _, rec in pairs(self.index) do
    rec.token = nil
  end
end

return M
