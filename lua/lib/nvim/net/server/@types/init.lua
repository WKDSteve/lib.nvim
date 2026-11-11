---@meta
---@module 'lib.nvim.net.server.@types'

---@class Lib.Net.Server.Request
---@field method string
---@field path string
---@field query table<string, string> decoded, every key and value already validated against the route
---@field params string[] path captures, already validated
---@field headers table<string, string> lowercase names
---@field body string|any the raw body, or what the route's `body` parser returned

---@class Lib.Net.Server.Route
---@field path? string exact path (exactly one of `path` / `pattern`)
---@field pattern? string Lua pattern on the path; every capture needs a validator in `captures`
---@field method? string default "GET"
---@field captures? (string|fun(value: string): boolean)[] one validator per capture, a Lua pattern (use `^...$`) or a predicate
---@field query? table<string, string|fun(value: string): boolean> the only query keys the route accepts, each with its validator
---@field body? boolean|fun(raw: string): any a body is accepted; a function parses it (it gets only the raw body, so `vim.json.decode` fits as is; a throw or a falsy result is a 400)
---@field body_required? boolean
---@field handler fun(req: Lib.Net.Server.Request): integer, string?, string? status, content type, body

---@class Lib.Net.Server.Opts
---@field routes Lib.Net.Server.Route[]
---@field name? string
---@field port? integer default 0 (the OS picks); the bind address is always 127.0.0.1
---@field max_header? integer default 65536
---@field max_body? integer default 1048576
---@field idle_ms? integer a client that has not finished its request is dropped after this long (default 10000)

---@class Lib.Net.Server.Handle
---@field port integer
---@field url string
---@field name string
---@field stop fun()
---@field is_running fun(): boolean

return {}
