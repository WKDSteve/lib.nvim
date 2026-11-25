# `lib.nvim.patterns.retry_backoff`

> Pattern: Retry with backoff · Group: modern · Stage: `impl`

Call a callback-style task again after growing delays until it succeeds or the attempts run out.

## The pattern in one paragraph

Transient failures (a busy file, a flaky request) often pass if you wait a moment. The delay grows per attempt (`base_ms * factor^(attempt-1)`, capped at `max_ms`, optionally with jitter) so the retry neither hammers the resource nor gives up at once. The wait is non-blocking.

## Usage

```lua
local retry = require("lib.nvim.patterns.retry_backoff")

retry.run(function(attempt, done)
  fetch(url, function(err, body) done(err == nil, err or body) end)
end, {
  max_attempts = 4,
  base_ms = 200,
  should_retry = function(err) return err ~= "404" end,
  on_done = function(ok, value_or_err, attempts) end,
})
```

## API

| Function | Does |
| --- | --- |
| `run(task, opts)` | `task(attempt, done)`; `opts`: `max_attempts` (5), `base_ms` (100), `factor` (2), `max_ms` (10000), `jitter`, `should_retry(err, attempt)`, `on_done(ok, res, attempts)`, `sleep(ms, cb)` |
| `delay(attempt, opts)` | the wait after failed attempt `attempt` |

A task that raises counts as a failure; a second `done` call is ignored. A raising `should_retry` means "do not retry" (`on_done` still gets the failure); an error raised by `on_done` or `sleep` is re-raised to the caller, never swallowed.

## When it helps / when it does not (Lua view)

- **Helps when:** the operation fails transiently and the caller cannot simply be run again by the user.
- **Does not help when:** the failure is permanent (bad input); use `should_retry` to stop at once, or do not retry. For synchronous file retries see `lib.nvim.cross.fs.mutate`.
- **Cheaper alternative in Lua:** a fixed single retry after `vim.defer_fn`.

## Related

- `lib.lua.patterns.circuit_breaker` (stop calling after repeated failure), `lib.nvim.cross.fs.mutate` (sync retry on Windows sharing errors), `lib.nvim.async`.

## Tests

`TESTS/patterns_retry_backoff_spec.lua`: delay growth/cap/jitter, success after retries, give-up, `should_retry`, raising task, double `done`.
