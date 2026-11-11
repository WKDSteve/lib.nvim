-- TESTS/net_server_spec.lua — lib.nvim.net.server (loopback only, validated routes, lifecycle)

return function(H)
  local eq, ok = H.eq, H.ok
  local server = require("lib.nvim.net.server")
  local uv = vim.uv or vim.loop

  ---One raw HTTP exchange over a TCP socket. `text` is written as is; returns the whole answer.
  ---@param port integer
  ---@param text string
  ---@return string|nil answer
  local function exchange(port, text)
    local client = uv.new_tcp()
    local answer, done, failed = {}, false, nil
    client:connect("127.0.0.1", port, function(err)
      if err then
        failed, done = err, true
        return
      end
      client:write(text)
      client:read_start(function(rerr, chunk)
        if rerr or not chunk then
          done = true
          return
        end
        answer[#answer + 1] = chunk
      end)
    end)
    vim.wait(5000, function()
      return done
    end, 5)
    if not client:is_closing() then
      client:close()
    end
    return not failed and table.concat(answer) or nil
  end

  local function get(s, target, extra_headers, host)
    return exchange(
      s.port,
      ("GET %s HTTP/1.1\r\nHost: %s\r\n%s\r\n"):format(
        target,
        host or ("127.0.0.1:%d"):format(s.port),
        extra_headers or ""
      )
    )
  end
  local function status(answer)
    return tonumber((answer or ""):match("^HTTP/1%.1 (%d+)"))
  end
  local function body(answer)
    return (answer or ""):match("\r\n\r\n(.*)$")
  end

  local seen = {}
  local s = assert(server.start({
    name = "spec",
    idle_ms = 800,
    max_body = 64,
    routes = {
      {
        path = "/ping",
        handler = function()
          return 200, "application/json", '{"ok":true}'
        end,
      },
      {
        pattern = "^/commit/(%x+)$",
        captures = {
          function(v)
            return #v >= 7 and #v <= 40
          end,
        },
        query = { n = "^%d+$" },
        handler = function(req)
          seen[#seen + 1] = req.params[1]
          return 200, "text/plain", req.params[1] .. ":" .. tostring(req.query.n)
        end,
      },
      {
        method = "POST",
        path = "/note",
        body = vim.json.decode,
        handler = function(req)
          return 200, "text/plain", "got " .. tostring(req.body.text)
        end,
      },
      {
        path = "/boom",
        handler = function()
          error("kaputt")
        end,
      },
    },
  }))

  -- binds loopback, OS-assigned port
  ok(s.port > 0, "an OS-assigned port")
  eq(s.url, ("http://127.0.0.1:%d/"):format(s.port), "the url is the loopback address")
  ok(s.is_running() and server.count() == 1, "running")
  local addr = s._server:getsockname()
  eq(addr.ip, "127.0.0.1", "bound to 127.0.0.1")

  -- a plain route
  local a = get(s, "/ping")
  eq(status(a), 200, "ping")
  eq(body(a), '{"ok":true}', "ping body")
  ok(a:find("Cache%-Control: no%-store"), "no-store")
  ok(a:find("X%-Content%-Type%-Options: nosniff"), "nosniff")

  -- validated capture and query
  a = get(s, "/commit/abcdef1?n=5")
  eq(status(a), 200, "valid commit")
  eq(body(a), "abcdef1:5", "capture and query reach the handler")
  eq(status(get(s, "/commit/abc")), 400, "a capture the validator refuses is a 400")
  eq(status(get(s, "/commit/zzzzzzz")), 404, "a path that does not match the pattern is a 404")
  eq(status(get(s, "/commit/abcdef1?n=x")), 400, "a query value the validator refuses is a 400")
  eq(status(get(s, "/commit/abcdef1?m=1")), 400, "an undeclared query key is a 400")
  eq(status(get(s, "/commit/abcdef1?n=1&n=2")), 400, "a repeated query key is a 400")
  eq(#seen, 1, "the handler only ran for the one valid request")

  -- path hygiene
  eq(status(get(s, "/ping/../ping")), 400, "dot-dot in the path is refused")
  eq(status(get(s, "/nope")), 404, "unknown route")

  -- method
  a = exchange(
    s.port,
    ("POST /ping HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nContent-Length: 0\r\n\r\n"):format(s.port)
  )
  eq(status(a), 405, "a method the route does not serve")
  ok(body(a):find("GET"), "...says which")

  -- Host header (DNS rebinding)
  eq(status(get(s, "/ping", nil, "evil.example")), 403, "a foreign Host is refused")
  eq(
    status(get(s, "/ping", nil, ("localhost:%d"):format(s.port))),
    200,
    "localhost with the port is fine"
  )
  eq(status(get(s, "/ping", nil, "127.0.0.1:1")), 403, "the wrong port is refused")

  -- POST with a body
  local payload = vim.json.encode({ text = "hi" })
  a = exchange(
    s.port,
    ("POST /note HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nContent-Length: %d\r\n\r\n%s"):format(
      s.port,
      #payload,
      payload
    )
  )
  eq(status(a), 200, "POST with a body")
  eq(body(a), "got hi", "the parsed body reaches the handler")
  a = exchange(
    s.port,
    ("POST /note HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nContent-Length: 3\r\n\r\n{{{"):format(s.port)
  )
  eq(status(a), 400, "a body the parser refuses is a 400")
  a = exchange(
    s.port,
    ("POST /note HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nContent-Length: 100\r\n\r\n"):format(s.port)
  )
  eq(status(a), 413, "a body above max_body is refused before it is read")
  a = exchange(
    s.port,
    ("POST /ping HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nContent-Length: 0\r\n\r\n"):format(s.port)
  )
  eq(status(a), 405, "POST on a GET route")

  -- handler errors are a 500 and do not take the server down
  a = get(s, "/boom")
  eq(status(a), 500, "a throwing handler is a 500")
  ok(body(a):find("kaputt"), "...with the message")
  eq(status(get(s, "/ping")), 200, "and the server keeps serving")

  -- malformed request
  eq(status(exchange(s.port, "NONSENSE\r\n\r\n")), 400, "a malformed request line is a 400")

  -- a stalled client is dropped
  local stalled = exchange(s.port, ("GET /ping HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n"):format(s.port))
  eq(status(stalled), 408, "a client that never finishes its headers gets a 408")

  -- start-time checks
  ok(not pcall(server.start, {
    routes = {
      {
        pattern = "^/x/(.+)$",
        handler = function()
          return 200
        end,
      },
    },
  }), "a capture without a validator is refused at start")
  ok(not pcall(server.start, {
    routes = {
      {
        handler = function()
          return 200
        end,
      },
    },
  }), "a route needs a path or a pattern")

  -- the port can be asked for, and a taken one is an error value
  local taken, err = server.start({
    port = s.port,
    routes = {
      {
        path = "/x",
        handler = function()
          return 200
        end,
      },
    },
  })
  eq(taken, nil, "a port that is taken does not start")
  ok(
    tostring(err):find("bind") or tostring(err):find("listen"),
    "...and says why: " .. tostring(err)
  )

  -- lifecycle
  s.stop()
  eq(s.is_running(), false, "stopped")
  eq(server.count(), 0, "no server left")
  eq(exchange(s.port, "GET /ping HTTP/1.1\r\nHost: x\r\n\r\n"), nil, "nothing listens after stop")
  s.stop() -- idempotent

  local a1 = assert(server.start({
    routes = {
      {
        path = "/x",
        handler = function()
          return 200
        end,
      },
    },
  }))
  local a2 = assert(server.start({
    routes = {
      {
        path = "/x",
        handler = function()
          return 200
        end,
      },
    },
  }))
  eq(server.count(), 2, "two servers")
  server.stop_all()
  ok(not a1.is_running() and not a2.is_running(), "stop_all stops every server")

  -- the loopback-only rule is in the code, not an option
  local f = assert(io.open(debug.getinfo(server.start, "S").source:sub(2), "rb"))
  local source = f:read("*a")
  f:close()
  ok(not source:find("0%.0%.0%.0"), "the module never mentions 0.0.0.0")
  ok(source:find('bind%("127%.0%.0%.1"'), "the bind address is the literal loopback")
end
