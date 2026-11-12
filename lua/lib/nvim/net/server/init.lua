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
---    one and only up to `max_body` (default 1 MB), and a stalled client is dropped after `idle_ms`.
--- 5. **The server dies with the editor:** `VimLeavePre` closes every socket (`server.stop_all()`).
---
--- Handlers run on the main loop (`vim.schedule`), where `vim.system():wait()` and the rest of the editor API are
--- allowed; libuv read callbacks are a fast-event context where they are not.
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
    if not client:is_closing() then
      client:close()
    end
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

  local ok, code, ctype, out = pcall(route.handler, {
    method = req.method,
    path = path,
    query = query,
    params = captures,
    headers = req.headers,
    body = body,
  })
  if not ok then
    return fail(client, 500, tostring(code))
  end
  if type(code) ~= "number" then
    return fail(client, 500, "handler returned no status")
  end
  respond(client, code, ctype or "application/json", out or "")
end

---@param s Lib.Net.Server.Handle
---@param opts Lib.Net.Server.Opts
---@param client uv.uv_tcp_t
local function on_connection(s, opts, client)
  local buf = ""
  local head_end, req
  local max_header = opts.max_header or 64 * 1024
  local max_body = opts.max_body or 1024 * 1024
  local timer = uv.new_timer()
  local function close()
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    if not client:is_closing() then
      client:close()
    end
  end
  timer:start(opts.idle_ms or 10000, 0, function()
    if not client:is_closing() then
      client:write(
        "HTTP/1.1 408 Request Timeout\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        function()
          close()
        end
      )
    end
  end)

  client:read_start(function(err, chunk)
    if err or not chunk then
      close()
      return
    end
    buf = buf .. chunk
    if not head_end then
      head_end = buf:find("\r\n\r\n", 1, true)
      if not head_end then
        if #buf > max_header then
          close()
        end
        return
      end
      if head_end > max_header then
        close()
        return
      end
      local head = buf:sub(1, head_end - 1)
      local first, rest = head:match("^([^\r\n]*)\r?\n?(.*)$")
      local method, target = first:match("^(%u+)%s+(%S+)%s+HTTP/1%.[01]$")
      req = { method = method, target = target, headers = parse_headers(rest or ""), body = "" }
      req.want = tonumber(req.headers["content-length"] or "0") or -1
    end
    if not req.method then
      client:read_stop()
      timer:stop()
      vim.schedule(function()
        fail(client, 400, "malformed request")
      end)
      return
    end
    if req.want < 0 or req.want > max_body then
      client:read_stop()
      timer:stop()
      vim.schedule(function()
        fail(
          client,
          req.want < 0 and 400 or 413,
          req.want < 0 and "bad Content-Length" or "body too large"
        )
      end)
      return
    end
    local have = #buf - (head_end + 3)
    if have < req.want then
      return -- wait for the rest of the body
    end
    req.body = buf:sub(head_end + 4, head_end + 3 + req.want)
    client:read_stop()
    timer:stop()
    vim.schedule(function()
      dispatch(s, opts, client, req)
    end)
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
  local handle = { port = addr.port, name = opts.name or "server", _server = server, _clients = {} }
  handle.url = ("http://127.0.0.1:%d/"):format(handle.port)

  local listened, listen_err = server:listen(128, function(err)
    if err then
      return
    end
    local client = uv.new_tcp()
    server:accept(client)
    handle._clients[client] = true
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
