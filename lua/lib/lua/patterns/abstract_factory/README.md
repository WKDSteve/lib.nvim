# `lib.lua.patterns.abstract_factory`

> Pattern: Abstract Factory · Group: creational · Stage: `idea`
> Status: idea pool — may bring no benefit in Lua, kept as a reference.

Families of constructors that always come as a matching set; construction fails if the families do not provide the same products.

## The pattern in one paragraph

Code is written against a set of products (border, icon, ...) and a family decides which concrete versions are used. The factory guarantees that every family provides the same product names, so switching the family cannot leave a hole.

## Usage

```lua
local abstract_factory = require("lib.lua.patterns.abstract_factory")

local ui = abstract_factory.new({
  ascii = { border = function() return "+-+" end, icon = function() return "*" end },
  nerd = { border = function() return "round" end, icon = function() return "N" end },
})
ui:create("ascii", "icon")
ui:family("nerd").border()
```

## API

| Function | Does |
| --- | --- |
| `new(families)` | checks equal product sets and function values; keeps its own copy of the table |
| `f:names()` | sorted family names |
| `f:family(name)` | the constructor table |
| `f:create(name, product, ...)` | build one product |

## When it helps / when it does not (Lua view)

- **Helps when:** two or more constructors must change together (a theme, a storage backend) and mixing families would be a bug.
- **Does not help when:** only one product varies; `factory_method` or a plain table is enough. Most plugin themes are just data tables.
- **Cheaper alternative in Lua:** one table per family plus a check in a test.

## Related

- `lib.lua.patterns.factory_method`, Strategy, `lib.nvim.ui.nerd_font` (glyph sets gated on a declaration).

## Tests

`TESTS/patterns_abstract_factory_spec.lua`: create, family access, unknown family/product, mismatched families, non-function products.
