---@meta
---@module 'lib.nvim.tree.registry.@types'

---@alias Lib.Tree.Registry.Kind "source"|"decorator"|"action"

---What a reader hands an entry when it calls it: which view, which root. The reader defines the fields.
---@alias Lib.Tree.Registry.Ctx table

---Supplies the nodes of one view.
---@class Lib.Tree.Registry.Source
---@field name string unique among sources; also the name of the view
---@field title? string shown where views are listed
---@field icon? string
---@field root fun(ctx: Lib.Tree.Registry.Ctx): Lib.Tree.Node
---@field children? fun(node: Lib.Tree.Node, ctx: Lib.Tree.Registry.Ctx, cb: fun(list?: Lib.Tree.Node[], err?: string)) lazy children for nodes that carry none of their own; answers like a node's own `children`
---@field subscribe? fun(ctx: Lib.Tree.Registry.Ctx, emit: Lib.Tree.Registry.Emit): fun() live updates while a view shows the source; returns unsubscribe
---@field actions? Lib.Tree.Registry.Action[] actions that only make sense in this source
---@field severity? string[] statuses, worst first (see `Lib.Tree.Opts.severity`)
---@field aggregate? fun(node: Lib.Tree.Node, child_aggs: Lib.Tree.Agg[], default: Lib.Tree.Agg): Lib.Tree.Agg
---@field preview? fun(node: Lib.Tree.Node, ctx: Lib.Tree.Registry.Ctx): table|nil
---@field available? fun(): boolean, string? false plus a reason when the source cannot load right now

---How a source reports changes to the view that shows it.
---@class Lib.Tree.Registry.Emit
---@field push fun(update: Lib.Tree.Update) one node changed (status, label, columns)
---@field invalidate fun(id: any, deep?: boolean) the children of a node must be asked again
---@field reset fun() the root changed

---A badge on a node.
---@class Lib.Tree.Registry.Badge
---@field text? string
---@field hl? string highlight group
---@field status? string feeds `roll_up`
---@field count? integer

---Badges on nodes, looked up by path or id.
---@class Lib.Tree.Registry.Decorator
---@field name string unique among decorators
---@field key? "path"|"id" what `get` is asked with (default "path")
---@field slot? "name"|"sign"|"badge"|"column"|"line" where it is drawn (default "badge")
---@field priority? integer higher survives when the window is narrow (default 0)
---@field get fun(key: string, node?: Lib.Tree.Node): Lib.Tree.Registry.Badge|nil a cache lookup; it runs while drawing and must do no I/O. A reader may hand the node of the row it draws
---@field subscribe fun(emit: fun(keys?: string[])): fun() tell which keys changed (nil: everything); returns unsubscribe
---@field all? fun(): table<string, Lib.Tree.Registry.Badge> every key that has a badge right now; what lets a reader add up a folder that was never opened, and what it re-reads after `emit()` without keys
---@field roll_up? "worst"|"count"|"any"|false how it shows on a folder (default false)
---@field severity? string[] statuses, worst first, for `roll_up = "worst"`

---One named parameter of an action.
---@class Lib.Tree.Registry.ActionArg
---@field desc? string
---@field values? string[] the allowed values; absent: free text
---@field default? string

---Something to do with the node under the cursor, or with the selection.
---@class Lib.Tree.Registry.Action
---@field name string unique among actions
---@field desc? string one line for the cheatsheet, the menu and a command catalog
---@field key? string|string[] default key(s) in the tree buffer
---@field needs? string[] where it applies: "path", "file", "dir", "mutable", "kind:<k>", "source:<s>"
---@field when? fun(node: Lib.Tree.Node, ctx: Lib.Tree.Registry.Ctx): boolean for what `needs` cannot say
---@field priority? integer among actions on the same key that apply (default 0)
---@field args? table<string, Lib.Tree.Registry.ActionArg> named parameters
---@field mutates? boolean it changes files: a reader asks before it runs one on somebody's behalf
---@field ai? boolean false keeps it out of a command catalog handed to a model (default true)
---@field run fun(nodes: Lib.Tree.Node[], ctx: Lib.Tree.Registry.Ctx, args?: table<string, string>)

---What `subscribe` reports.
---@class Lib.Tree.Registry.Event
---@field kind Lib.Tree.Registry.Kind
---@field name string
---@field entry? table the registered entry; nil for a removal
---@field replaced? boolean the name was taken before this registration

return {}
