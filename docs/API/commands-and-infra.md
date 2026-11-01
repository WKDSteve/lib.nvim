# API Reference — commands, automation, infrastructure

Part of the [lib.nvim API reference](README.md). Covers `lib.nvim.bindings.usercmd`
(including the `composer` subsystem), `autocmd`, `map`, `dotrepeat`,
`debounce`, `hooks`, `deps`, `treesitter`, `store`, `logger`, `progress`, `harvest`,
`git`, `net.curl`, `net.github`, `lua_ls`, `cache`, `core`, `normalize`, `require`,
`safe_api`, `system`, `token`, and `neotree`.

---

## `lib.nvim.bindings.usercmd` and `lib.nvim.bindings.usercmd.composer`

### `lib.nvim.bindings.usercmd` (see README)
Standardized wrapper around `nvim_create_user_command`/
`nvim_buf_create_user_command` with sane defaults (`force=true`,
`desc=""`, `nargs=0`) and a `pcall`-wrapped, notify-on-error callback.

```
M.create(name: string, callback: string|fun(args:Lib.UserCommand.Args), opts: LibUserCommandOpts|nil)
  -- opts.buffer (true=current buf, or bufnr) routes to nvim_buf_create_user_command; stripped before the native call
M.registered(filter?: { name?: string, buffer?: integer|boolean }): Lib.UserCommand.Record[]  -- newest last
M.delete(name: string, bufnr?: integer): boolean deleted   -- native delete AND forgets the record
M.docs   -- lazily-required proxy onto lib.nvim.bindings.usercmd.docs: write/check/create_usercmd
         -- (see README, in usercmd/README.md — bindings/usercmd/commands.md, :LibUsercmdDocs[Check])
M.composer   -- lazy proxy table onto lib.nvim.bindings.usercmd.composer (avoids a require cycle)
```

### `lib.nvim.bindings.usercmd.composer` (see README — extensive, read it for the full narrative)

**The most widely-used module in the whole library — 30+ consuming
plugins.** Compose a declarative route-tree spec into ONE Neovim user
command with subcommand dispatch, `<Tab>` completion, argument/flag/kv
coercion, and generated Markdown docs, all driven from the same tree.

Access: `require("lib.nvim.bindings.usercmd.composer")` (direct, most efficient),
`require("lib").composer`, `require("lib").usercmd.composer`.

#### `M.verb(name: string, spec?: Lib.UserCmd.Composer.Spec): Lib.UserCmd.Composer.Handle|table`
Core entry point. With a `spec`, registers immediately and returns a
`Handle`. Without one, returns a fluent builder (chain
`:desc()/:default()/:bang()/:range()/:count()/:buffer()/:route()/:build()`).

##### `spec` shape
```
desc?: string                          -- command description
default?: fun(ctx)                     -- handler for bare :Verb (no route path)
routes?: RouteSpec[]                   -- the route tree; each route:
  path: string[]                       -- literal subcommand tokens ({} = verb's root route)
  args?: ArgSpec[]                     -- { name, type, optional?, enum?, values?, variadic? }
                                        --   variadic (last arg only): tokens past the declared slots keep completing with it and usage shows `...`; they still arrive raw in ctx.rest
                                        --   types: STRING (default), INT, FLOAT, BOOL, PATH, DIR, FILE, BUFFER, WINDOW, custom
  flags?: FlagSpec[]                   -- --flag/-x parsing: { name, short?, bool?, type?, enum?, repeatable? }
  kv?: KvSpec[]                        -- bare key=value parsing: { key, type?, enum?, default? }
  run: fun(ctx)|string                 -- handler, or a module path required lazily on first dispatch
  desc?, check?: fun(): boolean, string?, bang?, range?, count?, visual?: string[]
bang?: boolean                         -- verb-level default (explicit route.bang wins if set)
range?: boolean|integer                -- verb-level default (first route's range wins if unset)
count?: integer                        -- verb-level :N Verb default (first route's count wins if unset)
buffer?: true|integer                  -- buffer-local registration
visual?: string[]                      -- verb-level default for routes declaring none
notify_prefix?: string                 -- overrides the deferred-notifier's prefix (default "[" .. name .. "]")
quotes?: boolean                       -- the handler cuts ctx.raw.args with a quote-aware tokenizer ('...' / "..." = one token): <Tab> and the help float count a quoted run as one token. Dispatch is unchanged
```

**`ctx` (handler context):** `ctx.args` (coerced positionals by name),
`ctx.pos` (by order), `ctx.flags` (by name), `ctx.kv` (by key), `ctx.rest`
(leftover tokens), `ctx.path` (matched literal path), `ctx.bang`,
`ctx.range` (`{ line1, line2, count, range, mode, col1, col2 }`), `ctx.raw`
(raw nvim callback args).

**`Handle`** (returned by `verb()` with a spec, or the builder's `:build()`):
```
handle:name(): string
handle:spec(): Lib.UserCmd.Composer.Spec
handle:document(path?: string): boolean ok, string|nil err
handle:check(): Lib.UserCmd.Composer.CheckResult[]
```

##### Other module functions
```
M.document(path?: string): boolean ok, string|nil err   -- docs for EVERY verb registered in this process
M.setup(opts?: Lib.UserCmd.Composer.SetupOpts)
  -- opts.docs = { path?, mode? }; mode "replace" (default, whole file) | "section" (delimited block in-place)
M.register_type(name: string, def: Lib.UserCmd.Composer.TypeDef)
  -- def = { validate = fun(raw): boolean, any, string|nil, complete = fun(lead): string[] }
M.registry(): table<string, Lib.UserCmd.Composer.Handle>
M.check_all(): table<string, Lib.UserCmd.Composer.CheckResult[]>
M.checkhealth(name_or_handle: string|Lib.UserCmd.Composer.Handle)
  -- call from your plugin's own health.lua; composer cannot self-register a :checkhealth target
M.notify_check_all(): boolean ok_overall   -- notification-based alternative to checkhealth
```

**Behavior notes:** flags are parsed anywhere in the tail; `--` sentinel
stops flag parsing; unknown `--name` is a hard error; short-flag `-x`
aliases via `short = "x"` (value flags only take the *next* token, never
`-x=value`); an unrecognized `-x` falls through as positional. Undeclared
`key=value` tokens are left positional (not an error, unlike flags).
Composer's internals (`parse.lua`, `tree.lua`, `flags.lua`, `kv.lua`,
`argtypes.lua`, `docgen.lua`, `complete.lua`, `check.lua`, `registry.lua`,
`format.lua`) are reached only through the public functions above.

---

## `lib.nvim.bindings.autocmd` (see README)

Standardized autocommand creation on top of `nvim_create_autocmd` —
automatic augroup lookup/caching, a defensive `pcall`-wrapped callback,
event/pattern normalization.

