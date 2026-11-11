---@meta
---@module 'lib.nvim.bindings.usercmd.composer.@types'

--- The argument type names `argtypes` ships with. Custom types registered via
--- `composer.register_type` extend this set at runtime.
---@alias Lib.UserCmd.Composer.ArgTypeBuiltin
---| "STRING"
---| "INT"
---| "FLOAT"
---| "BOOL"
---| "PATH"
---| "DIR"
---| "FILE"
---| "BUFFER"
---| "WINDOW"

--- Open on purpose: `composer.register_type(name, def)` is public API, so
--- a type name this library has never heard of is a legitimate value.
--- A closed union would reject every custom type its own API invites.
---@alias Lib.UserCmd.Composer.ArgType Lib.UserCmd.Composer.ArgTypeBuiltin|string

--- A Visual submode, as named in a route's `visual` allowlist. Vim's own raw
--- spellings ("v"/"V"/"\22") are accepted interchangeably.
---@alias Lib.UserCmd.Composer.VisualMode
---| "charwise"   # v
---| "linewise"   # V
---| "blockwise"  # CTRL-V

--- One positional argument that follows a route's literal path.
---@class Lib.UserCmd.Composer.ArgSpec
---@field name      string                          # shown in usage/help/docs
---@field type?     Lib.UserCmd.Composer.ArgType    # default "STRING"
---@field enum?     string[]                        # closed set; overrides type for completion + validation
---@field values?   string[]                        # completion-only hints for a STRING arg (not enforced)
---@field optional? boolean                         # default false
---@field default?  any                             # value bound when an optional arg is omitted
---@field desc?     string                          # one short line for the help float (what the argument is for)
---@field enum_desc? table<string, string>          # value -> one short line, shown next to each `enum`/`values` entry in the help float
---@field variadic? boolean                         # on the LAST arg only: more tokens than declared slots keep completing with this spec, and usage/docs show `...`. Parsing is unchanged -- the extra tokens still arrive raw in `ctx.rest`, for the handler to read

--- One `--flag` accepted by a route, parsed out of its token tail before
--- positional binding. Opt-in per route: a route with no `flags` behaves
--- exactly as before (a leading "--" is just an ordinary positional token).
---@class Lib.UserCmd.Composer.FlagSpec
---@field name        string                          # matched as --name / --name=value
---@field short?      string                          # single-char alias matched as -x (e.g. short="r" for -r); next-token-value form only, no -x=value
---@field type?       Lib.UserCmd.Composer.ArgType    # value type; default "STRING". Ignored when bool=true
---@field bool?       boolean                         # presence-only flag, no value consumed, e.g. --dry
---@field optional_value? boolean                    # value may be omitted: --name binds true, --name=value binds the value. Never consumes the next token (unlike a plain value flag), so a positional may follow the bare form. Ignored when bool=true
---@field bare_value? any                            # with optional_value: what the bare `--name` binds instead of `true` (e.g. "%" for "the current buffer"); bound as declared, not validated against `type`. Ignored without optional_value
---@field enum?       string[]                        # closed set for the value (ignored when bool=true)
---@field values?     string[]                        # completion-only hints for the value (not enforced, unlike enum); listed in the help float like an enum (ignored when bool=true)
---@field repeatable? boolean                         # collect every occurrence into an array (ctx.flags.name = {...})
---@field default?    any                             # value bound when the flag is never passed
---@field desc?       string                          # one short line for the help float
---@field enum_desc?  table<string, string>           # value -> one short line for each `enum` entry in the help float

--- One bare `key=value` pair (no dashes) accepted by a route, parsed out of
--- its token tail before positional binding. Opt-in per route: an
--- undeclared key is left as an ordinary positional, not an error (see
--- kv.lua) — "=" is too common in legitimate positional values to treat
--- every match as intentional.
---@class Lib.UserCmd.Composer.KvSpec
---@field key     string                          # matched as key=value
---@field type?   Lib.UserCmd.Composer.ArgType    # value type; default "STRING"
---@field enum?   string[]                        # closed set for the value; validated + completed (see argtypes.validate)
---@field values? string[]                        # completion-only hints for a STRING value (not enforced, unlike enum) — same argtypes.STRING.complete a plain ArgSpec uses
---@field default? any                            # value bound when the key is never passed
---@field desc?    string                          # one short line for the help float
---@field enum_desc? table<string, string>         # value -> one short line for each `enum` entry in the help float

