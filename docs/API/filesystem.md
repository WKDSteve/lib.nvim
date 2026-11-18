# API Reference — `lib.nvim.fs.*` (filesystem / path helpers)

Part of the [lib.nvim API reference](README.md). 30 submodules covering
path resolution, root/project detection, directory creation and scanning,
file reading/writing/watching, ignore lists, and opening files/URLs. All
built on `vim.fs`/`vim.uv` (or `vim.loop` fallback), not shell commands,
unless noted.

---

## Working-directory management

### `lib.nvim.fs.chdir` (see README)
Scope-aware working-directory change (global `:cd` / tab `:tcd` / window
`:lcd`), with path normalization via `normkey`, validation, and no throwing.

```
return function(path: string, opts?: Lib.Fs.Chdir.Opts): boolean ok, string? err
```
`opts.scope: "global"|"tab"|"win"` (default `"global"`), `opts.win`, `opts.tab`.

### `lib.nvim.fs.dir_guard` (see README)
Holds the working directory on a path until released, undoing foreign
`DirChanged` events; built on `chdir`.

```
M.hold(path: string, opts?: Lib.Fs.DirGuard.Opts): Lib.Fs.DirGuard.Handle? handle, string? err
```
`opts`: `scope`, `win`/`tab`, `on_violation: fun(new_cwd, held): boolean?`, `on_error: fun(err)`.

Returned handle (closure-based, dot syntax, no `self`):
```
handle.path(): string
handle.is_held(): boolean
handle.update(new_path: string): boolean ok, string? err
handle.bypass(fn: fun()): ...     -- runs fn unguarded, then restores; returns pcall result
handle.release(): nil
```

---

## Root / project detection

### `lib.nvim.fs.find_upward_dir` (see README)
Uncached primitive: walk upward from a directory and return the nearest
ancestor holding one of a set of marker names (plain names or `*`/`?`
globs). Underneath `find_root`.

```
return function(names: string[], from: string, opts?: { stop?: string }): string|nil
```
Sibling `lib.nvim.fs.find_upward_dir.matcher` (no README) — glob-aware
marker matching shared with `find_root`:
```
M.has_glob(names: string[]): boolean
M.build(names: string[]): fun(name: string, path?: string): boolean
```

### `lib.nvim.fs.find_root` (see README)
Cached, marker-based project-root finder (factory). LRU-cached per
directory (or per full chain with `cache_chain`), with `skip_dirs`/
`max_depth` bounding. Built on `find_upward_dir` + `lib.lua.memo.lru`.

```
return function(opts?: Lib.Fs.FindRoot.Opts): Lib.Fs.FindRoot
```
`opts`: `markers: string[]` (default `{".git"}`), `capacity`, `cache`,
`cache_chain`, `skip_dirs`, `max_depth`.
```
finder.find(path: string): string|nil
finder.clear(): nil
```

### `lib.nvim.fs.project_key` (see README)
Stable per-project cache key: prefers the Git root of `path` (via
`find_root`, marker `.git`), falls back to `path`/cwd, always run through
`normkey`.

```
return function(path?: string): string
```

### `lib.nvim.fs.polymorphic_rootresolver` (see README)
Polymorphic LSP root-directory resolver: accepts a filename or bufnr, finds
VCS/config markers upward via `vim.fs.root`, optional `stdpath("config")`
fallback, optional callback.

```
return function(cfg?: RootResolverCfg): fun(arg: string|integer, cb?: fun(root: string)): string
```
`cfg.markers` (default `{".git",".hg",".svn"}`), `cfg.include_stdpath_config` (default `true`).
See also its sibling `example-setup-luals-marksman.md` setup guide.

---

## Path resolution / string manipulation

### `lib.nvim.fs.normkey` (see README)
Canonical, cross-platform cache/dedup key for a path: expands `~`,
optionally resolves symlinks (`uv.fs_realpath`, on by default), forces
forward slashes, uppercases the Windows drive letter, collapses duplicate
separators (UNC-safe).

```
return function(p: string, opts?: { realpath?: boolean }): string   -- realpath default true
```

### `lib.nvim.fs.relpath` (see README)
Compute `path` relative to `base` (both made absolute + forward-slash
normalized); `..`-climbs POSIX-style from the common ancestor; returns the
absolute path unchanged if the two paths share no root (e.g. different
Windows drives).

