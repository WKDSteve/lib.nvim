-- TESTS/git_commit_ref_spec.lua — lib.nvim.git.commit_ref: parse/token_at by
-- form, resolve_async against real temp repositories (bare hash, repo@hash,
-- unknown repo, missing and ambiguous commit, SSH and HTTPS remotes),
-- fetch_async and lines_async.

return function(H)
  local dir0 = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
  local F = dofile(dir0 .. "git_fixture.lua")(H)
  local ref = require("lib.nvim.git.commit_ref")

  local function same(got, want, msg)
    H.ok(vim.deep_equal(got, want), msg .. " (got " .. vim.inspect(got) .. ")")
  end

  ---@param fn fun(done: fun(...))
  local function await(fn)
    local out, finished = nil, false
    fn(function(...)
      out, finished = { n = select("#", ...), ... }, true
    end)
    vim.wait(10000, function()
      return finished
    end, 10)
    H.ok(finished, "await: the callback ran")
    return unpack(out or {}, 1, out and out.n or 0)
  end

  -- ── parse: the form only ─────────────────────────────────────────────────
  same(ref.parse("a02ddae"), { sha = "a02ddae" }, "parse: a bare short hash")
  local full = "0123456789abcdef0123456789abcdef01234567"
  same(ref.parse(full), { sha = full }, "parse: a full hash")
  H.eq(ref.parse("deadbeef"), nil, "parse: a hex WORD (no digit) is not a hash")
  H.eq(ref.parse("1234567"), nil, "parse: digits only is a number, not a hash")
  H.eq(ref.parse("a02dda"), nil, "parse: 6 characters are too short")
  H.eq(ref.parse(full .. "a"), nil, "parse: 41 characters are too long")
  H.eq(ref.parse("feature"), nil, "parse: an ordinary word")
  same(
    ref.parse("tasks.nvim@a02ddae"),
    { repo = "tasks.nvim", sha = "a02ddae" },
    "parse: repo@hash"
  )
  same(
    ref.parse("lib.nvim@1234567"),
    { repo = "lib.nvim", sha = "1234567" },
    "parse: behind repo@ an all-digit hash is explicit enough"
  )
  same(
    ref.parse("lib.nvim@a02ddae..b13eeaf"),
    { repo = "lib.nvim", sha = "a02ddae", to = "b13eeaf" },
    "parse: repo@a..b is its first commit, `to` keeps the second"
  )
  H.eq(ref.parse("lib.nvim@zzzzzzz"), nil, "parse: repo@ with a non-hex tail")

  -- ── token_at: inside a line ──────────────────────────────────────────────
  local line = "fixed in tasks.nvim@a02ddae, see 9fceb02."
  local tok = ref.token_at(line, 15)
  H.eq(tok and tok.repo, "tasks.nvim", "token_at: the repo@ form under the cursor")
  H.eq(
    tok and line:sub(tok.first, tok.last),
    "tasks.nvim@a02ddae",
    "token_at: range excludes the comma"
  )
  tok = ref.token_at(line, 38)
  H.eq(tok and tok.sha, "9fceb02", "token_at: a bare hash before a full stop")
  H.eq(tok and line:sub(tok.first, tok.last), "9fceb02", "token_at: range excludes the full stop")
  H.eq(ref.token_at(line, 3), nil, "token_at: a plain word")
  H.eq(ref.token_at(line, #line + 5), nil, "token_at: past the end")

  -- ── resolve_async ────────────────────────────────────────────────────────
  local repos = F.tmpdir("-repos")
  local proj = repos .. "/proj.nvim"
  vim.fn.mkdir(proj, "p")
  F.git(proj, { "init", "-q", "-b", "main" })
  F.write(proj .. "/a.txt", "one\n")
  local sha1 = F.commit(proj, "first commit\n\nbody line\n")
  F.write(proj .. "/a.txt", "two\n")
  F.write(proj .. "/b.txt", "bee\n")
  local sha2 = F.commit(proj, "second commit\n")
  F.git(proj, { "remote", "add", "origin", "https://github.com/WKDSteve/proj.nvim.git" })

  local opts = { roots = { repos }, dir = proj }

  local r = await(function(done)
    ref.resolve_async({ sha = sha1:sub(1, 8) }, opts, done)
  end)
  H.eq(r.status, "local", "resolve: a bare hash resolves in the buffer's repo")
  H.eq(r.full, sha1, "resolve: ...to the full hash")
  H.eq(
    r.url,
    "https://github.com/WKDSteve/proj.nvim/commit/" .. sha1,
    "resolve: ...with the web URL from an https remote"
  )

  r = await(function(done)
    ref.resolve_async(
      { repo = "proj.nvim", sha = sha2:sub(1, 9) },
      { roots = { repos }, dir = repos },
      done
    )
  end)
  H.eq(r.status, "local", "resolve: repo@hash finds the repo by name, wherever the buffer is")
  H.eq(r.full, sha2, "resolve: repo@hash full hash")

  r = await(function(done)
    ref.resolve_async({ repo = "nope.nvim", sha = sha2:sub(1, 9) }, opts, done)
  end)
  H.eq(r.status, "no_repo", "resolve: an unknown repo")

  r = await(function(done)
    ref.resolve_async(
      { sha = sha2:sub(1, 9) },
      { roots = { repos }, dir = F.tmpdir("-plain") },
      done
    )
  end)
  H.ok(
    r.status == "no_repo" or r.status == "local" or r.status == "missing",
    "resolve: a dir outside any repo falls back to the cwd"
  )

  r = await(function(done)
    ref.resolve_async(
      { sha = "abcdef0123" },
      { roots = { repos }, dir = proj, cache = false },
      done
    )
  end)
  H.eq(r.status, "missing", "resolve: a hash the repo does not have")

  -- SSH remote and an unknown host
  F.git(proj, { "remote", "set-url", "origin", "git@gitlab.com:grp/sub/proj.nvim.git" })
  ref.clear_cache()
  r = await(function(done)
    ref.resolve_async({ sha = sha1:sub(1, 8) }, opts, done)
  end)
  H.eq(
    r.url,
    "https://gitlab.com/grp/sub/proj.nvim/-/commit/" .. sha1,
    "resolve: an SSH remote on gitlab"
  )
  F.git(proj, { "remote", "set-url", "origin", "git@git.example.invalid:o/r.git" })
  ref.clear_cache()
  r = await(function(done)
    ref.resolve_async({ sha = sha1:sub(1, 8) }, opts, done)
  end)
  H.eq(r.status, "local", "resolve: an unknown host still resolves the commit")
  H.eq(r.url, nil, "resolve: ...without a URL, and without an error")
  r = await(function(done)
    ref.resolve_async(
      { sha = sha1:sub(1, 8) },
      vim.tbl_extend(
        "force",
        opts,
        { hosts = { ["git.example.invalid"] = "github" }, cache = false }
      ),
      done
    )
  end)
  H.eq(r.url, "https://git.example.invalid/o/r/commit/" .. sha1, "resolve: a host from `hosts`")

  -- cache: a known commit is not looked up twice
  ref.clear_cache()
  await(function(done)
    ref.resolve_async({ repo = "proj.nvim", sha = sha1:sub(1, 8) }, opts, done)
  end)
  local broken = vim.tbl_extend("force", opts, { git_cmd = "git-that-does-not-exist" })
  r = await(function(done)
    ref.resolve_async({ repo = "proj.nvim", sha = sha1:sub(1, 8) }, broken, done)
  end)
  H.eq(r.status, "local", "resolve: a known commit comes from the cache, git is not asked again")

  -- ── ambiguous: two commits that share a short prefix ─────────────────────
  local amb = F.init("-amb")
  local stream = {}
  for i = 1, 1800 do
    stream[#stream + 1] = ("commit refs/heads/main\nmark :%d\ncommitter t <t@e.invalid> %d +0000\ndata 2\n%d\n"):format(
      i,
      1700000000 + i,
      i % 10
    )
    if i > 1 then
      stream[#stream + 1] = ("from :%d\n"):format(i - 1)
    end
    stream[#stream + 1] = "\n"
  end
  local fi = vim
    .system({ "git", "-C", amb, "fast-import", "--quiet" }, { stdin = table.concat(stream), text = true })
    :wait()
  H.eq(fi.code, 0, "fixture: fast-import wrote the commits: " .. (fi.stderr or ""))
  local seen, prefix = {}, nil
  local list = F.git(amb, { "rev-list", "main" })
  for h in list:gmatch("%x+") do
    local p = h:sub(1, 4)
    if seen[p] then
      prefix = p
      break
    end
    seen[p] = true
  end
  H.ok(prefix ~= nil, "fixture: two commits share a four-digit prefix")
  if prefix then
    r = await(function(done)
      ref.resolve_async({ sha = prefix }, { dir = amb, cache = false }, done)
    end)
    H.eq(r.status, "ambiguous", "resolve: a prefix that two commits share")
  end
  H.eq(
    ref.is_ambiguous("error: short object ID abcd is ambiguous"),
    true,
    "is_ambiguous: git's own wording"
  )
  H.eq(ref.is_ambiguous("fatal: Needed a single revision"), false, "is_ambiguous: another failure")

  -- caller-built tables are validated: nothing reaches git or the file system
  r = await(function(done)
    ref.resolve_async({ sha = "--output=x" }, opts, done)
  end)
  H.eq(r.status, "missing", "resolve: a sha that is no hash is refused")
  r = await(function(done)
    ref.resolve_async({ repo = "../proj.nvim", sha = sha1:sub(1, 8) }, opts, done)
  end)
  H.eq(r.status, "no_repo", "resolve: a repo name with a path in it is refused")
  local fok, fwhy = await(function(done)
    ref.fetch_async({ dir = proj, sha = "-x" }, nil, done)
  end)
  H.eq(fok, false, "fetch: a sha that is no hash is refused")
  H.eq(fwhy, "not a hash", "fetch: ...with its reason")

  -- url_async: a missing commit is linked as written
  F.git(proj, { "remote", "set-url", "origin", "https://github.com/WKDSteve/proj.nvim.git" })
  local url = await(function(done)
    ref.url_async({ dir = proj, sha = "abcdef0123", status = "missing" }, opts, done)
  end)
  H.eq(
    url,
    "https://github.com/WKDSteve/proj.nvim/commit/abcdef0123",
    "url_async: a missing commit"
  )

  -- ── lines_async ──────────────────────────────────────────────────────────
  r = await(function(done)
    ref.resolve_async(
      { sha = sha1:sub(1, 8) },
      vim.tbl_extend("force", opts, { cache = false }),
      done
    )
  end)
  local lines, err = await(function(done)
    ref.lines_async(r, nil, done)
  end)
  H.eq(err, nil, "lines: no error")
  H.eq(lines and lines[1], "commit " .. sha1, "lines: the first line names the commit")
  H.ok(table.concat(lines or {}, "\n"):find("first commit", 1, true) ~= nil, "lines: the subject")
  H.ok(
    table.concat(lines or {}, "\n"):find("a.txt", 1, true) ~= nil,
    "lines: the stat names the file"
  )
  H.ok(table.concat(lines or {}, "\n"):find("+one", 1, true) == nil, "lines: no patch by default")
  lines = await(function(done)
    ref.lines_async(r, { patch = true }, done)
  end)
  H.ok(
    table.concat(lines or {}, "\n"):find("+one", 1, true) ~= nil,
    "lines: patch = true shows the diff"
  )
  local _, why = await(function(done)
    ref.lines_async({ status = "missing", sha = "x" }, nil, done)
  end)
  H.ok(why ~= nil, "lines: a commit that is not local gives an error")

  -- ── fetch_async: a commit that exists only in another clone ──────────────
  local origin = F.init("-origin")
  F.write(origin .. "/f.txt", "x\n")
  local o1 = F.commit(origin, "origin one\n")
  local clone = F.tmpdir("-clone")
  F.git(clone, { "init", "-q", "-b", "main" })
  F.git(clone, { "remote", "add", "origin", origin })
  F.git(origin, { "config", "uploadpack.allowAnySHA1InWant", "true" })
  r = await(function(done)
    ref.resolve_async({ sha = o1:sub(1, 8) }, { dir = clone, cache = false }, done)
  end)
  H.eq(r.status, "missing", "fetch: the clone does not have the commit yet")
  local ok, ferr = await(function(done)
    ref.fetch_async(r, { remote = "origin" }, done)
  end)
  H.ok(ok, "fetch: a short hash fetches the remote's branches: " .. tostring(ferr))
  r = await(function(done)
    ref.resolve_async({ sha = o1:sub(1, 8) }, { dir = clone, cache = false }, done)
  end)
  H.eq(r.status, "local", "fetch: the commit is local afterwards")
  -- a full hash is fetched by itself, also when no branch of the remote points at it
  F.write(origin .. "/g.txt", "y\n")
  local o2 = F.commit(origin, "origin two\n")
  F.git(origin, { "checkout", "-q", "--detach", "HEAD" })
  F.git(origin, { "branch", "-q", "-f", "main", o1 })
  r = await(function(done)
    ref.resolve_async({ sha = o2 }, { dir = clone, cache = false }, done)
  end)
  H.eq(r.status, "missing", "fetch: the second commit is not in the clone")
  ok, ferr = await(function(done)
    ref.fetch_async(r, { remote = "origin" }, done)
  end)
  H.ok(ok, "fetch: a full hash is fetched by itself: " .. tostring(ferr))
  r = await(function(done)
    ref.resolve_async({ sha = o2 }, { dir = clone, cache = false }, done)
  end)
  H.eq(r.status, "local", "fetch: ...and is local afterwards")
  ok, ferr = await(function(done)
    ref.fetch_async(
      { dir = clone, sha = "0123456789abcdef0123456789abcdef01234567" },
      { remote = "origin" },
      done
    )
  end)
  H.eq(ok, false, "fetch: a hash the remote does not have fails")
  H.ok(type(ferr) == "string" and ferr ~= "", "fetch: ...with a reason")

  F.cleanup()
end
