# API Reference — UI, windows, buffers

Part of the [lib.nvim API reference](README.md). Covers
`lib.nvim.buf_win_tab.*`, `lib.nvim.window.*`, `lib.nvim.ui.*`,
`lib.nvim.notify.*`, `lib.nvim.selection`, `lib.nvim.terminal`,
`lib.nvim.companion`, and `lib.nvim.buffer.*`.

---

## `lib.nvim.buf_win_tab.*`

### `lib.nvim.buf_win_tab.buffer_utils` (no README; documented in sibling `Command-List.md`)
Inspecting and reacting to Neovim buffers.

```
M.DEFAULT_EXCLUDE_FILETYPES: string[]   -- neo-tree, NvimTree, qf, TelescopePrompt, alpha, startify, packer, help, notify
M.count_listed_buffers(): integer
M.count_real_listed_buffers(exclude_filetypes?: string[]): integer
M.get_buffer_info(bufnr: number): table
M.list_all_buffers_info(): table[]
M.list_listed_buffers_info(): table[]
M.format_buffers_table(buftable: table[]): string
M.print_buffers_table(buftable: table[]): nil
M.collect_all_buffer_info(): table   -- {listed_count, real_listed_count, listed, all, formatted_listed}
M.print_summary(): nil
```

### `lib.nvim.buf_win_tab.tabs_utils` (no README; documented in `Command-List.md`)
Inspect/format tabpage information.

```
M.list_tabs(): TabInfo[]
M.format_tab_one_line(info: TabInfo): string
M.print_tabs(tabs?: TabInfo[]): nil
M.get_current_tab(): TabInfo?
M.get_tab_by_number(tabnr: integer): TabInfo?
M.is_single_tab(): boolean
M.collect_report(): table   -- {count, tabs, textual}
-- TabInfo = { tabnr, tabpage, wins, bufs, current_win, current_buf }
```

### `lib.nvim.buf_win_tab.tab_buffers` (header comment)
The buffers of the current tab in the order a user sees them, through a four-step fallback chain.
```
M.list(): integer[] bufnrs, "vim.t.bufs"|"tabpagebuflist"|"windows"|"getbufinfo"|nil source
M.nth(n: integer): integer|nil bufnr
```
The first step with a valid buffer wins; invalid numbers are dropped, duplicates removed, order kept.

### `lib.nvim.buf_win_tab.windows_utils` (no README; documented in `Command-List.md`)
Inspect buffers/tabs/windows, cross-platform.

```
M.count_listed_buffers(): integer
M.list_all_buffers_info(): table[]
M.get_listed_buffer_ids(): integer[]
M.get_buffers_grouped_by_filetype(): table<string, integer[]>
M.get_current_buffer_info(): table
M.get_tabpage_buffers(tabnr?: integer): integer[]
M.format_buffers_report(): string
M.only_nonfile_listed_buffers(): boolean
  -- true when every listed buffer is non-file (matches buffer_utils.DEFAULT_EXCLUDE_FILETYPES,
  -- or has a non-empty buftype like terminal/quickfix/nofile); vacuously true if none qualify
M.collect_all_state(): table
M.show_aggregated_state(silent?: boolean): string|nil
M.collect_win_report(winid?: integer): { textual: string[], raw: table }
```

### `lib.nvim.buf_win_tab.capture` (see README)
Deterministic capture of buffers/windows created by an Ex command, via
delta-detection + optional polling.

```
M.capture(cmd: string, opts?: BufWinCapture.Opts, cb?: fun(result)): BufWinCapture.Results|nil
```
`opts`: `{ timeout?, interval?, tag?: {buf?, win?}, emit_event? }`. Sync
(no `cb`): blocks until timeout, returns `{ wins: integer[], bufs: integer[] }`.
Async (`cb` given): returns `nil` immediately, calls `cb(result)` later.

### `lib.nvim.buf_win_tab.get_option` (see README)
Read a buffer option across Neovim versions (tries
`nvim_get_option_value` → `nvim_buf_get_option` → `vim.bo` → `nvim_buf_call`+`vim.bo`).

```
return function(bufnr: integer, name: string): any|nil
```

