# `lib.lua.patterns.factory_method`

> Pattern: Factory Method · Group: creational · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.

`create(kind, ...)` picks the constructor from a table instead of an if/elseif chain.

## The pattern in one paragraph

The caller names what it wants; which constructor builds it is decided by the factory. In Lua the "subclass per product" of the textbook becomes a table `kind -> function`, which can grow by `register` without touching the factory.

## Usage

```lua
local factory_method = require("lib.lua.patterns.factory_method")

local make = factory_method.new({
  md = function(path) return { kind = "md", path = path } end,
  pdf = function(path) return { kind = "pdf", path = path } end,
}, { default = function(path) return { kind = "raw", path = path } end })

make:create("pdf", "a.pdf")
make:register("png", function(path) return { kind = "png", path = path } end)
make:kinds() --> { "md", "pdf", "png" }
```

## API

| Function | Does |
| --- | --- |
| `new(ctors, opts)` | `opts.default` handles unknown kinds |
| `f:register(kind, ctor)` | add or replace, chainable |
| `f:create(kind, ...)` | build; unknown kind uses `default` or raises |
| `f:kinds()` | copy of the kind list (initial ones sorted, later ones in registration order) |

## When it helps / when it does not (Lua view)

- **Helps when:** an if/elseif ladder on a type string appears in more than one place, or other modules should be able to add kinds.
- **Does not help when:** there are two fixed kinds; a conditional is clearer.
- **Cheaper alternative in Lua:** a bare table `local ctors = { md = fn }` and `ctors[kind](...)`. `lib.nvim.registry` adds ordering and validation when entries register themselves.

## Related

- `lib.nvim.registry`, Strategy, Abstract Factory. The Index lists several such ladders in `casedesk.nvim` (`clipboard.lua`) and `cmdlog.nvim` (`shell.lua`).

## Tests

`TESTS/patterns_factory_method_spec.lua`: create, args, unknown kind, register, kinds copy, default.
