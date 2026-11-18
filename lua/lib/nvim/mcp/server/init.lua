---@module 'lib.nvim.mcp.server'
---@brief An MCP (Model Context Protocol) server over stdio: JSON-RPC 2.0 dispatch, a tool registry, the read loop.
---@description
--- The other half of `lib.nvim.mcp` (the client). Moved here from `docmap.mcp.protocol` (docmap.nvim), where it was
--- the one server of the ecosystem; the protocol is generic, the tools are the plugin's.
---
---```lua
--- local mcp_server = require("lib.nvim.mcp.server")
--- local s = mcp_server.new({ name = "tasks.nvim", version = "0.1.0", instructions = "Read-only tools over ..." })
--- s:add("tasks_hello", {
---   description = "What this engine is.",
---   input_schema = { type = "object", properties = {} },
---   run = function(args, ctx) return mcp_server.text({ ok = true }) end,
--- })
--- os.exit(s:serve())          -- nvim --headless -u NONE -l scripts/mcp.lua; blocks until stdin closes
---```
---
--- What it does:
---
--- * `initialize` echoes a protocol version of `SUPPORTED` the client asks for, else answers the newest one;
---   `capabilities.tools.listChanged` is `false` (the registry is fixed once `serve` runs). `ping`, `tools/list`
---   (sorted by name, no paging: a catalogue of a few dozen tools fits one answer), `tools/call`.
--- * A notification (no `id`) is never answered. Nothing is gated on the handshake: every tool is a read, there is no
---   session state to protect, and a client that sends `tools/list` right behind `initialize` must not get an error.
--- * A failing tool (unknown name, a `run` that raises) is a *result* with `isError = true`, not a JSON-RPC error: the
---   model sees it and can fix its argument. A malformed line is `-32700`, a message that is no request `-32600`, an
---   unknown method `-32601`, a `tools/call` without a name `-32602`; a crash inside dispatch is `-32603` and the
---   process lives on.
--- * `serve` writes nothing but protocol to stdout: while it runs, `print` and `vim.notify` go to stderr (in
---   `nvim -l`, `print` writes to stdout and one stray line would corrupt the stream). Each answer is flushed (the
---   Windows C runtime buffers a "line buffered" stdout fully).
---
--- Helpers for the tools: `text(value)` (a value as one JSON text block, canonical bytes), `error_text(msg)`,
--- `clamp_limit(n, default, max)`, and `contract_tools(api, spec)`: read methods of a `lib.nvim.contract.api`
--- dispatcher as tools, with an input schema made from the method's parameter types. Only the methods `spec` names
--- become tools: a plugin lists its read methods, and a write door (`ops`) is not exposed by accident.
---
--- Not here: resources, prompts, sampling, an HTTP transport, `notifications/tools/list_changed`.

require("lib.nvim.mcp.server.@types")

local M = {}

---Spec revisions this server claims to speak, newest first. Nothing here branches on the version (the surface used
---is the same in all of them), so the list is a claim that was checked, not a guess forward.
---@type string[]
M.SUPPORTED = { "2025-06-18", "2025-03-26", "2024-11-05" }

M.VERSION = "0.1.0"

-- JSON-RPC 2.0 reserved error codes.
M.ERR_PARSE = -32700
M.ERR_INVALID_REQUEST = -32600
M.ERR_METHOD_NOT_FOUND = -32601
M.ERR_INVALID_PARAMS = -32602
M.ERR_INTERNAL = -32603

---What MCP allows as a tool name (2025-06-18: 1..128 of `[A-Za-z0-9_.-]`); 64 keeps older clients happy too.
local NAME_MAX = 64

---@param id any
---@param result table
---@return table
local function ok(id, result)
  return { jsonrpc = "2.0", id = id, result = result }
end

---@param id any
---@param code integer
---@param message string
---@return table
local function fail(id, code, message)
  return {
    jsonrpc = "2.0",
    id = id == nil and vim.NIL or id,
    error = { code = code, message = message },
  }
end

---A value as an MCP tool result: one text block with the value's canonical JSON (sorted keys, the same bytes on every
---run, so a client's cache of a result means something). A string is sent as it is.
---@param value any
---@param is_error? boolean
---@return Lib.Mcp.Server.Result
function M.text(value, is_error)
  local text = type(value) == "string" and value or require("lib.nvim.json.canonical").encode(value)
  local res = { content = { { type = "text", text = text } } }
  if is_error then
    res.isError = true
  end
  return res
end

---A failed tool call the model should see.
---@param message string
---@return Lib.Mcp.Server.Result
function M.error_text(message)
  return M.text(tostring(message), true)
end

