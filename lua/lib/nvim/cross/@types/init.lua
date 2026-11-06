---@meta
---@module 'lib.nvim.cross.@types'

---Shape of the `lib.nvim.cross` aggregate table (see `cross/init.lua`).
---@class Lib.Cross
---@field is_windows fun(): boolean
---@field is_wsl fun(): boolean
---@field is_macos fun(): boolean
---@field is_linux fun(): boolean
---@field is fun(platform?: Lib.Cross.Platform.PlatformName): boolean|Lib.Cross.Platform.PlatformName
---@field executable Lib.Cross.Executable # PATH / Mason binary lookup: exists / path / find / mason_bin / clear.
---@field bash fun(): string|nil, string|nil # Git Bash on Windows (never the WSL launcher), `bash` elsewhere; nil + reason when missing. Memoized (`lib.nvim.cross.bash`.clear()).
---@field run Lib.Cross.Run
---@field fs Lib.Cross.Fs
---@field separators Lib.Cross.Separators
---@field uv Lib.Cross.Uv
---@field open_default fun(target: string, opts?: { on_exit?: fun(code: integer), schemes?: string[] }): boolean, string|nil # Open a path/URL with the OS default application.
---@field reveal_in_fm fun(target: string, opts?: Lib.Cross.RevealInFm.Opts): boolean, string|nil # Show a path in the system file manager.

---Libuv-backed process helpers (the `cross.uv` sub-table).
---@class Lib.Cross.Uv
---@field spawn_command { spawn_project_command: fun(cmd: string, opts?: table): uv.uv_process_t? } # Shell-string runner on raw uv.spawn.
---@field spawn_shell_command fun(cmd: string, args: string[], opts?: table): uv.uv_process_t? # Same, cmd/args passed separately.
---@field spawn_capture Lib.Cross.Uv.SpawnCapture # Async argv spawn, output buffered, one callback at exit.
---@field spawn_stream Lib.Cross.Uv.SpawnStream # Async argv spawn, output streamed line by line.
---@field wait_until Lib.Cross.Uv.WaitUntil # Poll a predicate on a libuv timer until true or max attempts.

--- CDX: `Lib.Cross.ALL` has no `---@type` referent anywhere in the repo, listed
--- CDX: `run_blocking` twice (the second entry is `run_argv.run_blocking`), and is
--- CDX: superseded by `Lib` in `lua/lib/@types/all_functions.lua`. Left as-is
--- CDX: pending an external-consumer check, mirroring `Lib.Modules`.
---@class Lib.Cross.ALL
---@field is_windows fun(): boolean
---@field is_wsl fun(): boolean
---@field is_macos fun(): boolean
---@field is_linux fun(): boolean
---@field is fun(platform?: Lib.Cross.Platform.PlatformName): boolean|Lib.Cross.Platform.PlatformName
---@field shell fun(): OsShell
---@field run fun(cmd: string, cb: fun(ok:boolean, res:OsRunResult)): nil
---@field run_blocking fun(cmd: string): OsRunResult
---@field copy_to_clipboard fun(text: string): boolean
---@field run_blocking fun(cmd: string[], input?: string): boolean, string|nil # Low-level argv-based process runner with stdin support.

return {}
