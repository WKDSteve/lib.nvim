---@meta
---@module 'lib.nvim.deps.@types'

---Per-package-manager package name for one tool. Keys are package-manager
---ids (`apt`, `dnf`, `pacman`, `zypper`, `apk`, `brew`, `winget`, `scoop`,
---`choco`); values are that manager's package name. A missing key means "no
---known package on that manager", not "impossible" — `has_exec` detection
---still works for a tool with an empty `pkg` map, install offers just won't
---cover every manager.
---@alias Lib.Deps.PkgMap table<string, string>

---One tool requirement, parsed from either a ```install-tool fenced block
---(`docs/INSTALL.md`) or a `tools[]` array entry (`docs/install.json`).
---@class Lib.Deps.Tool
---@field bin string canonical executable name: the tool's identity, its display label, the key its install state is stored under, and what `pkg` maps from
---@field bin_alternatives string[]|nil other names the SAME tool is installed as on some platform (`gs` -> `gswin64c`, `gswin32c`). Detection only -- see `lib.nvim.deps.detect`. Not a list of substitutes: a different program that would also do the job is a different tool.
---@field paths Lib.Deps.PathMap|nil literal install locations to try after every name in `bin`/`bin_alternatives` has missed on PATH -- for installers (Chrome, LibreOffice, …) that never extend PATH. See `lib.nvim.deps.detect.candidate_paths`.
---@field files string[]|nil paths that must ALL exist for the tool to count as present (`$ENVVAR`-expandable); replaces the PATH check, for a toolchain that is a tree of files. See `lib.nvim.deps.detect.found_as`.
---@field probe string[]|nil argv that must exit 0 for the tool to count as present, on top of the PATH/`files` check (e.g. `{"cargo","tauri","--version"}`)
---@field required boolean true when the plugin cannot function at all without it
---@field why string one-sentence reason this tool matters (validation requires non-empty)
---@field see string|nil optional anchor/link into the plugin's own docs for more detail
---@field pkg Lib.Deps.PkgMap package name per package manager (validation requires >= 1 entry)

---Fallback install locations for one tool, by platform. Each entry may
---contain `$ENVVAR` tokens (`$PROGRAMFILES`, `$LOCALAPPDATA`, `$HOME`, …),
---expanded via `vim.fn.expand()` before the filesystem check -- so the same
---declaration works across every account's differently-rooted install, not
---just the one machine it was measured on.
---@alias Lib.Deps.PathMap { win?: string[], mac?: string[], linux?: string[] }

---One validation problem found while parsing a spec file.
---@class Lib.Deps.Error
---@field index integer 1-based position of the offending tool entry; 0 for a file-level problem (e.g. malformed JSON/YAML, not a list)
---@field field string|nil the offending field name, when attributable to one
---@field message string human-readable description

---Result of parsing + validating one spec file (`docs/INSTALL.md` or `docs/install.json`).
---@class Lib.Deps.ParseResult
---@field tools Lib.Deps.Tool[] entries that passed validation
---@field errors Lib.Deps.Error[] entries (or the whole file) that did not; empty on a fully clean parse

---@class Lib.Deps.HealthEntry
---@field bin? string executable name, probed via `has_exec` (mutually exclusive with `python_module`)
---@field bin_alternatives? string[] other names the same executable goes by on some platform; only meaningful alongside `bin`
---@field paths? Lib.Deps.PathMap fallback install locations, tried after `bin`/`bin_alternatives` miss on PATH; only meaningful alongside `bin`
---@field files? string[] paths that must ALL exist; replaces the PATH check
---@field probe? string[] argv that must exit 0, on top of the PATH/`files` check
---@field python_module? string Python module name, probed via `python -c "import <module>"` (mutually exclusive with `bin`)
---@field required? boolean reported as an error (not a warning) when missing; defaults to false
---@field label? string display label; defaults to `bin`/`python_module`
---@field hint? string human install hint shown alongside a missing report (e.g. "pip install pdfplumber")

---`lib.nvim.deps.spec` module surface: parse/validate/find spec files.
---@class Lib.Deps.Spec
---@field parse_markdown fun(text: string): Lib.Deps.ParseResult
---@field parse_json fun(text: string): Lib.Deps.ParseResult
---@field load fun(path: string): Lib.Deps.ParseResult|nil, string|nil
---@field find fun(plugin_name: string): string|nil path to the resolved spec file, or nil if none found
---@field plugins fun(): string[] names of every plugin on runtimepath shipping a deps spec

---`lib.nvim.deps.health` module surface: generic `check_exe`/`probe` replacement.
---@class Lib.Deps.Health
---@field report fun(entries: Lib.Deps.HealthEntry[]): nil
---@field from_tools fun(tools: Lib.Deps.Tool[]): nil report health directly from a parsed spec's `tools`
---@field report_for fun(plugin_name: string): nil locate + report a plugin's own spec, plus a pointer to `:Lib deps show`
---@field pointer_for fun(plugin_name: string): nil the `:Lib deps show` pointer alone, no per-tool report -- for a plugin whose hand-rolled checks already cover every declared tool

---One OS package manager: how to detect it and how to compose an install command.
---@class Lib.Deps.Manager
---@field id string manager id, matching the keys used in a tool's `pkg` map (`apt`, `brew`, …)
---@field bin string executable probed to decide whether this manager is present
---@field install string[] argv tokens between the binary and the package names (e.g. `{"install"}`, `{"-S","--needed"}`)
---@field needs_root boolean true when the command must be run as root (prefixed with `sudo` where available)
---@field multi boolean true when one invocation accepts several packages; false forces one command per package (winget)

---What installing a tool list would involve on this host.
---@class Lib.Deps.Plan
---@field manager Lib.Deps.Manager|nil detected (or overridden) package manager; nil when none is present
---@field present Lib.Deps.Tool[] tools already found on PATH
---@field missing Lib.Deps.Tool[] tools not found on PATH
---@field installable Lib.Deps.Tool[] subset of `missing` this manager has a package name for
---@field unsupported Lib.Deps.Tool[] subset of `missing` with no package name for this manager
---@field packages string[] package names for `installable`, in the same order
---@field commands string[][] argv list(s) (a pipx/pip command is appended for a tool only those can install) that would install `packages`; more than one only for managers with `multi = false`

---`lib.nvim.deps.pm` module surface: package-manager detection + command composition.
---@class Lib.Deps.Pm
---@field get fun(id: string): Lib.Deps.Manager|nil
---@field ids fun(): string[]
---@field available fun(): Lib.Deps.Manager[]
---@field detect fun(): Lib.Deps.Manager|nil
---@field commands fun(manager: Lib.Deps.Manager, packages: string[]): string[][]
---@field resolve fun(tool: Lib.Deps.Tool, os_manager?: Lib.Deps.Manager|false): Lib.Deps.Manager|nil, string|nil # OS manager first, then pipx, then pip (when declared and on PATH)
---@field render fun(argv: string[]): string
---@field is_root fun(): boolean
---@field needs_terminal fun(manager: Lib.Deps.Manager): boolean

---`lib.nvim.deps.detect` module surface: does a declared tool exist on this
---host, under any of the names it goes by?
---@class Lib.Deps.Detect
---@field names fun(tool: Lib.Deps.Tool|Lib.Deps.HealthEntry): string[] every name the tool may be found under, canonical first
---@field candidate_paths fun(tool: Lib.Deps.Tool|Lib.Deps.HealthEntry): string[] this host's declared fallback `paths`, `$ENVVAR`-expanded
---@field found_as fun(tool: Lib.Deps.Tool|Lib.Deps.HealthEntry): string|nil the name (or resolved path) it was found under, nil when absent
---@field found fun(tool: Lib.Deps.Tool|Lib.Deps.HealthEntry): boolean
---@field forget fun(tool: Lib.Deps.Tool|Lib.Deps.HealthEntry): nil drop the memoized PATH result for every one of its names and resolved paths

---`lib.nvim.deps.install` module surface: plan computation + confirmed terminal handoff.
---@class Lib.Deps.Install
---@field plan fun(tools: Lib.Deps.Tool[], opts?: Lib.Deps.ManagerOpts): Lib.Deps.Plan
---@field run fun(plan: Lib.Deps.Plan, opts?: { confirm?: boolean, on_done?: fun(started: boolean) }): boolean|nil nil while the question is open

---Live install state for one tool, keyed by `tool.bin` in `deps.view`'s
---`ui` tables.
---@class Lib.Deps.View.ToolUiState
---@field lines string[] streamed stdout/stderr lines, in arrival order
---@field running boolean
---@field done boolean
---@field exit_code integer|nil
---@field collapsed boolean

---What `lib.nvim.deps.status.collect` found across every plugin shipping a spec.
---@class Lib.Deps.Status.Collected
---@field tools Lib.Deps.Tool[] one entry per distinct `bin`, merged across declarers
---@field sources table<string, string[]> which plugins declared each `bin`, in encounter order
---@field plugins string[] plugins whose spec was read successfully
---@field failed string[] plugins listed by `spec.plugins()` whose spec could not be read

---`lib.nvim.deps.status` module surface: every declared tool, across every
---plugin, in one report.
---@class Lib.Deps.Status
---@field collect fun(): Lib.Deps.Status.Collected the merge (reads spec files, touches nothing else)
---@field lines fun(opts?: Lib.Deps.ManagerOpts): string[] the aggregate report as lines
---@field show fun(opts?: Lib.Deps.ManagerOpts): boolean the aggregate report as a popup, with install keymaps
---@field install fun(opts?: Lib.Deps.ManagerOpts): boolean plan + confirm + hand off everything missing

---Options for one `require_tool` check.
---@class Lib.Deps.RequireTool.Opts
---@field silent? boolean answer the question without reporting; for a caller with its own error path
---@field throttle_ms? integer how long this (plugin, tool) pair stays quiet after a report; `<= 0` disables the guard
---@field manager? Lib.Deps.Manager package manager to compose the install line for, instead of the detected one

---`lib.nvim.deps.require_tool` module surface: the failure-moment check —
---is this tool here, and if not, say so with the spec's own `why` and the
---install command for this host.
---@class Lib.Deps.RequireTool
---@field check fun(plugin_name: string, bin: string, opts?: Lib.Deps.RequireTool.Opts): string|nil the name it was found under, nil when missing
---@field message fun(plugin_name: string, tool: Lib.Deps.Tool, opts?: Lib.Deps.ManagerOpts): string[] the reported lines (pure)
---@field lines fun(plugin_name: string, bin: string, opts?: Lib.Deps.ManagerOpts): string[] the same lines by binary name, reporting nothing — for callback/result error paths
---@field reset fun(plugin_name?: string): nil forget throttle state and memoized specs

---`lib.nvim.deps.first_run` module surface: show a plugin's deps popup once
---ever, persisted across restarts.
---@class Lib.Deps.FirstRun
---@field seen fun(plugin_name: string, cache_opts?: Lib.Cache.Opts): boolean
---@field mark_seen fun(plugin_name: string, cache_opts?: Lib.Cache.Opts)
---@field reset fun(plugin_name?: string, cache_opts?: Lib.Cache.Opts)
---@field show_once fun(plugin_name: string, opts?: { manager?: Lib.Deps.Manager, cache?: Lib.Cache.Opts }): boolean

--- The one option the view and install entry points take: an explicit package
--- manager instead of the detected one. A named class rather than the
--- inline `{ manager?: Lib.Deps.Manager }` it used to be written as --
--- inline table types normalise differently at a declaration and at a
--- call, and the same spelling stopped matching itself.
---@class Lib.Deps.ManagerOpts
---@field manager? Lib.Deps.Manager

---`lib.nvim.deps.view` module surface: render/show a plugin's tool report.
---@class Lib.Deps.View
---@field render fun(plugin_name: string, result: Lib.Deps.ParseResult, opts?: Lib.Deps.ManagerOpts, ui?: table<string, Lib.Deps.View.ToolUiState>): { lines: string[], line_tools: (Lib.Deps.Tool|nil)[] }
---@field lines fun(plugin_name: string, result: Lib.Deps.ParseResult, opts?: Lib.Deps.ManagerOpts): string[]
---@field show_split fun(plugin_name: string, result: Lib.Deps.ParseResult): integer, integer
---@field show fun(plugin_name: string, result: Lib.Deps.ParseResult, opts?: Lib.Deps.ManagerOpts): integer, integer

---`lib.nvim.deps` module surface.
---@class Lib.Deps
---@field spec Lib.Deps.Spec
---@field detect Lib.Deps.Detect
---@field health Lib.Deps.Health
---@field pm Lib.Deps.Pm
---@field install Lib.Deps.Install
---@field view Lib.Deps.View
---@field first_run Lib.Deps.FirstRun
---@field status Lib.Deps.Status
---@field project Lib.Deps.Project
---@field show_once fun(plugin_name: string, opts?: { manager?: Lib.Deps.Manager, cache?: Lib.Cache.Opts }): boolean
---@field require_tool fun(plugin_name: string, bin: string, opts?: Lib.Deps.RequireTool.Opts): string|nil is this tool here — and if not, report it usefully
---@field plugins fun(): string[] every plugin on runtimepath shipping a deps spec
---@field show fun(plugin_name: string): boolean render one plugin's tool report in a scratch split
---@field install_for fun(plugin_name: string): boolean|nil plan + confirm + hand off to a terminal (nil while the question is open)
---@field routes fun(): table[] the `:Lib deps …` routes, for `lib.nvim_usrcmds` to merge into the `:Lib` verb

return {}
