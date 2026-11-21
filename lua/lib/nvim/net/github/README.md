# `lib.nvim.net.github`

GitHub REST API requests on top of [`lib.nvim.net.curl`](../curl/README.md),
plus token resolution. The shared GitHub client of the fleet: a plugin that
talks to `api.github.com` uses this instead of its own curl wrapper.

## Usage

```lua
local github = require("lib.nvim.net.github")

-- Token: the caller's own variable first, then `gh auth token`.
local token, source_or_reason = github.token({ env_var = "MY_PLUGIN_GITHUB_TOKEN" })

-- Blocking
local res, err = github.request_blocking("/repos/owner/repo/actions/runs", {
  token = token,
  query = { head_sha = sha, per_page = "20" },
})
if not res then
  vim.notify(err, vim.log.levels.WARN)
elseif not res.not_modified then
  vim.print(res.data.workflow_runs, res.etag, res.rate_limit.remaining)
end

-- Async, conditional: an unchanged resource answers 304 (no data, no error)
github.request("/repos/owner/repo", { token = token, etag = last_etag }, function(r, e)
  -- runs on the main loop, never synchronously
end)
```

## API

```
M.request(path_or_url, opts: Lib.Net.Github.RequestOpts|nil, cb: fun(result|nil, err|nil))
M.request_blocking(path_or_url, opts?): Lib.Net.Github.Response|nil, string|nil
M.token(opts: Lib.Net.Github.TokenOpts|nil): string|nil token, string source_or_reason
```

`path_or_url` is an API path (`/repos/o/r`, the leading slash optional), joined
to `opts.api_base` (default `https://api.github.com`), or an absolute URL such
as the next page from a `Link` header (`result.headers.link`).

The token goes only to the API's own origin: an absolute URL whose scheme, host
or port differs from `api_base` is requested without it, and a token is never
sent over plain `http://` except to a loopback host (`localhost`, `127.x.x.x`,
`[::1]`); such a request is refused with
`GitHub request refused: the token is never sent over http to <host>`.

### Request options

| option       | effect                                                                 |
| ------------ | ---------------------------------------------------------------------- |
| `token`      | `Authorization: Bearer ...`, through curl's `-K -` config, never argv   |
| `etag`       | `If-None-Match`; an unchanged resource answers `304`                    |
| `query`      | URL-encoded query string                                               |
| `method`     | HTTP method (default `GET`)                                            |
| `body`       | Request body as `application/json` (GraphQL: `POST /graphql`); argv, no secrets |
| `api_base`   | API root for a path                                                    |
| `timeout_ms` | deadline, default 15000; `false` lifts it                              |
| `max_bytes`  | response size limit, default 5 MiB; `false` lifts it                   |
| `transport`  | `fun(url, curl_opts, done(ok, response_or_err))` replacing the curl call (specs) |

Every request sends `Accept: application/vnd.github+json` and
`X-GitHub-Api-Version: 2022-11-28`.

### Result and errors

A usable answer (2xx or 304) is
`{ status, etag, data, not_modified, rate_limit = { remaining, reset }, headers }`:
`data` is the decoded JSON body (`nil` on 304), `rate_limit` comes from the
`x-ratelimit-*` headers (`reset` in epoch seconds). Everything else is
`nil, err`:

- curl failed: `GitHub request failed: <curl's message>`; so does a curl
  (missing on `PATH`) or transport that throws, and a malformed response
- 4xx/5xx: `GitHub API error: HTTP 404: Not Found` (GitHub's `message`, else
  the reason phrase)
- any other 3xx (curl follows no redirect; a renamed repository answers 301):
  `GitHub API error: HTTP 301: Moved Permanently (location: <url>)`
- a `200` whose body is a GitHub error object (`message`, `documentation_url`
  and nothing else of substance): `GitHub API error: HTTP 200: Bad credentials`.
  A resource that merely has a `message` field (a commit) is data.
- an exhausted rate limit (403/429 with `x-ratelimit-remaining: 0`):
  `GitHub API rate limit exhausted (HTTP 403); resets at 2026-10-31T12:00:00Z (in 600s)`
- an undecodable 2xx body: `GitHub API error: HTTP 200: invalid JSON response`

`request`'s `cb` always runs, exactly once, on the main loop.

## Token resolution

`token(opts)` tries, in order:

1. `opts.env_var` -- an environment variable the caller names (a dedicated,
   fine-grained, read-only token), when set and non-empty;
2. `gh auth token` (argv through `vim.system`, `opts.timeout_ms`, default
   5000).

It returns `token, "env:<NAME>"` or `token, "gh"`, else `nil, reason`.

`GITHUB_TOKEN` is never read unless the caller passes that name as
`env_var`. It is also removed from the environment of the `gh` child, since gh
would otherwise print it back as its token. (`GH_TOKEN`, gh's own variable,
stays in effect.) No reason string ever carries a token: only gh's stderr is
quoted, never its stdout. `opts.runner` replaces the `vim.system` call for
specs.