--- One node of the route tree (see `composer.tree`): literal `children` and an
--- optional terminal `route`.
---@class Lib.UserCmd.Composer.Node
---@field children table<string, Lib.UserCmd.Composer.Node>
---@field route?   Lib.UserCmd.Composer.Route
---@field token?   string   # the literal token that reaches this node (nil at root)
---@field families? string[] # root only: the spec's `families`, the order the help lists them in

--- A single command route: a literal token path, an optional positional arg
--- schema, optional flags, and the handler.
---@class Lib.UserCmd.Composer.Route
---@field path   string[]                            # literal subcommand tokens, e.g. { "surround", "quote" }. `{}` = the verb's root route (args/flags parsed even with no literal subcommand, e.g. `:Replace {old} {new} --dry`)
---@field args?  Lib.UserCmd.Composer.ArgSpec[]      # positional args accepted after the path
---@field flags? Lib.UserCmd.Composer.FlagSpec[]     # --flag / --flag=value accepted anywhere in the tail, in any order
---@field kv?    Lib.UserCmd.Composer.KvSpec[]       # bare key=value pairs (no dashes) accepted anywhere in the tail
---@field run    (fun(ctx: Lib.UserCmd.Composer.Ctx): any)|string  # handler, or a module path returning a callable / { run = fn }. Whatever it returns is what `dispatch` returns.
---@field desc?  string
---@field family? string                             # the help float lists the subcommands of a node under one heading per family (in the order of the spec's `families`, then as they first appear), the ones without a family under "Subcommands" as before. Only the help changes: paths, completion and dispatch do not. A group without a route of its own takes the family of its first route; a node whose subcommands all share one family lists them under "Subcommands"
---@field bang?  boolean                             # honor :Verb! for this route
---@field range? boolean|integer
---@field count? integer                             # accept a :N Verb count prefix, defaulting to this value when omitted (see nvim_create_user_command's `count`)
---@field check? fun(): boolean, string|nil          # optional pre-flight dependency check for THIS route (e.g. "is an external CLI on PATH"), surfaced by handle:check()/composer.checkhealth() alongside run's own resolvability -- a FAILING check is reported there as an error, so this is for a route that is genuinely broken without its dependency. Also read by `<Tab>` completion (composer.complete) to drop this route's literal when it fails -- must be cheap, synchronous and side-effect-free: it can run on every completion request, not just an explicit health check. For a route that is merely one of several interchangeable optional backends (one being absent is not an error, just a narrower feature set), use `available` instead -- it affects completion only, never checkhealth
---@field available? fun(): boolean                  # optional predicate gating ONLY this route's own literal out of `<Tab>` completion (composer.complete) -- unlike `check`, NEVER read by handle:check()/composer.checkhealth()/check_all(), so a route backed by an optional plugin/binary that degrades gracefully (this route is one of several equivalent options, or falls back to a narrower feature set) can hide itself from `<Tab>` without checkhealth reporting an error for something that was never a hard requirement. Same cheap/synchronous/side-effect-free expectation as `check`
---@field visual? Lib.UserCmd.Composer.VisualMode[]  # allowlist of Visual submodes this route accepts, e.g. { "charwise", "blockwise" }. Only enforced when the '<'/'> marks span exactly the invoked range — see check_visual

--- The full spec passed to `composer.verb(name, spec)`.
---@class Lib.UserCmd.Composer.Spec
---@field desc?    string                                    # verb description (docs + :command listing)
---@field default? fun(ctx: Lib.UserCmd.Composer.Ctx): any   # handler for the bare `:Verb` (no tokens); its return value is `dispatch`'s
---@field routes?  Lib.UserCmd.Composer.Route[]
---@field families? string[]                                 # the order the help float lists the routes' `family` headings in; a family not named here follows, in order of first appearance
---@field bang?    boolean                                   # allow the bang form at the command level (default: true if any route uses it)
---@field range?   boolean|integer                           # allow a range at the command level
---@field count?   integer                                   # allow a :N Verb count prefix at the command level, default value when omitted
---@field buffer?  boolean|integer                           # register buffer-locally: true = current buffer, or an explicit bufnr. Default: nil (global)
---@field visual?  Lib.UserCmd.Composer.VisualMode[]         # default `visual` allowlist for routes that declare none of their own
---@field notify_prefix? string                              # notify() bracket prefix for this verb's dispatch errors/usage. Default: "[Name]" (the verb name) — override when it doesn't already identify your plugin, e.g. two verbs from one plugin that should share one prefix
---@field quotes?  boolean                                   # the verb's own handler cuts `ctx.raw.args` with a quote-aware tokenizer (`:Replace "foo bar" baz`): `<Tab>` and the help float then count a '...' / "..." run as ONE token instead of cutting at its blanks, so the slot they offer is the slot the handler fills. Dispatch (`fargs`, `ctx.args`) is untouched. Default false -- see README "Verbs that read quotes themselves"
---@field help?    boolean                                   # help float (cheatsheet + replaces the usage notification) for this verb: true = on, false = off, nil = follows `setup({ help = { enable } })` (default off -- opt-in)
---@field src?     string                                    # override the `file:line` recorded in `usercmd.registered()`. The composer already walks past itself to the declaring file, so this is only for a wrapper of your own that declares verbs on someone else's behalf