### `lib.nvim.buf_win_tab.move_buffer_to_tab` (see README)
Moves the current buffer out of the current tab into the next/new tab.

```
return function(): nil   -- acts on current buffer/window/tab, no arguments
```

### `lib.nvim.buf_win_tab.normal_buffer` (see README)
Shared primitives around "normal" file buffers.

```
M.is_normal_file_buffer(bufnr?: integer): boolean
M.find_last_normal_window(exclude_win?: integer): integer|nil bufnr, integer|nil winid
M.edit_in_window(winid: integer, path: string): boolean ok, string|nil err
M.prompt_save(bufnr: integer): boolean proceed   -- blocking vim.fn.confirm
```

### `lib.nvim.buf_win_tab.resize_guarded` (see README)
Factory for window-resize keymap callbacks that forward the raw key to
terminal/plugin buffers instead of intercepting it.

```
M.create(cmd: string, exclude_filetypes?: string[]|nil, exclude_names?: string[]|nil, lhs: string): function
```

### `lib.nvim.buf_win_tab.safe_adjacent_buffer` (see README)
Force-saves (`:w!`) the most relevant *normal* file buffer without ever
touching the current buffer.

```
M.save_last_normal_buffer(): nil
```

### `lib.nvim.buf_win_tab.selection` (see README)
Read the current/most-recent Visual selection whether or not Visual mode
is still active. (Contrast `lib.nvim.selection`, which *restores* a
selection after a mutation.)

```
M.get_visual_selection(): Lib.BufWinTab.Selection|nil   -- {lines, start_row, start_col, end_row, end_col}
M.reselect_visual(): boolean ok   -- programmatic gv
```

### `lib.nvim.buf_win_tab.word_under_cursor` (see README)
Extract the word under the cursor with a configurable word-character
pattern and its byte span.

```
return function(opts?: { pattern?: string }): { word: string, start_col: integer, end_col: integer, row: integer } | nil
  -- opts.pattern default "[%w_']"; start_col 0-based incl., end_col 0-based excl., row 1-based
```

---

## `lib.nvim.window.*`

### `lib.nvim.window` (aggregator, see README)
Overlay/floating window helpers (not normal file windows): scratch
buffers, close-on-key, title, positioning, focus, tagging. Two
consumption styles: free functions, or `attach(winid)` bound handle.

```
M.nice_quit, M.set_title, M.make_scratch, M.close_on_focus_lost, M.center
M.is_usable_window, M.target_window                          -- from find_usable
M.ensure_bottom, M.make_focusable, M.force_focus, M.reveal_at_bottom   -- from focus_helpers
M.open_named_scratch, M.open_scratch_split, M.tag
M.attach(winid: integer): Lib.Window.Handle
  -- dot-call bound wrapper; every winid-first method above becomes handle.method(...)
```
> `find_by_filetype.lua` exists as a flat file but is **not** re-exported
> from `init.lua` — require it directly.

### `lib.nvim.window.make_scratch` (documented in directory README)
Creates an unlisted `nofile`/`bufhidden=wipe` scratch buffer inside a
centered floating window in one call.

```
return function(opts?: Lib.Window.MakeScratchOpts): integer|nil winid, integer|nil bufnr
```
`opts`: `lines, width, height, relative, row, col, border, title,
title_pos, focusable, enter, zindex, filetype, modifiable, nice_quit
(boolean|NiceQuitOpts), wo, bo`.

### `lib.nvim.window.nice_quit` (documented in directory README)
Binds `q`/`<Esc>` (buffer-local, Normal-mode only) to close a window;
never closes the tabpage's last window.

```
return function(winid: integer, opts?: { keys?: string[], force?: boolean }): boolean ok
```

### `lib.nvim.window.set_title` (documented in directory README)
```
return function(winid: integer, title: string|nil, opts?: { pos? }): boolean ok
```

### `lib.nvim.window.close_on_focus_lost` (documented in directory README)
One-shot buffer-local autocmd that closes a window as soon as focus leaves it.

```
return function(winid: integer, opts?: { events?: string[], force?: boolean }): integer|nil augroup
  -- events default {"WinLeave","BufLeave"}, force default true
```

### `lib.nvim.window.center` (documented in directory README)
```
return function(winid: integer): boolean ok   -- no-op on non-floats/invalid
```

