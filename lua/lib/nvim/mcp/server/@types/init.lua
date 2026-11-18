---@meta
---@module 'lib.nvim.mcp.server.@types'

---@class Lib.Mcp.Server.Result
---@field content table[] content blocks, usually one `{ type = "text", text = ... }`
---@field isError? boolean the tool failed; the model sees the text and can correct its call

---@class Lib.Mcp.Server.Tool
---@field description? string what the tool answers, for the model
---@field input_schema? table JSON Schema of the arguments (default: an object without properties)
---@field run fun(args: table, ctx: any): Lib.Mcp.Server.Result raises on failure (answered as `isError`)

---@class Lib.Mcp.Server.Opts
---@field name? string `serverInfo.name` (default "lib.nvim")
---@field version? string `serverInfo.version`
---@field instructions? string sent in `initialize`: what the tools are for
---@field tools? table<string, Lib.Mcp.Server.Tool> registered at once (same as `add` for each)
---@field ctx? any handed to every `run` as its second argument

---@class Lib.Mcp.Server
---@field name string
---@field version string
---@field instructions? string
---@field ctx any
---@field initialized boolean set by `notifications/initialized`; informational, nothing is gated on it
---@field tools table<string, Lib.Mcp.Server.Tool>

---@class Lib.Mcp.Server.ServeOpts
---@field read? fun(): string|nil one line without its newline, `nil` at the end (default: stdin)
---@field write? fun(text: string) one answer (default: stdout, flushed)
---@field err? fun(text: string) a diagnostic line (default: stderr)

---@class Lib.Mcp.Server.ContractSpec
---@field prefix? string put before each method name (`"tasks_"` -> `tasks_list`)
---@field methods table<string, string|{ description: string, name?: string }> the READ methods to expose, with their description
---@field opts? table|fun(): table the engine options of every call (`root`, `rulesets`, ...), a function is asked each call

return {}
