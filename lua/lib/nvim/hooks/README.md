# `lib.nvim.hooks`

Hook registry for a pipeline with named stages (`before_apply`, `after_apply`, `before_write`,
`after_write`, ...): callbacks run in a defined order, a `before_*` hook can veto the step, and a throwing
hook never stops the others or the pipeline. Extracted from `replacer.nvim`; meant for any plugin with an
apply pipeline (`migrate.nvim`, `pdfport.nvim`).

Every plugin makes its own registry with `new`, so two plugins never share hooks.

## Usage

```lua
local hooks = require("lib.nvim.hooks")

local reg = hooks.new({
  events = { "before_apply", "after_apply", "before_write", "after_write" },
})

-- register (returns the unregister function)
local off = reg.on("before_apply", function(ctx)
  if ctx.file:match("%.min%.js$") then
    return false -- veto: skip this file
  end
end)

-- in the pipeline
local proceed = reg.run("before_apply", { file = file }, cfg.hooks and cfg.hooks.before_apply)
if not proceed then
  return
end
-- ... apply ...
reg.run("after_apply", { file = file })
```

## API

| Call | Meaning |
|---|---|
| `hooks.new(opts)` | New registry. `opts.events` (required): the event names. `opts.vetoable`: events whose hooks can veto, default the ones named `before_*`. `opts.short_circuit`: stop at the first veto. `opts.on_error(event, err, fn)`: replaces the default `vim.notify` WARN. |
| `reg.on(event, fn, { priority? })` | Register `fn` (`priority` must be a number); returns a function that unregisters exactly this registration. |
| `reg.off(event, fn)` | Remove the first registration of `fn`; returns whether one was removed. |
| `reg.clear(event?)` | Remove the registrations of one event, or of all. |
| `reg.count(event)` | Number of registered hooks of an event. |
| `reg.run(event, ctx, extra?)` | Run the hooks; returns `proceed, errors`. `extra` is a function or a list of functions (the plugin's `config.hooks`), run before the registered ones. |

An unknown event name is an error in every call (a typo fails loudly instead of never firing).

## Behaviour

- **Order:** the `extra` hooks of `run` first, then the registered ones by ascending `priority` (default 0),
  equal priorities in registration order.
- **Veto:** a hook of a vetoable event that returns exactly `false` vetoes; `run` returns `proceed = false`.
  Every other hook still runs (a later hook may be a cleanup that must see the event) unless
  `short_circuit = true`. A `false` from a non-vetoable event is ignored.
- **Errors:** a throwing hook is passed to `on_error` and counted in the second result; it never vetoes and
  never stops the pass. An entry of `extra` that is not callable counts the same way (a typo in a plugin's
  config is reported, not dropped). A throwing `on_error` does not escape either.
- **Snapshot:** a hook that registers or removes hooks changes the next run, not the running one.
- **Storage:** the registered hooks of an event live in a [`lib.lua.listeners`](../../lua/listeners/README.md) list (O(1) unregister, no array shifting); ordering by priority, veto, `short_circuit` and error isolation are `hooks`' own. `TESTS/hooks_equivalence_spec.lua` compares it with the original implementation over randomized operation sequences.
