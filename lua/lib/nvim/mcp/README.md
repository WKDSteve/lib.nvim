# `lib.nvim.mcp`

A generic MCP (Model Context Protocol) client over **stdio** or **Streamable HTTP**: JSON-RPC 2.0, `initialize`,
`tools/list`, `tools/call`. `cmd` starts a process (one JSON message per line); `url` talks to an HTTP endpoint. It
knows nothing about a particular server.

```lua
local mcp = require("lib.nvim.mcp")
local c = mcp.client({ id = "tosca", cmd = { "npx", "-y", "mcp-remote@latest", url }, timeout_ms = 30000 })

c:list_tools(function(tools, err) end)                  -- starts the process on first use, follows nextCursor
c:call_tool("run_playlist", { id = "x" }, function(res, err)
  -- res = { content, structuredContent, isError }, exactly as the server sent it
end, { timeout_ms = 120000 })
local id = c:call_tool("slow", {}, cb); c:cancel(id)    -- notifications/cancelled to the server
c:state(); c:server(); c:log(); c:stop()
```

- **One process per client id**; `mcp.client` with an existing id returns that client. Started on the first
  request, stopped at `VimLeavePre` (`mcp.stop_all()`).
- Requests wait for the handshake. `initialize` sends the protocol version, `clientInfo` and **no**
  `sampling`/`elicitation` capability; `notifications/initialized` follows.
- Every request has a timeout; on a timeout the server gets `notifications/cancelled` and the caller
  `{ code = "timeout" }`.
- **stderr never reaches a notification** (a bridge may print a login link there). It goes to `client:log()` and
  `opts.on_log`. A non-JSON line on stdout (a banner) is logged and ignored.
- Server requests are answered (`ping` with `{}`, anything else "method not found"); server notifications go to
  `opts.on_notification(method, params)`.
- Errors are values, `{ code, message, data? }`: a JSON-RPC number, or `"spawn"` (command missing), `"exited"`
  (process ended; `data.code` is the exit code), `"port_in_use"` (recognised from stderr), `"timeout"`,
  `"closed"`, `"cancelled"`. A failed start stays failed until `c:restart()`.

### HTTP (`url`)

```lua
local c = mcp.client({
  id = "commander",
  url = "http://127.0.0.1:8080/mcp",
  headers = { ["X-Client"] = "casedesk" },
  secret_headers = { Authorization = "Bearer " .. token },  -- curl's config path, never argv
})
```

Same API as stdio (`request`, `list_tools`, `call_tool`, `cancel`, `log`, `stop`, ...); give `cmd` **or** `url`.

- One `POST` per message. The answer is `application/json` (an object or an array of messages) or a
  `text/event-stream` whose `data:` events are the messages; `202` carries nothing. The whole answer is read first, so a
  notification the server streams in front of its answer reaches `on_notification` together with the answer.
- The `Mcp-Session-Id` from `initialize` and the agreed `MCP-Protocol-Version` go on every later request.
  `stop` (and `VimLeavePre`) ends the session with a `DELETE`; a server that answers 405 is fine.
- Errors: `401`/`403` is `"unauthorized"`; `404` on a live session is `"closed"` (the next request initialises a new
  session); any other non-2xx is `"http"` with `data = { status, body }`, as is a curl failure (connection refused).
  Timeouts and `cancel` work as for stdio.
- Spec: `TESTS/mcp_http_spec.lua`, against a fake server on loopback.

**Why `vim.system` and not `system.job`:** `lib.nvim.system.job.start` does not expose an open stdin pipe. This
module calls `vim.system(cmd, { stdin = true })` itself and uses `lib.nvim.system.lines` for the line splitting.

Not here: `resources/read`, server-initiated sampling, a server-pushed stream outside a request (`GET` SSE), resumption.
