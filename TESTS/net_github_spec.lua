-- TESTS/net_github_spec.lua — lib.nvim.net.github
--
-- No network: every request goes through `opts.transport`, a fake that
-- answers with a canned `Lib.Net.Curl.RawResponse`, and `token` runs a fake
-- `gh` through `opts.runner`.

return function(H)
  local eq, ok = H.eq, H.ok

  ---Deep equality (`H.eq` compares with `==`).
  local function deq(a, b, msg)
    ok(vim.deep_equal(a, b), ("%s: got %s"):format(msg, vim.inspect(a)))
  end

  local github = require("lib.nvim.net.github")

  ---A transport that records what it was handed and answers `resp`
  ---synchronously (a string answers as a curl failure).
  ---@param resp Lib.Net.Curl.RawResponse|string
  ---@return Lib.Net.Github.Transport transport
  ---@return table seen  `{ url, opts }` of the last call
  local function fake(resp)
    local seen = {}
    return function(url, curl_opts, done)
      seen.url, seen.opts = url, curl_opts
      if type(resp) == "string" then
        done(false, resp)
      else
        done(true, resp)
      end
    end,
      seen
  end

  ---@param status integer
  ---@param headers table<string, string>|nil
  ---@param body string|nil
  ---@return Lib.Net.Curl.RawResponse
  local function response(status, headers, body)
    return { status = status, status_text = "", headers = headers or {}, body = body or "" }
  end

  -- 200: decoded data, etag, rate limit, GitHub headers and the token.
  do
    local transport, seen = fake(response(200, {
      etag = 'W/"abc"',
      ["x-ratelimit-remaining"] = "4999",
      ["x-ratelimit-reset"] = "1700000000",
    }, '{"total_count":1,"workflow_runs":[{"id":7}]}'))
    local res, err = github.request_blocking("/repos/o/r/actions/runs", {
      token = "tkn",
      query = { head_sha = "deadbeef" },
      transport = transport,
    })
    eq(err, nil, "github: a 200 is no error")
    eq(res.status, 200, "github: status reported")
    eq(res.data.workflow_runs[1].id, 7, "github: body decoded into data")
    eq(res.etag, 'W/"abc"', "github: etag reported")
    eq(res.not_modified, false, "github: a 200 is not 'not modified'")
    deq(res.rate_limit, { remaining = 4999, reset = 1700000000 }, "github: rate limit parsed")
    eq(
      seen.url,
      "https://api.github.com/repos/o/r/actions/runs",
      "github: a path joins the API base"
    )
    eq(seen.opts.bearer_token, "tkn", "github: token goes out as bearer_token (curl's -K path)")
    eq(seen.opts.headers.Accept, "application/vnd.github+json", "github: Accept header")
    eq(seen.opts.headers["X-GitHub-Api-Version"], github.API_VERSION, "github: API version header")
    eq(seen.opts.headers["If-None-Match"], nil, "github: no If-None-Match without opts.etag")
    deq(seen.opts.query, { head_sha = "deadbeef" }, "github: query passed through")
    eq(seen.opts.timeout_ms, 15000, "github: default timeout")
    eq(seen.opts.max_bytes, 5 * 1024 * 1024, "github: default size limit")
  end

  -- Limits passed through, `false` lifts them; an absolute URL is kept.
  do
    local transport, seen = fake(response(200, {}, "[]"))
    local res = github.request_blocking("https://api.github.com/x?page=2", {
      timeout_ms = 1234,
      max_bytes = false,
      transport = transport,
    })
    deq(res.data, {}, "github: an array body decodes")
    eq(seen.url, "https://api.github.com/x?page=2", "github: an absolute URL is used as given")
    eq(seen.opts.timeout_ms, 1234, "github: timeout passed through")
    eq(seen.opts.max_bytes, nil, "github: max_bytes = false lifts the limit")
  end

  -- 304: If-None-Match sent, not_modified reported, no data, no error.
  do
    -- A stray body (a proxy's) is not decoded: a 304 has no new data.
    local transport, seen = fake(response(304, { etag = '"e1"' }, '{"stale":true}'))
    local res, err = github.request_blocking("repos/o/r", { etag = '"e1"', transport = transport })
    eq(err, nil, "github: a 304 is no error")
    eq(res.not_modified, true, "github: a 304 is reported as not_modified")
    eq(res.data, nil, "github: a 304 carries no data")
    eq(seen.opts.headers["If-None-Match"], '"e1"', "github: opts.etag goes out as If-None-Match")
    eq(seen.url, "https://api.github.com/repos/o/r", "github: a path without a leading slash")
  end

  -- 200 with a GitHub error object: an error naming the status.
  do
    local res, err = github.request_blocking("/x", {
      transport = fake(response(200, {}, '{"message":"Bad credentials","documentation_url":"u"}')),
    })
    eq(res, nil, "github: a 200 {message} body is no result")
    eq(
      err,
      "GitHub API error: HTTP 200: Bad credentials",
      "github: ... but an error naming the status"
    )
  end

  -- A resource that merely has a `message` field (a commit) is data.
  do
    local res, err = github.request_blocking("/x", {
      transport = fake(response(200, {}, '{"message":"fix: x","sha":"abc"}')),
    })
    eq(err, nil, "github: a resource with a message field is no error")
    eq(res.data.sha, "abc", "github: ... and is returned as data")
  end

  -- 4xx/5xx: the status and GitHub's message, or the reason phrase.
  do
    local res, err = github.request_blocking("/x", {
      transport = fake(response(404, {}, '{"message":"Not Found"}')),
    })
    eq(res, nil, "github: a 404 is no result")
    eq(err, "GitHub API error: HTTP 404: Not Found", "github: a 404 names status and message")

    local raw = response(502, {}, "<html>bad gateway</html>")
    raw.status_text = "Bad Gateway"
    local _, err2 = github.request_blocking("/x", { transport = fake(raw) })
    eq(
      err2,
      "GitHub API error: HTTP 502: Bad Gateway",
      "github: a non-JSON 5xx names the reason phrase"
    )
  end

  -- 3xx other than 304: curl follows no redirect, so a renamed repository's
  -- 301 `{message, url}` object is an error, never data.
  do
    local res, err = github.request_blocking("/repos/old/name", {
      transport = fake(
        response(
          301,
          { location = "https://api.github.com/repositories/42" },
          '{"message":"Moved Permanently","url":"https://api.github.com/repositories/42","documentation_url":"d"}'
        )
      ),
    })
    eq(res, nil, "github: a 301 is no result")
    eq(
      err,
      "GitHub API error: HTTP 301: Moved Permanently (location: https://api.github.com/repositories/42)",
      "github: a 301 names status, message and location"
    )

    local raw = response(302)
    raw.status_text = "Found"
    local _, err2 = github.request_blocking("/x", { transport = fake(raw) })
    eq(err2, "GitHub API error: HTTP 302: Found", "github: a bodyless 3xx names the reason phrase")
  end

  -- 403 with an exhausted rate limit: an error that says when it resets.
  do
    local reset = os.time() + 600
    local res, err = github.request_blocking("/x", {
      transport = fake(response(403, {
        ["x-ratelimit-remaining"] = "0",
        ["x-ratelimit-reset"] = tostring(reset),
      }, '{"message":"API rate limit exceeded"}')),
    })
    eq(res, nil, "github: an exhausted rate limit is no result")
    ok(err:find("rate limit exhausted", 1, true), "github: the error names the rate limit: " .. err)
    ok(
      err:find(os.date("!%Y-%m-%dT%H:%M:%SZ", reset), 1, true),
      "github: ... and when it resets: " .. err
    )
  end

  -- A 403 with requests left is a plain permission error.
  do
    local _, err = github.request_blocking("/x", {
      transport = fake(
        response(403, { ["x-ratelimit-remaining"] = "12" }, '{"message":"Forbidden"}')
      ),
    })
    eq(
      err,
      "GitHub API error: HTTP 403: Forbidden",
      "github: a 403 with quota left is no rate-limit error"
    )
  end

  -- Invalid JSON on a 2xx, and a failed transport.
  do
    local _, err = github.request_blocking("/x", { transport = fake(response(200, {}, "{oops")) })
    eq(
      err,
      "GitHub API error: HTTP 200: invalid JSON response",
      "github: an undecodable 200 body is an error"
    )

    local _, err2 =
      github.request_blocking("/x", { transport = fake("curl: (6) Could not resolve host\n") })
    eq(
      err2,
      "GitHub request failed: curl: (6) Could not resolve host",
      "github: a curl failure becomes a request error"
    )
  end

  -- request (async): same contract, callback on the main loop, never inline.
  do
    local got
    github.request("/x", {
      transport = fake(response(200, { etag = '"z"' }, '{"a":1}')),
    }, function(res, err)
      got = { res = res, err = err }
    end)
    local inline = got ~= nil
    vim.wait(1000, function()
      return got ~= nil
    end, 5)
    eq(inline, false, "github.request: the callback is not called synchronously")
    eq(got and got.res.data.a, 1, "github.request: data delivered to the callback")
    eq(got and got.res.etag, '"z"', "github.request: etag delivered too")

    local got2
    github.request(
      "/x",
      { transport = fake(response(500, {}, '{"message":"boom"}')) },
      function(res, err)
        got2 = { res = res, err = err }
      end
    )
    vim.wait(1000, function()
      return got2 ~= nil
    end, 5)
    eq(
      got2 and got2.err,
      "GitHub API error: HTTP 500: boom",
      "github.request: errors delivered as err"
    )
  end

  ---Run `github.request` and wait for its callback.
  ---@return table|nil got `{ res, err, calls }`, nil when cb never ran
  local function request_and_wait(path, opts)
    local got
    local ok_call, call_err = pcall(github.request, path, opts, function(res, err)
      got = got or { calls = 0 }
      got.res, got.err, got.calls = res, err, got.calls + 1
    end)
    ok(ok_call, "github.request: does not throw: " .. tostring(call_err))
    vim.wait(1000, function()
      return got ~= nil
    end, 5)
    vim.wait(20)
    return got
  end

  -- A transport that throws synchronously: an error, never a throw, cb once.
  do
    local function throwing()
      error("ENOENT: no such file or directory (cmd): 'curl'")
    end
    local res, err = github.request_blocking("/x", { transport = throwing })
    eq(res, nil, "github: a throwing transport is no result")
    ok(
      err and err:find("^GitHub request failed: .*ENOENT"),
      "github: ... but a request error: " .. tostring(err)
    )

    local got = request_and_wait("/x", { transport = throwing })
    ok(
      got and got.err and got.err:find("^GitHub request failed: .*ENOENT"),
      "github.request: ditto"
    )
    eq(got and got.calls, 1, "github.request: cb runs exactly once")

    -- Answering, then throwing: the answer counts, cb still runs once.
    local got2 = request_and_wait("/x", {
      transport = function(_, _, done)
        done(true, response(200, {}, '{"a":2}'))
        error("late")
      end,
    })
    eq(got2 and got2.res and got2.res.data.a, 2, "github.request: an answer before a throw wins")
    eq(got2 and got2.calls, 1, "github.request: ... and cb runs once")
  end

  -- curl itself throwing (no curl on PATH): the default path reports it too.
  do
    local curl = require("lib.nvim.net.curl")
    local orig_raw, orig_blocking = curl.fetch_raw, curl.fetch_raw_blocking
    curl.fetch_raw = function()
      error("ENOENT: curl", 0)
    end
    curl.fetch_raw_blocking = curl.fetch_raw
    local success, failure = pcall(function()
      local _, err = github.request_blocking("/x", {})
      eq(err, "GitHub request failed: " .. "ENOENT: curl", "github (curl): a throw is an error")
      local got = request_and_wait("/x", {})
      ok(got and got.err and got.err:find("ENOENT: curl", 1, true), "github.request (curl): ditto")
    end)
    curl.fetch_raw, curl.fetch_raw_blocking = orig_raw, orig_blocking
    if not success then
      error(failure, 0)
    end
  end

  -- A malformed response (no status) reaches cb as an error, not a throw in
  -- the scheduled callback that would leave cb unanswered.
  do
    local got = request_and_wait("/x", { transport = fake({ headers = {}, body = "" }) })
    ok(
      got and got.err and got.err:find("^GitHub request failed: "),
      "github.request: a response without status is an error: " .. vim.inspect(got)
    )
    local _, err = github.request_blocking("/x", { transport = fake({ headers = {}, body = "" }) })
    ok(err and err:find("^GitHub request failed: "), "github: ditto, blocking")
  end

  -- The token goes only to the API's own origin, never over plain http.
  do
    local transport, seen = fake(response(200, {}, "{}"))
    github.request_blocking(
      "https://api.github.com/x?page=2",
      { token = "t", transport = transport }
    )
    eq(seen.opts.bearer_token, "t", "github: same-origin absolute URL carries the token")

    for _, url in ipairs({
      "https://evil.example/x",
      "http://api.github.com/x",
      "https://api.github.com:8443/x",
      "https://api.github.com.evil.example/x",
      "https://api.github.com@evil.example/x",
    }) do
      seen.opts = nil
      local res = github.request_blocking(url, { token = "t", transport = transport })
      ok(res, "github: a foreign URL is still requested: " .. url)
      eq(seen.opts and seen.opts.bearer_token, nil, "github: ... but without the token: " .. url)
    end

    seen.url = nil
    local res, err = github.request_blocking("/x", {
      api_base = "http://ghe.example",
      token = "t",
      transport = transport,
    })
    eq(res, nil, "github: no token over plain http off loopback")
    eq(
      err,
      "GitHub request refused: the token is never sent over http to ghe.example",
      "github: ... the error says why"
    )
    eq(seen.url, nil, "github: ... and nothing is sent")
    local got = request_and_wait("/x", {
      api_base = "http://ghe.example",
      token = "t",
      transport = transport,
    })
    eq(got and got.err, err, "github.request: ditto, through cb")

    local res2 = github.request_blocking("/x", {
      api_base = "http://localhost:8080",
      token = "t",
      transport = transport,
    })
    ok(res2, "github: plain http to loopback is fine")
    eq(seen.opts.bearer_token, "t", "github: ... and carries the token")
  end

  -- Without a transport: real curl against a local socket (`api_base`), never
  -- GitHub. Proves the default path parses headers and sends the token off argv.
  do
    local uv = vim.uv or vim.loop

    ---Serve `reply` to one connection on 127.0.0.1, capturing the request.
    ---@param reply string
    ---@return integer port, uv.uv_tcp_t server, table captured
    local function serve(reply)
      local server = assert(uv.new_tcp())
      assert(server:bind("127.0.0.1", 0))
      local captured = {}
      server:listen(128, function(listen_err)
        assert(not listen_err, listen_err)
        local client = assert(uv.new_tcp())
        server:accept(client)
        client:read_start(function(_, chunk)
          captured.data = (captured.data or "") .. (chunk or "")
          if captured.data:find("\r\n\r\n", 1, true) and not captured.sent then
            captured.sent = true
            client:write(reply)
            client:shutdown(function()
              client:close()
            end)
          end
        end)
      end)
      return server:getsockname().port, server, captured
    end

    local reply = table.concat({
      "HTTP/1.1 200 OK",
      "Content-Type: application/json",
      'ETag: "real"',
      "X-RateLimit-Remaining: 59",
      "X-RateLimit-Reset: 1700000000",
      "Content-Length: 8",
      "",
      '{"id":3}',
    }, "\r\n")

    local port, server, captured = serve(reply)
    local res, err = github.request_blocking("/repos/o/r", {
      api_base = ("http://127.0.0.1:%d"):format(port),
      token = "local-tkn",
      timeout_ms = 10000,
    })
    server:close()
    eq(err, nil, "github (curl): no error from a local 200")
    eq(res and res.data.id, 3, "github (curl): body decoded")
    eq(res and res.etag, '"real"', "github (curl): etag header read")
    eq(res and res.rate_limit.remaining, 59, "github (curl): rate limit header read")
    local req = (captured.data or ""):lower()
    ok(req:find("authorization: bearer local-tkn", 1, true), "github (curl): token sent as bearer")
    ok(req:find("x-github-api-version: ", 1, true), "github (curl): API version header sent")

    local port2, server2 = serve(reply)
    local got
    github.request(
      "/x",
      { api_base = ("http://127.0.0.1:%d/"):format(port2), timeout_ms = 10000 },
      function(r, e)
        got = { res = r, err = e }
      end
    )
    vim.wait(10000, function()
      return got ~= nil
    end, 10)
    server2:close()
    eq(got and got.err, nil, "github.request (curl): no error")
    eq(got and got.res and got.res.data.id, 3, "github.request (curl): body decoded")
  end

  ---A fake `gh` runner that records its calls.
  ---@param code integer
  ---@param stdout string
  ---@param stderr string|nil
  local function runner(code, stdout, stderr)
    local calls = {}
    return function(argv, sys_opts)
      calls[#calls + 1] = { argv = argv, opts = sys_opts }
      return { code = code, stdout = stdout, stderr = stderr or "" }
    end,
      calls
  end

  ---Run `fn` with environment variable `name` set to `value` (nil unsets).
  local function with_env(name, value, fn)
    local orig = vim.env[name]
    vim.env[name] = value
    local success, err = pcall(fn)
    vim.env[name] = orig
    if not success then
      error(err, 0)
    end
  end

  -- Token order: the caller-named env var wins, gh is not asked.
  with_env("LIB_SPEC_GH_TOKEN", "  envtoken\n", function()
    local run, calls = runner(0, "ghtoken\n")
    local tok, src = github.token({ env_var = "LIB_SPEC_GH_TOKEN", runner = run })
    eq(tok, "envtoken", "github.token: the named env var wins (trimmed)")
    eq(src, "env:LIB_SPEC_GH_TOKEN", "github.token: ... and is named as the source")
    eq(#calls, 0, "github.token: gh is not asked when the env var is set")
  end)

  -- Unset or empty env var: gh fallback.
  with_env("LIB_SPEC_GH_TOKEN", "", function()
    local run, calls = runner(0, "ghtoken\n")
    local tok, src = github.token({ env_var = "LIB_SPEC_GH_TOKEN", runner = run, timeout_ms = 42 })
    eq(tok, "ghtoken", "github.token: an empty env var falls back to gh")
    eq(src, "gh", "github.token: ... source gh")
    deq(calls[1].argv, { "gh", "auth", "token" }, "github.token: gh auth token argv")
    eq(calls[1].opts.timeout_ms, 42, "github.token: timeout passed to the runner")
  end)

  -- GITHUB_TOKEN is ignored: not read, and stripped from gh's environment.
  with_env("GITHUB_TOKEN", "broad-actions-token", function()
    local run, calls = runner(0, "ghtoken\n")
    local tok = github.token({ runner = run })
    eq(tok, "ghtoken", "github.token: GITHUB_TOKEN is not read without being named")
    eq(calls[1].opts.env.GITHUB_TOKEN, nil, "github.token: GITHUB_TOKEN is stripped from gh's env")
    ok(
      calls[1].opts.env.PATH or calls[1].opts.env.Path,
      "github.token: ... the rest of the env stays"
    )

    local tok2, src2 = github.token({ env_var = "GITHUB_TOKEN", runner = run })
    eq(tok2, "broad-actions-token", "github.token: GITHUB_TOKEN only when the caller names it")
    eq(src2, "env:GITHUB_TOKEN", "github.token: ... source named")
  end)

  -- Windows: names are case-insensitive and gh reads any spelling; pinned
  -- that `environ()` uppercases them, so `Github_Token` goes too.
  if require("lib.nvim.cross.platform.is_windows")() then
    with_env("GITHUB_TOKEN", nil, function()
      with_env("Github_Token", "mixed-case-token", function()
        local run, calls = runner(0, "ghtoken\n")
        github.token({ runner = run })
        for name in pairs(calls[1].opts.env) do
          ok(name:upper() ~= "GITHUB_TOKEN", "github.token: stripped in any case: " .. name)
        end
      end)
    end)
  end

  -- No token anywhere: nil plus a reason that never carries stdout.
  with_env("LIB_SPEC_GH_TOKEN", nil, function()
    local run = runner(1, "partial-secret", "not logged in\nmore")
    local tok, reason = github.token({ env_var = "LIB_SPEC_GH_TOKEN", runner = run })
    eq(tok, nil, "github.token: nil when neither source has a token")
    eq(
      reason,
      "$LIB_SPEC_GH_TOKEN is not set; `gh auth token` failed (exit 1): not logged in",
      "github.token: the reason names both sources"
    )
    ok(not reason:find("partial-secret", 1, true), "github.token: stdout never reaches the reason")

    local _, reason2 = github.token({ runner = runner(0, "  \n") })
    eq(reason2, "`gh auth token` printed no token", "github.token: empty gh output is no token")
  end)

  -- The default runner: a `wait` that answers nil (seen when `gh auth token` hung) is a timeout
  -- with a reason, not "attempt to index local 'obj'"; the process is killed, not left running.
  with_env("LIB_SPEC_GH_TOKEN", nil, function()
    local killed
    local orig_system = vim.system
    vim.system = function()
      return {
        wait = function()
          return nil
        end,
        kill = function(_, signal)
          killed = signal or true
        end,
      }
    end
    local success, tok, reason = pcall(github.token, { timeout_ms = 5 })
    vim.system = orig_system
    ok(success, "github.token: a nil wait does not throw: " .. tostring(tok))
    eq(tok, nil, "github.token: no token when gh never answered")
    eq(
      reason,
      "`gh auth token` failed (exit 124): no answer within 5 ms",
      "github.token: a nil wait reads as a timeout"
    )
    ok(killed ~= nil, "github.token: the hanging gh is killed")
  end)
end
