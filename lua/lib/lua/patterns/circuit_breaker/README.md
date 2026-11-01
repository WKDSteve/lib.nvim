# `lib.lua.patterns.circuit_breaker`

> Pattern: Circuit Breaker · Group: modern · Stage: `idea`
> Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.

After `threshold` consecutive failures stop calling a function for `reset_ms`, then allow one probe.

## The pattern in one paragraph

A failing dependency (network, external tool) is not hammered on every keystroke. The breaker is *closed* while calls work, *open* after too many failures (calls are refused at once), and *half-open* after the pause: one probe decides whether it closes again or opens again.

## Usage

```lua
local circuit_breaker = require("lib.lua.patterns.circuit_breaker")

local breaker = circuit_breaker.new({ threshold = 3, reset_ms = 30000 })
local ok, value_or_err = breaker:call(fetch, url)
-- circuit open: ok == false, value_or_err == "circuit open"
breaker:state() --> "closed" | "open" | "half_open"
```

## API

| Function | Does |
| --- | --- |
| `new(opts)` | `threshold` (5), `reset_ms` (30000), `now` (ms clock, injectable), `on_change(new, old)` |
| `b:call(fn, ...)` | `true, result` or `false, err`; `false, "circuit open"` when refused |
| `b:state()` | current state (an open circuit past its pause reports `half_open`) |
| `b:reset()` | force closed |

## When it helps / when it does not (Lua view)

- **Helps when:** a call to something that can be down is triggered often (completion sources, status polling, remote lookups) and each failure is slow.
- **Does not help when:** the call is user-triggered once; just show the error. Not a retry mechanism either: it stops calling, `retry_backoff` calls again.
- **Cheaper alternative in Lua:** a `disabled_until` timestamp next to the call.

## Related

- `lib.nvim.patterns.retry_backoff` (retry with growing delay), `lib.nvim.debounce`.

## Tests

`TESTS/patterns_circuit_breaker_spec.lua`: closed/open/half-open cycle with an injected clock, probe success and failure, reset, state-change callback.
