---@meta
---@module 'lib.nvim.system.@types'

--- Computed snapshot of the host environment (see `lib.nvim.system.env`).
--- Platform booleans are mutually exclusive: on WSL `is_wsl == true` and
--- `is_linux == false`.
---@class Lib.System.Env
---@field is_windows boolean  # Native Windows (not WSL).
---@field is_wsl boolean      # Windows Subsystem for Linux (v1 or v2).
---@field is_linux boolean    # Linux, excluding WSL.
---@field is_macos boolean    # macOS (Darwin).
---@field is_pwsh boolean     # `pwsh` (PowerShell Core) is on PATH. Computed on first read (see `lib.nvim.system.env`'s DEFERRED), so it is absent from `pairs()` until then.
---@field repo_base string|nil # Value of `$REPOS_DIR`, or nil if unset.
---@field pathsep string      # Path separator for the current OS ("\\" or "/").
---@field home string         # Expanded home directory (`~`).

--- Options accepted by `require("lib.nvim.system").setup`.
---@class Lib.System.SetupOptions
---@field publish_globals? boolean|{ fields?: string[] } # Mirror the snapshot to `vim.g.*`. `true` uses defaults; a table forwards `fields`.
---@field rpc_pipe? boolean|table # Start the Windows named-pipe RPC server. `true` uses defaults; a table is forwarded to `rpc_pipe.setup`.
---@field info_usercmd? boolean|string # Register the system-info user command. `true` uses ":SystemInfo"; a string sets the command name.

--- A line collector (see `lib.nvim.system.lines`). `feed` returns the whole
--- lines a chunk completed; `flush` returns output that never got its newline,
--- or nil when there is none.
---@class Lib.System.Lines.Collector
---@field feed fun(data: string): string[]
---@field flush fun(): string|nil

--- `lib.nvim.system.lines` module surface.
---@class Lib.System.Lines
---@field collector fun(): Lib.System.Lines.Collector
---@field deliver fun(batch: string[], fn: fun(line: string))
---@field buffered fun(cb: (fun(err: nil, line: string))|nil): (fun(err: string|nil, data: string|nil))|nil

--- Aggregator surface of `require("lib.nvim.system")`.
---@class Lib.System
---@field env Lib.System.Env.Module
---@field rpc_pipe Lib.System.RpcPipe
---@field info Lib.System.Info
---@field proc_trace Lib.System.ProcTrace
---@field job Lib.System.Job
---@field lines Lib.System.Lines
---@field setup fun(opts?: Lib.System.SetupOptions): Lib.System.Env

--- `lib.nvim.system.env` module surface.
---@class Lib.System.Env.Module
---@field get fun(opts?: { refresh?: boolean }): Lib.System.Env
---@field publish_globals fun(opts?: { fields?: string[] }): Lib.System.Env

--- `lib.nvim.system.rpc_pipe` module surface.
---@class Lib.System.RpcPipe
---@field setup fun(opts?: { debug?: boolean, allow_override?: boolean, export?: boolean, pipe?: string }): nil
---@field is_active fun(): boolean
---@field get_address fun(): string|nil
---@field clear fun(): nil

--- Options for `lib.nvim.system.info.build_cmd` / `get`.
---@class Lib.System.Info.BuildCmdOpts
---@field prefer_fetch? boolean # Use fastfetch/neofetch when installed (default true). `false` forces the uniform "Key : Value" platform probe.

--- Options for `lib.nvim.system.info.show`.
---@class Lib.System.Info.ShowOpts : Lib.System.Info.BuildCmdOpts
---@field clipboard? boolean # Copy the output to the system clipboard (default true).
---@field title? string # Float title, defaults to " System Information ".

--- `lib.nvim.system.info` module surface (cross-platform system information).
---@class Lib.System.Info
---@field build_cmd fun(opts?: Lib.System.Info.BuildCmdOpts): string[] # Probe command as argv list (fastfetch/neofetch or platform-native fallback).
---@field get fun(opts?: Lib.System.Info.BuildCmdOpts): string[]|nil, string|nil # Run the probe; cleaned output lines or nil + error.
---@field show fun(opts?: Lib.System.Info.ShowOpts): integer|nil, integer|nil # Float + clipboard; returns winid, bufnr.
---@field create_usercmd fun(name?: string, opts?: Lib.System.Info.ShowOpts): nil # Register the user command (default :SystemInfo).

--- Options accepted by `lib.nvim.system.proc_trace.start`.
---@class Lib.System.ProcTrace.StartOptions
---@field threshold_ms? integer # Calls at/above this duration get a traceback logged (default 200).
---@field path? string # Log file path (default: stdpath("state") .. "/proc_trace.log").

