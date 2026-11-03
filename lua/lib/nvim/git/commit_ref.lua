---@brief [[
--- lib.nvim.git.commit_ref -- turn a commit reference in text into a commit.
---
--- A reference is a bare hash (7 to 40 hex digits) or `repo@hash`, the form of
--- the `commits:` fields and notes of the task vaults. `repo@hash1..hash2` is
--- accepted too: it resolves as its FIRST commit (`to` keeps the second hash,
--- the caller decides what a range means).
---
--- Three steps, each usable alone:
---
---   * `parse` / `token_at`: by form only, no git, cheap (safe in a hover trigger).
---   * `resolve_async`: repository directory, full hash, status, web URL.
---   * `fetch_async` / `lines_async`: fetch a missing commit, render one.
---
--- Nothing here blocks the editor: every git call runs through `git.run_async`.
---@brief ]]

local git = require("lib.nvim.git")
local remote = require("lib.nvim.git.remote")

local M = {}

---@class Lib.Git.CommitRef
---@field sha string The hash as written (7 to 40 hex digits).
---@field repo? string Repository name of the `repo@` form.
---@field to? string Second hash of a `repo@a..b` range.

---@class Lib.Git.CommitRefToken: Lib.Git.CommitRef
---@field first integer 1-based byte column where the reference starts.
---@field last integer 1-based byte column where it ends (inclusive).

---@alias Lib.Git.CommitRefStatus "local"|"missing"|"ambiguous"|"no_repo"

---@class Lib.Git.CommitRefResolved: Lib.Git.CommitRef
---@field status Lib.Git.CommitRefStatus
---@field dir? string Repository work-tree (absent for `no_repo`).
---@field full? string Full hash (only `local`).
---@field url? string Web URL of the commit (host known, remote present).
---@field remote? string Remote the URL was built from.
---@field err? string Why it did not resolve.

---@class Lib.Git.CommitRefOpts
---@field dir? string Directory of the buffer (repository of a bare hash); falls back to the cwd.
---@field roots? string[] Where `repo@` looks for `<root>/<repo>`; default `$REPOS_DIR` and `$REPOS_DIR/repos`.
---@field hosts? table<string, "github"|"gitlab"|"codeberg"> Extra hosts for the web URL (see `remote.host_kind`).
---@field remote? string Remote name for URL and fetch; default `origin`.
---@field timeout_ms? integer Per git call; default 5000 (fetch: 60000).
---@field cache? boolean `false` skips the per-hash cache.
---@field git_cmd? string

local MIN_LEN, MAX_LEN = 7, 40
-- `missing` is cached briefly: a fetch or a pull makes it local.
local MISSING_TTL_NS = 30 * 1e9

local cache = {} ---@type table<string, { at: integer, value: Lib.Git.CommitRefResolved }>

--- A bare hash that is a hash, not a word: 7 to 40 hex digits with at least one
--- digit and one letter (`deadbeef` and `1234567` are never taken).
---@param s string
---@return boolean
local function bare_hash(s)
  return #s >= MIN_LEN
    and #s <= MAX_LEN
    and s:match("^%x+$") ~= nil
    and s:find("%d") ~= nil
    and s:find("%a") ~= nil
end

--- Behind `repo@` the form is explicit, so all-digit and all-letter hashes pass.
---@param s string
---@return boolean
local function tagged_hash(s)
  return #s >= MIN_LEN and #s <= MAX_LEN and s:match("^%x+$") ~= nil
end

--- Read a reference out of text by form alone.
---@param text string One token, no surrounding blanks or punctuation.
---@return Lib.Git.CommitRef|nil
function M.parse(text)
  if type(text) ~= "string" then
    return nil
  end
  local repo, rest = text:match("^([%w][%w._-]*)@(.+)$")
  if repo then
    local from, to = rest:match("^(%x+)%.%.(%x+)$")
    if from and tagged_hash(from) and tagged_hash(to) then
      return { repo = repo, sha = from, to = to }
    end
    if tagged_hash(rest) then
      return { repo = repo, sha = rest }
    end
    return nil
  end
  if bare_hash(text) then
    return { sha = text }
  end
  return nil
