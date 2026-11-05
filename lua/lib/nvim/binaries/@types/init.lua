---@meta
---@module 'lib.nvim.binaries.@types'

---@class Lib.Binaries.Spec
---@field fetch fun(): boolean|nil, string|nil # Downloads everything the plugin needs; true on success, else false and why.
---@field status? fun(): string # One line: what is installed.

---@class Lib.Binaries.Result
---@field ok boolean
---@field err? string

---@class Lib.Binaries
---@field MODES string[] # "auto", "manual", "never".
---@field mode fun(): "auto"|"manual"|"never" # `vim.g.lib_binaries`, default "auto"; an invalid value is "manual".
---@field guard fun(name: string): boolean, string|nil # May `name` download now? Ask right before a download.
---@field register fun(name: string, spec: Lib.Binaries.Spec) # Tell lib how this plugin downloads on request.
---@field registered fun(): string[]
---@field status fun(): table<string, string>
---@field fetch fun(name?: string): table<string, Lib.Binaries.Result> # Download on request (allowed in "manual", refused in "never").

return {}
