---@module 'lib.nvim.mcp'
--- A generic MCP (Model Context Protocol) client over stdio or Streamable HTTP: JSON-RPC 2.0, `initialize`,
--- `tools/list`, `tools/call`. It knows nothing about a particular server. `opts.cmd` starts a process and speaks one
--- JSON message per line; `opts.url` talks to an HTTP endpoint instead (see "HTTP" below). Everything after
--- `mcp.client` (request, list_tools, call_tool, cancel, log, stop) is the same for both.
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
--- HTTP (`opts.url`, optionally `headers` and `secret_headers`):
---
--- * Every client message is one `POST`. The answer is `application/json` (an object, or an array of messages) or an
---   `text/event-stream` whose `data:` events are the messages; `202` (notifications, answers to the server) carries
---   nothing. The whole answer is read before it is handled: a notification the server streams before its answer
---   reaches `on_notification` together with the answer, not earlier.
--- * The `Mcp-Session-Id` the server returns on `initialize` is sent back on every later request, and
---   `MCP-Protocol-Version` (the version the server agreed to) too. `stop` ends the session with a `DELETE`.
--- * `secret_headers` go through curl's config path, never argv (see `lib.nvim.net.curl`): put a token there, not in
---   `headers`.
--- * HTTP errors are values as well: `401`/`403` is `{ code = "unauthorized" }`, `404` on a live session is
---   `{ code = "closed" }` (the session ended; the next request starts a new one), any other non-2xx is
---   `{ code = "http", data = { status, body } }`, a curl failure is `{ code = "http" }` too.
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

local http_post

---@param self Lib.Mcp.Client
---@param message table
---@return boolean
local function send(self, message)
  if self._opts.url then
    return http_post(self, message)
  end
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

---One decoded JSON-RPC message from the server, whichever transport carried it.
---@param self Lib.Mcp.Client
---@param msg table
local function on_message(self, msg)
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
  on_message(self, msg)
end

-- ── HTTP transport ──────────────────────────────────────────────────────────

