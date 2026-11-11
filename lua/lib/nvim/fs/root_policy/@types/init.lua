---@meta
---@module 'lib.nvim.fs.root_policy.@types'

---@alias Lib.Fs.RootPolicy.Mode "follow"|"project"|"nearest"|"lock"|"manual"|"tree_leads"

---What the policy wants done for one buffer.
---@class Lib.Fs.RootPolicy.Decision
---@field root?   string  Directory to use for both the cwd and the tree root (nil: nothing pinned).
---@field chdir   boolean May the cwd be changed to `root`?
---@field reveal  boolean May the tree be re-rooted / the file revealed?

---@class Lib.Fs.RootPolicy.State
---@field mode   Lib.Fs.RootPolicy.Mode
---@field pinned string|nil

---@class Lib.Fs.RootPolicy.Opts
---@field mode? Lib.Fs.RootPolicy.Mode Starting mode (default "follow", inert).
---@field scope? Lib.Fs.Chdir.Scope Directory scope for every chdir and the guard: "global" (default), "tab", "win".
---@field find_root? fun(file: string, kind: "project"|"nearest"): string|nil Root finder for the project and nearest modes (VCS root versus package boundary).
---@field seed? fun(mode: Lib.Fs.RootPolicy.Mode): string|nil Where a new project/nearest/tree_leads pin starts (default: the current buffer, else the cwd).
---@field sticky? boolean A file with no root of its own keeps the current root (default true).
---@field reveal_outside? "skip"|"reveal" What `reveal` is for a file outside a held root (default "skip").
---@field enforce? boolean Revert foreign cwd changes in lock mode via `lib.nvim.fs.dir_guard` (default true).
---@field chdir? boolean Change the cwd at all (default true; false: only answer and track).
---@field on_error? fun(err: string) A held directory could not be restored.
---@field on_change? fun(state: Lib.Fs.RootPolicy.State) Called only when mode or pinned root actually changed.

---@class Lib.Fs.RootPolicy.Handle
---@field mode fun(): Lib.Fs.RootPolicy.Mode
---@field pinned fun(): string|nil
---@field decide fun(file: string): Lib.Fs.RootPolicy.Decision|nil # nil in follow mode (no policy) and for an unusable path
---@field set_mode fun(mode: Lib.Fs.RootPolicy.Mode, dir?: string): boolean, string? # `dir` pins lock mode (default: the cwd)
---@field unlock fun(): boolean, string? # leave lock mode for the mode before it
---@field cycle fun(list: Lib.Fs.RootPolicy.Mode[]): boolean, string? # next mode of `list`
---@field repin fun(dir: string): boolean, string? # move the pin without changing mode (a manual re-root)
---@field bypass fun(fn: fun()): boolean, any # run `fn` with the lock guard paused
---@field release fun() # drop the guard; the state stays readable

return {}
