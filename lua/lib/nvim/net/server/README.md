# `lib.nvim.net.server`

A small local HTTP server for a plugin whose page or script has to call back into Neovim. Loopback only, an
OS-assigned port, strict route validation, torn down at `VimLeavePre`. Generalized from docmap.nvim's
`editor/serve.lua`.

```lua
local server = require("lib.nvim.net.server")
local s, err = server.start({
  name = "docs",
  routes = {
    { path = "/api/ping", handler = function() return 200, "application/json", '{"ok":true}' end },
    { pattern = "^/api/commit/([0-9a-f]+)$", captures = { "^%x+$" },
      query = { n = "^%d+$" },
      handler = function(req) return 200, "text/plain", req.params[1] end },
    { method = "POST", path = "/api/note", body = vim.json.decode,
      handler = function(req) save(req.body); return 204 end },
  },
})
-- s.url  s.port  s.stop()  s.is_running()
```

(Validators are Lua patterns, not regexes: write `"^%x+$"` / `"^%d+$"`, or pass a predicate function.)

## What it enforces

1. Binds **`127.0.0.1`** only; there is no host option. Port 0 unless you pass `port`.
2. **Whitelist routes:** method, exact path or pattern, every path capture, every query key and value. Unknown
   query keys, a repeated key, `..` or control characters in the path: 400 before a handler runs. A pattern route
   must declare a validator per capture (asserted at `start`).
3. **`Host` header** must be `127.0.0.1:<port>` or `localhost:<port>` (403 otherwise): protection against DNS
   rebinding from a web page.
4. **Bounded input:** header block 64 KB, body only for routes with `body` and up to `max_body` (413), a client
   that stalls is dropped after `idle_ms` (408), and at most `max_clients` (default 64) connections are open at
   once (one more gets a 503 and is closed).
5. **`VimLeavePre` stops every server** (`server.stop_all()`); `s.stop()` stops one.

Handlers run on the main loop; they return `status, content_type, body`. An error thrown in a handler is a 500
with the message. Answers carry `Cache-Control: no-store`, `X-Content-Type-Options: nosniff` and
`Connection: close` (no keep-alive state machine).

## Answering later (asynchronous routes)

A handler that asks git or another program would block the editor while it waits. Mark the route `async = true`:
the handler gets `respond` as its second argument and answers whenever it is ready, without blocking.

```lua
{ path = "/api/commits", async = true, timeout_ms = 10000,
  handler = function(req, respond)
    git.log_async("HEAD", { max_count = 5 }, function(commits, err)
      if not commits then return respond(500, "application/json", vim.json.encode({ error = err })) end
      respond(200, "application/json", vim.json.encode(commits))
    end)
  end },
```

- **The first answer counts, once.** `respond` a second time, after the deadline, after the client hung up or
  after `s.stop()` writes nothing and does not throw.
- **A throw before the answer is a 500**; a throw after it changes nothing.
- **No answer within `timeout_ms`** (default `opts.async_timeout_ms`, else 30 s) **is a 504**, so no connection
  hangs on a handler that forgot to answer.
- `respond` may be called from a raw libuv callback (answering uses only libuv and `vim.json`).
- Synchronous routes (no `async`) are unchanged.

Not here: TLS, keep-alive, static file serving (a route can do that with `lib.nvim.fs`), WebSockets.
