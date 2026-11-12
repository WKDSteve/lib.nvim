-- TESTS/mcp_http_spec.lua — lib.nvim.mcp over Streamable HTTP, against a fake server on loopback (no network)
--
-- The fake is a few lines of raw libuv, not `lib.nvim.net.server`: it has to set `Mcp-Session-Id`, answer 202 and 401
-- and stream `text/event-stream`, which that server's handler contract (status, content type, body) does not offer.

return function(H)
  local eq, ok = H.eq, H.ok
  local mcp = require("lib.nvim.mcp")
  local uv = vim.uv or vim.loop

  local function wait_for(pred, ms)
    return vim.wait(ms or 10000, pred, 10)
  end
  local function ask(fn)
    local done, a, b = false, nil, nil
    fn(function(x, y)
      done, a, b = true, x, y
    end)
    wait_for(function()
      return done
    end)
    return done, a, b
  end

  -- ── the fake server ──────────────────────────────────────────────────────
  local seen = {} ---@type { method: string, headers: table, message: table|nil }[]
  local sessions = 0
  local sockets = {}
  local srv = assert(uv.new_tcp())
  assert(srv:bind("127.0.0.1", 0))

  ---@param c userdata
  ---@param status string
  ---@param headers table<string, string>
  ---@param body string
  local function reply(c, status, headers, body)
    local lines = { "HTTP/1.1 " .. status }
    headers["Content-Length"] = tostring(#body)
    headers["Connection"] = "close"
    for k, v in pairs(headers) do
      lines[#lines + 1] = k .. ": " .. v
    end
    c:write(table.concat(lines, "\r\n") .. "\r\n\r\n" .. body, function()
      pcall(function()
        c:close()
      end)
    end)
  end
  local function json(c, extra, value)
    local headers = vim.tbl_extend("force", { ["Content-Type"] = "application/json" }, extra or {})
    reply(c, "200 OK", headers, vim.json.encode(value))
  end

  ---@param c userdata
  ---@param req { method: string, headers: table, message: table|nil }
  local function handle(c, req)
    seen[#seen + 1] = req
    if req.method == "DELETE" then
      return reply(c, "200 OK", {}, "")
    end
    local msg = req.message or {}
    if msg.method == "initialize" then
      sessions = sessions + 1
      return json(c, { ["Mcp-Session-Id"] = "sess-" .. sessions }, {
        jsonrpc = "2.0",
        id = msg.id,
        result = {
          protocolVersion = msg.params.protocolVersion,
          serverInfo = { name = "fakehttp" },
          capabilities = vim.empty_dict(),
        },
      })
    elseif msg.method == "notifications/initialized" or msg.method == "notifications/cancelled" then
      return reply(c, "202 Accepted", {}, "")
    elseif msg.method == "tools/list" then
      local note = vim.json.encode({
        jsonrpc = "2.0",
        method = "notifications/message",
        params = { level = "info", data = "listing" },
      })
      local answer = vim.json.encode({
        jsonrpc = "2.0",
        id = msg.id,
        result = { tools = { { name = "echo" }, { name = "slow" } } },
      })
      return reply(
        c,
        "200 OK",
        { ["Content-Type"] = "text/event-stream" },
        "event: message\ndata: " .. note .. "\n\nevent: message\ndata: " .. answer .. "\n\n"
      )
    elseif msg.method == "tools/call" then
      local name = msg.params.name
      if name == "echo" then
        return json(c, nil, {
          jsonrpc = "2.0",
          id = msg.id,
          result = {
            content = { { type = "text", text = "echo" } },
            structuredContent = { args = msg.params.arguments },
            isError = false,
          },
        })
      elseif name == "unauth" then
        return reply(c, "401 Unauthorized", {}, "no")
      elseif name == "broken" then
        return reply(c, "500 Internal Server Error", {}, "oops")
      elseif name == "gone" then
        return reply(c, "404 Not Found", {}, "")
      elseif name == "slow" then
        sockets[#sockets + 1] = c -- never answered; closed at the end
        return
      end
    end
    reply(c, "400 Bad Request", {}, "")
  end

  srv:listen(16, function(listen_err)
    assert(not listen_err, listen_err)
    local c = assert(uv.new_tcp())
    srv:accept(c)
    local buf = ""
    c:read_start(function(read_err, data)
      if read_err or not data then
        return
      end
      buf = buf .. data
      local head_end = buf:find("\r\n\r\n", 1, true)
      if not head_end then
        return
      end
      local head = buf:sub(1, head_end - 1)
      local method = head:match("^(%u+) ")
      local headers = {}
      for k, v in head:gmatch("\r\n([^:\r\n]+):%s*([^\r\n]*)") do
        headers[k:lower()] = v
      end
      local want = tonumber(headers["content-length"] or "0") or 0
      local body = buf:sub(head_end + 4)
      if #body < want then
        return
      end
      c:read_stop()
      local ok_json, message = pcall(vim.json.decode, body)
      handle(c, { method = method, headers = headers, message = ok_json and message or nil })
    end)
  end)
  local port = srv:getsockname().port
  local url = ("http://127.0.0.1:%d/mcp"):format(port)

  local function posts(method)
    local out = {}
    for _, r in ipairs(seen) do
      if r.method == "POST" and r.message and r.message.method == method then
        out[#out + 1] = r
      end
    end
    return out
  end

  local clients = {}
  local function body()
    local notes = {}
    local c = mcp.client({
      id = "h1",
      url = url,
      timeout_ms = 5000,
      headers = { ["X-Extra"] = "1" },
      secret_headers = { ["X-Api-Key"] = "s3cret" },
      on_notification = function(method, params)
        notes[#notes + 1] = method .. ":" .. tostring(params and params.data)
      end,
    })
    clients[#clients + 1] = "h1"
    eq(c:state(), "idle", "http: nothing is sent before the first request")
    eq(#seen, 0, "http: ...no request at all")

    -- handshake, SSE answer with a notification in front of it
    local done, tools, e = ask(function(cb)
      c:list_tools(cb)
    end)
    ok(done and e == nil, "http: list_tools answers: " .. vim.inspect(e))
    eq(c:state(), "ready", "http: the handshake finished")
    eq(tools and #tools, 2, "http: the tools come out of the event stream")
    eq(c:server().serverInfo.name, "fakehttp", "http: the initialize result is kept")
    ok(
      wait_for(function()
        return notes[1] == "notifications/message:listing"
      end, 2000),
      "http: a notification streamed in front of the answer reaches on_notification"
    )

    -- session and protocol headers, and the secret header, on every request but the first of each kind
    local init = posts("initialize")[1]
    eq(init.headers["mcp-session-id"], nil, "http: initialize carries no session yet")
    eq(init.headers["mcp-protocol-version"], nil, "http: ...nor a protocol version")
    eq(init.headers["x-api-key"], "s3cret", "http: secret_headers reach the server")
    eq(init.headers["x-extra"], "1", "http: headers reach the server")
    ok(
      init.headers["accept"]:find("text/event-stream", 1, true),
      "http: Accept names both answer forms"
    )
    local listed = posts("tools/list")[1]
    eq(
      listed.headers["mcp-session-id"],
      "sess-1",
      "http: the session id comes back on later requests"
    )
    eq(
      listed.headers["mcp-protocol-version"],
      mcp.PROTOCOL_VERSION,
      "http: ...with the agreed protocol version"
    )
    ok(
      #posts("notifications/initialized") == 1,
      "http: notifications/initialized was posted (202 is fine)"
    )

    -- a tool call
    local _, res, ce = ask(function(cb)
      c:call_tool("echo", { a = 1 }, cb)
    end)
    eq(ce, nil, "http: echo: no error")
    eq(res.content[1].text, "echo", "http: the result is handed back unchanged")
    eq(res.structuredContent.args.a, 1, "http: ...structuredContent too")

    -- errors are values
    local _, _, unauthorized = ask(function(cb)
      c:call_tool("unauth", {}, cb)
    end)
    eq(unauthorized and unauthorized.code, "unauthorized", "http: 401 is its own code")
    local _, _, broken = ask(function(cb)
      c:call_tool("broken", {}, cb)
    end)
    eq(broken and broken.code, "http", "http: another non-2xx is `http`")
    eq(broken and broken.data.status, 500, "http: ...with the status")
    eq(broken and broken.data.body, "oops", "http: ...and the start of the body")

    local started = vim.uv.hrtime()
    local _, _, timed_out = ask(function(cb)
      c:call_tool("slow", {}, cb, { timeout_ms = 300 })
    end)
    eq(timed_out and timed_out.code, "timeout", "http: a call the server never answers times out")
    ok((vim.uv.hrtime() - started) / 1e6 < 4000, "http: ...at the call's own deadline")

    -- cancel by the caller
    local cancelled
    local id = c:call_tool("slow", {}, function(_, cerr)
      cancelled = cerr
    end)
    c:cancel(id)
    ok(wait_for(function()
      return cancelled ~= nil
    end, 2000) and cancelled.code == "cancelled", "http: cancel settles the request")

    -- a 404 on a live session ends it; the next request starts a new one
    local _, _, gone = ask(function(cb)
      c:call_tool("gone", {}, cb)
    end)
    eq(gone and gone.code, "closed", "http: 404 on a live session is `closed`")
    eq(c:state(), "closed", "http: ...and the client is closed")
    local _, again, again_err = ask(function(cb)
      c:call_tool("echo", { b = 2 }, cb)
    end)
    eq(again_err, nil, "http: the next request starts over: no error")
    eq(again.structuredContent.args.b, 2, "http: ...and is answered")
    eq(#posts("initialize"), 2, "http: ...by a second initialize")
    eq(posts("initialize")[2].headers["mcp-session-id"], nil, "http: ...without the old session id")
    local last = posts("tools/call")[#posts("tools/call")]
    eq(last.headers["mcp-session-id"], "sess-2", "http: ...and the new session id afterwards")

    -- stop ends the session with a DELETE
    c:stop()
    eq(c:state(), "closed", "http: stop closes the client")
    ok(
      wait_for(function()
        for _, r in ipairs(seen) do
          if r.method == "DELETE" then
            return r.headers["mcp-session-id"] == "sess-2"
          end
        end
      end, 3000),
      "http: stop sends DELETE with the session id"
    )

    -- a server that is not there
    local dead = mcp.client({ id = "h2", url = "http://127.0.0.1:1/mcp", timeout_ms = 8000 })
    clients[#clients + 1] = "h2"
    local _, _, refused = ask(function(cb)
      dead:list_tools(cb)
    end)
    eq(refused and refused.code, "http", "http: a refused connection is `http`")

    -- cmd and url are exclusive; one of them is required
    ok(not pcall(mcp.client, { id = "h3" }), "http: neither cmd nor url is refused")
    ok(
      not pcall(mcp.client, { id = "h4", cmd = { "x" }, url = url }),
      "http: both cmd and url are refused"
    )
  end

  local finished, run_err = pcall(body)
  for _, id in ipairs(clients) do
    pcall(mcp.forget, id)
  end
  for _, c in ipairs(sockets) do
    pcall(function()
      c:close()
    end)
  end
  pcall(function()
    srv:close()
  end)
  if not finished then
    error(run_err, 0)
  end
end
