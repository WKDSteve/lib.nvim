# `lib.lua.patterns.visitor`

> Pattern: Visitor · Group: behavioral · Stage: `idea`
> Status: idea pool — may bring no benefit in Lua, kept as a reference.

Operations over a node structure from outside: one handler per node kind, plus a depth-first `walk`.

## The pattern in one paragraph

Instead of adding a method to every node class, a visitor holds one handler per kind and is applied to nodes. `new(handlers, opts)` dispatches on `node.type` (or `opts.kind(node)`) with `opts.default` as fallback; `walk(root, children, fn)` visits pre-order with depth, and `fn` returning `false` skips that subtree.

## Usage

```lua
local visitor = require("lib.lua.patterns.visitor")

local describe = visitor.new({
  heading = function(n) return "# " .. n.text end,
}, { default = function(n) return "<" .. n.type .. ">" end })

visitor.walk(tree, function(n) return n.children end, function(n, depth) print(depth, n.type) end)
```

## API

| Function | Does |
| --- | --- |
| `new(handlers, opts)` | `visit(node, ...)`; no handler and no default raises |
| `walk(root, children, fn)` | pre-order walk, `fn(node, depth)` |

## When it helps / when it does not (Lua view)

- **Helps when:** several independent operations (print, count, validate, transform) run over the same node tree and should live apart from the node definitions.
- **Does not help when:** Lua tables are open and `handlers[node.type](node)` already is the visitor; the tree walk is a few lines. This module may bring no benefit beyond naming the idea.
- **Limit:** `walk` is recursive and does not detect cycles: a graph with a cycle ends in a stack overflow (a catchable error). Walk trees, or keep your own visited set.
- **Cheaper alternative in Lua:** a recursive function with a handler table.

## Related

- `lib.lua.patterns.interpreter` (rules per node type that evaluate), Iterator, `lib.nvim.treesitter` (tree access).

## Tests

`TESTS/patterns_visitor_spec.lua`: dispatch by kind, extra arguments, default, custom kind, pre-order depth, skipping subtrees.
