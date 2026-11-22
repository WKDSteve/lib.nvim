-- TESTS/net_server_async_spec.lua — lib.nvim.net.server asynchronous routes
--
-- Loopback only (127.0.0.1): a raw TCP client per request, started without
-- waiting so a spec can hang up before the answer or let a handler answer
-- later. No real program runs; "later" is a libuv timer.

return function(H)
  local eq, ok = H.eq, H.ok
  local server = require("lib.nvim.net.server")
  local uv = vim.uv or vim.loop

  ---Start one raw request; the returned context fills in as the answer arrives.
  ---@param port integer
  ---@param target string
  ---@return { answer: string[], done: boolean, client: uv.uv_tcp_t }
  local function request(port, target)
    local ctx = { answer = {}, done = false }
    local client = assert(uv.new_tcp())
    ctx.client = client
    client:connect("127.0.0.1", port, function(err)
      if err then
        ctx.done = true
        return
      end
      client:write(("GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n\r\n"):format(target, port))
      client:read_start(function(rerr, chunk)
        if rerr or not chunk then
          ctx.done = true
          return
        end
        ctx.answer[#ctx.answer + 1] = chunk
      end)
    end)
    return ctx
  end

  ---@return string
  local function finish(ctx, ms)
    vim.wait(ms or 5000, function()
      return ctx.done
    end, 5)
    if not ctx.client:is_closing() then
      ctx.client:close()
    end
    return table.concat(ctx.answer)
  end

  local function status(answer)
    return tonumber((answer or ""):match("^HTTP/1%.1 (%d+)"))
  end
  local function body(answer)
    return (answer or ""):match("\r\n\r\n(.*)$")
  end

  local later = {} ---@type table<string, Lib.Net.Server.Respond>
  local late_errors = {} ---@type string[]
  local function stash(name)
    return function(_, respond)
      later[name] = respond
    end
  end
  ---Call a stashed respond; it must never throw.
  local function late(name, ...)
    local fine, err = pcall(later[name], ...)
    if not fine then
      late_errors[#late_errors + 1] = tostring(err)
    end
  end

  local s = assert(server.start({
    name = "spec-async",
    routes = {
      {
        path = "/sync",
        handler = function()
          return 200, "text/plain", "sync"
        end,
      },
      {
        path = "/later",
        async = true,
        handler = function(_, respond)
          local timer = assert(uv.new_timer())
          -- answered from a raw libuv callback (fast-event context)
          timer:start(80, 0, function()
            timer:close()
            respond(200, "text/plain", "late answer")
          end)
        end,
      },
      {
        path = "/twice",
        async = true,
        handler = function(_, respond)
          respond(201, "text/plain", "first")
          respond(200, "text/plain", "second")
        end,
      },
      {
        path = "/throw",
        async = true,
        handler = function()
          error("handler broke", 0)
        end,
      },
      {
        path = "/throw-after",
        async = true,
        handler = function(_, respond)
          respond(200, "text/plain", "answered")
          error("too late to matter", 0)
        end,
      },
      {
        path = "/nostatus",
        async = true,
        handler = function(_, respond)
          respond(nil)
        end,
      },
      {
        path = "/nostatus-late",
        async = true,
        handler = function(_, respond)
          local timer = assert(uv.new_timer())
          timer:start(20, 0, function()
            timer:close()
            respond(nil) -- a 500 (vim.json) from a raw libuv callback
          end)
        end,
      },
      { path = "/never", async = true, timeout_ms = 150, handler = stash("never") },
      { path = "/hangup", async = true, handler = stash("hangup") },
      { path = "/stopped", async = true, handler = stash("stopped") },
    },
  }))

  do -- the handler answers later; the editor is not blocked meanwhile
    local ticks = 0
    local ticker = assert(uv.new_timer())
    ticker:start(10, 10, function()
      ticks = ticks + 1
    end)
    local answer = finish(request(s.port, "/later"))
    ticker:stop()
    ticker:close()
    eq(status(answer), 200, "async: a later respond is the answer")
    eq(body(answer), "late answer", "async: with its body")
    ok(ticks >= 3, "async: the loop kept running while the handler had not answered")
  end

  do
    local answer = finish(request(s.port, "/twice"))
    eq(status(answer), 201, "async: the first respond counts")
    eq(body(answer), "first", "async: a second respond writes nothing")
  end

  do
    local answer = finish(request(s.port, "/throw"))
    eq(status(answer), 500, "async: a throw before the answer is a 500")
    ok((body(answer) or ""):find("handler broke", 1, true), "async: the 500 names the error")
  end

  do
    local answer = finish(request(s.port, "/throw-after"))
    eq(status(answer), 200, "async: a throw after the answer changes nothing")
  end

  do
    local answer = finish(request(s.port, "/nostatus"))
    eq(status(answer), 500, "async: respond without a status is a 500")
  end

  do
    local answer = finish(request(s.port, "/nostatus-late"))
    eq(status(answer), 500, "async: a 500 answered from a libuv callback")
  end

  do -- no answer: 504 at the deadline, and a late respond afterwards is a no-op
    local t0 = uv.hrtime()
    local answer = finish(request(s.port, "/never"))
    local ms = (uv.hrtime() - t0) / 1e6
    eq(status(answer), 504, "async: no answer within timeout_ms is a 504")
    ok(ms >= 140, "async: the 504 comes at the deadline, not at once")
    late("never", 200, "text/plain", "after the deadline")
    eq(#late_errors, 0, "async: respond after the deadline does not throw")
  end

  do -- the client hangs up before the answer
    local ctx = request(s.port, "/hangup")
    vim.wait(2000, function()
      return later.hangup ~= nil
    end, 5)
    ok(later.hangup ~= nil, "async: the handler got respond")
    ctx.client:close()
    vim.wait(50)
    late("hangup", 200, "text/plain", "nobody listens")
    vim.wait(50)
    eq(#late_errors, 0, "async: respond after the client left does not throw")
    eq(body(finish(request(s.port, "/sync"))), "sync", "async: the server still serves afterwards")
  end

  do -- the server stops before the answer
    local ctx = request(s.port, "/stopped")
    vim.wait(2000, function()
      return later.stopped ~= nil
    end, 5)
    s.stop()
    late("stopped", 200, "text/plain", "server gone")
    vim.wait(50)
    eq(#late_errors, 0, "async: respond after stop() does not throw")
    eq(table.concat(ctx.answer), "", "async: respond after stop() writes nothing")
    finish(ctx, 200)
  end

  do -- synchronous routes are unchanged, also next to async ones
    local s2 = assert(server.start({
      routes = {
        {
          path = "/a",
          handler = function()
            return 200, "text/plain", "plain"
          end,
        },
        {
          path = "/b",
          async = true,
          handler = function(_, respond)
            respond(200, "text/plain", "async")
          end,
        },
      },
    }))
    eq(body(finish(request(s2.port, "/a"))), "plain", "sync route next to an async one")
    eq(body(finish(request(s2.port, "/b"))), "async", "async route answering at once")
    s2.stop()
  end
end
