-- A fake MCP server for TESTS/mcp_spec.lua: JSON-RPC 2.0, one JSON message per line on stdin/stdout.
-- Run: nvim --headless -u NONE -l TESTS/support/fake_mcp_server.lua
-- FAKE_MODE: "" (normal) | "banner" (non-JSON line on stdout first) | "port_busy" (stderr EADDRINUSE, exit 1)
--            | "die_after_init" (exits right after `notifications/initialized`)

local mode = vim.env.FAKE_MODE or ""

local function out(msg)
  io.stdout:write(vim.json.encode(msg) .. "\n")
  io.stdout:flush()
end

if mode == "port_busy" then
  io.stderr:write("Error: listen EADDRINUSE: address already in use :::56874\n")
  io.stderr:flush()
  os.exit(1)
end
if mode == "banner" then
  io.stdout:write("Fake bridge v1 -- open https://login.example/secret to sign in\n")
  io.stdout:flush()
end
io.stderr:write("fake: started, visit https://login.example/secret?token=abc\n")
io.stderr:flush()

local TOOLS = {
  { name = "echo", description = "Echo the arguments back", inputSchema = { type = "object" } },
  { name = "slow", description = "Never answers", inputSchema = { type = "object" } },
  { name = "boom", description = "Fails", inputSchema = { type = "object" } },
  { name = "second_page", description = "On page two", inputSchema = { type = "object" } },
}

for line in io.stdin:lines() do
  local ok, msg = pcall(vim.json.decode, line)
  if ok and type(msg) == "table" then
    if msg.method == "initialize" then
      out({
        jsonrpc = "2.0",
        id = msg.id,
        result = {
          protocolVersion = msg.params.protocolVersion,
          capabilities = { tools = vim.empty_dict() },
          serverInfo = { name = "fake", version = "0" },
          -- the client's own capabilities, echoed so the spec can check none were claimed
          echoedClientCapabilities = msg.params.capabilities,
          echoedClientInfo = msg.params.clientInfo,
        },
      })
    elseif msg.method == "notifications/initialized" then
      out({ jsonrpc = "2.0", method = "notifications/message", params = { note = "ready" } })
      if mode == "die_after_init" then
        os.exit(3)
      end
    elseif msg.method == "notifications/cancelled" then
      out({
        jsonrpc = "2.0",
        method = "notifications/message",
        params = { cancelled = msg.params.requestId },
      })
    elseif msg.method == "tools/list" then
      local cursor = msg.params and msg.params.cursor
      if cursor == "p2" then
        out({ jsonrpc = "2.0", id = msg.id, result = { tools = { TOOLS[4] } } })
      else
        out({
          jsonrpc = "2.0",
          id = msg.id,
          result = { tools = { TOOLS[1], TOOLS[2], TOOLS[3] }, nextCursor = "p2" },
        })
      end
    elseif msg.method == "tools/call" then
      local name = msg.params.name
      if name == "echo" then
        out({
          jsonrpc = "2.0",
          id = msg.id,
          result = {
            content = { { type = "text", text = "echo" } },
            structuredContent = { args = msg.params.arguments },
            isError = false,
          },
        })
      elseif name == "boom" then
        out({
          jsonrpc = "2.0",
          id = msg.id,
          result = { content = { { type = "text", text = "it failed" } }, isError = true },
        })
      elseif name == "missing" then
        out({ jsonrpc = "2.0", id = msg.id, error = { code = -32602, message = "unknown tool" } })
      end
      -- "slow": no answer at all
    elseif msg.method == "ping" then
      out({ jsonrpc = "2.0", id = msg.id, result = vim.empty_dict() })
    end
  end
end
