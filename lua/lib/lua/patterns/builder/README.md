# `lib.lua.patterns.builder`

> Pattern: Builder · Group: creational · Stage: `impl`

Collect options step by step through fluent setters, validate once in `build()`.

## The pattern in one paragraph

A product with many optional parts is assembled by a builder instead of a constructor with a dozen parameters. The builder holds the partial state, checks required fields and validators in one place, and `build()` returns the finished table or `nil, err`.

## Usage

```lua
local builder = require("lib.lua.patterns.builder")

local new_cmd = builder.new({
  name = { required = true },
  nargs = { default = 0, validate = function(v) return type(v) == "number" end },
})
local cmd, err = new_cmd():name("Foo"):nargs(1):build()
```

## API

| Function | Does |
| --- | --- |
| `new(schema)` | returns a constructor; each call yields a fresh builder; field entries: `default`, `required`, `validate`; keeps its own copy of the schema; a `validate` that raises makes `build()` return `nil, err` |
| `b:<field>(v)` / `b:set(name, v)` | set a field, chainable; unknown field raises |
| `b:get(name)` | value or default |
| `b:build()` | `product` or `nil, err` (missing required / failed validator) |

## When it helps / when it does not (Lua view)

- **Helps when:** a product has many optional parts with defaults and cross-checks, or is assembled over several steps (command definitions, window specs).
- **Does not help when:** an `opts` table with defaults is enough, which is the normal Lua form (`lib.lua.config`).
- **Cheaper alternative in Lua:** `vim.tbl_deep_extend("force", defaults, opts)` plus a validation function.

## Related

- `lib.nvim.bindings.usercmd.composer` (its `make_builder` is a fluent builder), `lib.lua.config`, Factory Method.

## Tests

`TESTS/patterns_builder_spec.lua`: setters, defaults, required, validators, unknown/reserved names, isolation between builders.
