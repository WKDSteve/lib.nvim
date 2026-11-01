# `lib.lua.patterns.dependency_injection`

> Pattern: Dependency Injection · Group: modern · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.

A small container: `provide(name, factory)`, `value(name, v)`, `resolve(name)` (cached, or `transient`), `child()` for overlays.

## The pattern in one paragraph

A component receives its collaborators instead of requiring them itself, so tests can pass fakes and wiring lives in one place. The container builds on first use, caches singletons, detects cycles and lets a child overlay replace single entries without touching the parent.

## Usage

```lua
local di = require("lib.lua.patterns.dependency_injection")

local c = di.new()
c:value("config", { root = "." })
c:provide("scanner", function(k) return make_scanner(k:resolve("config")) end)
c:resolve("scanner")

local test = c:child()
test:value("config", { root = "/tmp" })
```

## API

| Function | Does |
| --- | --- |
| `new(parent)` | container |
| `c:provide(name, factory, opts)` / `c:value(name, v)` | register (`opts.transient`) |
| `c:resolve(name)` / `c:has(name)` / `c:child()` | use |

## When it helps / when it does not (Lua view)

- **Helps when:** one setup wires many parts together and tests replace some of them; the `require`d module is hard to fake.
- **Does not help when:** a plain `opts.scanner or require("my.scanner")` parameter covers it, which is the usual Lua form.
- **Cheaper alternative in Lua:** pass the collaborator as an argument; `package.loaded` stubbing in tests.

## Related

- `lib.nvim.registry` (keyed entries registered from outside), Factory Method, Singleton.

## Tests

`TESTS/patterns_dependency_injection_spec.lua`: caching, transient, child overlay, cycles, failing factories.

## Note on child containers

A child resolves names it does not hold through its parent, and the parent's factories run against the parent. To change what a parent-provided service sees, provide that service again in the child (as the usage example does for `config` and `scanner`); overriding only `config` in the child does not rewire a `scanner` the parent already built.
