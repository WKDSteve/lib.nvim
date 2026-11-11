---@module 'lib.nvim.mcp'
--- A generic MCP (Model Context Protocol) client over stdio: start a process, speak JSON-RPC 2.0 with one JSON
--- message per line, `initialize`, `tools/list`, `tools/call`. It knows nothing about a particular server.
---
--- Decision (stdin): `lib.nvim.system.job.start` does not expose an open stdin pipe, so this module uses
--- `vim.system(cmd, { stdin = true, ... })` directly, with `lib.nvim.system.lines` for the stdout/stderr line
--- splitting. Extending `job.start` would be the right move only if a second consumer needs an open stdin.
---
---```lua
--- local mcp = require("lib.nvim.mcp")
--- local c = mcp.client({ id = "tosca", cmd = { "npx", "-y", "mcp-remote@latest", url } })
--- c:list_tools(function(tools, err) ... end)                  -- starts the process on first use
--- c:call_tool("run_playlist", { id = "x" }, function(res, err) -- res: { content, structuredContent, isError }
---   ...
--- end)
---```
---
--- What it does, and what it deliberately does not:
---
--- * One process per client id (`mcp.client` with an id returns the existing one), started on first use, stopped
---   at `VimLeavePre`.
--- * Requests carry an id and are matched to their answer; each has a timeout. On a timeout (or a `cancel`) the
---   server gets `notifications/cancelled`, and the caller gets `{ code = "timeout" }`.
--- * `initialize` states the protocol version and `clientInfo` and **no** `sampling`/`elicitation`
---   capability; `notifications/initialized` follows. Requests made earlier wait for it.
--- * `tools/list` follows `nextCursor`; `tools/call` hands `content`, `structuredContent` and `isError` back
---   unchanged.
--- * **stderr never reaches a notification.** A bridge may print a login link there. It goes to the client's
---   ring buffer (`client:log()`) and to `opts.on_log`; nothing else.
--- * Errors are values: `{ code, message, data? }`, where `code` is a JSON-RPC number or one of `"spawn"`,
---   `"exited"`, `"timeout"`, `"port_in_use"`, `"closed"`, `"protocol"`.
---
--- See @types/init.lua for Lib.Mcp.*.

require("lib.nvim.mcp.@types")

local lines = require("lib.nvim.system.lines")

local M = {}

M.PROTOCOL_VERSION = "2025-06-18"
M.DEFAULT_TIMEOUT_MS = 30000
local LOG_KEEP = 200

---@type table<string, Lib.Mcp.Client>
local registry = {}
local exit_hook = false

local Client = {}
Client.__index = Client

---@param code string|integer
---@param message string
---@param data any
---@return Lib.Mcp.Error
local function err(code, message, data)
  return { code = code, message = message, data = data }
end