```
return function(path: string, base: string): string
```

### `lib.nvim.fs.path_shorten` (see README)
Shorten a path for display: `"fit"` (default; ellipsis-collapses the
middle to fit `max_len`) or `"label"` (Harpoon-style
`<root>/<ellipsis>/<parent>/<file>`, ignores `max_len`).

```
return function(path: string, max_len: integer|nil, opts?: Lib.Fs.PathShortenOpts): string
```
`opts.style: "fit"|"label"` (default `"fit"`), `opts.ellipsis`.

### `lib.nvim.fs.path` (see README)
Small grab-bag of path helpers.

```
M.from_repo_relative(raw: string): string   -- resolves repo-root-relative (or absolute) path
M.joinpath(parts: string[]): string          -- wraps vim.fs.joinpath, table.concat fallback
M.ensure_dir(path: string): boolean ok, string? err   -- ensures the *parent* dir of a file exists (fast-event safe)
```

### `lib.nvim.fs.is_subpath` (see README)
```
return function(path: string, base: string, opts?: Lib.Fs.IsSubpathOpts): boolean   -- equality included
```
Without `opts` this is a pure `vim.fs.normalize` string compare (no syscalls).
Pass `opts` to route both sides through `normkey` instead, when the two paths
come from different sources and may spell one directory two ways.

### `lib.nvim.fs.stdpath_config_root` (see README)
"Is `dir` inside `stdpath("config")`, and if so which spelling should an LSP
get?" — answers a path that is always a **prefix of `dir`**, or `nil`. Tries the
normalized `stdpath("config")` and its canonicalized form, so a `~/.config/nvim`
that is a symlink into a dotfiles repo still matches a buffer path Neovim
canonicalized on the way in. Never `stdpath("config")` verbatim, on either
branch: a plain match returns the normalized spelling, the symlink branch the
realpath-canonicalized one — the raw value carries native separators on every
call on Windows (measured), which would otherwise break the prefix-of-`dir`
promise there. The `realpath` is resolved once per `stdpath("config")` value,
not per call — keyed on that string, so a symlink re-pointed at a different
target while Neovim keeps running is not seen until restart.

```
return function(dir: string|nil): string|nil
```

### `lib.nvim.fs.is_valid_filename` (see README)
Validates a bare filename (not a full path) for cross-platform filesystem
safety — rejects Windows-illegal characters `\/:*?"<>|`, embedded NUL,
nil/non-string/empty/whitespace-only.

```
return function(name: string|nil): boolean ok, string|nil err
```

### `lib.nvim.fs.globbable` (see README)
Spells a directory path so it is safe to hand to `vim.fn.glob`/`globpath`.
On Windows, `~` in a glob *pattern* is a home-directory reference, so an
8.3 short name in the path (`C:/Users/STEFAN~1/...`, common under `%TEMP%`)
silently globs to an empty list instead of erroring. Resolves via
`uv.fs_realpath`; a root with no `~` is returned untouched (no syscall), a
missing root is returned unchanged.

```
return function(root: string): string
```

---

## Stat checks

### `lib.nvim.fs.is_dir` (see README)
```
return function(p: string): boolean   -- false on any missing path or stat failure, never raises
```

### `lib.nvim.fs.is_readable_file` (see README)
Despite the name, true for a readable file **or** an existing directory.

```
return function(filepath: string): boolean
```

---

## Directory creation

### `lib.nvim.fs.mkdirp` (see README)
Recursive directory creation (`mkdir -p`) built purely on libuv
(`vim.uv`/`vim.loop` only, no `vim.fn`) — safe from fast-event contexts (uv
timers, `fs_event`, spawn callbacks; `vim.fn.mkdir` there aborts with
`E5560`). Handles POSIX/relative/Windows-drive/UNC paths; mode `0755`.

```
return function(path: string): boolean ok, string|nil err
```

### `lib.nvim.fs.create_entry` (see README)
Create a file or directory relative to a parent directory — shared core
for "create file/folder" picker actions. Trailing separator on `name` →
directory (`mkdir -p` via `mkdirp`); otherwise creates an empty file
(parents via `mkdirp`). Validates each path segment via `is_valid_filename`.

