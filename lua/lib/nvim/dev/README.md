# `lib.nvim.dev`

Tooling for whoever is developing *across* the plugin ecosystem lib.nvim sits
under, not for a single plugin's own runtime. Occupants: `duplicates.lua`,
`reload.lua`, `notify_scan.lua`, `handrolled_scan.lua`, `deprecations/`.

## `reload.lua` — reload a config module on save

```lua
require("lib.nvim.dev.reload").watch()
```

One line in **your own config's** startup, not in a plugin: registers a
`BufWritePost` autocmd that reloads whatever module under
`stdpath("config")/lua` you just saved (`package.loaded[name] = nil`,
`require(name)` again) — matched lazily per save, not by pre-globbing every
`*.lua` file at startup. `M.module(name)` is the reload alone, if you already
have your own autocmd wiring.

## `duplicates.lua` — cross-repo function duplication

Identical function bodies across sibling repos — candidates for extraction
into lib.nvim itself, not a general clone-detector. Promoted from a
throwaway `python duplicate_functions.py` that walked a hardcoded path;
this is the same detection (normalize each top-level function body, group by
the normalized text, keep groups spanning two or more different repos),
parameterized by a root directory instead.

```lua
local duplicates = require("lib.nvim.dev.duplicates")

duplicates.scan("E:/repos")   -- default: cwd
duplicates.lines("E:/repos")  -- the same, as printable lines
```

**Scope: `root`'s immediate subdirectories, not `root` itself.** A hit only
means something when the *same* body shows up in *two different repos*, so
point this at a directory holding several sibling checkouts — `root`'s own
`lua/` (if it has one) is never itself scanned as a repo. Pointing it at a
single plugin's own root, with no sibling checkouts underneath, correctly
finds nothing: there is no second repo to duplicate against.

lib.nvim's own directory is always excluded from the repo set — the question
this answers is "what should move INTO lib.nvim", so lib.nvim's own code is
never itself a candidate.

`duplicates.create_usercmd()` registers `:LibDuplicateScan [path]`. Put that
one line in **your own config**, not in a plugin. `path` is optional and
defaults to cwd — run it from the directory that holds your sibling repos.

```lua
require("lib.nvim.dev.duplicates").create_usercmd()
```

## `notify_scan.lua` — where do sibling repos emit user messages?

Scans every immediate subdirectory of a root for `vim.notify`, `nvim_echo`,
`nvim_err_write(ln)`, `:echoerr`/`:echomsg`, `print(` and `lib.nvim.notify`
usage — the worklist for moving repos onto
[`lib.nvim.notify.popup`](../notify/README.md). Per finding: kind, level (when
spelled out), literal head, and two migration flags: `dynamic` (a wrapper —
converting it converts every caller) and `bound` (`local notify = vim.notify`
at load, which bypasses hooks installed later).

```lua
local scan = require("lib.nvim.dev.notify_scan")
scan.scan("B:/repos")      -- Finding[]
scan.summarize(findings)   -- per-repo totals
scan.lines("B:/repos")     -- Markdown: summary table + findings per repo
```

`notify_scan.create_usercmd()` registers `:LibNotifyScan [path]` (call it from
your own config). A line scanner, not a parser: it skips `TESTS/`, `.deps/`,
`lib.nvim` and `ui.nvim`, and counts `lib.nvim.notify` *creation* sites, not
each `notifier.info(...)` call.

## `handrolled_scan.lua` — hand-rolled debounce, throttle, event emitters

Warns where a sibling repo rebuilds what lib.nvim already ships: a restarted
one-shot timer (use `lib.nvim.debounce`), a clock reading minus a `last*`
variable (use `lib.nvim.patterns.throttle`), a `listeners` table with an `emit`
function (use `lib.nvim.hooks` or `lib.lua.patterns.event_bus`). It is the
runnable half of rule `LUA-09`, which has no `check` token because "debounce
rebuilt" is not greppable. Findings are warnings, never a gate.

```lua
local scan = require("lib.nvim.dev.handrolled_scan")
scan.scan("B:/repos", { exceptions = { ["repo/lua/x.lua"] = "why" } })
scan.lines("B:/repos")   -- Markdown: summary table + one WARN line per finding
scan.scan("B:/repos", { include_self = true })   -- also scan lib.nvim itself
```

`handrolled_scan.create_usercmd()` registers `:LibHandrolledScan[!] [path]` (call
it from your own config; the bang sets `include_self`). A line scanner with a heuristic, not a parser:

