---@module 'lib.nvim.net.server'
--- A small local HTTP server for a plugin that needs a page or a script to call back into Neovim: loopback only,
--- an OS-assigned port, strict route validation, torn down at `VimLeavePre`.
---
--- Generalized from `docmap.nvim` (`editor/serve.lua`). The rules that file enforces are enforced here for every
--- consumer, in code, not by documentation:
---
--- 1. **Bind `127.0.0.1`, never anything else.** There is no `host` option. The default port is 0 (the OS picks one);
---    `opts.port` exists for a caller that must know it in advance.
--- 2. **Every route is a whitelist.** A request is served only if method, path, query keys and values, and the
---    `Host` header match what the route declared. Anything else is 400/403/404/405 before a handler sees it.
---    Path captures and query values are validated against patterns (a whole-value pattern such as `^%x+$`, or a predicate) -- a request
---    path is never passed on unchecked, which is how it becomes argument injection into a subprocess.
--- 3. **The `Host` header must name the loopback address** (`127.0.0.1` or `localhost`, with this port): a web
---    page on another origin that makes the browser resolve its own name to 127.0.0.1 (DNS rebinding) is refused.
--- 4. **Bounded input:** the header block is capped (default 64 KB), a body is read only for a route that allows
---    one and only up to `max_body` (default 1 MB), a stalled client is dropped after `idle_ms`, and no more than
---    `max_clients` (default 64) connections are open at once (one more is answered 503 and closed).
--- 5. **The server dies with the editor:** `VimLeavePre` closes every socket (`server.stop_all()`).
---
--- Handlers run on the main loop (`vim.schedule`), where `vim.system():wait()` and the rest of the editor API are
--- allowed; libuv read callbacks are a fast-event context where they are not.
---
--- A handler that asks git or another program should not block the editor for it: a route with `async = true`
--- gets `handler(req, respond)` and answers with `respond(status, ctype?, body?)` whenever it is ready. A throw
--- before the answer is a 500, no answer within `timeout_ms` a 504; `respond` is effective once, and a late one
--- (client gone, server stopped, deadline passed) is a no-op.
---
---```lua
--- local server = require("lib.nvim.net.server")
--- local s = server.start({
---   name = "docs",
---   routes = {
---     { path = "/api/ping", handler = function() return 200, "application/json", '{"ok":true}' end },
---     { pattern = "^/api/commit/([0-9a-f]+)$", captures = { "^%x+$" }, query = { n = "^%d+$" },
---       handler = function(req) return 200, "text/plain", req.params[1] end },
---   },
--- })
--- s.url, s.port, s.stop()
---```
---
--- See @types/init.lua for Lib.Net.Server.*.

require("lib.nvim.net.server.@types")

local uv = vim.uv or vim.loop

local M = {}

---@type table<table, true>
local running = {}
local hook_installed = false

local STATUS = {
  [200] = "OK",
  [204] = "No Content",
  [400] = "Bad Request",
  [403] = "Forbidden",
  [404] = "Not Found",
  [405] = "Method Not Allowed",
  [408] = "Request Timeout",
  [413] = "Payload Too Large",
  [500] = "Internal Server Error",
  [503] = "Service Unavailable",
  [504] = "Gateway Timeout",
}

---@param s string
---@return string
local function url_decode(s)
  return (
    s:gsub("%+", " "):gsub("%%(%x%x)", function(h)
      return string.char(tonumber(h, 16))
    end)
  )
end