end

--- The reference under a column of a line.
---@param line string
---@param col integer 1-based byte column
---@return Lib.Git.CommitRefToken|nil
function M.token_at(line, col)
  if type(line) ~= "string" then
    return nil
  end
  local pos = 1
  while true do
    local s, e = line:find("[%w@._-]+", pos)
    if not s then
      return nil
    end
    if s > col then
      return nil
    end
    -- Trailing sentence punctuation is not part of the reference.
    local token = line:sub(s, e)
    local trimmed = token:gsub("[._-]+$", "")
    local lead = #token:match("^[._-]*")
    trimmed = trimmed:sub(lead + 1)
    local first, last = s + lead, s + lead + #trimmed - 1
    if col >= first and col <= last then
      local ref = M.parse(trimmed)
      if ref then
        ---@cast ref Lib.Git.CommitRefToken
        ref.first, ref.last = first, last
        return ref
      end
      return nil
    end
    pos = e + 1
  end
end

---@param opts Lib.Git.CommitRefOpts
---@return string[]
local function roots_of(opts)
  if opts.roots then
    return opts.roots
  end
  local base = vim.env.REPOS_DIR
  if not base or base == "" then
    return {}
  end
  return { base, vim.fs.joinpath(base, "repos") }
end

---@param repo string
---@param opts Lib.Git.CommitRefOpts
---@return string|nil
local function find_repo(repo, opts)
  for _, root in ipairs(roots_of(opts)) do
    local dir = vim.fs.joinpath(root, repo)
    if vim.uv.fs_stat(vim.fs.joinpath(dir, ".git")) then
      return dir
    end
  end
  return nil
end

---@param opts Lib.Git.CommitRefOpts
---@param ropts? table
---@return table
local function run_opts(opts, ropts)
  return vim.tbl_extend(
    "force",
    { timeout_ms = opts.timeout_ms or 5000, read_only = true },
    ropts or {}
  )
end