- **debounce**: the file creates a timer with `new_timer()`, starts one-shot
  (`:start(ms, 0, ...)`) and stops a *long-lived* handle (a field such as
  `st.timer`, or a `local pending` at column 0, or an indented `local timer` of
  a factory closure that is stopped before `timer = ...new_timer()` in the same
  function, i.e. restarted per event). A one-shot local timer, a timeout that
  is only stopped on completion (`finish`) and a periodic poll
  (`:start(every, every, ...)`) are not findings.
- **throttle**: the file reads a clock (`uv.now()`, `hrtime()`, `os.clock()`)
  and subtracts a `last*` variable.
- **emitter**: a `listeners`/`subscribers`/`observers` table plus an
  `emit`/`fire`/`publish`/`dispatch` function in one file.

Exceptions: `-- handrolled-ok: <reason>` anywhere in the file, or
`opts.exceptions` (`"repo"` or `"repo/lua/rel/path.lua"` -> reason). Skips
`TESTS/`, `.deps/` and `lib.nvim` itself; `include_self` scans lib.nvim too but
still leaves out `lua/lib/lua/patterns/`, `lua/lib/nvim/patterns/`, `debounce/`,
`hooks/` and the scanner file (the reference modules). Treat the output as a worklist: a
hit can be a false positive (a cleanup timer that is not an event debounce),
so look before replacing.

## `pattern_usage.lua` — who requires the pattern modules

Fills the generated "Used by" column of `docs/patterns.md`, so a pattern module
nobody uses is visible. It reads the module-map join of `docmap.nvim`
(`docmap.core.consumers`: lib.nvim's own `docs/map/module_map.json` against the
`*/docs/map/module_map.json` of the sibling repos); docmap is a development
dependency of this tool only (looked up as `<repos>/docmap.nvim` when it is not
on the runtimepath), nothing in lib.nvim's runtime needs it.

```sh
nvim --headless -u NONE -l scripts/pattern_usage.lua           # rewrite the column
nvim --headless -u NONE -l scripts/pattern_usage.lua --check   # exit 1 when out of date
```

```lua
local pu = require("lib.nvim.dev.pattern_usage")
local usage = pu.usage()                -- module -> { kind, consumers }
pu.sync({ check = true })               -- { rows, maps, changed }
```

The maps are git-ignored and local, so the column is a snapshot of the machine
that generated it: regenerate the maps first (docmap), then this. A dash means
"no map among those read", not dead code. The rows credit only the modules
before the "see also" part of the Module cell.

## `deprecations/` — deprecated Neovim calls, on save and in `:checkhealth`

```lua
require("lib.nvim.dev.deprecations").watch()   -- in your own config
```

`watch()` registers one `BufWritePost` autocmd (pattern `*.lua`): after a save
it scans the buffer and, only if it still holds deprecated calls, warns once
with the locations — `12:5 vim.loop -> vim.uv (deprecated since 0.10)`. A
clean save is silent. `opts.on_findings(findings, buf)` replaces the warning
(quickfix, diagnostics, ...); `unwatch()` removes it. Nothing runs at startup
beyond creating that autocmd; the rule table loads on the first scan.

`:checkhealth lib` has a **deprecated API calls** section scanning
`stdpath("config")`. A plugin can report on its own tree from its
`health.lua`:

```lua
require("lib.nvim.dev.deprecations").health({ plugin_root }, { title = "myplugin: deprecated calls" })
```

The rest of the surface: `scan_lines(lines)`, `scan_buffer(buf)`,
`scan_file(path)`, `scan_roots(roots)` (skips dot-directories such as `.git/`
or `.claude/worktrees/`, `node_modules/` and `---@meta` annotation files,
never follows a symlink, stops at `max_files`), `format(f)`,
`active_rules()`. `opts.rules` replaces the default table
([`rules.lua`](deprecations/rules.lua): `vim.loop`, `nvim_buf_set_option` and
the other option getters/setters, `vim.highlight`, `vim.tbl_flatten`,
`vim.lsp.get_active_clients`, `termopen`, `nvim_buf_add_highlight`,
`vim.diagnostic.goto_next`, ...), `opts.extra_rules` adds to it. A rule only
applies on a Neovim at least as new as its `since`, because on an older one
the replacement may not exist.

A line scanner, not a parser: comments and string contents are blanked
before matching, with open long strings / block comments carried across
lines, so a name inside a string or comment is not reported. A call built at
runtime is not seen. `---@diagnostic disable-next-line: deprecated` (or
`disable-line: deprecated`) silences a line — the marker LuaLS honours, so a
deliberate fallback for older Neovim is waived once for both.

**Why here and not in migrate.nvim or a mini plugin:** migrate.nvim rewrites
calls and deliberately has no watcher; the watcher is a dependency-free
scanner plus a few lines of autocmd and health wiring, and every config and
plugin already has lib.nvim on the runtime path — a separate plugin would add
an install step for the same code.