```
return function(parent_dir: string, name: string): boolean ok, "file"|"directory"|nil kind, string|nil path_or_err
```

---

## Directory scanning / walking

### `lib.nvim.fs.collect_recursive` (see README)
Recursive directory walker on `fs_scandir`/`fs_scandir_next`.

```
M.collect(root: string, opts?: Lib.Fs.CollectRecursive.Opts): string[] paths, string[]|nil errors
  -- opts.kind: "all"|"files"|"dirs" (default "all"), opts.ignore: fun(abs_path, is_dir): boolean
  -- errors: nil when every directory could be read, else one "<dir>: <reason>" per
  -- directory fs_scandir refused (root included) -- an empty and an unreadable tree
  -- both yield {} and only `errors` tells them apart
M.files(root: string, opts?): string[], string[]|nil   -- shorthand, kind = "files"
M.dirs(root: string, opts?): string[], string[]|nil    -- shorthand, kind = "dirs"
M.collect_async(root: string, opts?: Lib.Fs.CollectRecursive.Opts, on_done: fun(paths: string[], errors: string[]|nil)): fun() cancel
  -- non-blocking counterpart; coroutine-driven over async fs_scandir/fs_stat, one dir
  -- at a time (not parallel); on_done always vim.schedule-dispatched, never after cancel()
M.files_async(root: string, opts?, on_done): fun() cancel   -- shorthand, kind = "files"
M.dirs_async(root: string, opts?, on_done): fun() cancel    -- shorthand, kind = "dirs"
```

### `lib.nvim.fs.fast` (see README)
Deep list, folder size and recursive watch with the fastest tier there is: the file helper, `fd`,
`rg --files`, a Lua walk (size: helper, Lua; watch: helper, libuv recursive, libuv per folder).

```
M.list(root: string, opts?: Lib.Fs.Fast.ListOpts, on_batch: fun(paths: string[]), on_done: fun(ok: boolean)): fun() cancel
  -- opts: hidden (true), ignore "gitignore"|"names"|"none", names, no_ignore, follow, exclude (globs),
  -- max_depth, skip (Lua walk), tier (force); `.git` is never entered
M.list_all(root, opts?, on_done: fun(paths: string[], ok: boolean)): fun() cancel
M.size(dir: string, on_done: fun(bytes: integer|nil, files: integer|nil, tier: "helper"|"lua"), opts?): fun() cancel
M.watch(root: string, opts?: Lib.Fs.Fast.WatchOpts, on_change: fun(dirs: string[])): { stop, tier, handles }
M.tier(): "helper"|"fd"|"rg"|"lua", string|nil exe
M.norm(path): string   M.resolve(path): string exe, boolean direct   M.running(): integer
```

### `lib.nvim.fs.helper` (see README)
The client of `filetree-helper` (built and released by filetree.nvim), one process for every plugin.

```
M.request(method: "walk"|"size"|"watch", arg: string, handler: fun(kind, payload): boolean|nil, opts?): integer|nil gen
M.drop(gen, method?: "cancel"|"unwatch")   M.tell(gen, "follow", dir)
M.find(): string|nil exe, string|nil why   M.available(): boolean, string|nil
M.configure(mode?)   M.set_mode_provider(fn)   M.mode(): "auto"|false|string   -- vim.g.lib_fs_helper too
M.default_path(): string   -- stdpath("data") .. "/filetree-helper/filetree-helper[.exe]"
M.state(): Lib.Fs.Helper.State   M.health(ok, info, warn)   M.stop()
```

### `lib.nvim.fs.scan_cached` (see README)
Recursively scan one root, memoized in-memory with a TTL (session
lifetime); built on `collect_recursive` + `lib.nvim.cache.memory`.

```
M.scan(root: string, opts?: Lib.Fs.ScanCached.Opts): string[] paths, string[]|nil errors
  -- errors as in collect_recursive; a walk that reported any is returned but not cached
M.scan_async(root: string, opts?: Lib.Fs.ScanCached.Opts, on_done: fun(paths: string[], errors: string[]|nil)): nil
  -- non-blocking counterpart; a miss walks via collect_recursive.collect_async,
  -- a hit still calls on_done (vim.schedule-dispatched either way)
```
`opts`: `kind` (default `"files"`), `ignore`, `ttl_seconds` (default 5), `refresh`.