### `lib.nvim.window.matches` (documented in directory README)
Window-local match ledger over `matchadd`/`matchdelete`, addressed by name.
```
M.new(): Ledger
Ledger:add(win, name, group, pattern, opts?: {priority?, conceal?}): integer|nil id, string|nil err   -- same name replaces
Ledger:add_pos(win, name, group, positions, opts?): integer|nil, string|nil
Ledger:remove(win, name): boolean ; :clear(win): integer ; :clear_all(): integer
Ledger:has(win, name): boolean ; :list(win): table<string, integer>
```

### `lib.nvim.window.find_by_filetype` (no README)
```
M.find_by_filetype(filetype: string): integer|false winid
```

### `lib.nvim.window.find_usable` (no README)
Find a "normal" window (not floating, not a known sidebar filetype) to
reuse for content.

```
M.is_usable_window(winid: integer): boolean
M.target_window(opts?: { current_tab_only?: boolean }): integer|nil winid
M.best_target_window(opts?: { source_win?: integer, writable?: boolean, current_tab_only?: boolean }): integer|nil winid
  -- chain: source_win -> alternate window -> first usable; each normal + modifiable unless writable = false
  -- SIDEBAR_FILETYPES: neo-tree, NvimTree, aerial, Outline, qf
```

### `lib.nvim.window.focus_helpers` (no README)
```
M.is_at_bottom(winid: integer): boolean
M.ensure_bottom(winid: integer, opts?: { retries?, attempts?, retry_delay_ms? })
  -- retries (default 3): window doesn't exist yet, retried via vim.schedule
  -- attempts (default 1 = off): cursor-set didn't land at the bottom, retried `retry_delay_ms` (default 60) apart
M.make_focusable(winid: integer): boolean ok
M.force_focus(winid: integer): boolean ok
M.reveal_at_bottom(winid: integer, opts?: { attempts?, retry_delay_ms? }): boolean ok
  -- skips `relative == "win"` / degenerate (<=1 cell) windows; runs `normal! G` once focus lands
```

### `lib.nvim.window.open_named_scratch` (documented in directory README)
Find-or-replace a named, de-duplicated scratch buffer shown in a split.

```
return function(name: string, lines?: string[], opts?: { filetype?, split?, size?, modifiable? }): integer bufnr, integer winid
```

### `lib.nvim.window.open_scratch_split` (documented in directory README)
Fresh (non-de-duplicated) scratch buffer in a plain split — for
report/audit-style output.

```
return function(lines?: string[], opts?: Lib.Window.OpenScratchSplitOpts): integer bufnr, integer winid
```

