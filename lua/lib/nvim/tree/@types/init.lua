---@meta
---@module 'lib.nvim.tree.@types'

---A node as the consumer supplies it. The tree keeps the table and merges updates into it.
---@class Lib.Tree.Node
---@field id any unique in the tree (string or number)
---@field label string
---@field kind? string
---@field status? string leaf status; branches get an aggregated one (see `Lib.Tree.Agg`)
---@field icon? string
---@field columns? table
---@field children? Lib.Tree.Node[]|fun(node: Lib.Tree.Node, cb: fun(children: Lib.Tree.Node[]|nil, err?: string)) a list, or a lazy loader called on the first expand (sync or async answer)

---Aggregate of the leaves below a node.
---@class Lib.Tree.Agg
---@field status string|nil worst status (by `opts.severity`), nil when no leaf has one
---@field counts table<string, integer> leaves per status
---@field total integer leaves below (a leaf counts itself)

---One visible line.
---@class Lib.Tree.Row
---@field id any
---@field node Lib.Tree.Node
---@field depth integer 0 for the first visible level
---@field expandable boolean has children, or may have (lazy)
---@field expanded boolean
---@field loading boolean a lazy load is running
---@field error? string the lazy load failed
---@field agg Lib.Tree.Agg

---Replace `old_count` rows from `from` by `new_count` rows (read them back with `tree:row(i)`). Applied in order.
---@class Lib.Tree.Splice
---@field from integer 1-based
---@field old_count integer
---@field new_count integer

---@class Lib.Tree.Update
---@field id any
---@field label? string
---@field kind? string
---@field status? string
---@field icon? string
---@field columns? table
---@field children? Lib.Tree.Node[] replaces the subtree

---@class Lib.Tree.Opts
---@field root Lib.Tree.Node
---@field hide_root? boolean the root is not a row; its children are the first level (default false)
---@field expanded? table<any, true> ids open from the start
---@field severity? string[] statuses, worst first (default error, failed, fail, running, pending, warn, skipped, passed, ok)
---@field aggregate? fun(node: Lib.Tree.Node, child_aggs: Lib.Tree.Agg[], default: Lib.Tree.Agg): Lib.Tree.Agg replaces the default rule
---@field on_change? fun(changes: Lib.Tree.Splice[]) called when an async lazy load finished (sync changes are returned)

---@class Lib.Tree.Entry
---@field id any
---@field node Lib.Tree.Node
---@field parent any|nil
---@field depth integer
---@field state "leaf"|"loaded"|"lazy"|"loading"|"error"
---@field kids? any[]
---@field err? string
---@field agg Lib.Tree.Agg

---@class Lib.Tree
---@field _by_id table<any, Lib.Tree.Entry>
---@field _rows Lib.Tree.Row[]
---@field _row_of table<any, integer>
---@field _expanded table<any, boolean>
---@field _rank table<string, integer>
---@field _aggregate? function
---@field _on_change? function
---@field _root any
---@field _size integer
---@field _shift integer
---@field _hide_root boolean
---@field refresh fun(self: Lib.Tree)
---@field count fun(self: Lib.Tree): integer
---@field row fun(self: Lib.Tree, i: integer): Lib.Tree.Row|nil
---@field rows fun(self: Lib.Tree): Lib.Tree.Row[]
---@field row_of fun(self: Lib.Tree, id: any): integer|nil
---@field node fun(self: Lib.Tree, id: any): Lib.Tree.Node|nil
---@field agg fun(self: Lib.Tree, id: any): Lib.Tree.Agg|nil
---@field parent fun(self: Lib.Tree, id: any): any|nil
---@field size fun(self: Lib.Tree): integer
---@field is_expanded fun(self: Lib.Tree, id: any): boolean
---@field expand fun(self: Lib.Tree, id: any): Lib.Tree.Splice[]
---@field collapse fun(self: Lib.Tree, id: any): Lib.Tree.Splice[]
---@field toggle fun(self: Lib.Tree, id: any): Lib.Tree.Splice[]
---@field reveal fun(self: Lib.Tree, id: any): Lib.Tree.Splice[]
---@field collapse_all fun(self: Lib.Tree): Lib.Tree.Splice[]
---@field set_depth fun(self: Lib.Tree, n: integer): Lib.Tree.Splice[]
---@field set_children fun(self: Lib.Tree, id: any, list: Lib.Tree.Node[]): Lib.Tree.Splice[]
---@field merge_children fun(self: Lib.Tree, id: any, list: Lib.Tree.Node[]): Lib.Tree.Splice[]
---@field remove fun(self: Lib.Tree, id: any): Lib.Tree.Splice[]
---@field push fun(self: Lib.Tree, update: Lib.Tree.Update): Lib.Tree.Splice[]
---@field invalidate fun(self: Lib.Tree, id: any, deep?: boolean): Lib.Tree.Splice[]

return {}