### `lib.nvim.fs.scan_roots` (see README)
Scan multiple root directories, with directory-name ignoring and an
optional TTL-based on-disk JSON cache. `scan` is sequential; `scan_async` walks one root at a time
unless `opts.concurrency` > 1 (bounded, via `async.map_limit`); the merged result keeps the order of `roots`.

```
M.scan(roots: string[], opts?: Lib.Fs.ScanRoots.Opts): string[] paths, string[]|nil errors
  -- errors merged across roots; a scan that reported any is returned but not written
  -- to cache_path (the cache never expires by default, a transient failure must not stick)
M.scan_async(roots: string[], opts?: Lib.Fs.ScanRoots.Opts, on_done: fun(paths: string[], errors: string[]|nil)): nil
  -- non-blocking counterpart; the JSON cache file itself is still read/written
  -- synchronously, only the per-root walk is async
```
`opts`: `ignore_dirs` (default `{}`), `kind` (default `"files"`), `cache_path?`, `ttl_seconds?` (nil = never expires).
The cache file records `roots`/`kind`/`ignore_dirs`; a read with different ones through the same `cache_path` is a miss, not a hit.

---

## Named roots

### `lib.nvim.fs.roots` (see README)
Named root directories (`$REPOS_DIR`, `$NVIM_CONFIG_DIR`, your own) in one
registry: `expand` / `fold` / `remap` / list. `setup` is the user's (it
replaces); plugins use `register` and the per-call options.

```
M.setup(cfg?: Lib.Fs.Roots.Config): nil              -- enable, vars, nvim_config, extra, source, windows; wrong type / unknown key raises
M.register(name: string, value: string|fun(): string?): fun() unregister   -- survives setup(); the user's `extra` wins on the same name
M.unregister(name: string): boolean
M.enabled(): boolean                                 -- the user's `enable` (fold/remap on at all?)
M.roots(opts?: Lib.Fs.Roots.Opts): { name: string, root: string }[]        -- opts: names, vars (replaces), extra (this call only), nvim_config
M.names(): string[]
M.status(): Lib.Fs.Roots.Status[]                    -- + problem/detail/exists/env; for :checkhealth and json()
M.expand(s: string): string                          -- leading $NAME, ${NAME}, %NAME%, ~ only; unknown stays
M.match(s: string): string|nil, string|nil, string|nil   -- name, root, rest of a leading reference
M.relative(p: string, name: string): string|nil      -- part of p below root `name`, spelling-blind
M.fold(p: string, opts?: Lib.Fs.Roots.FoldOpts): string, string|nil   -- "$NAME/rest", name; deepest root wins; opts: those of roots + force
M.folder(opts?: Lib.Fs.Roots.FoldOpts): fun(p: string): string, string|nil   -- roots resolved once
M.root_of(p: string, opts?: Lib.Fs.Roots.FoldOpts): string|nil
M.remap(p: string, opts?: Lib.Fs.Roots.FoldOpts): string[]   -- a path from another machine under the local roots (existing only, bounded)
M.json(): string / M.print_json(): nil               -- the resolved roots for a reader outside Neovim
M.export_env(): boolean                              -- NVIM_CONFIG_DIR as a real env var (never overwrites the user's)
```
`cross.fs.expand_path` and the composer types `PATH` / `DIR` / `FILE` resolve a leading root reference through it.

---

## Ignore lists

### `lib.nvim.fs.ignore.list` (see README)
Centralized, canonical filesystem ignore rules (basenames + Lua patterns)
for developer tooling doing recursive traversal. No filesystem IO;
heuristic/conservative, not a `.gitignore` replacement.

```
M.basenames: string[]                        -- e.g. .git, node_modules, dist, .venv, ...
M.patterns: string[]                          -- Lua patterns, e.g. %.log, pnpm%-lock.yaml
M.normalize(s: string): string                -- trims trailing slash, lowercases on Windows
M.as_set(): table<string, boolean>            -- basenames as a lookup set
M.as_luals_patterns(): string[]               -- basenames -> LuaLS workspace.ignoreDir globs
M.as_telescope_patterns(): string[]           -- basenames + patterns, for file_ignore_patterns
M.as_neotree_names(): string[]                -- basenames only, for Neo-tree hide_by_name
```