---The `data:` payloads of a `text/event-stream` body, one string per event.
---@param body string
---@return string[]
local function sse_events(body)
  local events, data = {}, {}
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    if line == "" then
      if #data > 0 then
        events[#events + 1] = table.concat(data, "\n")
        data = {}
      end
    else
      local value = line:match("^data:%s?(.*)$")
      if value then
        data[#data + 1] = value
      end
    end
  end
  return events
end

---@param self Lib.Mcp.Client
---@param extra table<string, string>|nil
---@return table<string, string>
local function http_headers(self, extra)
  local headers = vim.tbl_extend("force", {}, self._opts.headers or {}, {
    ["Content-Type"] = "application/json",
    Accept = "application/json, text/event-stream",
  }, extra or {})
  if self._session_id then
    headers["Mcp-Session-Id"] = self._session_id
  end
  if self._protocol then
    headers["MCP-Protocol-Version"] = self._protocol
  end
  return headers
end

---The error a non-2xx answer stands for.
---@param self Lib.Mcp.Client
---@param resp Lib.Net.Curl.RawResponse
---@return Lib.Mcp.Error
local function http_error(self, resp)
  if resp.status == 401 or resp.status == 403 then
    return err(
      "unauthorized",
      ("the server refused the credentials (HTTP %d)"):format(resp.status),
      {
        status = resp.status,
      }
    )
  end
  if resp.status == 404 and self._session_id then
    self._session_id = nil
    self._state = "closed"
    return err("closed", "the session ended (HTTP 404); the next request starts a new one", {
      status = 404,
    })
  end
  return err("http", ("HTTP %d %s"):format(resp.status, resp.status_text or ""), {
    status = resp.status,
    body = (resp.body or ""):sub(1, 500),
  })
end

---POST one message. A request's answer settles by id; a failure settles that request with the error.
---@param self Lib.Mcp.Client
---@param message table
---@return boolean
function http_post(self, message)
  local ok, body = pcall(vim.json.encode, message)
  if not ok then
    return false
  end
  log(self, "in", body)
  local req_id = message.id ~= nil and message.method ~= nil and message.id or nil
  local timeout = (self._opts.timeout_ms or M.DEFAULT_TIMEOUT_MS) + 2000
  require("lib.nvim.net.curl").fetch_raw(self._opts.url, {
    method = "POST",
    headers = http_headers(self),
    secret_headers = self._opts.secret_headers,
    body = body,
    timeout_ms = timeout,
  }, function(done, resp)
    if not done then
      local e = err("http", "the request failed: " .. tostring(resp):gsub("%s+$", ""))
      if req_id then
        settle(self, req_id, nil, e)
      else
        log(self, "info", e.message)
      end
      return
    end
    local sid = resp.headers["mcp-session-id"]
    if sid and sid ~= "" and not self._session_id then
      self._session_id = sid
    end
    if resp.status < 200 or resp.status >= 300 then
      local e = http_error(self, resp)
      if req_id then
        settle(self, req_id, nil, e)
      else
        log(self, "info", e.message)
      end
      return
    end
    local text = resp.body or ""
    if text:match("^%s*$") then
      return -- 202 Accepted and the like: nothing to read
    end
    local kind = resp.headers["content-type"] or ""
    local payloads = kind:find("text/event-stream", 1, true) and sse_events(text) or { text }
    for _, payload in ipairs(payloads) do
      log(self, "out", payload)
      local decoded, msg =
        pcall(vim.json.decode, payload, { luanil = { object = true, array = true } })
      if decoded and type(msg) == "table" then
        if vim.islist(msg) then
          for _, item in ipairs(msg) do
            if type(item) == "table" then
              on_message(self, item)
            end
          end
        else
          on_message(self, msg)
        end
      end
    end
  end)
  return true
end

---End the session: a `DELETE` with the session id. A server that does not allow it (405) is fine.
---@param self Lib.Mcp.Client
---@param blocking boolean
local function http_end_session(self, blocking)
  local sid = self._session_id
  if not sid then
    return
  end
  self._session_id = nil
  local opts = {
    method = "DELETE",
    headers = vim.tbl_extend("force", {}, self._opts.headers or {}, {
      ["Mcp-Session-Id"] = sid,
      ["MCP-Protocol-Version"] = self._protocol,
    }),
    secret_headers = self._opts.secret_headers,
    timeout_ms = 1500,
  }
  local curl = require("lib.nvim.net.curl")
  pcall(function()
    if blocking then
      curl.fetch_raw_blocking(self._opts.url, opts)
    else
      curl.fetch_raw(self._opts.url, opts, function() end)
    end
  end)
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

  if self._opts.url then
    -- HTTP: nothing to spawn; the session starts with `initialize`
    self._session_id, self._protocol = nil, nil
  else
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
  end
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
      elseif self._opts.url then
        self._state = "closed"
      end
      fail_all(self, e)
      return
    end
    self._server = result
    self._protocol = (type(result) == "table" and result.protocolVersion) or M.PROTOCOL_VERSION
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
  if not sent and not self._proc and not self._opts.url then
    settle(self, id, nil, self._last_error or err("closed", "the server is not running"))
  elseif not sent then
    settle(self, id, nil, err("protocol", "the request cannot be encoded as JSON"))
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
  if self._opts.url then
    self._state = "closed"
    http_end_session(self, false)
    fail_all(self, err("closed", "the client was stopped"))
    return
  end
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
  assert(type(opts) == "table", "mcp.client: opts must be a table")
  assert(
    (type(opts.cmd) == "table" and #opts.cmd > 0) or (type(opts.url) == "string" and opts.url ~= ""),
    "mcp.client: opts.cmd must be an argv list, or opts.url the endpoint of an HTTP server"
  )
  assert(not (opts.cmd and opts.url), "mcp.client: give opts.cmd or opts.url, not both")
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
    elseif c._opts.url then
      c._state = "closed"
      http_end_session(c, true)
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