--- Range info handed to a route's handler via `ctx.range`. `mode`/`col1`/`col2`
--- are best-effort: populated from `vim.fn.visualmode()`/`getpos("'<"/"'>")`
--- whenever `opts.range > 0`, but those Neovim APIs report whichever Visual
--- selection was last active, not necessarily the one (if any) that produced
--- THIS invocation — a manually typed `:5,10Verb` after an unrelated earlier
--- Visual selection still reports that stale mode/columns. Treat as a hint,
--- not proof the range came from Visual just now.
---@class Lib.UserCmd.Composer.RangeInfo
---@field line1 integer
---@field line2 integer
---@field count integer
---@field range integer
---@field mode  string?   # "v" (charwise) | "V" (linewise) | "\22" (blockwise, CTRL-V) | nil (opts.range == 0, or Visual mode never used this session)
---@field col1  integer?  # byte column of the '< mark; nil under the same conditions as `mode`
---@field col2  integer?  # byte column of the '> mark; nil under the same conditions as `mode`. In LINEWISE mode this is Vim's MAXCOL sentinel (2147483647), not a real column — the selection ran to end-of-line. Clamp against the line length before slicing.

--- One route's pre-flight check result: whether its `run` resolves (and, if
--- declared, whether `route.check` passed) — NOT whether invoking it would
--- succeed at runtime, just whether the handler is reachable/callable.
---@class Lib.UserCmd.Composer.CheckResult
---@field path string[]   # the route's own `path`, e.g. {"surround","quote"}; {} for the root route
---@field ok   boolean
---@field err? string     # set iff ok == false: the require error, a shape error, or route.check's own message

--- Handler context. Carries coerced args plus the raw command modifiers so
--- migrated commands keep range/bang/count behavior.
---@class Lib.UserCmd.Composer.Ctx
---@field args   table<string, any>                  # coerced positional args, keyed by ArgSpec.name
---@field pos    any[]                               # coerced positional args, in order
---@field flags  table<string, any>                  # coerced --flag values, keyed by FlagSpec.name (true for bare bool flags, array for repeatable)
---@field kv     table<string, any>                  # coerced key=value pairs, keyed by KvSpec.key
---@field rest   string[]                            # leftover tokens beyond the declared schema
---@field bang   boolean
---@field range  Lib.UserCmd.Composer.RangeInfo
---@field path   string[]                            # the literal path that matched
---@field raw    Lib.UserCommand.Args                # the untouched nvim callback args

--- A registered argument type: a validator and a completer.
--- What `argtypes.validate`/`argtypes.complete` read off a spec: a type
--- name, an optional closed set, and completion-only hints. All three spec
--- shapes carry those, which is why all three share the two functions --
--- flags and kv pairs were passing a `FlagSpec`/`KvSpec` to a parameter
--- declared as `ArgSpec` long before this alias named the arrangement.
---@alias Lib.UserCmd.Composer.TypedSpec Lib.UserCmd.Composer.ArgSpec|Lib.UserCmd.Composer.FlagSpec|Lib.UserCmd.Composer.KvSpec

