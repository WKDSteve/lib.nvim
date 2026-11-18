---@meta
---@module 'lib.nvim.fs.helper.@types'

---@alias Lib.Fs.Helper.Mode "auto"|false|string

---@class Lib.Fs.Helper.WalkOpts
---@field hidden? boolean List and enter dot entries (default true).
---@field ignore? "gitignore"|"names"|"none" Which rules leave entries out (default "gitignore").
---@field names? string[] With `ignore = "names"`: the folder names not entered.
---@field no_ignore? boolean Same as `ignore = "none"` unless `ignore` is given.
---@field follow? boolean Follow links to folders.
---@field exclude? string[] Globs as `fd --exclude` takes them.
---@field max_depth? integer 1 = the files directly in the root.

---@class Lib.Fs.Helper.State
---@field mode Lib.Fs.Helper.Mode
---@field exe? string The program in use, or the one that would be used.
---@field running boolean
---@field pid? integer
---@field off? string Why no helper is used, when none is.
---@field lost? string Why the helper of this session ended, when it did.
---@field requests integer Requests waiting for an answer.

---@class Lib.Fs.Helper
---@field PROTOCOL integer
---@field SINK string
---@field binary_name fun(): string
---@field install_dir fun(): string
---@field default_path fun(): string
---@field workstation fun(): boolean
---@field set_mode_provider fun(fn: (fun(): Lib.Fs.Helper.Mode|nil)|nil)
---@field mode fun(): Lib.Fs.Helper.Mode
---@field find fun(): string|nil, string|nil
---@field available fun(): boolean, string|nil
---@field request fun(method: "walk"|"size"|"watch", arg: string, handler: (fun(kind: string, payload: any): boolean|nil), opts?: Lib.Fs.Helper.WalkOpts): integer|nil
---@field drop fun(gen: integer, method?: "cancel"|"unwatch")
---@field tell fun(gen: integer, method: "follow", arg: string)
---@field on fun(kind: string, gen: integer, payload: any)
---@field stop fun()
---@field configure fun(mode?: Lib.Fs.Helper.Mode)
---@field state fun(): Lib.Fs.Helper.State
---@field health fun(ok: fun(msg: string), info: fun(msg: string), warn: fun(msg: string))

return {}
