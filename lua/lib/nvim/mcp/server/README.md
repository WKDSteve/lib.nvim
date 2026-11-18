# `lib.nvim.mcp.server`

An MCP (Model Context Protocol) server over **stdio**: JSON-RPC 2.0, one message per line, `initialize`, `ping`,
`tools/list`, `tools/call`, and a tool registry. The counterpart of the client [`lib.nvim.mcp`](../README.md).
Moved here from docmap.nvim (`docmap.mcp.protocol`); docmap, tasks.nvim, rules.nvim and testing.nvim serve their
tools through it.

```lua
local mcp_server = require("lib.nvim.mcp.server")

local s = mcp_server.new({
  name = "demo.nvim",
  version = "0.1.0",
  instructions = "Read-only tools over the demo index.",
})
s:add("demo_echo", {
  description = "Echo the arguments.",
  input_schema = { type = "object", properties = { text = { type = "string" } } },
  run = function(args, ctx)
    return mcp_server.text({ echoed = args.text })  -- one text block, canonical JSON
  end,
})
os.exit(s:serve())   -- blocks until stdin closes
```

Started as a subprocess by the client (Claude Code, `lib.nvim.mcp`):

```sh
nvim --headless -u NONE -l scripts/mcp.lua
```

## Rules

- **stdout is the protocol.** While `serve` runs, `print` and `vim.notify` go to stderr; every answer is flushed (the
  Windows C runtime buffers a line-buffered stdout fully).
- **A notification is never answered**; nothing waits for the handshake (a `tools/list` right behind `initialize`
  works).
- **A failing tool is a result** (`isError = true`, the message as text), so the model sees it; a JSON-RPC error is
  for the plumbing: `-32700` bad JSON, `-32600` no request, `-32601` unknown method, `-32602` `tools/call` without a
  name, `-32603` a crash in dispatch (the process lives on).
- `initialize` echoes a version of `SUPPORTED` the client asks for, else the newest; `listChanged = false`.
- `tools/list` is sorted by name. A tool name is 1..64 of `A-Z a-z 0-9 _ . -`; `add` raises on a bad or taken name.

## Helpers

| Function | What |
| --- | --- |
| `text(value, is_error?)` | a value as one text block (`lib.nvim.json.canonical`: sorted keys, same bytes each run); a string as it is |
| `error_text(msg)` | `text(msg, true)` |
| `clamp_limit(n, default, max?)` | `nil` is the default, not "unlimited"; clamped to `1..max` (1000) |
| `contract_tools(api, spec)` | read methods of a `lib.nvim.contract.api` dispatcher as tools (below) |
| `schema_of(method)` | the JSON Schema of a contract method's `params` |

### Contract bridge

```lua
local tools = mcp_server.contract_tools(require("tasks_nvim.api"), {
  prefix = "tasks_",
  methods = {
    list = "A page of open tasks ...",
    task = "One task with body and steps ...",
  },
  opts = function() return { root = vault } end,  -- the engine options of each call
})
mcp_server.new({ name = "tasks.nvim", tools = tools }):serve()
```

Each tool sends `{ schema = 1, params = <arguments> }` to `api.call` and answers the document's canonical bytes; an
error document (`code ~= nil`) is `isError`. **Only the methods named in `spec.methods` become tools**, and a `flat`
method (a write door such as `ops`) is refused: a read server cannot grow a write tool by accident.

Spec: `TESTS/mcp_server_spec.lua` (protocol in-process, and a real stdio process driven by the client
`lib.nvim.mcp`, with stdin held open).

Not here: resources, prompts, sampling, HTTP, `notifications/tools/list_changed`.
