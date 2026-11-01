# `lib.lua.patterns.template_method`

> Pattern: Template Method · Group: behavioral · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.

A fixed skeleton whose steps the implementer supplies; missing or unknown steps fail at `implement()`, not at the first run.

## The pattern in one paragraph

The skeleton (`run(step, ...)`) decides the order; implementers fill in steps. Steps are `required` or have a `default`. Instead of subclassing, `implement(impl)` returns a plain function, so no class is needed.

## Usage

```lua
local template_method = require("lib.lua.patterns.template_method")

local import = template_method.define({
  steps = {
    read = { required = true },
    parse = { required = true },
    validate = { default = function(data) return data end },
  },
  run = function(step, source) return step.validate(step.parse(step.read(source))) end,
})
local import_json = import.implement({ read = read_file, parse = vim.json.decode })
```

## API

| Function | Does |
| --- | --- |
| `define(spec)` | `steps`, `run(steps, ...)`; returns `{ implement }` |
| `implement(impl)` | checks required/unknown/non-function steps; returns the runnable skeleton |

## When it helps / when it does not (Lua view)

- **Helps when:** several variants share one algorithm and differ in two or three steps (importers, analyzers, backends with the same flow). The Index lists three near-identical analyzers in `recommender.nvim`.
- **Does not help when:** there is one variant, or the "steps" are just options; pass the functions as parameters.
- **Cheaper alternative in Lua:** a function that takes the step functions as arguments, or `lib.lua.class` with `extend` for real class hierarchies.

## Related

- `lib.lua.class`, Strategy (the whole algorithm is swapped, not its steps).

## Tests

`TESTS/patterns_template_method_spec.lua`: order, defaults, own step, missing/unknown/invalid step, independent implementations.