---Clamp a caller's limit: `nil` (or no number) is `default`, not "unlimited".
---@param n any
---@param default integer
---@param max? integer default 1000
---@return integer
function M.clamp_limit(n, default, max)
  max = max or 1000
  if type(n) ~= "number" or n ~= n then
    return default
  end
  n = math.floor(n)
  if n < 1 then
    return 1
  end
  return n > max and max or n
end

---@class Lib.Mcp.Server
local Server = {}
Server.__index = Server

---@param opts? Lib.Mcp.Server.Opts
---@return Lib.Mcp.Server
function M.new(opts)
  opts = opts or {}
  local self = setmetatable({
    name = opts.name or "lib.nvim",
    version = opts.version or M.VERSION,
    instructions = opts.instructions,
    ctx = opts.ctx,
    initialized = false,
    tools = {},
  }, Server)
  for name, tool in pairs(opts.tools or {}) do
    self:add(name, tool)
  end
  return self
end

---Register a tool. Raises on a bad name, a name taken, or a tool without `run`: a mistake of the plugin, found when
---the server is built rather than on the first call.
---@param name string
---@param tool Lib.Mcp.Server.Tool
---@return Lib.Mcp.Server self
function Server:add(name, tool)
  if type(name) ~= "string" or #name > NAME_MAX or not name:match("^[%w_%.%-]+$") then
    error(
      ("mcp.server: bad tool name %s (1..%d of A-Z a-z 0-9 _ . -)"):format(
        vim.inspect(name),
        NAME_MAX
      ),
      2
    )
  end
  if self.tools[name] then
    error(("mcp.server: tool %s is registered twice"):format(name), 2)
  end
  if type(tool) ~= "table" or type(tool.run) ~= "function" then
    error(("mcp.server: tool %s needs a run function"):format(name), 2)
  end
  self.tools[name] = tool
  return self
end

---The catalogue as `tools/list` wants it, sorted by name (a hash walk would give another order on each connection,
---and some clients hash the list to decide whether a cached schema is still valid).
---@return table[]
function Server:list()
  local names = vim.tbl_keys(self.tools)
  table.sort(names)
  local out = {}
  for i, name in ipairs(names) do
    local tool = self.tools[name]
    out[i] = {
      name = name,
      description = tool.description or "",
      inputSchema = tool.input_schema or { type = "object", properties = vim.empty_dict() },
    }
  end
  return out
end

---Run one tool. Raises on an unknown name or a failing tool (`request` turns that into an `isError` result).
---@param name string
---@param args? table
---@return Lib.Mcp.Server.Result
function Server:call(name, args)
  local tool = self.tools[name]
  if not tool then
    error(("unknown tool: %s"):format(tostring(name)), 0)
  end
  local res = tool.run(args or {}, self.ctx)
  if type(res) ~= "table" or type(res.content) ~= "table" then
    error(("tool %s answered no content list"):format(name), 0)
  end
  return res
end

---@param params table
---@return table
function Server:_initialize(params)
  local want = type(params) == "table" and params.protocolVersion or nil
  local version = M.SUPPORTED[1]
  for _, v in ipairs(M.SUPPORTED) do
    if want == v then
      version = v
      break
    end
  end
  return {
    protocolVersion = version,
    capabilities = { tools = { listChanged = false } },
    serverInfo = { name = self.name, version = self.version },
    instructions = self.instructions,
  }
end

---Handle one decoded JSON-RPC message; `nil` for a notification (which is never answered).
---@param msg any
---@return table? response
function Server:request(msg)
  if type(msg) ~= "table" or msg.jsonrpc ~= "2.0" or type(msg.method) ~= "string" then
    return fail(
      type(msg) == "table" and msg.id or nil,
      M.ERR_INVALID_REQUEST,
      "not a JSON-RPC 2.0 request"
    )
  end
  local id, method = msg.id, msg.method
  local params = type(msg.params) == "table" and msg.params or {}
  if id == nil then
    if method == "notifications/initialized" then
      self.initialized = true
    end
    return nil
  end
  if method == "initialize" then
    return ok(id, self:_initialize(params))
  elseif method == "ping" then
    return ok(id, vim.empty_dict())
  elseif method == "tools/list" then
    return ok(id, { tools = self:list() })
  elseif method == "tools/call" then
    if type(params.name) ~= "string" then
      return fail(id, M.ERR_INVALID_PARAMS, "tools/call requires a string `name`")
    end
    local args = type(params.arguments) == "table" and params.arguments or {}
    local success, res = pcall(self.call, self, params.name, args)
    if success then
      return ok(id, res)
    end
    return ok(id, M.error_text(tostring(res)))
  end
  return fail(id, M.ERR_METHOD_NOT_FOUND, "unknown method: " .. method)
end

---Encode a response; a value `vim.json` cannot write (an id of `1e999`) is an invalid-request error with a null id
---rather than a raise out of the loop.
---@param response table
---@return string
local function encode(response)
  local encoded, text = pcall(vim.json.encode, response)
  if encoded then
    return text
  end
  return vim.json.encode(
    fail(nil, M.ERR_INVALID_REQUEST, "the response could not be encoded (invalid id?)")
  )
