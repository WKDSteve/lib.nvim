---@meta
---@module 'lib.nvim.mcp.@types'

---@class Lib.Mcp.Opts
---@field cmd string[] the server command as an argv list (e.g. `{ "npx", "-y", "mcp-remote@latest", url }`)
---@field id? string one client per id: a second `mcp.client` with the same id returns the first
---@field env? table<string, string> extra environment
---@field cwd? string
---@field timeout_ms? integer per-request timeout (default 30000)
---@field client_info? { name: string, version: string } sent in `initialize` (default lib.nvim.mcp)
---@field on_notification? fun(method: string, params: any) a server notification (progress, list_changed, ...)
---@field on_log? fun(kind: "out"|"err"|"in"|"info", text: string) every line of traffic and stderr, as it arrives. Never turn stderr into a user-visible message: a bridge may print a login link there.

---@class Lib.Mcp.Error
---@field code string|integer a JSON-RPC number, or "spawn" | "exited" | "timeout" | "port_in_use" | "closed" | "cancelled" | "protocol"
---@field message string
---@field data? any

---@class Lib.Mcp.ToolResult
---@field content? table[]
---@field structuredContent? any
---@field isError? boolean

---@alias Lib.Mcp.State "idle"|"starting"|"initializing"|"ready"|"stopping"|"closed"

---@class Lib.Mcp.Client
---@field request fun(self: Lib.Mcp.Client, method: string, params: table|nil, cb: fun(result: any, err: Lib.Mcp.Error|nil)|nil, opts?: { timeout_ms?: integer }): integer|nil
---@field cancel fun(self: Lib.Mcp.Client, id: integer)
---@field list_tools fun(self: Lib.Mcp.Client, cb: fun(tools: table[]|nil, err: Lib.Mcp.Error|nil))
---@field call_tool fun(self: Lib.Mcp.Client, name: string, args: table|nil, cb: fun(result: Lib.Mcp.ToolResult|nil, err: Lib.Mcp.Error|nil), opts?: { timeout_ms?: integer }): integer|nil
---@field state fun(self: Lib.Mcp.Client): Lib.Mcp.State
---@field server fun(self: Lib.Mcp.Client): table|nil
---@field log fun(self: Lib.Mcp.Client): { kind: string, text: string }[]
---@field stop fun(self: Lib.Mcp.Client)
---@field restart fun(self: Lib.Mcp.Client)

return {}