--- Repository of a bare hash: the buffer's, then the cwd.
---@param opts Lib.Git.CommitRefOpts
---@param on_dir fun(dir: string|nil)
local function buffer_repo(opts, on_dir)
  local candidates = {}
  if opts.dir and opts.dir ~= "" then
    candidates[#candidates + 1] = opts.dir
  end
  candidates[#candidates + 1] = vim.uv.cwd()
  local function try(i)
    local dir = candidates[i]
    if not dir then
      return on_dir(nil)
    end
    git.run_async({ "rev-parse", "--show-toplevel" }, run_opts(opts, { dir = dir }), function(res)
      local top = res.ok and vim.trim(res.stdout) or ""
      if top ~= "" then
        on_dir(top)
      else
        try(i + 1)
      end
    end, opts.git_cmd)
  end
  try(1)
end

--- Whether a failed `rev-parse` said "more than one object matches".
---@param stderr string|nil
---@return boolean
function M.is_ambiguous(stderr)
  return type(stderr) == "string" and stderr:lower():find("ambiguous", 1, true) ~= nil
end

---@param ref Lib.Git.CommitRef
---@param dir string
---@param opts Lib.Git.CommitRefOpts
---@return string
local function cache_key(ref, dir, opts)
  return table.concat({ dir, ref.sha:lower(), opts.remote or "origin" }, "\0")
end

--- Web URL of a commit from the repository's remote.
---@param dir string
---@param full string
---@param opts Lib.Git.CommitRefOpts
---@param on_done fun(url: string|nil, remote_name: string|nil)
local function web_url(dir, full, opts, on_done)
  local name = opts.remote or "origin"
  git.run_async({ "remote", "get-url", "--", name }, run_opts(opts, { dir = dir }), function(res)
    if not res.ok then
      return on_done(nil, nil)
    end
    local parsed = remote.parse_remote(vim.trim(res.stdout))
    local kind = parsed and remote.host_kind(parsed.host, opts.hosts)
    if not (parsed and kind) then
      return on_done(nil, name)
    end
    on_done(remote.commit_url(kind, parsed, full), name)
  end, opts.git_cmd)
end

--- Resolve a reference to a repository and a commit. Never blocks; `on_done` runs
--- on the main loop, once.
---@param ref Lib.Git.CommitRef
---@param opts? Lib.Git.CommitRefOpts
---@param on_done fun(res: Lib.Git.CommitRefResolved)
function M.resolve_async(ref, opts, on_done)
  opts = opts or {}
  -- `parse` guarantees these; a caller that builds the table itself must not smuggle an option (`-x`) or a path
  -- (`../x`) into a git argument or a directory name.
  if type(ref) ~= "table" or type(ref.sha) ~= "string" or not ref.sha:match("^%x+$") then
    return on_done({
      sha = type(ref) == "table" and tostring(ref.sha) or "",
      status = "missing",
      err = "not a hash",
    })
  end
  if ref.repo ~= nil and not (type(ref.repo) == "string" and ref.repo:match("^%w[%w._-]*$")) then
    return on_done({
      sha = ref.sha,
      repo = tostring(ref.repo),
      status = "no_repo",
      err = "not a repository name",
    })
  end
  local function finish(extra)
    on_done(vim.tbl_extend("force", { sha = ref.sha, repo = ref.repo, to = ref.to }, extra))
  end

  local function with_dir(dir)
    if not dir then
      return finish({
        status = "no_repo",
        err = ref.repo and ("repository not found: " .. ref.repo) or "not in a repository",
      })
    end
    local key = cache_key(ref, dir, opts)
    local hit = opts.cache ~= false and cache[key]
    if hit and (hit.value.status == "local" or vim.uv.hrtime() - hit.at < MISSING_TTL_NS) then
      return on_done(vim.deepcopy(hit.value))
    end
    git.run_async(
      { "rev-parse", "--verify", "--quiet", ref.sha .. "^{commit}" },
      run_opts(opts, { dir = dir, no_lazy_fetch = true }),
      function(res)
        ---@type Lib.Git.CommitRefResolved
        local out = { sha = ref.sha, repo = ref.repo, to = ref.to, dir = dir, status = "missing" }
        local full = res.ok and vim.trim(res.stdout) or ""
        if full == "" then
          -- `--quiet` hides git's reason; ask again without it only to tell ambiguous from missing.
          git.run_async(
            { "rev-parse", "--verify", ref.sha .. "^{commit}" },
            run_opts(opts, { dir = dir, no_lazy_fetch = true }),
            function(again)
              if M.is_ambiguous(again.stderr) then
                out.status, out.err = "ambiguous", vim.trim(again.stderr or "")
              else
                out.err = "commit not in " .. vim.fs.basename(dir)
              end
              if opts.cache ~= false then
                cache[key] = { at = vim.uv.hrtime(), value = vim.deepcopy(out) }
              end
              on_done(out)
            end,
            opts.git_cmd
          )
          return
        end
        out.status, out.full = "local", full
        web_url(dir, full, opts, function(url, name)
          out.url, out.remote = url, name
          if opts.cache ~= false then
            cache[key] = { at = vim.uv.hrtime(), value = vim.deepcopy(out) }
          end
          on_done(out)
        end)
      end,
      opts.git_cmd
    )
  end

  if ref.repo then
    with_dir(find_repo(ref.repo, opts))
  else
    buffer_repo(opts, with_dir)
  end
end

--- Web URL for a `missing` commit: there is no local object to expand the hash, so it is linked as
--- written (GitHub, GitLab and Codeberg expand a short hash themselves). `nil` without a known host.
---@param res Lib.Git.CommitRefResolved
---@param opts? Lib.Git.CommitRefOpts
---@param on_done fun(url: string|nil)
function M.url_async(res, opts, on_done)
  opts = opts or {}
  if res.url then
    return on_done(res.url)
  end
  if not res.dir or not res.sha:match("^%x+$") then
    return on_done(nil)
  end
  web_url(res.dir, res.sha, opts, function(url)
    on_done(url)
  end)
end

--- Fetch a missing commit from the remote, only on request. A full hash is fetched by
--- itself (`git fetch <remote> <hash>`; a server may refuse that). A short hash cannot be
--- named to a server, so the remote's branches are fetched instead (`git fetch <remote>`);
--- the caller resolves again and the commit is simply still `missing` when no branch has it.
---@param res Lib.Git.CommitRefResolved A `missing` resolution.
---@param opts? Lib.Git.CommitRefOpts
---@param on_done fun(ok: boolean, err: string|nil) The cache entry is dropped on success.
function M.fetch_async(res, opts, on_done)
  opts = opts or {}
  if not res.dir then
    return on_done(false, "no repository")
  end
  local name = opts.remote or "origin"
  if type(res.sha) ~= "string" or not res.sha:match("^%x+$") then
    return on_done(false, "not a hash")
  end
  local args = { "fetch", "--no-tags", "--quiet", "--", name }
  if #res.sha == 40 and res.sha:match("^%x+$") then
    args[#args + 1] = res.sha
  end
  git.run_async(args, {
    dir = res.dir,
    timeout_ms = opts.timeout_ms or 60000,
    env = { GIT_TERMINAL_PROMPT = "0" },
  }, function(r)
    if not r.ok then
      local why = r.timed_out and "git fetch timed out" or vim.trim(r.stderr or "")
      return on_done(false, why ~= "" and why or ("git fetch failed (exit code %d)"):format(r.code))
    end
    cache[cache_key(res, res.dir, opts)] = nil
    on_done(true, nil)
  end, opts.git_cmd)
end

--- The lines of a commit: a summary with stat, or (`opts.patch`) the whole `git show`.
---@param res Lib.Git.CommitRefResolved A `local` resolution.
---@param opts? Lib.Git.CommitRefOpts|{ patch?: boolean }
---@param on_done fun(lines: string[]|nil, err: string|nil)
function M.lines_async(res, opts, on_done)
  opts = opts or {}
  if res.status ~= "local" or not res.dir or not res.full then
    return on_done(nil, res.err or "commit is not local")
  end
  local args = { "show", "--no-color", "--no-ext-diff", "--date=short" }
  if opts.patch then
    vim.list_extend(args, { "--format=commit %H%nAuthor: %an <%ae>%nDate:   %ad%n%n%B", res.full })
  else
    vim.list_extend(
      args,
      { "--stat", "--format=commit %H%nAuthor: %an <%ae>%nDate:   %ad%n%n%B", res.full }
    )
  end
  git.run_async(
    args,
    run_opts(opts, {
      dir = res.dir,
      no_lazy_fetch = true,
      max_output_bytes = 8 * 1024 * 1024,
      timeout_ms = opts.timeout_ms or 15000,
    }),
    function(r)
      if not r.ok then
        return on_done(
          nil,
          vim.trim(r.stderr or "") ~= "" and vim.trim(r.stderr) or "git show failed"
        )
      end
      local lines =
        vim.split((r.stdout:gsub("\r\n", "\n"):gsub("\n+$", "")), "\n", { plain = true })
      on_done(lines, nil)
    end,
    opts.git_cmd
  )
end

--- Forget what was resolved (all, or one repository directory).
---@param dir? string
function M.clear_cache(dir)
  if not dir then
    cache = {}
    return
  end
  for key in pairs(cache) do
    if vim.startswith(key, dir .. "\0") then
      cache[key] = nil
    end
  end
end

return M