---Match a value against a validator: a Lua pattern (whole value, anchored by the caller's `^$`) or a function.
---@param validator string|fun(value: string): boolean
---@param value string
---@return boolean
local function valid(validator, value)
  if type(validator) == "function" then
    local ok, res = pcall(validator, value)
    return ok and res == true
  end
  return type(validator) == "string" and value:find(validator) ~= nil
end

---Does `host` (a Host header value) name this server?
---@param host string|nil
---@param port integer
---@return boolean
local function host_ok(host, port)
  if not host then
    return false
  end
  host = host:lower()
  return host == ("127.0.0.1:%d"):format(port) or host == ("localhost:%d"):format(port)
end

---@param raw string raw header block (everything before the blank line, without the request line)
---@return table<string, string>
local function parse_headers(raw)
  local headers = {}
  for line in raw:gmatch("[^\r\n]+") do
    local k, v = line:match("^([%w%-]+):%s*(.-)%s*$")
    if k then
      headers[k:lower()] = v
    end
  end
  return headers
end

---Split a target into a path and a decoded query table. Returns nil for a malformed one (repeated key).
---@param target string
---@return string path
---@return table<string, string>|nil query
local function split_target(target)
  local path, qs = target:match("^([^?]*)%??(.*)$")
  local query = {}
  if qs and qs ~= "" then
    for pair in qs:gmatch("[^&]+") do
      local k, v = pair:match("^([^=]*)=?(.*)$")
      k = url_decode(k or "")
      if query[k] ~= nil then
        return path, nil -- the same key twice: ambiguous, refused
      end
      query[k] = url_decode(v or "")
    end
  end
  return path, query
end

-- client -> the handle whose `_clients` set holds it; weak so a dropped client is never kept alive
local owners = setmetatable({}, { __mode = "k" })

---Close a client connection and take it out of its server's `_clients` set.
---@param client uv.uv_tcp_t
local function close_client(client)
  if not client:is_closing() then
    client:close()
  end
  local owner = owners[client]
  if owner then
    owner._clients[client] = nil
    owners[client] = nil
  end
end

---@param client uv.uv_tcp_t
---@param code integer
---@param ctype string
---@param body string
local function respond(client, code, ctype, body)
  if not client or client:is_closing() then
    return
  end
  body = body or ""
  local head = table.concat({
    ("HTTP/1.1 %d %s"):format(code, STATUS[code] or "OK"),
    "Content-Type: " .. ctype,
    "Content-Length: " .. #body,
    "Cache-Control: no-store",
    "X-Content-Type-Options: nosniff",
    "Connection: close",
    "",
    "",
  }, "\r\n")
  client:write(head .. body, function()
    close_client(client)
  end)
end

---@param client uv.uv_tcp_t
---@param code integer
---@param message string
local function fail(client, code, message)
  respond(client, code, "application/json", vim.json.encode({ error = message }))
end

---Find the route for a path: the matched route plus its captures, or nil. `allowed` collects the methods of
---routes whose path matched (for a 405).
---@param routes Lib.Net.Server.Route[]
---@param path string
---@param method string
---@return Lib.Net.Server.Route|nil route
---@return string[]|nil captures
---@return string[] allowed
local function find_route(routes, path, method)
  local allowed = {}
  for _, r in ipairs(routes) do
    local captures
    if r.path then
      if r.path == path then
        captures = {}
      end
    elseif r.pattern then
      if r._ncap == 0 then
        if path:find(r.pattern) then
          captures = {}
        end
      else
        local m = { path:match(r.pattern) }
        if #m > 0 then
          captures = m
        end
      end
    end
    if captures then
      local want = r.method or "GET"
      if want == method then
        return r, captures, allowed
      end
      allowed[#allowed + 1] = want
    end
  end
  return nil, nil, allowed
end

---Default deadline of an asynchronous route that never answers.
M.ASYNC_TIMEOUT_MS = 30000

---Run an asynchronous route: `handler(req, respond)` answers through `respond(status, ctype?, body?)`, now or
---later. Only the first answer counts -- `respond`, a throw before it (500) or the deadline (504) -- and every
---later one is a no-op, as is any answer once the client is gone or the server stopped (its socket is closed
---then). `respond` may be called from a libuv callback: answering uses only libuv and `vim.json`.
---@param opts Lib.Net.Server.Opts
---@param route Lib.Net.Server.Route
---@param client uv.uv_tcp_t
---@param request Lib.Net.Server.Request
local function dispatch_async(opts, route, client, request)
  local settled = false
  local timer = uv.new_timer()
  ---Take the one answer; false when one was given already.
  local function settle()
    if settled then
      return false
    end
    settled = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    return true
  end
  local function answer(code, ctype, out)
    if not settle() then
      return
    end
    if type(code) ~= "number" then
      return fail(client, 500, "handler answered no status")
    end
    respond(client, code, ctype or "application/json", out or "")
  end
  local deadline = route.timeout_ms or opts.async_timeout_ms or M.ASYNC_TIMEOUT_MS
  if timer then
    timer:start(deadline, 0, function()
      vim.schedule(function()
        if settle() then
          fail(client, 504, ("no answer within %d ms"):format(deadline))
        end
      end)
    end)
  end
  local ok, err = pcall(route.handler, request, answer)
  if not ok and settle() then
    fail(client, 500, tostring(err))
  end
end

---Validate and run one request. Main loop.
---@param s Lib.Net.Server.Handle
---@param opts Lib.Net.Server.Opts
---@param client uv.uv_tcp_t
---@param req { method: string, target: string, headers: table<string, string>, body: string }
local function dispatch(s, opts, client, req)
  if not host_ok(req.headers.host, s.port) then
    return fail(client, 403, "bad Host header")
  end
  local path, query = split_target(req.target)
  if not query then
    return fail(client, 400, "repeated query key")
  end
  if path:find("%.%.", 1, false) or path:find("[%z\1-\31\127]") then
    return fail(client, 400, "bad path")
  end

  local route, captures, allowed = find_route(opts.routes, path, req.method)
  if not route then
    if #allowed > 0 then
      return fail(client, 405, "method not allowed; use " .. table.concat(allowed, ", "))
    end
    return fail(client, 404, "no such route")
  end

  -- path captures
  for i, v in ipairs(captures) do
    local validator = route.captures and route.captures[i]
    if validator == nil or not valid(validator, v) then
      return fail(client, 400, ("bad path parameter %d"):format(i))
    end
  end
  -- query: only declared keys, only valid values
  for k, v in pairs(query) do
    local validator = route.query and route.query[k]
    if validator == nil then
      return fail(client, 400, "unknown query parameter: " .. k)
    end
    if not valid(validator, v) then
      return fail(client, 400, "bad query parameter: " .. k)
    end
  end
  -- body
  if req.body ~= "" and not route.body then
    return fail(client, 400, "this route takes no body")
  end
  local body = req.body
  if route.body and body ~= "" then
    if type(route.body) == "function" then
      local ok, parsed = pcall(route.body, body)
      if not ok or parsed == nil or parsed == false then
        return fail(client, 400, "invalid body")
      end
      body = parsed
    end
  elseif route.body and route.body_required then
    return fail(client, 400, "a body is required")
  end

  local request = {
    method = req.method,
    path = path,
    query = query,
    params = captures,
    headers = req.headers,
    body = body,
  }
  if route.async then
    return dispatch_async(opts, route, client, request)
  end
  local ok, code, ctype, out = pcall(route.handler, request)
  if not ok then
    return fail(client, 500, tostring(code))
  end
  if type(code) ~= "number" then
    return fail(client, 500, "handler returned no status")
  end
  respond(client, code, ctype or "application/json", out or "")
end

---@internal
---Incremental reader for one request. Chunks are kept in a list and joined once (head) and once more (body),
---and the blank line that ends the header block is searched only in the newest chunk plus the 3 bytes before it:
---a client that sends one byte at a time costs linear, not quadratic, work.
---
---`feed(chunk)` returns nothing while more input is needed, `"drop"` to close without an answer (the header block
---outgrew `max_header`), `"fail", code, message` to refuse, or `"done", req`.
---@param max_header integer
---@param max_body integer
---@return fun(chunk: string): string|nil, any, string|nil
function M._reader(max_header, max_body)
  local parts, total = {}, 0
  local tail = "" -- the last (up to) 3 bytes before the newest chunk, while the header block is open
  local head_end, req
  return function(chunk)
    parts[#parts + 1] = chunk
    total = total + #chunk
    if not head_end then
      local window = tail .. chunk
      local pos = window:find("\r\n\r\n", 1, true)
      if not pos then
        if total > max_header then
          return "drop"
        end
        tail = window:sub(-3)
        return
      end
      head_end = total - #window + pos
      if head_end > max_header then
        return "drop"
      end
      local buf = table.concat(parts)
      parts = { buf }
      local head = buf:sub(1, head_end - 1)
      local first, rest = head:match("^([^\r\n]*)\r?\n?(.*)$")
      local method, target = first:match("^(%u+)%s+(%S+)%s+HTTP/1%.[01]$")
      if not method then
        return "fail", 400, "malformed request"
      end
      req = { method = method, target = target, headers = parse_headers(rest or ""), body = "" }
      -- decimal digits only: `tonumber` would also take "0x10", "1e3" and "nan"
      local cl = req.headers["content-length"] or "0"
      req.want = cl:match("^%d+$") and tonumber(cl) or -1
      if req.want < 0 then
        return "fail", 400, "bad Content-Length"
      end
      if req.want > max_body then
        return "fail", 413, "body too large"
      end
    end
    if total - (head_end + 3) < req.want then
      return -- wait for the rest of the body
    end
    req.body = table.concat(parts):sub(head_end + 4, head_end + 3 + req.want)
    return "done", req
  end
end

---@param s Lib.Net.Server.Handle
---@param opts Lib.Net.Server.Opts
---@param client uv.uv_tcp_t
local function on_connection(s, opts, client)
  local max_header = opts.max_header or 64 * 1024
  local max_body = opts.max_body or 1024 * 1024
  local timer = uv.new_timer()
  -- the request is read (or refused): the idle timer has done its job, and a
  -- merely stopped timer is a live libuv handle that is never collected
  local function done_reading()
    client:read_stop()
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
  local function close()
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    close_client(client)
  end
  timer:start(opts.idle_ms or 10000, 0, function()
    if not client:is_closing() then
      client:write(
        "HTTP/1.1 408 Request Timeout\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        function()
          close()
        end
      )
    else
      close() -- the server stopped and closed the client: the timer still needs closing
    end
  end)

  local feed = M._reader(max_header, max_body)
  client:read_start(function(err, chunk)
    if err or not chunk then
      close()
      return
    end
    local what, a, b = feed(chunk)
    if what == "drop" then
      close()
    elseif what == "fail" then
      done_reading()
      vim.schedule(function()
        fail(client, a, b)
      end)
    elseif what == "done" then
      done_reading()
      vim.schedule(function()
        dispatch(s, opts, client, a)
      end)
    end
  end)
end

---Start a server. Returns the handle, or nil and a reason (no port could be bound).
---@param opts Lib.Net.Server.Opts
---@return Lib.Net.Server.Handle|nil
---@return string|nil err
function M.start(opts)
  assert(
    type(opts) == "table" and type(opts.routes) == "table",
    "net.server: opts.routes is required"
  )
  for i, r in ipairs(opts.routes) do
    assert(type(r.handler) == "function", ("net.server: route %d has no handler"):format(i))
    assert(
      (r.path ~= nil) ~= (r.pattern ~= nil),
      ("net.server: route %d needs exactly one of path/pattern"):format(i)
    )
    if r.pattern then
      -- a capture without a validator would let a path segment through unchecked
      local n = select(2, r.pattern:gsub("%b()", ""))
      r._ncap = n
      assert(
        r.captures and #r.captures >= n,
        ("net.server: route %d declares %d capture(s) without validators"):format(i, n)
      )
    end
  end

  local server = uv.new_tcp()
  local ok, bind_err = pcall(function()
    assert(server:bind("127.0.0.1", opts.port or 0))
  end)
  if not ok then
    server:close()
    return nil, "cannot bind 127.0.0.1: " .. tostring(bind_err)
  end
  local addr = server:getsockname()
  if not addr then
    server:close()
    return nil, "cannot bind 127.0.0.1: the socket has no address (port taken?)"
  end
  local max_clients = opts.max_clients or 64
  local handle = { port = addr.port, name = opts.name or "server", _server = server, _clients = {} }
  handle.url = ("http://127.0.0.1:%d/"):format(handle.port)

  local listened, listen_err = server:listen(128, function(err)
    if err then
      return
    end
    local client = uv.new_tcp()
    server:accept(client)
    local open = 0
    for _ in pairs(handle._clients) do
      open = open + 1
    end
    handle._clients[client] = true
    owners[client] = handle
    if open >= max_clients then
      -- over the limit: answer 503 at once, without parsing the request. The request bytes are read and
      -- discarded and the socket is half-closed first: closing it with unread input sends a reset, and a
      -- reset can throw the 503 away on the client's side before it is read. The connection goes when the
      -- client hangs up, or after a short grace period.
      local grace = uv.new_timer()
      local function gone()
        if not grace:is_closing() then
          grace:stop()
          grace:close()
        end
        close_client(client)
      end
      grace:start(1000, 0, gone)
      client:read_start(function(rerr, chunk)
        if rerr or not chunk then
          gone()
        end
      end)
      client:write(
        "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        function()
          if not client:is_closing() then
            client:shutdown()
          end
        end
      )
      return
    end
    on_connection(handle, opts, client)
  end)
  if not listened then
    server:close()
    return nil, "cannot listen: " .. tostring(listen_err)
  end

  function handle.stop()
    if not running[handle] then
      return
    end
    running[handle] = nil
    for c in pairs(handle._clients) do
      if not c:is_closing() then
        c:close()
      end
    end
    handle._clients = {}
    if not server:is_closing() then
      server:close()
    end
    -- the last server is gone: take the hook with it, so a session that stopped them all leaves no autocmd behind
    if next(running) == nil and hook_installed then
      hook_installed = false
      pcall(vim.api.nvim_del_augroup_by_name, "lib.nvim.net.server")
    end
  end

  function handle.is_running()
    return running[handle] == true
  end

  running[handle] = true
  if not hook_installed then
    hook_installed = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("lib.nvim.net.server", { clear = true }),
      callback = function()
        M.stop_all()
      end,
    })
  end
  return handle
end

---Stop every running server (done at `VimLeavePre` as well).
function M.stop_all()
  for h in pairs(running) do
    h.stop()
  end
end

---@return integer
function M.count()
  local n = 0
  for _ in pairs(running) do
    n = n + 1
  end
  return n
end

return M
