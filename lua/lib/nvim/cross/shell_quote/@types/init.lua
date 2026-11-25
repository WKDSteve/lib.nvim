---@meta
---@module 'lib.nvim.cross.shell_quote.@types'

---@alias Lib.ShellKind "posix"|"fish"|"powershell"|"cmd"|"portable"

---@class Lib.ShellQuote
---@field shell_kind fun(shell: string|nil): Lib.ShellKind # Quoting family of a shell (executable name, path, or command string with arguments); unknown shells count as posix
---@field arg_count fun(argv: any): integer # Highest positive integer index of an argv list (a hole is found, not skipped)
---@field word fun(s: string, kind: Lib.ShellKind, program?: boolean): string|nil, string|nil # One word quoted for the family, or `nil, err` when it cannot be represented safely
---@field argv_to_line fun(argv: string[], kind: Lib.ShellKind): string|nil, string|nil # A whole command line, every word quoted; refuses control characters and holes

return {}
