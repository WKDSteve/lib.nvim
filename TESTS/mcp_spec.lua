-- TESTS/mcp_spec.lua — lib.nvim.mcp against a fake stdio server (no network)

return function(H)
  local eq, ok = H.eq, H.ok
  local mcp = require("lib.nvim.mcp")
  local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
  local server = dir .. "/support/fake_mcp_server.lua"

  local function cmd()
    return { vim.v.progpath, "--headless", "-u", "NONE", "-l", server }
  end
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

  local clients = {}
  local function new(id, extra)
    local c =
      mcp.client(vim.tbl_extend("force", { id = id, cmd = cmd(), timeout_ms = 5000 }, extra or {}))
    clients[#clients + 1] = id
    return c
  end

  -- lazy start, handshake, tools
  local notes = {}
  local c = new("t1", {
    on_notification = function(method, params)
      notes[#notes + 1] = method .. ":" .. vim.inspect(params):gsub("%s+", " ")
    end,
  })
  eq(c:state(), "idle", "nothing starts before the first request")
  eq(mcp.client({ id = "t1", cmd = { "other" } }), c, "one client per id")

  local done, tools, err = ask(function(cb)
    c:list_tools(cb)
  end)
  ok(done and err == nil, "list_tools answers: " .. vim.inspect(err))
  eq(c:state(), "ready", "the handshake finished")
  local names = {}
  for _, t in ipairs(tools or {}) do
    names[#names + 1] = t.name
  end
  eq(table.concat(names, ","), "echo,slow,boom,second_page", "tools/list follows nextCursor")

  local server_info = c:server()
  eq(server_info.serverInfo.name, "fake", "the initialize result is kept")
  eq(server_info.protocolVersion, mcp.PROTOCOL_VERSION, "the client's protocol version was sent")
  eq(
    vim.tbl_count(server_info.echoedClientCapabilities),
    0,
    "no sampling/elicitation capability claimed"
  )
  eq(server_info.echoedClientInfo.name, "lib.nvim.mcp", "clientInfo sent")
  ok(
    wait_for(function()
      return #notes > 0
    end),
    "server notifications reach on_notification"
  )
  ok(notes[1]:find("notifications/message", 1, true), "...with the method")

  -- tool call: the result is handed back unchanged
  local _, res, e = ask(function(cb)
    c:call_tool("echo", { a = 1 }, cb)
  end)
  eq(e, nil, "echo: no error")
  eq(res.content[1].text, "echo", "content unchanged")
  eq(res.structuredContent.args.a, 1, "structuredContent unchanged")
  eq(res.isError, false, "isError unchanged")

  _, res = ask(function(cb)
    c:call_tool("boom", nil, cb)
  end)
  eq(res.isError, true, "a tool-level failure is a result with isError, not an error")

  -- JSON-RPC error object
  local _, none, rpc = ask(function(cb)
    c:call_tool("missing", {}, cb)
  end)
  eq(none, nil, "a JSON-RPC error has no result")
  eq(rpc.code, -32602, "the error code is kept")
  eq(rpc.message, "unknown tool", "...and the message")

  -- timeout, cancelled notification
  local started = vim.uv.hrtime()
  local _, _, terr = ask(function(cb)
    c:call_tool("slow", {}, cb, { timeout_ms = 300 })
  end)
  eq(terr and terr.code, "timeout", "a call that never answers times out")
  ok((vim.uv.hrtime() - started) / 1e6 < 4000, "...at the call's own deadline")
  ok(
    wait_for(function()
      for _, n in ipairs(notes) do
        if n:find("cancelled", 1, true) then
          return true
        end
      end
    end),
    "the server was told with notifications/cancelled"
  )

  -- cancel by the caller
  local cancelled
  local id = c:call_tool("slow", {}, function(_, ce)
    cancelled = ce
  end)
  c:cancel(id)
  ok(
    wait_for(function()
      return cancelled ~= nil
    end),
    "cancel calls back"
  )
  eq(cancelled.code, "cancelled", "...with code cancelled")

  -- several calls in flight are matched by id
  local got = {}
  for i = 1, 5 do
    c:call_tool("echo", { n = i }, function(r)
      got[i] = r.structuredContent.args.n
    end)
  end
  ok(
    wait_for(function()
      return #got == 5
    end),
    "five concurrent calls answered"
  )
  eq(table.concat(got, ","), "1,2,3,4,5", "...each to its own caller")

  -- stderr: logged, never a notification
  local seen_notify = false
  local real_notify = vim.notify
  vim.notify = function()
    seen_notify = true
  end
  ok(
    wait_for(function()
      for _, l in ipairs(c:log()) do
        if l.kind == "err" and l.text:find("login.example", 1, true) then
          return true
        end
      end
    end),
    "stderr (with the login link) lands in the log"
  )
  vim.notify = real_notify
  eq(seen_notify, false, "...and in no notification")

  -- process end: pending calls fail, state closed
  local died
  c:call_tool("slow", {}, function(_, de)
    died = de
  end, { timeout_ms = 60000 })
  c:stop()
  ok(
    wait_for(function()
      return died ~= nil and c:state() == "closed"
    end),
    "stop fails the pending call and closes"
  )
  eq(died.code, "closed", "...with code closed")

  -- a banner line that is not JSON does not break anything
  local b = new("t-banner", { env = { FAKE_MODE = "banner" } })
  local bdone, btools = ask(function(cb)
    b:list_tools(cb)
  end)
  ok(bdone and btools and #btools == 4, "a non-JSON banner on stdout is ignored")

  -- a missing command
  local m = new("t-missing", { cmd = { "definitely-not-a-program-xyz" } })
  local _, _, merr = ask(function(cb)
    m:list_tools(cb)
  end)
  eq(merr and merr.code, "spawn", "a command that cannot start is a spawn error")
  ok(tostring(merr and merr.message):find("definitely%-not%-a%-program"), "...naming the command")

  -- port in use, recognised from stderr
  local p = new("t-port", { env = { FAKE_MODE = "port_busy" } })
  local _, _, perr = ask(function(cb)
    p:list_tools(cb)
  end)
  eq(perr and perr.code, "port_in_use", "port in use is recognised from stderr")

  -- the server dies right after the handshake
  local d = new("t-die", { env = { FAKE_MODE = "die_after_init" } })
  local derr
  ask(function(cb)
    d:list_tools(function(x, y)
      derr = y
      cb(x, y)
    end)
  end)
  ok(derr ~= nil, "a server that exits mid-request fails the request")
  eq(derr.code, "exited", "...as exited")
  eq(derr.data.code, 3, "...with the exit code")

  for _, cid in ipairs(clients) do
    mcp.forget(cid)
  end
end