```
M.augroup   -- lazily-required proxy onto lib.nvim.bindings.autocmd.augroup
M.group(name: string, clear?: boolean): integer          -- memoized in an internal cache
M.get_augroup(name: string, opts?: { clear?, prefix? }): integer   -- separate cache from M.group
M.create(event: string|string[], callback: fun(args), opts?: LibAutocmdOpts): integer
  -- callback pcall-wrapped, notify-on-error tagged [lib.nvim.bindings.autocmd]; opts.buffer/opts.pattern mutually exclusive
M.norm_events(ev: any, fallback: string[]): string[]
M.norm_pattern(pat: any): string|string[]                -- nil -> "*"
M.registered(filter?: { event?: string, group?: string }): Lib.Autocmd.Record[]  -- newest last
M.by_event(): table<string, Lib.Autocmd.Record[]>        -- the same, grouped by event
M.delete(id: integer): boolean deleted                    -- native delete AND forgets the record
M.docs   -- lazily-required proxy onto lib.nvim.bindings.autocmd.docs (see below)
```

### `lib.nvim.bindings.autocmd.docs` (see README, in `autocmd/README.md`)
Generated `bindings/autocmd/` markdown, one file per event family, read
back from `M.registered()` above — not a hand-kept list.

```
M.write(opts?: Lib.Autocmd.Docs.Opts): (ok: boolean, err: string|nil, written: string[])
M.check(opts?: Lib.Autocmd.Docs.Opts): (up_to_date: boolean, stale: string[])  -- compares without writing, for CI
M.write_all(opts?: Lib.Autocmd.Docs.AllOpts): Lib.Autocmd.Docs.AllResult[]
  -- writes every repository that registered something this session, not just the caller's own
M.create_usercmd(name?: string)   -- registers :LibAutocmdDocs and :LibAutocmdDocsCheck
```

### `lib.nvim.bindings.autocmd.augroup` (no separate README)
A third, unrelated, uncached one-off augroup helper — always
creates/clears unconditionally (no memoization).

```
M.create.clear(name: string): integer
```

### `lib.nvim.bindings.autocmd.dispatcher` (see README)
One autocmd, many lazy-loaded, priority-ordered, per-buffer-`once`
handlers, factored out of the N-hand-rolled-`FileType`-autocmds
anti-pattern. Not a performance win over plain autocmds on a miss (see
README for measured numbers) — the win is uniform lazy loading,
deterministic ordering, and per-buffer `once`.

```
M.new(opts: Lib.Autocmd.Dispatcher.Opts): Lib.Autocmd.Dispatcher.Handle
  -- opts.event (required), opts.key: fun(ev): string (required), opts.name/opts.group
M.registry(): table                    -- every dispatcher created this session, for introspection
M.reattach_all(): nil                  -- re-run attach() on every live dispatcher (config hot-reload)
M.filetype.new(opts): Lib.Autocmd.Dispatcher.Handle   -- FileType convenience wrapper over M.new
```
Handle (returned by `new`):
```
handle.register(key_or_keys: string|string[], spec: fun(args)|{ load: fun(args), priority?, once?, owner?, desc? }): handle
handle.unregister(owner: string): integer removed
handle.handlers(): table[]             -- introspection: every live registration
handle.attach(): nil                   -- installs the autocmd (dispatch mode) or one per handler (bypass mode)
handle.detach(): nil
handle.stats(): table
```

---

## `lib.nvim.bindings.keymap` (see README)

Convenience wrapper around `vim.keymap.set` with sane defaults and
defensive argument validation. **The module itself is a function** —
`require("lib.nvim.bindings.keymap")` returns the callable directly.

```
return function(modes: string|string[], lhs: string, rhs: string|function, opts?: Lib.Map.Opts, desc?: string)
```
Defaults: `opts.noremap = true`, `opts.silent = true`, `opts.desc = ""`. A
string `desc` positional overrides `opts.desc`. `opts.buffer = true`
normalizes to `0`. On validation failure, `vim.keymap.set` is **not**
called — reports every failing field plus the real caller's call site
instead.

### `lib.nvim.bindings.keymap.cheatsheet` (see README)
`keymap.cheatsheet(plugin, opts?)`: the lines and highlight spans of a `g?` cheatsheet, from the registry.
```
M.build(plugin: string, opts?: { groups?: {title, actions}[], other_title?, buffer?, footer?: string|string[],
  width?, indent?, modes?, hl?: {heading?, key?, desc?, footer?} }): { lines: string[],
  highlights: { line, col_start, col_end, group }[], rows: { name, keys, modes, desc }[], width: integer }
```
Only bound actions; several keys of one action on one row; the `plugin: ` desc prefix stripped.

### `lib.nvim.bindings.keymap.portability` (see README)
Static reachability classifier over an `lhs` notation string — no terminal
is queried or probed; classifying the notation itself is the only part of
"can this key reach Neovim" that has a decidable answer.

```
M.classify(lhs: string|nil): (tier: "portable"|"common"|"fragile", reason: string)
  -- reason is "" for a portable key
M.is_portable(lhs: string|nil): boolean   -- classify(lhs) == "portable"
```

