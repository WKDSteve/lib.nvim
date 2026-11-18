---@meta
---@module 'lib.nvim.fs.collect_recursive.@types'

---@alias Lib.Fs.CollectRecursive.Kind "all"|"files"|"dirs"

---@class Lib.Fs.CollectRecursive.Opts
---@field ignore (fun(abs_path: string, is_dir: boolean): boolean)|nil Return true to skip an entry; for directories this also prunes the whole subtree.
---@field kind Lib.Fs.CollectRecursive.Kind|nil Defaults to "all".
---@field gitignore boolean|nil `files_async` only: list through `lib.nvim.fs.fast` (helper, fd, rg), leaving out what `.gitignore` names and `.git`; `ignore` is applied afterwards. Opt-in: other hits than the plain walk.
---@field tier Lib.Fs.Fast.Tier|nil With `gitignore`: force a tier of `lib.nvim.fs.fast` (specs).

---@class Lib.Fs.CollectRecursive
---@field collect fun(root: string, opts?: Lib.Fs.CollectRecursive.Opts): string[], string[]? # `errors` is nil when every directory could be read, otherwise one "<dir>: <reason>" per directory that could not be opened (root included); `paths` is then whatever was reachable.
---@field files fun(root: string, opts?: Lib.Fs.CollectRecursive.Opts): string[], string[]?
---@field dirs fun(root: string, opts?: Lib.Fs.CollectRecursive.Opts): string[], string[]?
---@field skip fun(opts?: { dirs?: string[], hidden?: boolean }): (fun(abs_path: string, is_dir: boolean): boolean) # An `ignore` predicate skipping folders by name while walking; `hidden = false` also skips dot entries (what globpath shows).
---@field files_with_ext fun(root: string, exts: string[], skip_opts?: { dirs?: string[], hidden?: boolean }): string[], string[]? # Files with one of `exts` (case-insensitive), walked with `skip(skip_opts)`; replaces `globpath(root, "**/*.<ext>")`.
---@field collect_async fun(root: string, opts: Lib.Fs.CollectRecursive.Opts|nil, on_done: fun(paths: string[], errors: string[]|nil)): (fun()) # Non-blocking counterpart to `collect`; returns a cancel function. on_done is vim.schedule-dispatched, never called for a cancelled walk.
---@field files_async fun(root: string, opts: Lib.Fs.CollectRecursive.Opts|nil, on_done: fun(paths: string[], errors: string[]|nil)): (fun())
---@field dirs_async fun(root: string, opts: Lib.Fs.CollectRecursive.Opts|nil, on_done: fun(paths: string[], errors: string[]|nil)): (fun())

return {}
