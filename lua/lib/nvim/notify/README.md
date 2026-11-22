# `lib.nvim.notify`

## Table of content

- [`lib.nvim.notify`](#libnvimnotify)
  - [Example: usage in a module](#example-usage-in-a-module)
  - [Example: another module, another prefix](#example-another-module-another-prefix)
  - [`popup = true`](#popup--true-toast-instead-of-messages)
    - [Configuring the toast (cap, min level, timeouts)](#configuring-the-toast-cap-min-level-timeouts)
    - [Global default: `notify.setup({ popup = true })`](#global-default-notifysetup-popup--true)
    - [Full text: `expand_last()` and the history's `<C-s>` toggle](#full-text-expand_last-and-the-historys-c-s-toggle)
    - [`:Lib notify last | history | dismiss | clear`](#lib-notify-last--history--dismiss--clear)
  - [`lib.nvim.notify.safe`](#libnvimnotifysafe)
    - [When is `lib.nvim.notify.safe` needed](#when-is-libnvimnotifysafe-needed)
    - [`safe.schedule`](#safeschedule)
    - [`safe.defer`](#safedefer)
    - [`safe.wrap`](#safewrap)
    - [`safe.notify`](#safenotify)
    - [`safe.create_safe(prefix)`](#safecreate_safeprefix)
    - [Recommended usage](#recommended-usage)
  - [Design properties](#design-properties)

---

## Example: usage in a module

```lua
---@module 'neotree_fs_refactor.core'

local notify = require("lib.nvim.notify").create("[neotree-fs-refactor]")

notify.info("Refactor started")
notify.warn("Some paths could not be updated")
notify.error("LSP rename failed")
```

---

## Example: another module, another prefix

```lua
---@module 'config.lsp.setup'

local notify = require("lib.nvim.notify").create("[lsp]")

notify.debug("Attaching server")
```

---

## `popup = true`: toast instead of `:messages`

On a plain Neovim UI `vim.notify` is `nvim_echo`, so long or multi-line text
(a rejected `git push`, say) pops up as a more-prompt. With `popup = true` the
message becomes a non-focus-stealing corner toast (`ui.kit.toast` from
ui.nvim, soft dependency) colored by level, and is kept in a yankable history:

```lua
local notify = require("lib.nvim.notify").create("[myplugin]", { popup = true, source = "myplugin" })
notify.error("push failed\n...")

local popup = require("lib.nvim.notify").popup
popup.show_history("myplugin") -- scratch buffer, `q` closes
popup.clear("myplugin")
```

A message is recorded in the popup's own history unconditionally --
`popup.show_history()`/`:Lib notify history`/`:Lib notify last` always have
the full text -- but is **not** also written to real `:messages` by default:
there is no Neovim API to add one to `:messages` without a plain `nvim_echo`
also briefly echoing it on screen (`'more'` toggled off around the call, so
it can at least never block on a `--More--` prompt), and that flash, on top
of a chip that already showed the same message, read as a second, confusing
notification for anything that notifies often (a git dashboard's pull/push,
say). Opt a notifier, a call, or the whole module back into real `:messages`
(e.g. for something that must show up there, or for a `noice.nvim` setup
reading from it) with `messages = true`:

```lua
require("lib.nvim.notify").create("[p]", { popup = true, messages = true })
popup.deliver("x", vim.log.levels.INFO, { messages = true })
popup.setup({ messages = true }) -- restores the pre-2026-09-29 default everywhere
```

The message is handed to plain `vim.notify` instead when `ui.notify` is
enabled (it already renders toasts) or when no toast can be shown, so a
message is never lost -- and in both cases `opts.title` (see below) still
reaches it, for a rich `vim.notify` backend to render.

**Without ui.nvim**, a one-line message stays a plain echo (`vim.notify`). A
multi-line one gets lib.nvim's own toast (`lib.nvim.ui.kit.toast`, which
`ui.kit.toast` re-exports): as an echo it would stop the editor at a
hit-enter prompt whenever it comes from a callback (an async git answer)
rather than from inside a command. This toast has **no time limit**: it is
often command output meant to be read (a `--dry-run` plan), so it stays until
it is closed with `:Lib notify dismiss` (or `popup.dismiss()`, e.g. from a
keymap of your own). It needs no key and never takes focus, and the full text
stays in the history (`:Lib notify last`). A caller that passes its own
`timeout` still gets that one.

**Specs that stub `vim.notify`** and read a multi-line message's text turn
this fallback off, so the message reaches `vim.notify` in full again:

```lua
local popup = require("lib.nvim.notify").popup
popup.setup({ fallback_toast = false }) -- before the spec
-- ... vim.notify = function(msg) ... end, assertions ...
popup.setup({ fallback_toast = true }) -- after it (the default)
```

`popup.deliver(msg, level, { source, title, timeout })` is the
direct entry point. `title` overrides the toast's default title; omit it and
a multi-line message's own first line becomes the title instead (e.g.
`"[gitsuite] docmap-desktop: push failed"`, with the rest -- git's own hint
lines -- as the body), so the one line that actually says what happened
isn't buried under three lines of explanation. A single-line message, or one
whose first line is empty or implausibly long (an unbroken block of text
that happens to carry a trailing `"\n... (truncated)"` from `entry_max_bytes`
below, say), keeps the previous default: `"source level-name"` (e.g.
`"sessions info"`), message untouched. Very large messages stay cheap: the toast wraps only the
first 4000 bytes by default (12 lines max, marked as cut), and a history entry
keeps at most 64 KB by default. Delivery from a fast event (libuv callback) is
rescheduled onto the main loop automatically.

### Configuring the toast (cap, min level, timeouts)

Every cap above is a default in `popup`'s own config, not a fixed constant --
override it globally or per call:

```lua
local popup = require("lib.nvim.notify").popup

popup.setup({
  max_lines = 12, -- toast line cap
  -- width = 38,  -- toast wrap width in columns; unset = follows the toast's own
  --               -- text budget (40% of the editor by default, see `toast`)
  -- toast = { width = "40%", min_width = 40, padding = 1 }, -- chip size, forwarded to ui.kit.toast.setup (needs ui.nvim)
  toast_max_bytes = 4000, -- bytes of a message considered when wrapping
  entry_max_bytes = 64 * 1024, -- bytes kept per history entry
  toast_min_level = vim.log.levels.INFO, -- below this: history/:messages only, no toast
  timeouts = { [vim.log.levels.ERROR] = 10000 }, -- per-level override, merged in
  history_full = false, -- show_history(): collapsed (default) or full entries
  fallback_toast = true, -- without ui.nvim: multi-line as lib's toast; false = vim.notify
})

-- Per call: overrides `popup.setup`'s defaults for this one delivery only.
popup.deliver(msg, vim.log.levels.WARN, { max_lines = 4, toast_max_bytes = 500 })
```

`toast_min_level` is what keeps a chatty plugin (dozens of `lib_notify` call
sites at INFO) from spamming the corner: below it, the message is still
recorded in history/`:messages`, it just never becomes a toast (and, since
either would still be a visible popup on a plain UI, never falls back to
plain `vim.notify` either).

### Global default: `notify.setup({ popup = true })`

Rather than passing `popup = true` to every `create()` call across a config,
set it once as the module-wide default -- existing and future notifiers that
don't set `popup` explicitly then follow it:

```lua
require("lib.nvim.notify").setup({ popup = true })
```

This is read at **call time**, not at `create()` time: a notifier built at
module load (`local notify = require("lib.nvim.notify").create("[p]")`, the
common style across these plugins) still picks up a default set later --
exactly the load-time-binding trap this module's own popup code warns about
elsewhere, closed one layer up. A `create(prefix, { popup = false })` still
wins over the global default for a notifier that wants to opt out.

### Full text: `expand_last()` and the history's `<C-s>` toggle

A toast is deliberately non-focusable and wraps to `max_lines`/`toast_max_bytes`
-- when it says `... (:Lib notify last)`, the full message is one call away:

```lua
popup.expand_last() -- read-only viewer panel, the last delivered message in full
```

`show_history(source)`'s scratch buffer collapses each entry to `max_lines`
the same way (`[+N lines, <C-s>]`); pressing `<C-s>` there (buffer-local, same
effect as `popup.toggle_full()`) expands every entry in place.

### `:Lib notify last | history | dismiss | clear`

`lib.nvim_usrcmds`'s `:Lib` verb carries these four subcommands (see
`lib.nvim.notify.popup.routes()`):

```vim
:Lib notify last              " expand_last()
:Lib notify history [source]  " show_history(source)
:Lib notify dismiss           " dismiss(): close every visible toast, history stays
:Lib notify clear [source]    " clear(source)
```

---

## `lib.nvim.notify.safe`

`lib.nvim.notify.safe` provides safe wrappers around `vim.notify`, specifically designed for so-called *fast event contexts*. These include, among others, callbacks from `autocmd`s such as `TextChanged`, `CursorMoved`, `BufWritePost` or other high-frequency events, in which a direct call to `vim.notify` can lead to errors, delays or undefined behavior.

The module encapsulates all common protection mechanisms (`vim.schedule`, `vim.defer_fn`, `vim.schedule_wrap`) behind a consistent, well-typed API.

---

### When is `lib.nvim.notify.safe` needed

You should use the safe variants when:

* notifications originate from autocommands
* notifications are triggered from LSP, tree or UI callbacks
* code is potentially executed multiple times per second
* it is not guaranteed that you are in the main event loop

For normal, direct user actions (commands, keymaps), `lib.nvim.notify.create` is still sufficient.

---

### `safe.schedule`

Schedules the notification with `vim.schedule` directly in the next main-loop tick.
This is the recommended default solution for almost all safe cases.

```lua
local safe = require("lib.nvim.notify").safe

safe.schedule("Scheduled notification", vim.log.levels.INFO)
```

Properties:

* immediate, but safe execution
* minimal overhead
* preferred default strategy

---

### `safe.defer`

Delays the notification by a defined time span using `vim.defer_fn`.

```lua
safe.defer("Delayed warning", vim.log.levels.WARN, {}, 150)
```

Properties:

* controlled delay
* useful for UI transitions or debouncing
* optional delay in milliseconds

---

### `safe.wrap`

Creates a reusable, already-scheduled notify function.
Ideal for repeated calls in hot paths.

```lua
local wrapped = safe.wrap()

wrapped("Repeated debug message", vim.log.levels.DEBUG)
```

Properties:

* efficient for many calls
* avoids repeatedly creating closures
* optimal for loops or event handlers

---

### `safe.notify`

A convenience wrapper that automatically chooses the appropriate strategy depending on the mode.

```lua
safe.notify("Auto scheduled", vim.log.levels.INFO)
safe.notify("Deferred", vim.log.levels.WARN, {}, "defer", 100)
```

Supported modes:

* `"schedule"` (default)
* `"defer"`
* `"wrap"`

---

### `safe.create_safe(prefix)`

Creates a safe notifier with a fixed prefix, analogous to `lib.nvim.notify.create`, but fully fast-event-safe.

```lua
local safe_notify = require("lib.nvim.notify").safe.create_safe("[plugin]")

safe_notify.info("Safe info message")
safe_notify.error("Safe error message")
```

Properties:

* the prefix is normalized once
* identical API to normal notifiers (`info`, `warn`, `error`, `debug`)
* internally always `vim.schedule`
* no duplicate prefixes possible

---

### Recommended usage

* `lib.nvim.notify.create`
  for commands, keymaps, user actions

* `lib.nvim.notify.safe.*`
  for autocommands, callbacks, LSP events, UI hooks

Both variants are fully compatible and can be used in parallel within the same project.

```vim
 Standard usage (as before)
local notify = require("lib.nvim.notify").create("[plugin]")
notify.info("Standard notification")

-- Safe variants for fast event contexts
local safe = require("lib.nvim.notify").safe

-- Variant 1: schedule (default)
safe.schedule("Message from fast event", vim.log.levels.INFO)

-- Variant 2: defer with delay
safe.defer("Delayed message", vim.log.levels.WARN, {}, 100)

-- Variant 3: wrapped notifier for repeated calls
local wrapped_notify = safe.wrap()
wrapped_notify("Efficient repeated call", vim.log.levels.DEBUG)

-- Variant 4: convenience wrapper
safe.notify("Auto-scheduled", vim.log.levels.INFO, {}, "schedule")

-- Variant 5: safe notifier with prefix
local safe_notify = safe.create_safe("[plugin]")
safe_notify.info("Safe + prefixed")
safe_notify.error("Error from fast context")
```

---

## Log-level resolution

```lua
local notify = require("lib.nvim.notify")

notify.resolve_log_level("warn")            --> vim.log.levels.WARN
notify.resolve_log_level(3)                 --> 3 (already a valid level)
notify.resolve_log_level("bogus", 1)        --> 1 (falls back to `default`)
notify.resolve_log_level(nil)               --> vim.log.levels.WARN (default's default)
```

Turns a user-provided log level — a number (0-5), a level name string
(case-insensitive: `"trace"`/`"debug"`/`"info"`/`"warn"`/`"error"`/`"off"`),
or `nil` — into a concrete `vim.log.levels` integer. Anything unrecognized
(an out-of-range number, an unknown string, any other type) falls back to
`default`, which itself defaults to `vim.log.levels.WARN`. Also reachable at
its own leaf path (`require("lib.nvim.notify.resolve_log_level")`) for
callers that only need this and not the rest of the module — `lib.nvim.logger`
uses it that way.

## Design properties

* one central, generic notify module
* the prefix is set **once per file**
* no double prefixing possible
* API identical to `vim.notify`
* easily reusable for any plugin or config component

---