### `lib.nvim.bindings.keymap.modifier` (see README)
Modifier keys that run *another* mapping and capture its result — `` \[a ``
copies what `[a` produced, `` \\[a `` also inserts it. Experimental: binds
nothing until `setup{ experimental = true }`.

```
M.setup(opts?: { experimental?: boolean, copy?: string, insert?: string }): boolean
  -- off unless experimental; copy/insert default to \ and \\
M.teardown(): nil                          -- unbind whatever is bound
M.keys(): { copy: string|nil, insert: string|nil }
M.declare(mode: string, lhs: string, fn: fun(): string|nil)   -- tier 1: pure result producer
M.undeclare(mode: string, lhs: string)
```

### `lib.nvim.bindings.audit` (see README, in `bindings/README.md`)
Keymap actions vs. command routes registered in the current session, plus a
handful of lints — deliberately reads what is already loaded rather than
spawning an isolated session to inspect a registry.

```
M.keymap_actions(root?: string): Lib.Bindings.Audit.KeyAction[]
M.command_routes(root?: string): Lib.Bindings.Audit.CmdRoute[]
M.gaps(root?: string): Lib.Bindings.Audit.KeyAction[]         -- actions with no obvious command counterpart
M.key_risks(root?: string): Lib.Bindings.Audit.KeyRisk[]      -- actions with no portable key, fragile first
M.naming_candidates(root?: string): (Lib.Bindings.Audit.CmdRoute|{vague: boolean})[]
  -- routes whose last path segment is a bare vague word (deep/full/check/...)
M.prefix_ambiguities(): Lib.Bindings.Audit.PrefixAmbiguity[]  -- live command names that are a prefix of another
M.checklist_lines(root?: string): string[]
  -- Markdown manual-verification checklist over every action/route; never invokes anything
M.lines/.gap_lines/.key_risk_lines/.naming_candidate_lines/.prefix_ambiguity_lines(...): string[]
  -- the above, as printable lines
M.create_usercmd(name?: string)
  -- registers :LibBindingsAudit[Gaps|Keys|Naming|Checklist] [path] and :LibBindingsAuditPrefixes (no path)
```
Every function taking `root` scopes to one repository; `nil` means the
whole session. `prefix_ambiguities`/`prefix_ambiguity_lines` take no `root`
— a live command name collides (or doesn't) independent of which repo
registered it.

---

## `lib.nvim.count` (see README)

Count-prefix helpers for keymaps (`3<leader>xy`). Reading, plus the two ways
an action repeats.

```
M.DEFAULT_MAX: integer                                   -- 1000; cap for times/chain
M.get(): integer                                         -- vim.v.count1 ("no count means once")
M.raw(): integer                                         -- vim.v.count (0 when none typed)
M.given(): boolean                                       -- was a count typed at all
M.clamp(min: integer, max: integer): integer             -- vim.v.count1 clamped into a range
M.times(fn: fun(i: integer): boolean|nil, opts?: { count?: integer, max?: integer }): integer
  -- runs fn once per count, synchronously; fn returning false stops early; returns times actually run
M.chain(opts: Lib.Count.ChainOpts): boolean
  -- repeats an async action, each call gated on the caller's completion signal; returns whether it chained
```

`chain` generalizes dap.nvim's `counted_step()`: `opts.subscribe(advance,
abort)` registers the caller's listeners and returns an unsubscribe.
`advance` releases the next call, `abort` drops the chain. With no count,
`action` is called directly and `subscribe` is never invoked. A missing or
raising `subscribe` reports and runs the action **once** — it deliberately
does not fall back to a synchronous loop, which is the unpaced repetition
`chain` exists to prevent. The chain also refuses to advance after `abort`,
so a completion signal that was already queued cannot resurrect it.

---

## `lib.nvim.dotrepeat` (see README)

Native Vim `.`-repeat wiring through `operatorfunc`, no `vim-repeat`
dependency.

```
M.run(fn: Lib.Dotrepeat.Fn)
  -- runs fn now, stores it as pending, points operatorfunc at the stable dispatcher, fires once via `normal! g@l`
M.repeatable(fn: Lib.Dotrepeat.Fn): Lib.Dotrepeat.Fn   -- wrapped equivalent, usable directly as a keymap callback
M._invoke(motion_type: string|nil)   -- dispatcher reached from Vimscript via v:lua; technically public
```

---

## `lib.nvim.hooks`

### `lib.nvim.hooks` (see README)
Hook registry for a pipeline with named stages: ordered callbacks, veto for `before_*` events, error isolation.

```
M.new(opts: Lib.Hooks.Opts): Lib.Hooks.Registry
  -- opts: { events: string[], vetoable?: string[], short_circuit?: boolean, on_error?: fun(event, err, fn) }
reg.on(event: string, fn: fun(ctx): boolean|nil, opts?: { priority?: integer }): fun()  -- returns the unregister function
reg.off(event: string, fn: function): boolean
reg.clear(event?: string)
reg.count(event: string): integer
reg.run(event: string, ctx?: any, extra?: function|function[]): boolean proceed, integer errors
```
Order: `extra` first, then registered hooks by ascending `priority` (default 0), ties in registration order.
Only an exact `false` from a vetoable event (default: names starting with `before_`) vetoes; every hook still
runs unless `short_circuit`. A throwing hook goes to `on_error` (default `vim.notify` WARN) and never aborts.
Unknown event names are errors.

---

## `lib.nvim.explorer` (see README)

File-explorer adapter registry on `lib.nvim.registry`; built in: neo-tree, NvimTree, netrw, oil.

```
M.register(adapter: { name, filetypes? | detect?(buf), module?, current_path?(buf), reload?() })   M.unregister(name): boolean
M.adapters(): adapter[]   M.detect(buf?): adapter|nil   M.current(buf?): string|nil   M.current_path(buf?): string|nil
M.reload_all(): string[]  M.reset()
```
Soft: a missing plugin answers `nil`, a raising adapter is skipped.

---

## `lib.nvim.registry` (see README)

Generic ordered key -> value registry with a lazy loader, validation and `reset()`.

```
M.new(opts?: { name?, validate?: fun(key, value): boolean?, string?, loader?: fun(), on_duplicate?: "replace"|"keep"|"error" }): Lib.Registry
r:register(key, value): Lib.Registry   r:unregister(key): boolean   r:reset(): Lib.Registry
r:get(key) r:has(key) r:count()        r:keys(): any[]   r:all(pred?): any[]   r:entries(): { key, value }[]
r:find(pred: fun(key, value): boolean?): key, value        -- first in registration order
```
Order is registration order; `loader` runs once before the first read (again after `reset`).

---

## `lib.nvim.debounce.*`

### `lib.nvim.debounce` (see README)
Generic debounce primitive built on `(vim.uv or vim.loop).new_timer()`.

```
M.new(fn: fun(...:any), ms: integer): Lib.Debounce.Handle   -- { call, cancel }
M.new_with_counter(fn: fun(...:any), ms: integer): (Lib.Debounce.Handle handle, fun(): integer skipped)
  -- returns TWO values (handle, get_skipped), not one table; skipped = calls coalesced since the last fire
```

### `lib.nvim.debounce.buffer` (see README)
Buffer-scoped debounce — one independent timer per `bufnr`, auto-armed
cleanup autocmd.

```
new(fn: fun(bufnr:integer, ...:any), opts?: Lib.Debounce.BufferOpts): Lib.Debounce.BufferHandle
  -- { call, cancel, cancel_all }
```
`opts.ms` (default 200), `opts.adaptive` (default false — effective delay
= `min(ms*4, ms + floor(line_count/50))`), `opts.cleanup_events` (default
`{ "BufDelete", "BufWipeout" }`).

---

## `lib.nvim.deps.*`

Directory README is extensive — external-tool detection, declared-dependency
spec parsing (`docs/INSTALL.md`/`docs/install.json`), confirmation-gated
install handoff. **Requiring any deps module executes nothing** — only
`install.run()` (reached via an explicit user action) ever opens a
terminal, and even then the command is only typed, never submitted.

### `lib.nvim.deps` (see README) — top-level aggregator/facade
```
M.spec, M.health, M.pm, M.install, M.view, M.first_run   -- re-exports, see below
M.show_once(plugin_name: string, opts?: { manager?, cache? }): boolean shown
M.plugins(): string[]                       -- every plugin on rtp shipping a deps spec
M.show(plugin_name: string): boolean shown
M.install_for(plugin_name: string): boolean started
M.routes(): table[]                          -- :Lib deps show|status|install|project|reset-first-run composer routes
M.project                                    -- lib.nvim.deps.project, see below
```

### `lib.nvim.deps.health`
Generic replacement for hand-rolled `check_exe`/`probe` loops.
```
M.report(entries: Lib.Deps.HealthEntry[])            -- { bin?, python_module?, label?, hint?, required? }
M.from_tools(tools: Lib.Deps.Tool[])
M.report_for(plugin_name: string)
M.pointer_for(plugin_name: string)                   -- `:Lib deps show` line only, no per-tool loop
```

### `lib.nvim.deps.spec`
Parse/validate a plugin's declared external-tool requirements.
```
M.parse_markdown(text: string): Lib.Deps.ParseResult   -- { tools, errors }
M.parse_json(text: string): Lib.Deps.ParseResult
M.load(path: string): (result|nil, string|nil err)
M.find(plugin_name: string): string|nil path
M.plugins(): string[]
```

### `lib.nvim.deps.pm`
OS package-manager detection and install-command composition — pure,
never executes anything.
```
M.get(id: string): Lib.Deps.Manager|nil
M.ids(): string[]
M.available(): Lib.Deps.Manager[]
M.detect(): Lib.Deps.Manager|nil
M.is_root(): boolean
M.commands(manager, packages: string[]): string[][]
M.needs_terminal(manager): boolean
M.render(argv: string[]): string   -- display/paste only, never handed to a shell
```

### `lib.nvim.deps.install`
Turn a parsed tool spec into an install plan (pure), and — only on an
explicit confirmed call — open a terminal with the composed command typed.
```
M.plan(tools: Lib.Deps.Tool[], opts?: { manager? }): Lib.Deps.Plan
M.run(plan: Lib.Deps.Plan, opts?: { confirm? }): boolean started
```

### `lib.nvim.deps.view`
Render a plugin's declared tools into buffer lines, show in a popup.
```
M.render(plugin_name, result, opts?, ui?): { lines, line_tools }
M.lines(plugin_name, result, opts?): string[]
M.show_split(plugin_name, result): integer bufnr, integer winid
M.show(plugin_name, result, opts?): integer bufnr, integer winid
```

### `lib.nvim.deps.project`
The project view: which treesitter parsers and tools the files under a root
need and lack. Nothing installs without one confirmation. See its README.
```
M.scan(root, opts?: { refresh?, ttl_seconds?, ignore?, max_files?, max_depth?, max_ms? }, on_done: fun(scan)): fun() cancel
M.forget(root?)
M.default_ignore(): fun(abs_path, is_dir): boolean     M.IGNORE_KEEP: string[]   -- fs.ignore.list minus `.github`
M.count(root, paths, errors?): Lib.Deps.Project.Scan     -- pure; M.key_of(path): "*.ext" | file name
M.register_tools(owner, { [filetype] = tools[] } | fn): fun() unregister   -- tool = Lib.Deps.Tool | { mason = "pkg" }
M.registered(): string[]
M.report(scan, opts?: { tools?, registered? }): Lib.Deps.Project.Report
M.report_async(scan, opts?, on_done)   -- report(), after one Mason registry refresh when an entry reads `unavailable`
M.lines(report, opts?): string[]    M.summary(report): string|nil
M.install_plan(report, opts?): Lib.Deps.Project.InstallPlan
M.install(report, opts?: { confirm?, manager? }): { parsers, mason, terminal }|nil
M.run(root?, action?: "refresh"|"install", opts?)        -- :Lib deps project [refresh|install]
M.setup(opts?: { auto?, ttl_seconds?, tools?, max_files?, max_depth?, max_ms? })   -- optional DirChanged trigger, default off
M.TRIGGER_LIMITS    M.is_broad_root(root): boolean   -- the trigger's walk limits / roots it never scans
M.reset_announced()
```

### `lib.nvim.deps.first_run`
Show a plugin's declared-tools popup exactly once, ever, persisted across restarts.
```
M.seen(plugin_name, cache_opts?): boolean
M.mark_seen(plugin_name, cache_opts?)
M.reset(plugin_name?, cache_opts?)
M.show_once(plugin_name, opts?): boolean shown
  -- opt-out via vim.g.lib_nvim_deps_disable_first_run / vim.g.lib_nvim_deps_disabled_plugins
```

---

## `lib.nvim.treesitter.*`

### `lib.nvim.treesitter.guard` (see README)
Filetype allowlist gate for treesitter-dependent features.
```
M.DEFAULT_WHITELIST: table<string, boolean>
M.is_enabled(bufnr: integer, whitelist?: table<string, boolean>): boolean
```

### `lib.nvim.net.curl` download cache (see header comments)
```
M.cache_path(url, opts?: {cache_dir?}): string       -- sha256(url) + the extension of the URL's path
M.download_cached(url, opts?: FetchOpts + {cache_dir?, ttl_s?, refresh?, max_age_s?, max_total_bytes?}, cb: fun(ok, path_or_err, info: {cached, response?}))
M.download_cached_blocking(url, opts?): ok, path_or_err, info
-- after a download: entries unused for max_age_s are removed, then the least recently used ones until the cache
-- entries total at most max_total_bytes; a hit renews the atime only; the file just stored is kept
```
A fresh entry is returned without a request; the body goes to a `.part` file renamed into place only after a 2xx
answer, so the cache never holds a partial file or an error page. `download` also checks the written file against
`max_bytes` (while it grows, async; afterwards, blocking) for curl versions that do not enforce `--max-filesize`
on a body without `Content-Length`.

### `lib.nvim.terminal.capabilities` (see terminal README)
Terminal capabilities from environment variables, cached per session; one warning per missing one.
```
M.detect(env?): { kitty_graphics, osc1337_images, sixel, truecolor: boolean, host: Lib.Terminal.Host }   -- pure
M.supports(name): boolean            -- cached; unknown name is an error
M.require(name, opts?: { feature?, notify?: fun(msg) }): boolean   -- + ONE warning per capability AND feature per session
M.names(): string[]    M.reset()
```

### `lib.nvim.treesitter.regions` (header comment)
Capture name -> ranges of a buffer, fail-open (no parser / query / capture is `nil, reason`, never an error).
```
M.collect(bufnr, captures: string[], opts?: { query?, lang?, first_row?, last_row?, hierarchical? }): table<string, Region[]>|nil, reason|nil
  -- Region = { sr, sc, er, ec, start_byte=, end_byte= } (0-based, end exclusive)
  -- names match EXACTLY ("comment" is not "comment.documentation") unless hierarchical = true (dotted children included)
  -- reasons: "invalid_buffer"|"no_filetype"|"no_parser"|"no_query"|"capture_not_defined"|"parse_failed"
M.contains(ranges, row, col): boolean        M.contains_pos(ranges, lnum, col): boolean   -- 1-based
M.contains_byte(ranges, byte): boolean       M.byte_ranges(ranges): { start_byte, end_byte }[]
```
Not `guard` (a filetype allowlist) nor `parser_policy`. From `language.nvim`'s spell regions.

### `lib.nvim.treesitter.parser_policy` (see README)
Prompt-or-auto-install policy for missing-but-available treesitter parsers.
```
M.setup(opts?: Lib.Treesitter.ParserPolicy.SetupOpts)
M.get_mode(): "off"|"prompt"|"auto"     -- default "prompt"
M.set_mode(mode): boolean ok, string? err
M.declined(): string[]                   -- persisted via lib.nvim.cache.disk
M.reset_declined()
M.ensure(lang: string, opts?: Lib.Treesitter.ParserPolicy.EnsureOpts)
```

---

## `lib.nvim.store.*`

### `lib.nvim.store` (see README) — thin re-export of `store.project`.

### `lib.nvim.store.project` (see README)
Persistent state keyed by project (git root, normalized).
```
M.save(key: string, data: any, opts?): boolean ok, string|nil err
M.load(key: string, opts?): any|nil        -- nil if missing/unreadable/(with ttl_seconds) expired
M.clear(key: string, opts?): boolean ok
M.root(opts?): string
M.stats(key: string, opts?): Lib.Cache.Stats   -- { exists, saved_at, age_seconds, size_bytes }
```

---

## `lib.nvim.logger` (see README)

Structured logging, diagnostics and crash-dump facility — richer sibling
of `lib.nvim.notify`: structured context, bounded in-memory history,
optional JSONL file sink, crash-dump wiring, near-zero-cost kill switches.

### Module-level (global)
```
M.new(opts?: Lib.Logger.Options): Lib.Logger.Instance
  -- opts: name, level (default "debug"), notify_level (default "warn"), file (nil=default path/false=off/string),
  --       capture (flush on VimLeavePre, default true), history, redact
M.setup(opts?: table)                    -- merges into global defaults for future M.new() calls
M.set_enabled(on: boolean) / M.is_enabled(): boolean
M.set_level(level?: Lib.Logger.LevelInput)
M.disable_tag(tag) / M.enable_tag(tag)
M.only_tags(tags?: string[])
M.tags(): { disabled, only }
M.loggers(): Lib.Logger.Instance[]
```

### Instance methods
```
inst.log(level, msg, ctx?, call_opts?) / inst.trace/debug/info/warn/error(msg, ctx?, call_opts?)
inst.set_enabled(on) / inst.is_enabled() / inst.set_level(level)
inst.flush(): boolean         -- writes the whole ring to the file sink now
inst.snapshot(): Lib.Logger.Record[]
inst.clear()
inst.once(key, level, msg, ctx?): boolean
inst.timer(label, level?): fun(ctx?)   -- returned closure logs elapsed ms
inst.guard(fn, fname?): function        -- xpcall wrapper, logs + flushes + RE-RAISES
inst.wrap(fn, fname?): function         -- same, but SWALLOWS the error
inst.assert(cond, msg, ctx?)
inst.count(key): integer                -- frequency tally, not a log record
inst.counters(): table<string,integer>
inst.add_sink(fn: fun(record))
```

`:LibLogger` command (scheduled right after the first `logger.new()`, never at `require`; `logger.install_command()` installs it at once): `show [n]`,
`on|off`, `level <l>`, `dump`, `clear`, `tags`.

---

## `lib.nvim.progress` (see README)

Cross-platform, style-agnostic progress-indicator handle — decouples
"reporting on a long-running operation" from how it's shown (`vim.notify`,
statusline, `fidget.nvim`, or an interactive float).

```
M.create(opts?: Lib.Progress.Opts): Lib.Progress.Handle
```
`opts`: `title` (default `""`), `style` (`"auto"|"notify"|"statusline"|"fidget"|"float"|"kit"`,
default `"auto"` — prefers fidget if installed else notify), `delay_ms`
(default 150), `level`, `kit_theme`.

### Returned handle
```
h:update(fields?: { text?, current?, total? })
h:finish(text?: string)      -- silent no-op if the delay guard never elapsed
h:cancel(text?: string)
h:on_cancel(fn: fun())
h:request_cancel()           -- sets h.cancelled=true, runs every on_cancel callback, then h:cancel()
h.cancelled: boolean
```

---

## `lib.nvim.harvest.*`

Building-block library for "collect something from a scope, then show or
export it" — three independent pieces, no framework glue.

### `lib.nvim.harvest` (see README) — top level
```
M.scope, M.render, M.sink   -- re-exports, see below
M.emit(text: string, out?: string, opts?): boolean ok, string|nil err
  -- out: "table"/"buffer" (scratch), "clipboard"/"clip", "echo", "file:<path>" (or "file" with opts.path)
M.outputs(): string[]   -- { "buffer", "clipboard", "echo", "file:", "table" }
```

### `lib.nvim.harvest.scope`
Resolve a "where should I look?" descriptor into a flat list of
`Lib.Harvest.Source` records (lines + provenance).
```
M.resolve(kind: "buffer"|"range"|"buffers"|"cwd"|"path"|nil, opts?): (sources[], string|nil err)
M.resolve_token(token: string|nil, opts?): (sources[], string|nil err)
  -- "" / "%" -> buffer; "cwd"/"buffers"/"buffer"/"range" -> themselves; else -> treated as path
```
`Source = { file?, bufnr?, lines: string[], first: integer }`.
`opts`: `bufnr, line1/line2, path, recursive (default true), match, ignore
(default fs.ignore.list), max_files (default 2000), max_filesize (default 1 MiB)`.

### `lib.nvim.harvest.render`
Header list + row matrix -> text.
```
M.markdown_table(headers: string[], rows: any[][], opts?: { align? }): string
M.csv(headers: string[]|nil, rows: any[][], sep?: string): string   -- default ",", RFC 4180 quoting
M.lines(rows: any[][], sep?: string): string                        -- default "  "
```

### `lib.nvim.harvest.sink`
```
M.clipboard(text: string): boolean ok, string|nil err
M.file(text: string, path: string): boolean ok, string|nil err
M.scratch(text: string, opts?: Lib.Harvest.ScratchOpts): integer bufnr
M.select(items: T[], opts?, on_choose: fun(item, idx))   -- kit.select if available, else vim.ui.select
```

---

## `lib.nvim.git` (see README)

Composable Git query helpers; every function shells out via
`lib.nvim.cross.run_argv` (argv, no shell). Every function except
`checkout` and the sync verbs (`fetch_async`, `pull_async`, `push_async`,
`update_async`, below) is side-effect free and returns `nil`/`false` (not throw) on
failure/no-repo; `checkout` mutates HEAD/the working tree and returns
`ok, err` instead (git's own stderr on failure). `opts.dir` runs a call as
`git -C <dir>` instead of against the cwd.

```
M.in_git_repo(opts?: {dir?}, git_cmd?: string): boolean
M.repo_root(opts?: {dir?}, git_cmd?: string): string|nil
M.current_branch(opts?: {dir?}, git_cmd?: string): string|nil
M.checkout(name: string, opts?: {dir?}, git_cmd?: string): boolean ok, string|nil err   -- mutates HEAD; git's own stderr on failure
M.is_detached_head(opts?: {dir?}, git_cmd?: string): boolean
M.is_dirty(opts?: {dir?}, git_cmd?: string): boolean
M.is_tracked(path: string, opts?: {dir?}, git_cmd?: string): boolean
M.is_skip_worktree(path: string, opts?: {dir?}, git_cmd?: string): boolean|nil, string|nil err
  -- `ls-files -v` tag S/s; nil + "not tracked" for an untracked path
M.set_skip_worktree(path: string, on: boolean, opts?: {dir?}, git_cmd?: string): boolean ok, string|nil err
M.toggle_skip_worktree(path: string, opts?: {dir?}, git_cmd?: string): boolean|nil skipped_after, string|nil err
M.upstream(opts?: {dir?}, git_cmd?: string): string|nil        -- "origin/main"-style
M.ahead_behind(opts?: {dir?}, git_cmd?: string): boolean ahead, boolean behind   -- vs @{u}
M.head_hash(opts?: {dir?}, git_cmd?: string): string|nil        -- full SHA
M.head_short_hash(opts?: {dir?}, git_cmd?: string): string|nil
M.tree_hash(opts?: {dir?}, git_cmd?: string): string|nil        -- HEAD^{tree}, same across a message-only amend
M.describe(opts?: {dir?}, git_cmd?: string): string|nil         -- nearest tag, or the short hash (--always)
M.info(dir: string, git_cmd?: string): { branch, version, commit }
M.status_porcelain(opts?: {dir?, ignored?}, git_cmd?: string): table<string, {code, orig_path}>|nil, err?   -- `-z`, exact paths
M.status_porcelain_async(opts: {dir?, ignored?}|nil, on_done: fun(map|nil, err|nil), git_cmd?: string): { stop }
M.parse_status(raw: string): table<string, {code, orig_path}>   -- pure, `-z` output
M.show(rev: string, path: string, opts?: {dir?}, git_cmd?: string): string|nil, err?   -- file content at a revision, byte for byte ("" = index, ":1/:2/:3" = merge stages)
M.show_async(rev: string, path: string, opts: {dir?}|nil, on_done: fun(content|nil, err|nil), git_cmd?: string): { stop }
M.clear_line_diff(ns: integer): fun(buf: integer): nil

-- Running git / reading someone else's history (Lib.Git.RunOpts = opts.dir + timeout_ms, max_output_bytes (exit 125), env, no_lazy_fetch (GIT_NO_LAZY_FETCH + GIT_ALLOW_PROTOCOL=none), read_only, input, binary)
M.run(args: string[], opts?: Lib.Git.RunOpts, git_cmd?: string): { ok, code, stdout, stderr, timed_out }   -- generic runner; does NOT validate the subcommand
M.run_async(args: string[], opts: Lib.Git.RunOpts|nil, on_done: fun(result), git_cmd?: string): { stop }
M.log(range?: string, opts?: Lib.Git.LogOpts, git_cmd?: string): Lib.Git.LogEntry[]|nil, err?   -- commits + bodies (+ files with name_status) in ONE process; NUL-separated, a hostile message cannot forge a record
M.log_async(range: string|nil, opts: Lib.Git.LogOpts|nil, on_done: fun(entries|nil, err|nil), git_cmd?: string): { stop }
M.parse_log(raw: string, opts?: { left_right?, name_status? }): Lib.Git.LogEntry[]|nil, err?   -- pure, strict
M.rev_parse(rev: string, opts?: Lib.Git.RevParseOpts, git_cmd?: string): string|nil, err?       -- full object name; short / commit (peel) options
M.merge_base(a: string, b: string, opts?: Lib.Git.RunOpts, git_cmd?: string): string|nil, err?  -- nil, "no common ancestor" for unrelated histories
M.is_ancestor(ancestor: string, rev: string, opts?: Lib.Git.RunOpts, git_cmd?: string): boolean|nil, err?   -- nil = git could not tell
M.tags(opts?: Lib.Git.TagsOpts, git_cmd?: string): Lib.Git.Tag[]|nil, err?   -- name, sha (peeled), object, annotated, time, subject; merged / no_merged / pattern / limit / sort
M.rev_parse_async / merge_base_async / is_ancestor_async / tags_async         -- same arguments plus `on_done` before `git_cmd`; vim.schedule-dispatched; return { stop }
M.LOG_FORMAT: string                                                           -- the --format= argument `log` passes (for a caller that runs `git log -z` itself)

-- Syncing with the remote (all async, vim.schedule-dispatched, return { stop }; git_cmd? as above)
-- opts: Lib.Git.NetOpts = Lib.Git.RunOpts (the verbs use dir, env, timeout_ms; no_lazy_fetch adds -c protocol.allow=never, so the verb
--       fails; max_output_bytes, read_only, input, binary have no effect) with timeout_ms?: integer|false -- false = no deadline, nil = 120000;
--       env is merged over { GIT_TERMINAL_PROMPT = "0" } and wins. Every git process of a call gets the same env and deadline:
--       the fetch, the pull, and the two rev-parse HEAD reads around the pull of pull_async / update_async
M.fetch_async(opts: Lib.Git.NetOpts|nil, on_done: fun(ok, err|nil, changed|nil), git_cmd?: string): { stop }   -- git fetch --all --prune; changed = a remote-tracking ref moved
M.pull_async(opts: Lib.Git.NetOpts|nil, on_done: fun(ok, err|nil, changed|nil), git_cmd?: string): { stop }    -- git pull --ff-only; changed = HEAD moved; silent once stop() was called
M.push_async(opts: Lib.Git.NetOpts|nil, on_done: fun(ok, err|nil), git_cmd?: string): { stop }                 -- git push
M.update_async(opts: Lib.Git.NetOpts|nil, on_done: fun(ok, err|nil, changed|nil), git_cmd?: string): { stop }  -- fetch, then pull (the pull's changed); silent once stop() was called
```

A killed git (OOM, `stop()`, crash) is a **failure** everywhere here (`code = 128 + signal`, `signal` set), never an
empty answer — also for the sync verbs, whose `err` then reads "git push failed (exit code 143)" (the POSIX shape; on
Windows libuv delivers a kill as exit code 1 with signal 15, so it reads "exit code 1" there), and for the async readers
`status_porcelain_async`/`show_async`/`blame_porcelain_async`; a git that cannot be
started reports why (`ENOENT: …`), not "exit code -1". After `stop()`, `pull_async`/`update_async` never call `on_done`
(`update_async` does not start its pull either); `fetch_async`/`push_async` call it once, with the kill as the failure
(on Windows possibly late: the exit is reported after helper processes such as `git-remote-http` have ended).
The sync verbs run with `GIT_TERMINAL_PROMPT=0` (`opts.env` wins) and kill each git process after 120 s unless
`opts.timeout_ms` says otherwise (`false` = no deadline); a deadline that was hit is the failure "git fetch timed out
after 120s" (`1.5s` for a fractional one, `500 ms` below a second), never an exit code. The same environment and deadline
reach the two `rev-parse HEAD` reads that `pull_async`/`update_async` make around the pull. On a timeout the whole
process group is killed (POSIX; Windows: the whole process tree), so a transport helper such as `git-remote-https` does
not outlive the deadline. Details: the module README, "Syncing with the remote".
`no_lazy_fetch` sets `GIT_NO_LAZY_FETCH=1` and `-c protocol.allow=never`, so it holds on git < 2.44.

`lib.nvim.git.remote` (pure, no process): `parse_remote(url)`, `host_kind(host, hosts_cfg?)`
(`hosts_cfg` is optional), `build(kind, remote, branch, rel_path?, first?, last?)` and the
history URLs `commit_url(kind, remote, sha)`, `compare_url(kind, remote, base, head)` (three-dot)
and `tag_url(kind, remote, tag)` — GitHub / GitLab (`/-/` namespace) / Codeberg shapes, every
ref/path part percent-encoded; parse_remote validates host/owner/repo (plain names only, else nil).

---

## `lib.nvim.net.curl` (see README)

Async/blocking HTTP-via-curl. Spawns via `vim.system` (Neovim 0.10+, no
`jobstart` fallback). curl's exit code ≠ HTTP status — `fetch_raw*` parse
status from the response's status line.

```
M.fetch_raw(url, opts: Lib.Net.Curl.FetchOpts|nil, cb: fun(ok, response_or_err, raw_obj))          -- async
M.fetch_raw_blocking(url, opts?): boolean ok, response_or_err, raw_obj
M.fetch_json(url, opts, cb: fun(ok, data_or_err, raw_obj))                                          -- async, JSON-decoded
M.fetch_json_blocking(url, opts?): boolean ok, data_or_err, raw_obj
```

## `lib.nvim.net.github` (see README)

GitHub REST API on top of `net.curl`: `Accept`/`X-GitHub-Api-Version` headers,
bearer token off argv, `If-None-Match` from `opts.etag`. 304 is a result
(`not_modified`); any other 3xx, 4xx/5xx, a 200 `{message}` error body and an exhausted rate
limit (the error says when it resets) are `nil, err`; `cb` always runs once. The token
goes only to `api_base`'s origin, never over plain http off loopback. `opts.transport` replaces
the curl call (specs). `token` reads `opts.env_var`, then `gh auth token`;
`GITHUB_TOKEN` only when named, and it is stripped from gh's environment.

```
M.request(path_or_url, opts: Lib.Net.Github.RequestOpts|nil, cb: fun(result|nil, err|nil))   -- async, cb on the main loop
M.request_blocking(path_or_url, opts?): Lib.Net.Github.Response|nil, string|nil
  -- Response = { status, etag, data, not_modified, rate_limit = { remaining, reset }, headers }
M.token(opts?: { env_var?, timeout_ms?, runner? }): string|nil token, string source_or_reason
```

---

## `lib.nvim.lua_ls.*`

### `lib.nvim.lua_ls.get_module_path` (see README)
Absolute file path -> the `require`-style dotted module path (finds the
first `/lua/` segment, strips `.lua`/trailing `/init`, dot-joins).

```
return function(filepath: string): string|nil module_path
```

### `lib.nvim.lua_ls.insert.module_annnotation` (see README — note: directory
literally spelled `module_annnotation`, triple-n, in the source tree)
Inserts a `---@module '...'` annotation at a buffer position.

```
return function(opts?: { bufnr?, row?, col? }): boolean success
  -- no args -> current buffer + cursor; explicit position overrides cursor
```

---

## `lib.nvim.cache.*`

### `lib.nvim.cache` (aggregator, see README) — `disk`, `memory` and `invocation`.

### `lib.nvim.cache.invocation`
A cache that lives for one call (`run`); a run belongs to the coroutine that started it.
```
M.new(name: string): Scope                      -- independent scope; same name does not share values
Scope:run(fn, ...): any...                      -- values live until the outermost run ends; errors re-raised unchanged
Scope:memo(key: string, produce: fun(): any): any   -- outside a run: produce() every time; nil/false are cached too
Scope:active(): boolean
Scope:editor_state(): EditorState               -- read_editor_state(), once per run
M.read_editor_state(): { buf, win, mode, cursor, cfile, cword, selection, buffer_path }
```

### `lib.nvim.cache.disk`
Persistent JSON disk cache with TTL, one JSON file per namespace under
`stdpath("cache")/lib.nvim/cache/<namespace>.json`.
```
M.save(namespace: string, data: any, opts?): boolean ok, string|nil err
M.load(namespace: string, opts?): any|nil
M.clear(namespace: string, opts?): boolean ok
M.stats(namespace: string, opts?): Lib.Cache.Stats
```

### `lib.nvim.cache.memory`
In-memory cache namespaces: per-key TTL and/or buffer-`changedtick`
validation, hit/miss/eviction stats, opt-in autocmd auto-invalidation.
Does not survive restart; monotonic clock (`vim.uv.hrtime`).
```
M.namespace(name: string, opts?): Lib.Cache.Memory.Namespace
  -- ns.get(key, bufnr?), ns.set(key, value, bufnr?), ns.invalidate(key), ns.clear(), ns.stats()
M.setup_auto_invalidation(opts?: { prefix? })   -- idempotent; TextChanged prunes, BufWritePost clears all
M.disable_auto_invalidation()
M.is_auto_invalidation_enabled(): boolean
M.get_all_stats(): Lib.Cache.Memory.Stats[]
M.format_stats(all?): string[]   -- aligned text: header, one row per namespace (name, entries, hits, misses, invalid, evict, hit rate), total
M.print_all_stats()
-- lib.nvim.cache.routes(): table[]  -- the `:Lib cache stats` route (merged into :Lib by lib.nvim_usrcmds)
```

---

## `lib.nvim.core` (see README)

Grab-bag: memoized executable lookup, preallocated `nvim_echo` wrapper.

```
M.has_exec(bin: string): boolean            -- memoized per binary name
M.first_available(candidates: string[]): string|nil
M.forget_exec(bin: string): nil             -- drops cached result
M.simple_echo   -- = require("lib.nvim.core.simple_echo") (lazy)
```

### `lib.nvim.core.simple_echo` (no README)
```
return function(msg: string, hl: string|nil, is_error: boolean|nil): integer|string
```

---

## `lib.nvim.normalize.*` (aggregator, see README)

Strict coercion toolkit for plugin configs at config boundaries, plus
schema-merge utilities. Pure; uses `vim.fs.normalize`/`vim.uv` with fallback.

**Direct value normalizers** (return `nil` on unparseable input, not an error):
```
M.to_bool(v): boolean|nil
M.to_int(v, min?, max?): integer|nil          -- truncates toward zero, clamps
M.to_float(v, min?, max?, precision?): number|nil
M.to_string(v, allow_empty?, do_trim?): string|nil
M.to_enum(v, allowed, case_insensitive?): string|nil
M.to_string_list(v, opts?: {sep?, trim?, dedup?}): string[]|nil
M.to_argv(v): string[]|nil                     -- best-effort shell-token split, double-quote segments only
M.to_diagnostic_severity(v): integer|nil       -- -> vim.diagnostic.severity.*
M.to_log_level(v): integer|nil                 -- -> vim.log.levels.*
M.to_path(v, type_filter?, must_exist?): string|nil
```

### Validators, `(ok, val, err)` contract
```
M.as_int(name, v, min, allow_nil): boolean ok, integer|nil val, string|nil err
M.as_bool(name, v): boolean ok, boolean|nil val, string|nil err   -- only real Lua booleans, no coercion
M.is_one_of(v, candidates): boolean
M.buf_valid(bufnr): boolean
M.win_valid(winid): boolean
```

### Utilities
```
M.trim(s): string
M.clamp(n, min, max): number
M.coalesce(...): T|nil                          -- first non-nil
M.path_kind(p): "file"|"directory"|""
M.normalize_path(p): string                     -- ~/$VAR/%VAR% expansion then vim.fs.normalize
M.dedup_strings(list): string[]                 -- order-preserving
M.normalize_switch_group(v, key?): table|nil    -- false -> {enable=false} (key names the switch), true -> {}, table -> deep copy, else nil (REL-20)
```

---

## `lib.nvim.require` (see README)

Safe/extended `require` utilities.

```
M.safe(name: string): boolean ok, any result       -- pcall(require, name)
M.dir(dir: string, calls?: string|string[]|"")
  -- non-recursively requires every *.lua directly in stdpath("config").."/lua/"..dir, then
  --   nil -> mod.setup({}); string -> call that name (""=require only); string[] -> call each in order
M.lazy(module_name: string): fun(): table          -- requires+caches on first call
```

---

## `lib.nvim.safe_api` (see README)

Validated, `pcall`-wrapped `vim.api` accessors for buffers/windows — every
call shares return shape `(success, result, error)`.

```
M.safe_call(fn: function, ...): boolean success, any|nil result, string|nil error
M.is_valid_buffer(bufnr): boolean       -- fast, no pcall
M.is_valid_window(winnr): boolean       -- fast, no pcall
M.buf_get_lines(bufnr, start, end_, strict_indexing): boolean, string[]|nil, string|nil
M.buf_line_count(bufnr): boolean, integer|nil, string|nil
M.buf_get_option(bufnr, name): boolean, any|nil, string|nil
M.buf_set_option(bufnr, name, value): boolean, nil, string|nil
M.buf_set_extmark(bufnr, ns_id, line, col, opts): boolean, integer|nil, string|nil
M.set_extmark(bufnr, ns_id, line, col_start, col_end, hl_group, line_content, priority?): boolean, integer|nil, string|nil
M.buf_clear_namespace(bufnr, ns_id, line_start, line_end): boolean, nil, string|nil
M.win_get_option(winnr, name): boolean, any|nil, string|nil
M.win_set_option(winnr, name, value): boolean, nil, string|nil
M.win_get_buf(winnr): boolean, integer|nil, string|nil
M.win_close(winnr, force): boolean, nil, string|nil
M.buf_delete(bufnr, opts?): boolean, nil, string|nil
M.with_retry(fn, max_retries, ...): boolean, any|nil, string|nil   -- retries only "invalid"/"closed"-looking errors
```

---

## `lib.nvim.system.*` (aggregator, see README)

Host-environment namespace: cached OS/shell/paths snapshot, Windows
named-pipe RPC helper, cross-platform system-info probe. Pure by default;
side effects opt-in via `setup()`.

```
M.setup(opts?: Lib.System.SetupOptions)
  -- flags: publish_globals, rpc_pipe, info_usercmd (each true=defaults or table/string forwarded)
```

### `lib.nvim.system.env`
Memoized host-environment snapshot.
```
M.get(opts?: { refresh? }): Lib.System.Env   -- is_windows, is_wsl, is_linux, is_macos, repo_base, pathsep, home (+ is_pwsh, deferred to first read)
M.publish_globals(opts?: { fields? })         -- mirrors snapshot fields to vim.g.*
```

### `lib.nvim.system.rpc_pipe`
Predictable RPC server on a Windows named pipe (no-op off Windows). The address is
**not** exported as `NVIM_LISTEN_ADDRESS` unless `export = true` (children inherit it and die).
```
M.setup(opts?: { debug?, allow_override?, export? (default false), pipe? })
M.is_active(): boolean        -- a pipe was started (or found pre-set)
M.get_address(): string|nil   -- the pipe name to connect to
M.clear()                     -- stop the pipe setup started, unset an exported variable
```

### `lib.nvim.system.info`
Cross-platform system information (OS/CPU/RAM/GPU/uptime); backend:
`fastfetch` -> `neofetch` -> platform-native probe.
```
M.build_cmd(opts?): string[] argv
M.get(opts?): string[]|nil lines, string|nil err
M.show(opts?): integer|nil winid, integer|nil bufnr   -- centered float, copies to clipboard by default
M.create_usercmd(name?, opts?)                          -- registers :SystemInfo or custom name
```

### `lib.nvim.system.proc_trace`
Instruments `vim.fn.system`/`systemlist`, `vim.system`, `vim.fn.jobstart`
to measure call duration and log a traceback above a threshold.
```
M.start(opts?: { threshold_ms? (default 200), path? }): { path, active }   -- idempotent
M.stop(): { path, active }
M.is_active(): boolean
M.log_path(): string|nil
```

### `lib.nvim.system.job`
Thin `vim.system` wrapper restoring plenary.job-like ergonomics.
```
M.start(opts: Lib.System.Job.Opts): vim.SystemObj
  -- on_stdout/on_stderr: one call per complete line, trailing \r stripped, already vim.schedule-wrapped
```

---

## `lib.nvim.token` (see README)

Ephemeral session-nonce/token generator. **Not cryptographically secure.**

```
M.gen_token(len?: integer): string   -- default length 16, lowercase hex
```

---

## `lib.nvim.neotree.*`

### `lib.nvim.neotree.node` (see README)
Pure, side-effect-free Neo-tree node/path extraction utilities.
```
M.get_current(state): Lib.Neotree.RawNode|nil
M.get_path(node): string path, boolean is_dir       -- never nil; falls back to "", false
M.collect_nodes(state): Lib.Neotree.RawNode[]        -- marked nodes, else [cursor node]
M.extract_paths(nodes): string[] paths, string[] names
M.get_line_number(state, node_id): integer|nil
```

### `lib.nvim.neotree.watch` (see README)
File-watcher handle registry + proactive release — fixes a Windows
file-lock that intermittently blocks renaming/deleting a directory
neo-tree is watching.
```
M.install(): boolean ok       -- patches neo-tree's fs_watch; idempotent; false if neo-tree absent
M.installed(): boolean
M.release(paths: string|string[]): integer released
M.with_release(paths, fn: fun(): any): any
M.count(): integer
M.list(): { path, active, exists }[]   -- exists=false is the leak signature
M.clear()
```