--- Result returned by `start`/`stop`.
---@class Lib.System.ProcTrace.Result
---@field path string # Log file path.
---@field active boolean # Whether tracing is active after the call.

--- What `proc_trace` puts aside while it is active: the four functions it
--- replaces, plus the open log handle. Declared because the table used to
--- be a `table<string, function>`, which made the handle an
--- `assign-type-mismatch` and every method call on it an undefined field.
---@class Lib.System.ProcTrace.Saved
---@field fn_system function
---@field fn_systemlist function
---@field fn_jobstart function
---@field vim_system? function
---@field __fd? file*

--- `lib.nvim.system.proc_trace` module surface (blocking-call instrumentation).
---@class Lib.System.ProcTrace
---@field start fun(opts?: Lib.System.ProcTrace.StartOptions): Lib.System.ProcTrace.Result # Wrap vim.fn.system/systemlist, vim.system, vim.fn.jobstart; idempotent.
---@field stop fun(): Lib.System.ProcTrace.Result # Restore the original functions.
---@field is_active fun(): boolean
---@field log_path fun(): string|nil # Path of the active (or last) log file.

--- Options accepted by `lib.nvim.system.job.start` / `start_blocking` / `chain`.
---@class Lib.System.Job.Opts
---@field command string # Executable name/path.
---@field args? string[] # Argv, excluding `command` itself.
---@field on_stdout? fun(err: nil, line: string) # Called once per stdout line, already vim.schedule-wrapped. Ignored by `start_blocking`/`chain` (raw-capture tier).
---@field on_stderr? fun(err: nil, line: string) # Called once per stderr line, already vim.schedule-wrapped. Ignored by `start_blocking`/`chain` (raw-capture tier).
---@field timeout_ms? integer # `start_blocking`/`chain`: passed to `vim.system`'s `timeout` / `wait(timeout)`. `start` with `kill_tree`: the deadline after which the process TREE is killed (exit code 124, `timed_out`). Ignored by a plain `start`.
---@field stdin? string # `start_blocking`/`chain`/`start` with `kill_tree`: raw stdin text. In `chain`, defaults to the previous step's captured stdout unless set explicitly.
---@field kill_tree? boolean # `start` only: timeout and `kill()` end the whole process tree (POSIX process group, Windows `taskkill /T`) through `lib.nvim.cross.run_argv`; `start` then returns a `Lib.System.Job.TreeHandle`.
---@field cwd? string # `start` with `kill_tree` only: working directory of the child.
---@field env? table<string, string> # `start` with `kill_tree` only: variables merged over the inherited environment.
---@field on_exit? fun(result: Lib.System.Job.TreeResult) # `start` with `kill_tree` only: called once on the main loop, after the last line callback (lines a surviving descendant writes after the run was reported are dropped).

--- Outcome of a `start({ kill_tree = true })` run.
---@class Lib.System.Job.TreeResult
---@field code integer # Exit code; `124` after `timeout_ms`, `128 + signal` for a run a signal ended (`kill()`: 143, or 137 after the escalation; never 0), `-1` when the command could not be started.
---@field signal integer # Terminating signal, `0` if none.
---@field stdout string # What the process wrote to stdout, or `""` when `on_stdout` is set (the lines went there; nothing is collected twice).
---@field stderr string # Up to 64 KiB of stderr; the reason when `code == -1`.
---@field timed_out boolean # The deadline killed the tree.
---@field killed boolean # `kill()` was called before the run ended.

--- Handle of a `start({ kill_tree = true })` run. Methods work with `.` and `:`.
---@class Lib.System.Job.TreeHandle
---@field kill fun() # End the process tree: SIGTERM, SIGKILL 1.5 s later (Windows: `taskkill /T /F`). No-op once the run ended (its pid may be reused) and, like the deadline, blind to descendants of a child that has exited already.
---@field is_done fun(): boolean
---@field wait fun(timeout_ms?: integer): Lib.System.Job.TreeResult|nil # Block (vim.wait) until the run ended; nil when `timeout_ms` passed first.

--- `lib.nvim.system.job` module surface: a `vim.system` wrapper with
--- plenary.job-style line-buffered, schedule-safe callbacks, plus a
--- raw-capture blocking/chaining tier.
---@class Lib.System.Job
---@field start fun(opts: Lib.System.Job.Opts): vim.SystemObj|Lib.System.Job.TreeHandle
---@field start_blocking fun(opts: Lib.System.Job.Opts): vim.SystemCompleted
---@field chain fun(job_specs: Lib.System.Job.Opts[], on_done: fun(ok: boolean, results: vim.SystemCompleted[]))

return {}
