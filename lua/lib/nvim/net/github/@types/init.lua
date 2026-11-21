---@meta
---@module 'lib.nvim.net.github.@types'

---Options for `require("lib.nvim.net.github").request` / `request_blocking`.
---@class Lib.Net.Github.RequestOpts
---@field token? string Sent as `Authorization: Bearer <token>` (curl's `-K -` config path, never argv), only to `api_base`'s origin and never over plain http off loopback
---@field etag? string Sent as `If-None-Match`; an unchanged resource answers `304` (`result.not_modified`)
---@field query? table<string, string> URL-encoded and appended as `?k=v&...`
---@field method? string HTTP method (default `"GET"`)
---@field body? string Request body, sent as `Content-Type: application/json` (a GraphQL query: `method = "POST"`, path `/graphql`); it goes into curl's argv, so never put a secret in it
---@field api_base? string API root for a path (default `https://api.github.com`); ignored for an absolute URL
---@field timeout_ms? integer|false Request deadline (default 15000); `false` lifts it
---@field max_bytes? integer|false Response size limit, curl's `--max-filesize` (default 5 MiB); `false` lifts it
---@field transport? Lib.Net.Github.Transport Replaces the curl call (specs: no network)

---The function `opts.transport` replaces `lib.nvim.net.curl.fetch_raw` with.
---`done` takes the same `(ok, response_or_err)` pair `fetch_raw` hands its
---callback; `curl_opts` is what would have gone to curl (headers, token,
---query, limits).
---@alias Lib.Net.Github.Transport fun(url: string, curl_opts: Lib.Net.Curl.FetchOpts, done: fun(ok: boolean, response_or_err: Lib.Net.Curl.RawResponse|string))

---Rate-limit state from the `x-ratelimit-*` headers; `nil` fields when a
---response did not carry them.
---@class Lib.Net.Github.RateLimit
---@field remaining integer|nil Requests left in the current window
---@field reset integer|nil Epoch seconds when the window resets

---A usable GitHub answer (2xx or 304).
---@class Lib.Net.Github.Response
---@field status integer HTTP status
---@field etag string|nil The `ETag` header, for the next request's `opts.etag`
---@field data any Decoded JSON body; `nil` on 304 or an empty body
---@field not_modified boolean `true` for a 304 answer to `opts.etag`
---@field rate_limit Lib.Net.Github.RateLimit
---@field headers table<string, string> All response headers, keys lowercased (`link` for pagination)

---Options for `require("lib.nvim.net.github").token`.
---@class Lib.Net.Github.TokenOpts
---@field env_var? string Environment variable to read first (the caller names it; `GITHUB_TOKEN` only if passed here)
---@field timeout_ms? integer Deadline for `gh auth token` (default 5000)
---@field runner? fun(argv: string[], sys_opts: Lib.Net.Github.RunnerOpts): Lib.Net.Github.RunnerResult Replaces the `vim.system` call (specs)

---What `token` hands its runner: the child environment (without
---`GITHUB_TOKEN`; it replaces, not extends, the parent environment) and the
---deadline.
---@class Lib.Net.Github.RunnerOpts
---@field env table<string, string>
---@field timeout_ms integer

---@class Lib.Net.Github.RunnerResult
---@field code integer
---@field stdout string
---@field stderr string

---@class Lib.Net.Github
---@field API_BASE string
---@field API_VERSION string
---@field request fun(path_or_url: string, opts: Lib.Net.Github.RequestOpts|nil, cb: fun(result: Lib.Net.Github.Response|nil, err: string|nil))
---@field request_blocking fun(path_or_url: string, opts: Lib.Net.Github.RequestOpts|nil): Lib.Net.Github.Response|nil, string|nil
---@field token fun(opts: Lib.Net.Github.TokenOpts|nil): string|nil, string