---

## File reading / writing / mutation

### `lib.nvim.fs.read` (see README)
```
return function(path: string): string|nil content, string|nil err   -- binary mode, byte-exact
```

### `lib.nvim.fs.read_bounded` (see README)
```
return function(path: string, max_bytes: integer, opts?: { follow_symlinks?: boolean }): string|nil content, string|nil err
-- regular files of at most max_bytes only (stat before open): no FIFO hang, no device, no huge file
```

### `lib.nvim.fs.write.to_file` (see README)
Synchronous, byte-exact write (creates parent dir, truncates, binary
`"wb"`, appends trailing newline if missing).

```
return function(path: string, content: string): boolean, string|nil
```

### `lib.nvim.fs.write.append` (see README)
Sibling of `write.to_file` (which truncates) — appends instead.

```
return function(path: string, content: string): boolean ok, string|nil err
```

### `lib.nvim.fs.write.async` (see README)
Asynchronous counterpart: creates parent dir synchronously, then writes via
libuv without blocking.

```
return function(path: string, content: string, cb: fun(ok: boolean, err: string|nil))
```

### `lib.nvim.fs.write.batch` (see README)
Write many files asynchronously via `write.async`, one callback once all
have settled.

```
return function(entries: {path: string, content: string}[], cb: fun(all_ok: boolean, results: {path, ok, err}[]))
```

### `lib.nvim.fs.json` (see README)
Read/write JSON files. Encoding via `lib.lua.json.encode`; decoding via
`vim.json.decode`. Writes are atomic (write to a sibling temp file unique per
write, `M.tmp_path(path)`, then `fs_rename`).

```
M.read(path: string): table|nil decoded, string|nil err
M.write(path: string, tbl: table): boolean ok, string|nil err
```

### `lib.nvim.fs.trash` (see README)
Cross-platform "send to trash/recycle bin" (not permanent delete).
Dispatches to the OS-native mechanism (PowerShell on Windows, Finder via
`osascript` on macOS, `gio trash`/`trash-put` on Linux/WSL, XDG-move
fallback otherwise).

```
M.trash(path: string, cb: fun(ok: boolean, err: string|nil))   -- async
M.trash_blocking(path: string): boolean ok, string|nil err
```

---

## Portable artifacts (placeholders for machine-specific roots)

### `lib.nvim.fs.portable` (see README)
Root paths become placeholders when a file is written and are resolved again on read through a temporary
copy; the stored file is never changed. Boundary-aware (`ui.nvim` does not match inside `ui.nvim-backup`).

```
M.make(content: string, roots: Lib.Fs.Portable.Root[]): string       -- { path, placeholder }[]; longest root wins
M.resolve(content: string, roots, opts?: { remap?: table<string,string> }): string
M.make_file(path: string, roots): boolean ok, string|nil err         -- in place, byte-exact, atomic
M.resolve_file(path: string, roots, opts?: { remap?, suffix? }): string source, boolean is_temp, string|nil err
  -- source is a temp copy when anything was resolved (the caller deletes it), otherwise `path`
```

---

## Watching for changes

### `lib.nvim.fs.watch` (see README)
Generic "watch this path, debounced, call me on change" primitive:
`uv.new_fs_event()` plus `lib.nvim.debounce`, since one filesystem change
can fire the raw event several times in quick succession.

```
M.start(path: string, on_change: fun(path, filename, events), opts?: { debounce_ms?: integer, recursive?: boolean }): Lib.Fs.Watch.Handle|nil handle, string|nil err
  -- handle.stop(): nil   -- safe to call more than once
  -- start() returns before the backend is guaranteed live (macOS: a change in the first
  -- milliseconds may go unreported) -- see the module README, "Start-up latency"
```
`opts.debounce_ms` default `200`; `opts.recursive` default `false` (ignored
by Linux's `inotify` backend — a recursive watch there needs one `M.start`
per subdirectory).

---

## Opening files / URLs

See [`lib.nvim.cross.open_default`](cross-platform.md) — open a path or URL
with the OS default handler. This used to live under `lib.nvim.fs` as
`open.url.system_opener`; that module was removed 2026-09-06 once every
caller had migrated to `cross.open_default` directly.
