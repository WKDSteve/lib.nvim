---@meta
---@module 'lib.nvim.fs.fast.@types'

---@alias Lib.Fs.Fast.Tier "helper"|"fd"|"rg"|"lua"

---@class Lib.Fs.Fast.ListOpts
---@field hidden? boolean List and enter dot entries (default true).
---@field ignore? "gitignore"|"names"|"none" Which rules leave entries out (default "gitignore"; the Lua walk uses `names` or `skip` for it).
---@field names? string[] Folder names not entered with `ignore = "names"` (and by the Lua walk for "gitignore"); default `lib.nvim.fs.ignore.list.basenames`.
---@field no_ignore? boolean Same as `ignore = "none"` unless `ignore` is given.
---@field follow? boolean Follow links to folders (each real folder once).
---@field exclude? string[] Globs as `fd --exclude` takes them: without `/` they match a name at any depth.
---@field max_depth? integer 1 = the files directly in the root.
---@field skip? fun(name: string, is_dir: boolean): boolean For the Lua walk with `ignore = "gitignore"`: replaces `names`.
---@field tier? Lib.Fs.Fast.Tier Force a tier (specs).

---@class Lib.Fs.Fast.WatchOpts
---@field debounce_ms? integer The quiet before `on_change` (libuv tiers; default 200).
---@field hidden? boolean Per-folder watch: enter dot folders (default true).
---@field names? string[] Per-folder watch: folder names not watched (default the ignore list).
---@field max_watches? integer Per-folder watch: at most this many handles (default 4000).
---@field tier? "libuv" Force libuv (specs).

---@class Lib.Fs.Fast.Watch
---@field stop fun()
---@field tier fun(): "helper"|"libuv"
---@field handles fun(): integer The libuv handles in use (0 with the helper).

---@class Lib.Fs.Fast
---@field WALK_LIMIT integer
---@field MAX_WATCHES integer
---@field norm fun(path: string): string
---@field resolve fun(path: string): string, boolean
---@field running fun(): integer
---@field tier fun(): Lib.Fs.Fast.Tier, string|nil
---@field command fun(tier: "fd"|"rg", exe: string, root: string, opts?: Lib.Fs.Fast.ListOpts, kind?: "f"|"l"): string[]
---@field list fun(root: string, opts: Lib.Fs.Fast.ListOpts|nil, on_batch: (fun(paths: string[])), on_done: (fun(ok: boolean))): (fun())
---@field list_all fun(root: string, opts: Lib.Fs.Fast.ListOpts|nil, on_done: (fun(paths: string[], ok: boolean))): (fun())
---@field size fun(dir: string, on_done: (fun(bytes: integer|nil, files: integer|nil, tier: "helper"|"lua")), opts?: { tier?: "helper"|"lua" }): (fun())
---@field watch fun(root: string, opts: Lib.Fs.Fast.WatchOpts|nil, on_change: (fun(dirs: string[]))): Lib.Fs.Fast.Watch

return {}