---@class Lib.UserCmd.Composer.TypeDef
---@field desc? string  # one short line for the help float: what a value of this type is (shown for an argument of this type that has no `desc` of its own)
---@field validate fun(raw: string, spec: Lib.UserCmd.Composer.TypedSpec): boolean, any, string|nil  # ok, value, err
---@field complete? fun(arg_lead: string, spec: Lib.UserCmd.Composer.TypedSpec, cmd_line: string|nil): string[]  # cmd_line is the full command line (nil outside a real one) — for types whose candidates depend on tokens typed before this slot

--- Handle returned by `composer.verb(...)` / `:build()`.
---@class Lib.UserCmd.Composer.Handle
---@field name     fun(self: Lib.UserCmd.Composer.Handle): string
---@field spec     fun(self: Lib.UserCmd.Composer.Handle): Lib.UserCmd.Composer.Spec
---@field document fun(self: Lib.UserCmd.Composer.Handle, path?: string): boolean, string|nil
---@field check    fun(self: Lib.UserCmd.Composer.Handle): Lib.UserCmd.Composer.CheckResult[]
--- Fluent builders additionally expose
--- :desc/:default/:route/:bang/:range/:count/:buffer/:build.

--- The partial docs override a caller hands to `composer.setup{ docs = ... }`.
---@class Lib.UserCmd.Composer.DocsOpts
---@field path? string                               # default output file (default: docs/BINDINGS/Usercmds.md)
---@field mode? "replace"|"section"                  # overwrite whole file, or update a delimited block (default: "replace")

--- The *resolved* defaults `composer.registry.docs` holds. Separate from
--- `DocsOpts` because both keys are always set here -- one type doing both
--- jobs made every read of `registry.docs.path` an optional string.
---@class Lib.UserCmd.Composer.DocsDefaults
---@field path string
---@field mode "replace"|"section"

--- Help float settings (`composer.setup({ help = ... })`). All of it is opt-in.
---@class Lib.UserCmd.Composer.HelpOpts
---@field enable? boolean   # turn the help on for every verb that does not say `help = false` (default false: only verbs with `help = true`)
---@field keymap? string|false  # Cmdline-mode key that opens the cheatsheet for the verb being typed (default: none)

---@class Lib.UserCmd.Composer.SetupOpts
---@field docs? Lib.UserCmd.Composer.DocsOpts
---@field help? Lib.UserCmd.Composer.HelpOpts

--- `lib.nvim.bindings.usercmd.composer.help`: the option float (see its module doc).
---@class Lib.UserCmd.Composer.Help
---@field cfg          { enable: boolean, keymap: string|false|nil }
---@field enabled      fun(spec: Lib.UserCmd.Composer.Spec|nil): boolean
---@field parse_line   fun(line: string, quotes?: boolean): Lib.UserCmd.Composer.Help.State|nil
---@field sanitize     fun(line: string): string
---@field undocumented fun(verb?: string, opts?: { args?: boolean }): { verb: string, route: string, kind: "flag"|"kv"|"arg", name: string }[]
---@field insertion    fun(state: Lib.UserCmd.Composer.Help.State, entry: Lib.UserCmd.Composer.Help.Entry): string
---@field open         fun(root: Lib.UserCmd.Composer.Node, state: Lib.UserCmd.Composer.Help.State, opts?: { title?: string, restore?: string }): boolean
---@field from_cmdline fun(line: string, restore_if_refused?: boolean): boolean
---@field on_dispatch  fun(name: string, spec: Lib.UserCmd.Composer.Spec, root: Lib.UserCmd.Composer.Node, tokens: string[], reason?: string, fallback?: fun(), cmd_opts?: table): boolean
---@field set_keymap   fun(lhs: string|false|nil)
---@field setup        fun(opts?: Lib.UserCmd.Composer.HelpOpts)

---@class Lib.UserCmd.Composer
---@field verb             fun(name: string, spec?: Lib.UserCmd.Composer.Spec): Lib.UserCmd.Composer.Handle
---@field document         fun(path?: string): boolean, string|nil
---@field setup            fun(opts?: Lib.UserCmd.Composer.SetupOpts)
---@field register_type    fun(name: string, def: Lib.UserCmd.Composer.TypeDef)
---@field registry         fun(): table<string, Lib.UserCmd.Composer.Handle>
---@field check_all        fun(): table<string, Lib.UserCmd.Composer.CheckResult[]>
---@field checkhealth      fun(name_or_handle: string|Lib.UserCmd.Composer.Handle)
---@field notify_check_all fun(): boolean ok_overall
---@field help             Lib.UserCmd.Composer.Help

return {}