### `lib.nvim.window.tag` (documented in directory README)
Identify windows by an arbitrary string tag in `vim.w[win].custom_tag`
(same convention as `buf_win_tab.capture`'s `tag` option).

```
M.set(win: integer, tag: string, buf?: integer)
M.get(win: integer): string|nil
M.find(tag: string): integer|nil   -- first live, real content window across all tabpages
```

### `lib.nvim.window.context` (see README)
Window-metadata accessor with a same-event cache.

```
M.get(winid?: integer): Lib.Window.Context.Ctx
  -- { winid, is_valid, bufnr, cursor, topline, botline, width, height,
  --   is_cursor_in_range(start_line,end_line), get_visible_lines() }
M.clear_cache()
M.invalidate(winid: integer)
M.get_stats(): { hits, misses, total_requests, hit_rate }
```

---

## `lib.nvim.ui.*`

### `lib.nvim.ui.hl` (see README)
Idempotent highlight-group definition with optional namespace support, plus
highlight state that survives a theme change.

```
M.namespace(name: string): integer   -- cached nvim_create_namespace
M.set(group: string, opts: Lib.Highlight.Opts, ns?: string|integer|nil)   -- wraps nvim_set_hl
M.persist(spec, opts: Lib.UI.HL.PersistOpts): Lib.UI.HL.PersistHandle
```
`spec` is a group table, or a function returning one (re-evaluated on every
change, so derived colours follow the theme), or a function returning
nothing (a side-effect callback -- clearing a colour-derived cache is the
same problem shaped differently). `opts`: `name` (required; augroup and
identity -- re-registering replaces), `background` (default `true`, also
re-applies on `OptionSet background`), `ns`, `immediate` (default `true`).
Handle: `apply(), detach()`. Replaces 19 hand-written `ColorScheme` blocks
across 7 plugins, which disagreed about all three of those defaults.

### `lib.nvim.ui.list` (see README)
Quickfix and location lists: entries + title in one call, with the stack,
open and focus policy made explicit instead of implicit.

```
M.set(opts?: Lib.UI.List.Opts): integer count
M.qf(items: Lib.UI.List.Item[], title?: string, opts?: Lib.UI.List.Opts): integer count
M.loc(items: Lib.UI.List.Item[], title?: string, opts?: Lib.UI.List.Opts): integer count
```
`opts`: `items` (default `{}`, which clears the list), `title`, `loclist`
(`false` | `true` = current window | window id), `action` (default `" "` pushes
a new list; `"r"` replaces the current one; `"a"` appends), `open` (default
`true`; `"auto"` opens only when non-empty; `false` never), `focus` (default
`"list"`, as bare `:copen`; `"source"` hands the cursor back), `height`.
Does **not** wrap `vim.diagnostic.setqflist`/`setloclist` -- different API,
own severity handling, version-dependent signature.

### `lib.nvim.ui.statusline` (see README)
A short status badge pinned to one row of one window, auto-choosing
between window-local `&statusline` and a float depending on `laststatus`.

```
M.is_global(): boolean   -- true when laststatus >= 3
M.resolve_mode(mode?: "auto"|"statusline"|"float"): "statusline"|"float"
M.attach(winid: integer, opts?: Lib.UI.Statusline.Opts): Lib.UI.Statusline.Segment? segment, string? err
```
`opts`: `mode` (default `"auto"`), `align` (default `"left"`), `anchor`
(default `"bottom"`, float-only), `hl`, `zindex` (default 30, float-only).
Segment: `mode(), text(), set(text, hl?), clear(), refresh(), detach()`.

### `lib.nvim.ui.kit` (see README, plus `docs/GUIDE-ui-kit.md`)
Themed, composable UI toolkit built on `lib.nvim.window` + `lib.nvim.ui.hl`.
~19 internal implementation files, independently `require`-able but
intended to be consumed via `init.lua`'s dispatch functions or `kit.popup`.

#### Top-level dispatch API
```
M.theme, M.surface, M.chooser, M.layout            -- re-exported submodules
M.setup(opts?: { default?: string, presets?: table<string,table> })
M.preview(): integer config_buf, integer preview_buf   -- also :KitPreview (registered by M.setup() or the first M.preview(), not by require)
M.note(opts): Lib.UI.Kit.Surface|nil
M.viewer(opts): Lib.UI.Kit.Surface|nil
M.toast(opts): Lib.UI.Kit.Surface|nil
M.input(opts): Lib.UI.Kit.Surface|nil
M.form(opts): Lib.UI.Kit.Surface|nil
M.live_input(opts): Lib.UI.Kit.Surface|nil
M.select(opts)
M.prompt(opts)
M.picker(opts): table|nil
M.compare(opts): Lib.UI.Kit.CompareHandle|nil
M.confirm(opts): Lib.UI.Kit.Surface|nil
M.menu(opts): Lib.UI.Kit.Surface|nil
M.progress(opts): table   -- passthrough to lib.nvim.progress.create
M.sync(open_fn, opts, timeout_ms?): any result, boolean cancelled, boolean timed_out
M.popup(opts): any   -- dispatch on opts.type (default "note")
```

**Internal component/primitive submodules** (each independently
`require("lib.nvim.ui.kit.<name>")`):

```
surface     -- one themed float + lifecycle handle
  M.open(opts?): Surface|nil
  Surface:set_lines(lines), :set_title(title), :focus(), :on_close(cb),
  :is_valid(), :fire_close(), :close()

theme       -- theme/preset engine (built-ins: minimal, rounded, solid, double, ascii)
  M.resolve(theme?), M.materialize(resolved), M.border_glyphs(resolved),
  M.apply(winid, resolved), M.window_groups(resolved), M.role_remaps(resolved),
  M.scoped_group(winid, group), M.refresh(), M.setup(opts?), M.presets(): string[],
  M.default(): string

config      -- static defaults: M.defaults = { default = "rounded" }

layout      -- declarative multi-float layout engine
  M.compute(spec): { slots, outer }              -- pure, no I/O
  M.mount(spec, opts?): { slots, close }
  M.templates                                     -- built-in: picker
  M.template(name, opts?): { slots, close }|nil

note        -- centered title+message float, auto-dismiss
  M.open(opts): Surface|nil

viewer      -- read-only auto-sized info panel (q/<Esc>/focus-loss to close)
  M.open(opts): Surface|nil

toast       -- ephemeral top-right stacking messages
  M.open(opts): Surface|nil   -- default timeout 3000ms
  M.active(): integer         -- live toast count, also prunes dead ones
  M.clear()

input       -- single-line insert-mode prompt (vim.ui.input replacement)
  M.open(opts): Surface|nil   -- supports secret masking, completion

live_input  -- like input but debounces on_change(query) as the user types
  M.open(opts): Surface|nil   -- debounce default 80ms

form        -- sequential multi-field prompt chaining kit.input calls
  M.open(opts): Surface|nil   -- fields = {{name, label|prompt, default?, required?, ...}}

select      -- native themed list chooser; optionally delegates to overridden vim.ui.select
  M.open(opts): Surface|nil

prompt      -- ask a question: confirm (yes/no/custom) or text
  M.open(opts): any

confirm     -- horizontal button-confirm dialog (single active instance, mouse-clickable)
  M.is_open(): boolean, M.close(), M.current_focus(): integer, M.click(),
  M.move(delta), M.confirm(), M.cancel(), M.open(opts): Surface|nil

menu        -- cursor-anchored action list
  M.open(opts): Surface|nil   -- items = {{label, action}, ...}

picker      -- interactive Telescope-style picker (prompt + results + preview slots)
  M.open(opts): table|nil
  -- returned handle: { slots, query(), set_results(lines), move(delta), submit(), close() }

compare     -- pick two items from one picker, view side by side (SEARCH -> MARKED -> COMPARE)
  M.open(opts): CompareHandle|nil
  -- handle: { close(), state(), slots(), move(delta), mark(), confirm() }

chooser     -- low-level native list chooser kit.select delegates to (single active instance)
  M.is_open(), M.close(), M.move(delta), M.current_index(), M.current_item(),
  M.toggle()   -- multi-select mark toggle
  M.submit(), M.open(opts): Surface|nil

sync        -- blocking vim.wait() bridge for on_submit/on_cancel-shaped components
  M.open(open_fn, opts, timeout_ms?): any result, boolean cancelled, boolean timed_out
  -- default timeout 10 min; must not be called from a fast-event context

preview     -- live theme playground (:KitPreview, once setup() ran or M.open()/M.ensure_command() was called)
  M.render(config_buf, preview_buf), M.ensure_command(), M.open(): config_buf, preview_buf
```

---

## `lib.nvim.notify.*`

### `lib.nvim.notify` (see README)
Generic per-module-prefixed notification factory mirroring `vim.notify`
semantics.

```
M.create(prefix: string): Lib.Notify.Notifier
  -- { notify(msg, level?, opts?), info(msg, opts?), warn(msg, opts?), error(msg, opts?), debug(msg, opts?) }
M.safe   -- = require("lib.nvim.notify.safe")
```

### `lib.nvim.notify.resolve_log_level` (see README)
```
return function(level?: LogLevel, default?: LogLevelNumber): integer resolved_level
  -- default fallback: vim.log.levels.WARN
```

### `lib.nvim.notify.safe` (see README)
Safe wrappers around `vim.notify` for fast-event contexts.

```
M.schedule(msg: string, level?: integer, opts?: table)   -- via vim.schedule
M.defer(msg: string, level?: integer, opts?: table, delay_ms?: integer)   -- via vim.defer_fn
M.wrap(): fun(msg, level?, opts?)   -- reusable vim.schedule_wrap'd notifier
M.notify(msg, level?, opts?, mode?: "schedule"|"defer"|"wrap", delay_ms?)
M.create_safe(prefix: string): Lib.Notify.Safe.Notifier   -- always dispatches via schedule
```

---

## `lib.nvim.selection` (see README)

Reselect a Visual-mode line/char range after a mapping mutates the buffer
(Neovim drops Visual selection the instant a mapped function returns).
Distinct from `lib.nvim.buf_win_tab.selection` (which just *reads* the
selection).

```
M.lines(): integer srow, integer erow   -- 0-based inclusive
M.reselect_lines(srow, erow)             -- restore linewise (V) selection
M.keep_lines(fn: fun(srow, erow): T): T  -- capture, run fn, reselect same rows
M.chars(): integer|nil row, integer|nil scol, integer|nil ecol   -- only if same-line charwise
M.reselect_chars(row, scol, ecol)        -- restore charwise (v) selection
M.keep_chars(fn: fun(row, scol, ecol): T): T|nil ret, boolean applicable
```

---

## `lib.nvim.terminal` (see README)

Small terminal-buffer helpers: shell-escaping, terminal-buffer
detection/cleanup, Kitty detection.

```
M.escape(path: string): string          -- narrow ad-hoc shell escaping, not full quoting
M.is_terminal_buf(bufnr: integer): boolean|nil
M.delete_terminal_buf(bufnr: integer): boolean|nil   -- force-deletes; does NOT check is_terminal_buf first
M.is_kitty(): boolean
```

---

## `lib.nvim.companion` (see README)

A second Neovim in its own terminal window, fed over msgpack-RPC: one read-only
buffer whose content the main instance pushes, keys there run named actions in
the main instance. First consumer: the dap.nvim memory view.

```
M.open(opts: Lib.Companion.OpenOpts): Lib.Companion.Handle|nil, string|nil
  -- opts: title, lines, highlights, filetype, actions (name -> fn, run HERE),
  --       keys (lhs -> name | { name, args... , prompt? }), on_close, terminal (argv
  --       template with {cmd}; false = headless, no window), attach_timeout (ms,
  --       default 15000; false = no limit), env (tests)
handle:update(lines: string[], highlights?: Lib.Companion.Highlight[]): boolean, string|nil
handle:set_title(title: string): boolean
handle:close()                       -- idempotent; on_close once; the quit is a notification
handle:is_open(): boolean
handle:is_attached(): boolean
M.handles(): Lib.Companion.Handle[]
M.close_all()
-- launch (pure): inner_argv(opts), default_terminal(env), terminal_template(term),
--                expand(template, inner, title), argv(...)
-- protocol: new(transport, clock?) -> registry (create/attach/connect/action/detach/check/close_all),
--           messages, ATTACH_TIMEOUT_MS; the transport has no blocking request (deadlock)
```

---

## `lib.nvim.buffer.*`

### `lib.nvim.buffer.context` (see README)
Buffer-metadata accessor cached by `changedtick` (weak-keyed, auto-GC'd on
buffer deletion). Window-side equivalent of `lib.nvim.window.context`.

```
M.get(bufnr?: integer): Lib.Buffer.Context.Ctx
  -- { bufnr, is_valid, name, filetype, buftype, modifiable, modified, tick,
  --   line_count, size_bytes, lines (lazy), is_normal(), is_processable(...), has_filetype(ft) }
M.invalidate(bufnr: integer)
M.clear_all()
M.get_stats(): Lib.Buffer.Context.Stats
M.print_stats()
```

### `lib.nvim.buffer.get_alternate` (no README)
```
return function(): integer|nil bufnr, string|nil filepath
```

### `lib.nvim.buffer.insert_lines` (no README)
```
return function(lines: string[], pos?: Lib.Buf.InsertLinesPos)
  -- pos: nil -> start; {cursor=true} -> cursor row; {row=n[,col=c]} -> explicit (0-based); {position="end"}
```

### `lib.nvim.buffer.is_markdown_buf` (no README)
```
return function(bufnr_arg?: integer|nil): integer|nil
```

### `lib.nvim.buffer.open_background` (no README)
Add a file to the buffer list without creating or focusing a window.

```
return function(path: string, opts?: { load?: boolean }): boolean ok, integer|string bufnr_or_err
```