---@param self Lib.Mcp.Client
---@param kind "out"|"err"|"in"|"info"
---@param text string
local function log(self, kind, text)
  local ring = self._log
  ring[#ring + 1] = { kind = kind, text = text }
  if #ring > LOG_KEEP then
    table.remove(ring, 1)
  end
  if self._opts.on_log then
    pcall(self._opts.on_log, kind, text)
  end
end

---@param self Lib.Mcp.Client
---@param message table
---@return boolean
local function send(self, message)
  if not self._proc then
    return false
  end
  local ok, text = pcall(vim.json.encode, message)
  if not ok then
    return false
  end
  log(self, "in", text)
  local wrote = pcall(function()
    self._proc:write(text .. "\n")
  end)
  return wrote
end

---@param self Lib.Mcp.Client
---@param id integer
---@param result any
---@param e Lib.Mcp.Error|nil
local function settle(self, id, result, e)
  local p = self._pending[id]
  if not p then
    return
  end
  self._pending[id] = nil
  if p.timer then
    p.timer:stop()
    p.timer:close()
  end
  if p.cb then
    pcall(p.cb, result, e)
  end
end

---@param self Lib.Mcp.Client
---@param e Lib.Mcp.Error
local function fail_all(self, e)
  local ids = vim.tbl_keys(self._pending)
  table.sort(ids)
  for _, id in ipairs(ids) do
    settle(self, id, nil, e)
  end
  local queued = self._queue
  self._queue = {}
  for _, q in ipairs(queued) do
    if q.cb then
      pcall(q.cb, nil, e)
    end
  end
end

---@param self Lib.Mcp.Client
---@param line string
local function on_stdout_line(self, line)
  if line == "" then
    return
  end
  log(self, "out", line)
  local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
  if not ok or type(msg) ~= "table" then
    return -- a bridge may print a banner on stdout; not JSON-RPC, kept in the log only
  end
  if msg.id ~= nil and (msg.result ~= nil or msg.error ~= nil) then
    local id = msg.id
    if msg.error then
      local e = msg.error
      settle(self, id, nil, err(e.code or "protocol", tostring(e.message or "error"), e.data))
    else
      settle(self, id, msg.result, nil)
    end
  elseif msg.method and msg.id ~= nil then
    -- a request from the server (ping, sampling, roots...): answer "method not found" so it never waits
    if msg.method == "ping" then
      send(self, { jsonrpc = "2.0", id = msg.id, result = vim.empty_dict() })
    else
      send(self, {
        jsonrpc = "2.0",
        id = msg.id,
        error = {
          code = -32601,
          message = "method not supported by this client: " .. tostring(msg.method),
        },
      })
    end
  elseif msg.method then
    if self._opts.on_notification then
      pcall(self._opts.on_notification, msg.method, msg.params)
    end
  end
end

---@param self Lib.Mcp.Client
---@param text string
local function on_stderr_line(self, text)
  log(self, "err", text)
  if self._state == "starting" or self._state == "initializing" then
    if
      text:find("EADDRINUSE", 1, true)
      or text:lower():find("address already in use", 1, true)
      or text:lower():find("port %d+ is in use")
    then
      self._port_in_use = true
    end
  end
end

---@param self Lib.Mcp.Client
---@param obj table vim.SystemCompleted
local function on_exit(self, obj)
  local was = self._state
  self._proc = nil
  self._state = "closed"
  local e
  if self._port_in_use then
    e = err(
      "port_in_use",
      "the bridge could not bind its port (already in use): " .. (self._opts.cmd[1] or "?")
    )
  elseif was == "stopping" then
    e = err("closed", "the client was stopped")
  else
    e = err(
      "exited",
      ("the server process ended (exit code %s)"):format(tostring(obj.code)),
      { code = obj.code }
    )
  end
  self._last_error = e
  fail_all(self, e)
end

---@param self Lib.Mcp.Client
local function flush_queue(self)
  local queued = self._queue
  self._queue = {}
  for _, q in ipairs(queued) do
    Client.request(self, q.method, q.params, q.cb, q.opts)
  end
end

---Start the process and run the handshake. Idempotent.
---@param self Lib.Mcp.Client
local function ensure_started(self)
  if self._state ~= "idle" and self._state ~= "closed" then
    return
  end
  self._state = "starting"
  self._port_in_use = false
  self._last_error = nil

  local stdout = lines.buffered(function(_, line)
    vim.schedule(function()
      on_stdout_line(self, line)
    end)
  end)
  local stderr = lines.buffered(function(_, line)
    vim.schedule(function()
      on_stderr_line(self, line)
    end)
  end)

  local ok, proc = pcall(vim.system, self._opts.cmd, {
    stdin = true,
    stdout = stdout,
    stderr = stderr,
    env = self._opts.env,
    cwd = self._opts.cwd,
    text = true,
  }, function(obj)
    -- a beat later: the stderr it printed on the way out is still in the pipe
    vim.defer_fn(function()
      on_exit(self, obj)
    end, 50)
  end)

  if not ok then
    self._state = "closed"
    local e =
      err("spawn", ("cannot start %s: %s"):format(tostring(self._opts.cmd[1]), tostring(proc)))
    self._last_error = e
    fail_all(self, e)
    return
  end
  self._proc = proc
  self._state = "initializing"

  Client.request(self, "initialize", {
    protocolVersion = M.PROTOCOL_VERSION,
    capabilities = vim.empty_dict(),
    clientInfo = self._opts.client_info or { name = "lib.nvim.mcp", version = "1" },
  }, function(result, e)
    if e then
      self._last_error = e
      if self._proc then
        pcall(function()
          self._proc:kill("sigterm")
        end)
      end
      fail_all(self, e)
      return
    end
    self._server = result
    self._state = "ready"
    send(self, { jsonrpc = "2.0", method = "notifications/initialized" })
    flush_queue(self)
  end, { handshake = true })
end

---@param self Lib.Mcp.Client
---@param method string
---@param params table|nil
---@param cb fun(result: any, err: Lib.Mcp.Error|nil)|nil
---@param opts { timeout_ms?: integer, handshake?: boolean }|nil
---@return integer|nil id
function Client.request(self, method, params, cb, opts)
  opts = opts or {}
  if
    self._state == "closed"
    and self._last_error
    and self._last_error.code == "spawn"
    and not opts.handshake
  then
    -- a command that cannot start stays an error until the caller asks again via `restart`
    vim.schedule(function()
      if cb then
        cb(nil, self._last_error)
      end
    end)
    return nil
  end
  if not opts.handshake then
    if self._state == "idle" or self._state == "closed" then
      self._queue[#self._queue + 1] = { method = method, params = params, cb = cb, opts = opts }
      ensure_started(self)
      return nil
    elseif self._state ~= "ready" then
      self._queue[#self._queue + 1] = { method = method, params = params, cb = cb, opts = opts }
      return nil
    end
  end

  self._next = self._next + 1
  local id = self._next
  local timer = vim.uv.new_timer()
  local timeout = opts.timeout_ms or self._opts.timeout_ms or M.DEFAULT_TIMEOUT_MS
  self._pending[id] = { cb = cb, timer = timer, method = method }
  timer:start(timeout, 0, function()
    vim.schedule(function()
      if self._pending[id] then
        send(self, {
          jsonrpc = "2.0",
          method = "notifications/cancelled",
          params = { requestId = id, reason = "timeout" },
        })
        settle(self, id, nil, err("timeout", ("%s timed out after %d ms"):format(method, timeout)))
      end
    end)
  end)
  local sent = send(self, { jsonrpc = "2.0", id = id, method = method, params = params })
  if not sent and not self._proc then
    settle(self, id, nil, self._last_error or err("closed", "the server is not running"))
  end
  -- A failed write with the process still registered means it is going away: its exit settles the request, with
  -- the stderr it printed on the way out taken into account (port in use).
  return id
end

---Abandon a request: the callback gets `{ code = "cancelled" }` and the server a `notifications/cancelled`.
---@param self Lib.Mcp.Client
---@param id integer
function Client.cancel(self, id)
  if self._pending[id] then
    send(self, {
      jsonrpc = "2.0",
      method = "notifications/cancelled",
      params = { requestId = id, reason = "cancelled by the client" },
    })
    settle(self, id, nil, err("cancelled", "cancelled by the caller"))
  end
end

---All tools, following `nextCursor`.
---@param self Lib.Mcp.Client
---@param cb fun(tools: table[]|nil, err: Lib.Mcp.Error|nil)
function Client.list_tools(self, cb)
  local all = {}
  local function page(cursor)
    Client.request(
      self,
      "tools/list",
      cursor and { cursor = cursor } or vim.empty_dict(),
      function(result, e)
        if e then
          cb(nil, e)
          return
        end
        vim.list_extend(all, (result and result.tools) or {})
        if result and type(result.nextCursor) == "string" and result.nextCursor ~= "" then
          page(result.nextCursor)
        else
          cb(all, nil)
        end
      end
    )
  end
  page(nil)
end

---Call a tool; the result is handed back as the server sent it (`content`, `structuredContent`, `isError`).
---@param self Lib.Mcp.Client
---@param name string
---@param args table|nil
---@param cb fun(result: Lib.Mcp.ToolResult|nil, err: Lib.Mcp.Error|nil)
---@param opts { timeout_ms?: integer }|nil
---@return integer|nil id
function Client.call_tool(self, name, args, cb, opts)
  return Client.request(
    self,
    "tools/call",
    { name = name, arguments = args or vim.empty_dict() },
    cb,
    opts
  )
end

---@param self Lib.Mcp.Client
---@return Lib.Mcp.State
function Client.state(self)
  return self._state
end

---@param self Lib.Mcp.Client
---@return table|nil server_info the `initialize` result (serverInfo, capabilities, protocolVersion)
function Client.server(self)
  return self._server
end

---@param self Lib.Mcp.Client
---@return { kind: string, text: string }[] log recent traffic and stderr, oldest first
function Client.log(self)
  return vim.deepcopy(self._log)
end

---Stop the process; pending requests fail with `{ code = "closed" }`.
---@param self Lib.Mcp.Client
function Client.stop(self)
  if self._proc then
    self._state = "stopping"
    pcall(function()
      self._proc:kill("sigterm")
    end)
    local proc = self._proc
    vim.defer_fn(function()
      if self._proc == proc then
        pcall(function()
          proc:kill("sigkill")
        end)
      end
    end, 2000)
  else
    self._state = "closed"
    fail_all(self, err("closed", "the client was stopped"))
  end
end

---Forget a failed start so the next request tries again.
---@param self Lib.Mcp.Client
function Client.restart(self)
  if self._proc then
    return
  end
  self._state, self._last_error = "idle", nil
end

---Create (or fetch, by id) a client. Nothing starts until the first request.
---@param opts Lib.Mcp.Opts
---@return Lib.Mcp.Client
function M.client(opts)
  assert(
    type(opts) == "table" and type(opts.cmd) == "table" and #opts.cmd > 0,
    "mcp.client: opts.cmd must be an argv list"
  )
  if opts.id and registry[opts.id] then
    return registry[opts.id]
  end
  local self = setmetatable({
    _opts = opts,
    _state = "idle",
    _pending = {},
    _queue = {},
    _next = 0,
    _log = {},
  }, Client)
  if opts.id then
    registry[opts.id] = self
  end
  if not exit_hook then
    exit_hook = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("lib.nvim.mcp", { clear = true }),
      callback = function()
        M.stop_all()
      end,
    })
  end
  return self
end

---@param id string
---@return Lib.Mcp.Client|nil
function M.get(id)
  return registry[id]
end

---Stop every client (also done at `VimLeavePre`).
function M.stop_all()
  for _, c in pairs(registry) do
    if c._proc then
      pcall(function()
        c._proc:kill("sigterm")
      end)
    end
  end
end

---Drop a client from the registry (stops it first).
---@param id string
function M.forget(id)
  local c = registry[id]
  if c then
    Client.stop(c)
    registry[id] = nil
  end
end

return M