end

---Decode one line, dispatch it, encode the answer. `nil` when nothing goes back (a notification, a blank line).
---@param line string
---@return string? response without the trailing newline
function Server:dispatch(line)
  if type(line) ~= "string" or line:match("^%s*$") then
    return nil
  end
  local decoded, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not decoded then
    return encode(fail(nil, M.ERR_PARSE, "invalid JSON"))
  end
  local handled, response = pcall(self.request, self, msg)
  if not handled then
    return encode(fail(type(msg) == "table" and msg.id or nil, M.ERR_INTERNAL, tostring(response)))
  end
  if response == nil then
    return nil
  end
  return encode(response)
end

---Serve over stdin/stdout until stdin closes. Blocks; returns the exit code (0) instead of exiting.
---@param opts? Lib.Mcp.Server.ServeOpts
---@return integer
function Server:serve(opts)
  opts = opts or {}
  local read = opts.read or function()
    return io.read("l")
  end
  local write = opts.write
    or function(text)
      io.stdout:write(text, "\n")
      io.stdout:flush()
    end
  local err = opts.err or function(text)
    io.stderr:write(text, "\n")
  end
  -- stdout is the protocol channel: whatever a module prints or notifies while a tool runs goes to stderr
  local saved_print, saved_notify = _G.print, vim.notify
  _G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
      parts[i] = tostring((select(i, ...)))
    end
    err(table.concat(parts, "\t"))
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.notify = function(msg)
    err(tostring(msg))
  end
  if not opts.read then
    io.stdout:setvbuf("line")
  end
  err(("%s MCP server ready"):format(self.name))
  local success, problem = pcall(function()
    while true do
      local line = read()
      if line == nil then
        break -- stdin closed: the client went away, the normal end
      end
      local response = self:dispatch(line)
      if response then
        write(response)
      end
    end
  end)
  _G.print, vim.notify = saved_print, saved_notify
  if not success then
    err("mcp.server: " .. tostring(problem))
    return 1
  end
  return 0
end

-- ── contract bridge ───────────────────────────────────────────────────────────

---JSON Schema of one `lib.nvim.contract.api` parameter type.
---@type table<string, table>
local SCHEMA_OF = {
  string = { type = "string" },
  boolean = { type = "boolean" },
  integer = { type = "integer" },
  number = { type = "number" },
  object = { type = "object" },
  string_list = { type = "array", items = { type = "string" } },
  object_list = { type = "array", items = { type = "object" } },
}

---The input schema of a contract method: its parameters with their types (a plugin's own type is left open), the
---required ones listed.
---@param method Lib.Contract.ApiMethod
---@return table
function M.schema_of(method)
  local props = {}
  for name, ty in pairs(method.params or {}) do
    props[name] = vim.deepcopy(SCHEMA_OF[ty] or {})
  end
  local schema = { type = "object", properties = next(props) and props or vim.empty_dict() }
  if method.required and #method.required > 0 then
    local req = vim.list_slice(method.required, 1)
    table.sort(req)
    schema.required = req
  end
  return schema
end

---Read methods of a contract dispatcher (`lib.nvim.contract.api.make`, or a plugin's wrapper with `METHODS` and
---`call`) as tools: `<prefix><method>`, the arguments are the method's `params`, the answer is the document's
---canonical bytes, an error document is `isError`. Only the methods in `spec.methods` become tools.
---@param api { METHODS: table<string, Lib.Contract.ApiMethod>, call: fun(name: string, request: table, opts?: table): string, string? }
---@param spec Lib.Mcp.Server.ContractSpec
---@return table<string, Lib.Mcp.Server.Tool>
function M.contract_tools(api, spec)
  local tools = {}
  for method_name, entry in pairs(spec.methods) do
    local method = api.METHODS[method_name]
    if not method then
      error(("mcp.server.contract_tools: the contract has no method %s"):format(method_name), 2)
    end
    if method.flat then
      -- a flat method is a write door (`ops`); a read tool over it would be a write tool by another name
      error(
        ("mcp.server.contract_tools: %s is a write door (flat), not a read method"):format(
          method_name
        ),
        2
      )
    end
    local description = type(entry) == "string" and entry or entry.description
    local name = (type(entry) == "table" and entry.name) or ((spec.prefix or "") .. method_name)
    tools[name] = {
      description = description,
      input_schema = M.schema_of(method),
      run = function(args)
        local opts = spec.opts
        if type(opts) == "function" then
          opts = opts()
        end
        local text, code = api.call(method_name, { schema = 1, params = args }, opts)
        return M.text(text, code ~= nil)
      end,
    }
  end
  return tools
end

return M
