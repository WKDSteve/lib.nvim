# `lib.nvim.fs.collect_recursive`

Recursive directory walker built on `(vim.uv or vim.loop).fs_scandir`/
`fs_scandir_next`. Returns a flat array of absolute paths under a root
directory, with an optional `ignore` predicate that can prune whole
subtrees — pass a matcher once instead of every consumer hand-rolling its
own recursive scan (Neo-tree-style pickers, project indexers, …).

## Usage

```lua
local collect_recursive = require("lib.nvim.fs.collect_recursive")

-- Everything (files + directories)
local all = collect_recursive.collect("/repo")

-- Files only, skipping the folders of lib.nvim.fs.ignore.list (.git, node_modules, .claude, target, ...)
local files = collect_recursive.files("/repo", { ignore = collect_recursive.skip() })

-- What globpath("/repo", "**/*.md") shows (no dot entries), minus those folders, and much faster
local md = collect_recursive.files_with_ext("/repo", { "md" })

-- Directories only
local dirs = collect_recursive.dirs("/repo")

-- Non-blocking counterpart, same options, for large trees (node_modules-
-- sized) where the synchronous walk above would stall the main loop:
local cancel = collect_recursive.collect_async("/repo", { kind = "files" }, function(paths)
  -- called once, vim.schedule-dispatched, never for a cancelled walk
end)
-- cancel()  -- stop early if the caller no longer needs the result
```

## Returns

| Function             | Returns    | Meaning                                             |
|-----------------------|------------|------------------------------------------------------|
| `M.collect(root, opts)` | `string[], string[]?` | Absolute paths matching `opts.kind` (default `"all"`), plus `errors` |
| `M.files(root, opts)`   | `string[], string[]?` | Shorthand for `collect` with `kind = "files"`         |
| `M.dirs(root, opts)`    | `string[], string[]?` | Shorthand for `collect` with `kind = "dirs"`          |
| `M.files_with_ext(root, exts, skip_opts)` | `string[], string[]?` | Files whose extension is one of `exts` (case-insensitive), walked with `skip(skip_opts)` (default `{ hidden = false }`) |
| `M.skip(opts)` | `fun(abs_path, is_dir): boolean` | An `ignore` predicate: skips the folders named in `opts.dirs` (default `lib.nvim.fs.ignore.list.basenames`), and with `hidden = false` every dot entry |

## Instead of `globpath(root, "**/*.ext")`

`globpath` shows no dot entries but walks into `node_modules`, and it is slow on Windows. Measured
2026-11-17 (STEVESPC): `**/*.md` took 1.1 s on lib.nvim and 7.3 s on a vault of 7 000 files (one run 49 s);
this walker with `skip()` took 75 and 400 ms for every file. `files_with_ext(root, { "md" })` returns what
`globpath` returns, minus the skipped folders (`TESTS/collect_skip_spec.lua` compares both).

`errors` is `nil` when every directory could be read. Otherwise it holds one
`"<dir>: <reason>"` entry per directory `fs_scandir` refused — the root
itself included — and `paths` is whatever was reachable. An empty tree and
an unreadable tree both yield `{}`; only `errors` tells them apart, so a
caller that persists or caches the result should check it.

When `opts.ignore(abs_path, is_dir)` returns `true` for a directory, that
directory entry is skipped **and** its subtree is not recursed into.

A symlinked directory is still listed like any other directory, but the
walk never recurses into it — a symlink can point at an ancestor (or
itself), and following it would recurse forever, bounded in practice only
by an OS path-length error or a Lua stack overflow, neither of which is a
real base case.

## `collect_async(root, opts, on_done)`

Non-blocking counterpart to `collect`, same result and same `opts` (`kind`,
`ignore`). `walk`'s synchronous `uv.fs_scandir`/`uv.fs_stat` calls block the
caller until the syscall returns — fine for a handful of directories, but a
`node_modules`-sized tree stalls Neovim's UI for the whole walk.
`collect_async` uses the async form of those same libuv calls instead, one
directory at a time, driven by [`lib.nvim.async`](../../async/README.md) so
the recursive walk still reads like the synchronous version — no callback
pyramid — while every `await()` actually yields control back to the event
loop.

This fixes the main-loop stall; it is **not** a parallel/concurrent scan and
so not necessarily a wall-clock speedup — sibling directories are still
visited one after another, deliberately, to keep the coroutine driver
simple. `M.files_async`/`M.dirs_async` mirror `files`/`dirs`.

```
M.collect_async(root: string, opts?: Lib.Fs.CollectRecursive.Opts, on_done: fun(paths: string[], errors: string[]|nil)): fun() cancel
M.files_async(root: string, opts?: Lib.Fs.CollectRecursive.Opts, on_done: fun(paths: string[], errors: string[]|nil)): fun() cancel
M.dirs_async(root: string, opts?: Lib.Fs.CollectRecursive.Opts, on_done: fun(paths: string[], errors: string[]|nil)): fun() cancel
```

`errors` follows the same rule as `collect`'s second return value.

`on_done` is always `vim.schedule`-dispatched and fires **at most once**;
calling the returned `cancel()` function stops the walk after its current
in-flight libuv call settles and `on_done` is not called at all — not
"called with a partial result", genuinely skipped.
