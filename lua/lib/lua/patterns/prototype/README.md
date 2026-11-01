# `lib.lua.patterns.prototype`

> Pattern: Prototype · Group: creational · Stage: `impl`

Create objects by cloning a template: `clone(overrides)` returns an independent deep copy with the overrides merged in.

## The pattern in one paragraph

Instead of building each object from scratch, copy a prepared one and change the differences. `deepcopy` here handles cycles and keeps metatables; nested override tables merge, other values replace.

## Usage

```lua
local prototype = require("lib.lua.patterns.prototype")

local base = prototype.new({ width = 80, theme = { fg = "white", bg = "black" } })
local dark = base:clone({ theme = { bg = "blue" } }) --> width 80, fg white, bg blue
```

## API

| Function | Does |
| --- | --- |
| `new(template)` | keeps its own copy of the template |
| `p:clone(overrides)` | independent deep copy plus merged overrides |
| `deepcopy(v)` | standalone deep copy with cycle protection |

## When it helps / when it does not (Lua view)

- **Helps when:** many similar configuration-like objects differ in a few fields, and sharing nested tables by accident would be a bug.
- **Does not help when:** Neovim's `vim.deepcopy` and `vim.tbl_deep_extend` are available and enough; this module exists for code that must stay editor-independent.
- **Limit:** `deepcopy` and the override merge are recursive without a depth limit: a very deep table ends in a stack overflow (a catchable error). Cycles are handled.
- **Cheaper alternative in Lua:** `setmetatable({}, { __index = proto })` shares instead of copying.

## Related

- `lib.lua.class` (prototype-style inheritance), `lib.lua.config` (`deep_merge`), Flyweight (share instead of copy).

## Tests

`TESTS/patterns_prototype_spec.lua`: independence of clones, template snapshot, override merge, cycles, metatables.
