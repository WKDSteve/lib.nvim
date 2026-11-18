-- TESTS/mcp_server_spec.lua -- lib.nvim.mcp.server: the protocol in-process, then a real stdio process talked to
-- by the client lib.nvim.mcp with stdin held open (each answer has to arrive while the client waits).
---@diagnostic disable: need-check-nil

return function(H)
  local eq, ok = H.eq, H.ok
  local mcp_server = require("lib.nvim.mcp.server")

  local s = mcp_server.new({ name = "demo.nvim", version = "1.2.3", instructions = "demo" })
  s:add("b_tool", {
    description = "B",
    run = function(args, ctx)
      return mcp_server.text({ got = args.x, ctx = ctx })
    end,
  })
  s:add("a_tool", {
    description = "A",
    input_schema = { type = "object", properties = { n = { type = "integer" } } },
    run = function()
      error("kaputt", 0)
    end,
  })
  s:add("bad_shape", {
    run = function()
      return { "no content" }
    end,
  })

  local function send(msg)
    local line = s:dispatch(type(msg) == "string" and msg or vim.json.encode(msg))
    return line and vim.json.decode(line) or nil
  end

  -- handshake
  local res = send({
    jsonrpc = "2.0",
    id = 1,
    method = "initialize",
    params = { protocolVersion = "2025-03-26" },
  })
  eq(res.result.protocolVersion, "2025-03-26", "initialize echoes a known version")
  eq(res.result.serverInfo.name, "demo.nvim", "serverInfo.name")
  eq(res.result.serverInfo.version, "1.2.3", "serverInfo.version")
  eq(res.result.instructions, "demo", "instructions")
  eq(res.result.capabilities.tools.listChanged, false, "no list_changed claimed")
  res = send({
    jsonrpc = "2.0",
    id = 2,
    method = "initialize",
    params = { protocolVersion = "1999-01-01" },
  })
  eq(res.result.protocolVersion, mcp_server.SUPPORTED[1], "an unknown version gets our newest")
  eq(
    send({ jsonrpc = "2.0", method = "notifications/initialized" }),
    nil,
    "a notification is not answered"
  )
  ok(s.initialized, "initialized is set by the notification")
  eq(
    send({ jsonrpc = "2.0", method = "notifications/whatever" }),
    nil,
    "any notification: no answer"
  )
  eq(s:dispatch("   "), nil, "a blank line: no answer")
  eq(vim.tbl_count(send({ jsonrpc = "2.0", id = 3, method = "ping" }).result), 0, "ping answers {}")
  ok(
    s:dispatch('{"jsonrpc":"2.0","id":3,"method":"ping"}'):find('"result":{}', 1, true),
    "ping is {} on the wire"
  )

  -- tools/list: sorted, default schema
  res = send({ jsonrpc = "2.0", id = 4, method = "tools/list" })
  local names = vim.tbl_map(function(t)
    return t.name
  end, res.result.tools)
  eq(table.concat(names, ","), "a_tool,b_tool,bad_shape", "tools/list sorted by name")
  eq(res.result.tools[2].inputSchema.type, "object", "a default input schema")
  eq(res.result.tools[1].inputSchema.properties.n.type, "integer", "the tool's own schema")

  -- tools/call
  s.ctx = "the ctx"
  res = send({
    jsonrpc = "2.0",
    id = 5,
    method = "tools/call",
    params = { name = "b_tool", arguments = { x = 7 } },
  })
  eq(
    res.result.content[1].text,
    '{"ctx":"the ctx","got":7}',
    "a result is canonical JSON with the ctx"
  )
  eq(res.result.isError, nil, "a good result is no error")
  res = send({ jsonrpc = "2.0", id = 6, method = "tools/call", params = { name = "a_tool" } })
  ok(res.result and res.result.isError, "a raising tool is an isError result, not a JSON-RPC error")
  eq(res.result.content[1].text, "kaputt", "its message reaches the model")
  res = send({ jsonrpc = "2.0", id = 7, method = "tools/call", params = { name = "nope" } })
  ok(
    res.result.isError and res.result.content[1].text:find("unknown tool: nope", 1, true),
    "unknown tool"
  )
  res = send({ jsonrpc = "2.0", id = 8, method = "tools/call", params = { name = "bad_shape" } })
  ok(res.result.isError, "a tool answering no content list is an error result")

  -- JSON-RPC errors
  eq(
    send({ jsonrpc = "2.0", id = 9, method = "tools/call", params = {} }).error.code,
    -32602,
    "no name: -32602"
  )
  eq(
    send({ jsonrpc = "2.0", id = 10, method = "resources/list" }).error.code,
    -32601,
    "unknown method: -32601"
  )
  res = send("{not json")
  eq(res.error.code, -32700, "bad JSON: -32700")
  eq(res.id, vim.NIL, "bad JSON answers a null id")
  eq(send({ id = 11, method = "ping" }).error.code, -32600, "no jsonrpc field: -32600")
  eq(send({ jsonrpc = "2.0", id = 12 }).error.code, -32600, "no method: -32600")
  eq(send("[1,2]").error.code, -32600, "a batch array is no request")
  res = send('{"jsonrpc":"2.0","id":1e999,"method":"ping"}')
  eq(res.error.code, -32600, "an id that cannot be echoed is answered, not raised")
  H.with_patched(s, "request", function()
    error("crash in dispatch")
  end, function()
    local r = send({ jsonrpc = "2.0", id = 13, method = "ping" })
    eq(r.error.code, -32603, "a crash inside dispatch is -32603")
    eq(r.id, 13, "with the request's id")
  end)

  -- registry rules
  ok(not pcall(s.add, s, "a_tool", { run = print }), "a name taken twice raises")
  ok(not pcall(s.add, s, "bad name", { run = print }), "a name with a space raises")
  ok(not pcall(s.add, s, ("x"):rep(65), { run = print }), "a name over 64 raises")
  ok(not pcall(s.add, s, "no_run", {}), "a tool without run raises")
  local s2 = mcp_server.new({
    tools = {
      t = {
        run = function()
          return mcp_server.text("plain")
        end,
      },
    },
  })
  eq(s2:call("t").content[1].text, "plain", "tools in new(); a string is sent as it is")
  eq(s2.name, "lib.nvim", "default name")

  -- helpers
  eq(mcp_server.clamp_limit(nil, 50), 50, "clamp: nil is the default")
  eq(mcp_server.clamp_limit(0, 50), 1, "clamp: below 1")
  eq(mcp_server.clamp_limit(5000, 50), 1000, "clamp: above max")
  eq(mcp_server.clamp_limit(7.9, 50, 5), 5, "clamp: own max")
  eq(mcp_server.clamp_limit(0 / 0, 50), 50, "clamp: NaN is the default")
  eq(mcp_server.error_text("x").isError, true, "error_text")

  -- serve with injected handles: stdout gets protocol only, print/notify go to err, restored afterwards
  do
    local input = {
      '{"jsonrpc":"2.0","id":1,"method":"ping"}',
      '{"jsonrpc":"2.0","method":"notifications/initialized"}',
      '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"p"}}',
    }
    local out, err = {}, {}
    local srv = mcp_server.new({ name = "loop" })
    srv:add("p", {
      run = function()
        print("noise", 1)
        vim.notify("more noise")
        return mcp_server.text("done")
      end,
    })
    local saved_print, saved_notify = print, vim.notify
    local code = srv:serve({
      read = function()
        return table.remove(input, 1)
      end,
      write = function(t)
        out[#out + 1] = t
      end,
      err = function(t)
        err[#err + 1] = t
      end,
    })
    eq(code, 0, "serve: 0 when the input ends")
    eq(#out, 2, "serve: one answer per request, none for the notification")
    ok(vim.json.decode(out[2]).result.content[1].text == "done", "serve: the tool answered")
    ok(
      vim.tbl_contains(err, "noise\t1") and vim.tbl_contains(err, "more noise"),
      "print/notify went to err"
    )
    ok(print == saved_print and vim.notify == saved_notify, "serve restores print and vim.notify")
  end

  -- contract bridge, on a real lib.nvim.contract.api dispatcher
  do
    local d = require("lib.nvim.contract.doc").new({ plugin = "demo.nvim", schema = 1 })
    d.clock = function()
      return "2026-01-01T00:00:00Z"
    end
    d.engine_info = function()
      return { version = "0.1.0", git = "abc1234", nvim = "v0.11.0" }
    end
    local seen
    local api = require("lib.nvim.contract.api").make({
      doc = d,
      engine_opts = { "root" },
      methods = {
        item = {
          params = { id = "string", tags = "string_list", n = "integer", custom = "mine" },
          required = { "id" },
          run = function(p, opts)
            seen = opts.root
            local doc = d.head("demo.item", opts.root)
            doc.id = p.id
            return doc
          end,
        },
        ops = { flat = true, params = { op = "string" }, run = function() end },
      },
      types = {
        mine = function()
          return true
        end,
      },
    })
    local tools = mcp_server.contract_tools(api, {
      prefix = "demo_",
      methods = { item = "One item", ops = nil },
      opts = function()
        return { root = "/tmp/demo-root" }
      end,
    })
    eq(vim.tbl_count(tools), 1, "only the named methods become tools")
    local t = tools.demo_item
    eq(t.description, "One item", "description")
    eq(t.input_schema.properties.tags.items.type, "string", "string_list schema")
    eq(t.input_schema.properties.n.type, "integer", "integer schema")
    eq(vim.tbl_count(t.input_schema.properties.custom), 0, "a plugin's own type stays open")
    eq(t.input_schema.required[1], "id", "required")
    local r = t.run({ id = "X-1" })
    eq(seen, "/tmp/demo-root", "the opts function reached the engine")
    ok(
      not r.isError and vim.json.decode(r.content[1].text).id == "X-1",
      "the document as the result"
    )
    r = t.run({})
    ok(
      r.isError and r.content[1].text:find("invalid_argument", 1, true),
      "an error document is isError"
    )
    ok(
      not pcall(mcp_server.contract_tools, api, { methods = { ops = "write" } }),
      "a flat method (write door) is refused"
    )
    ok(
      not pcall(mcp_server.contract_tools, api, { methods = { nope = "x" } }),
      "an unknown method raises"
    )
    local named = mcp_server.contract_tools(
      api,
      { methods = { item = { description = "d", name = "get_item" } } }
    )
    ok(named.get_item, "an entry can name its tool")
  end

  -- a real process, driven by the client lib.nvim.mcp
  do
    local mcp = require("lib.nvim.mcp")
    local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
    local c = mcp.client({
      id = "mcp-server-spec",
      cmd = {
        vim.v.progpath,
        "--headless",
        "-u",
        "NONE",
        "-l",
        dir .. "/support/mcp_server_demo.lua",
      },
      timeout_ms = 20000,
    })
    local function ask(fn)
      local done, a, b = false, nil, nil
      fn(function(x, y)
        done, a, b = true, x, y
      end)
      vim.wait(20000, function()
        return done
      end, 10)
      return done, a, b
    end
    local done, tools, err = ask(function(cb)
      c:list_tools(cb)
    end)
    ok(
      done and tools and not err,
      "stdio: tools/list answered while stdin stays open " .. vim.inspect(err)
    )
    eq(#tools, 2, "stdio: two tools")
    eq(c:server().serverInfo.version, "9.9.9", "stdio: the handshake reached the server")
    local _, r = ask(function(cb)
      c:call_tool("demo_echo", { text = "hi" }, cb)
    end)
    eq(
      r and r.content[1].text,
      '{"echoed":"hi"}',
      "stdio: a call, untouched by print/notify in the tool"
    )
    _, r = ask(function(cb)
      c:call_tool("demo_boom", {}, cb)
    end)
    ok(r and r.isError, "stdio: a failing tool is an isError result")
    local strays = 0
    for _, entry in ipairs(c:log()) do
      if entry.kind == "err" and entry.text:find("a stray", 1, true) then
        strays = strays + 1
      end
      ok(
        not (entry.kind == "out" and entry.text:find("a stray", 1, true)),
        "stdio: no stray line on stdout"
      )
    end
    ok(strays >= 1, "stdio: the stray print reached stderr")
    c:stop()
  end
end
