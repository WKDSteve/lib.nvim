---@module 'lib.nvim.git'
--- Git utility helpers for Neovim.
---
--- This module provides small, composable helpers around common
--- Git queries that are frequently needed in editor features
--- (autocommands, status integrations, conditional behavior).
---
--- All functions are intentionally side-effect free and rely only
--- on invoking the Git CLI.
---
--- Every function that has no path of its own to act on takes an optional
--- `opts.dir` and then runs as `git -C <dir> ...` instead of against the
--- editor's cwd -- the right default for editor features, wrong for a caller
--- correlating data with a specific repo (a plugin's own checkout, one row of
--- a multi-repo overview, a file's containing repo).

local M = {}

-- =========================================================
-- Internal helpers
-- =========================================================

---@internal
--- Execute a git command (argv, no shell) and return trimmed stdout.
--- Stderr is suppressed to avoid user-facing noise.
---@param argv string[]
---@return string|nil
local function git_system(argv)
  local ok, out = require("lib.nvim.cross.run_argv").run_blocking_captured(argv)
  if not ok or type(out) ~= "string" then
    return nil
  end
  out = vim.trim(out)
  if out == "" then
    return nil
  end
  return out
end

---@internal
--- Build `{ bin, ["--no-optional-locks",] ["-C", dir,] ...args }`. An absent or
--- empty `opts.dir` leaves git to use the cwd.
---
--- `opts` must be a table (or nil). A string there is the pre-`opts.dir`
--- calling convention -- `git_cmd` used to be the first parameter -- and is
--- rejected loudly: quietly ignoring it would run the default `git` where the
--- caller asked for a specific binary.
---
--- `read_only` adds `--no-optional-locks` for a query that can refresh the
--- index (`status`): without it git opportunistically takes `index.lock`,
--- which makes a concurrent `git commit`/`git add` of the user fail with
--- "index.lock exists" whenever an automatic refresh happens to overlap it.
---
--- `opts.no_lazy_fetch` (a `Lib.Git.RunOpts` field) adds `-c protocol.allow=never`
--- and, in `runner_opts`, the environment `GIT_NO_LAZY_FETCH=1` (git 2.44+, the
--- primary lock) and `GIT_ALLOW_PROTOCOL=none` (every git since 2.10): a per-protocol
--- policy in the repository's own config (`protocol.file.allow=always`, which
--- many users set globally since git 2.38.1) beats `protocol.allow`, but not
--- `GIT_ALLOW_PROTOCOL`. Without a usable transport a partial clone's lazy fetch
--- cannot reach its remote -- the object it needs is reported missing instead.
---@param bin string
---@param opts Lib.Git.Opts|nil
---@param args string[]
---@param read_only? boolean
---@return string[]
local function git_argv(bin, opts, args, read_only)
  if opts ~= nil and type(opts) ~= "table" then
    error(
      ("lib.nvim.git: `opts` must be a table like { dir = ... }, got %s -- `git_cmd` is now the last parameter"):format(
        type(opts)
      ),
      3
    )
  end
  local argv = { bin }
  if opts and opts.no_lazy_fetch then
    vim.list_extend(argv, { "-c", "protocol.allow=never" })
  end
  if read_only then
    argv[#argv + 1] = "--no-optional-locks"
  end
  local dir = opts and opts.dir or nil
  if dir and dir ~= "" then
    argv[#argv + 1] = "-C"
    argv[#argv + 1] = dir
  end
  return vim.list_extend(argv, args)
end

-- =========================================================
-- Public API
-- =========================================================

--- Options shared by every function that can target a repo other than the cwd.
---@class Lib.Git.Opts
---@field dir? string Run as `git -C <dir>` instead of against the cwd.
---@field ignored? boolean Also list ignored paths (`git status --ignored`). Only honoured by `status_porcelain`/`status_porcelain_async`; every other function ignores it.

--- Check if the current working directory (or `opts.dir`) is inside a Git work-tree.
---@param opts? Lib.Git.Opts
---@param git_cmd? string Optional git binary (defaults to "git")
---@return boolean
function M.in_git_repo(opts, git_cmd)
  local out = git_system(git_argv(git_cmd or "git", opts, { "rev-parse", "--is-inside-work-tree" }))
  return out == "true"
end

--- Get the absolute path to the repository root.
---@param opts? Lib.Git.Opts
---@param git_cmd? string
---@return string|nil
function M.repo_root(opts, git_cmd)
  return git_system(git_argv(git_cmd or "git", opts, { "rev-parse", "--show-toplevel" }))
end

--- Get the current branch name.
--- Returns nil in detached HEAD state.
---@param opts? Lib.Git.Opts
---@param git_cmd? string
---@return string|nil
function M.current_branch(opts, git_cmd)
  return git_system(git_argv(git_cmd or "git", opts, { "symbolic-ref", "--short", "HEAD" }))
end

--- Check out an existing local branch or other revision (`git checkout
--- <name>`, a real filesystem/index mutation -- unlike every read-only
--- helper above).
---
--- Uses `run_blocking` (not `run_blocking_captured`, which the rest of this
--- module builds on): a failed checkout writes its reason to stderr, and
--- `run_blocking` is the one runner here that actually captures it (see its
--- own doc comment) -- a caller reporting a failed checkout to the user
--- needs git's real reason ("pathspec '<name>' did not match any file(s)
--- known to git", "Your local changes ... would be overwritten"), not the
--- read helpers' bare nil.
---
--- No `--` before `name`: that would tell `git checkout` to treat it as a
--- pathspec (restore a file from the index) instead of a branch -- exactly
--- the opposite of what this function does. A leading `-` is refused
--- outright instead, the same guard `show`'s `rev` argument uses.
---@param name string Branch name or other revision `git checkout` accepts. Must not start with `-`.
---@param opts? Lib.Git.Opts
---@param git_cmd? string
---@return boolean ok
---@return string|nil err Git's own stderr on failure, or the rejection reason for an invalid `name`.
function M.checkout(name, opts, git_cmd)
  if type(name) ~= "string" or name == "" or name:sub(1, 1) == "-" then
    return false, ("git checkout: invalid revision %s"):format(vim.inspect(name))
  end
  local argv = git_argv(git_cmd or "git", opts, { "checkout", name })
  return require("lib.nvim.cross.run_argv").run_blocking(argv)
end

--- Check whether the repository is in a detached HEAD state.
--- `false` outside a repository -- there is no HEAD to be detached.
---@param opts? Lib.Git.Opts
---@param git_cmd? string
---@return boolean
function M.is_detached_head(opts, git_cmd)
  local out = git_system(git_argv(git_cmd or "git", opts, { "symbolic-ref", "-q", "HEAD" }))
  if out ~= nil then
    return false
  end
  -- No output means either a detached HEAD or that the call failed outright
  -- (not a repo, git missing); `git_system` cannot tell the two apart, and a
  -- non-repo is not "detached".
  return M.in_git_repo(opts, git_cmd)
end

--- Check whether the working tree has uncommitted changes.
---@param opts? Lib.Git.Opts
---@param git_cmd? string
---@return boolean
function M.is_dirty(opts, git_cmd)
  local out = git_system(git_argv(git_cmd or "git", opts, { "status", "--porcelain" }, true))
  return out ~= nil
end

--- Check whether the given path is tracked by Git.
---@param path string Absolute path, or relative to `opts.dir`/the cwd.
---@param opts? Lib.Git.Opts
---@param git_cmd? string
---@return boolean
function M.is_tracked(path, opts, git_cmd)
  local out =
    git_system(git_argv(git_cmd or "git", opts, { "ls-files", "--error-unmatch", "--", path }))
  return out ~= nil
end

--- Get the upstream branch of the current branch.
---@param opts? Lib.Git.Opts
---@param git_cmd? string
---@return string|nil
function M.upstream(opts, git_cmd)
  return git_system(
    git_argv(
      git_cmd or "git",
      opts,
      { "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}" }
    )
  )
end

--- Check whether the current branch is ahead or behind its upstream.
---@param opts? Lib.Git.Opts
---@param git_cmd? string
---@return boolean ahead, boolean behind
function M.ahead_behind(opts, git_cmd)
  local out = git_system(
    git_argv(git_cmd or "git", opts, { "rev-list", "--left-right", "--count", "HEAD...@{u}" })
  )
  if not out then
    return false, false
  end
  local left, right = out:match("^(%d+)%s+(%d+)$")
  if not left or not right then
    return false, false
  end
  return tonumber(left) > 0, tonumber(right) > 0
end

--- Get the full hash of HEAD.
---@param opts? Lib.Git.Opts
---@param git_cmd? string
---@return string|nil
function M.head_hash(opts, git_cmd)
  return git_system(git_argv(git_cmd or "git", opts, { "rev-parse", "HEAD" }))
end

--- Get the tree id of HEAD (`git rev-parse HEAD^{tree}`). Unlike the commit
--- hash it survives a message-only amend or a rebase without content change,
--- so it identifies "this exact content" (used by `testing ci verify`).
---@param opts? Lib.Git.Opts
---@param git_cmd? string
---@return string|nil # nil outside a repo or without commits
function M.tree_hash(opts, git_cmd)
  return git_system(git_argv(git_cmd or "git", opts, { "rev-parse", "HEAD^{tree}" }))
end

--- Get the short hash of HEAD.
---@param opts? Lib.Git.Opts
---@param git_cmd? string
---@return string|nil
function M.head_short_hash(opts, git_cmd)
  return git_system(git_argv(git_cmd or "git", opts, { "rev-parse", "--short", "HEAD" }))
end

--- The nearest reachable tag (`git describe --tags`), or the short hash if
--- there is none yet (`--always`) -- "there is a version tag" and "there is
--- no tag" are both answered honestly, neither masquerading as the other.
--- Same command `M.info`'s `version` field runs, split out on its own for a
--- caller that wants only this and not `info`'s other two processes.
---@param opts? Lib.Git.Opts
---@param git_cmd? string
---@return string|nil
function M.describe(opts, git_cmd)
  return git_system(git_argv(git_cmd or "git", opts, { "describe", "--tags", "--always" }))
end

--- One-shot repo identity snapshot for an arbitrary directory. Takes an
--- explicit path (`git -C <dir> ...`) -- a caller correlating data with *a
--- specific plugin's* repo state (`lib.nvim.telemetry`'s `info` field, for
--- one) usually wants a different repo than whatever the editor's own cwd
--- happens to be. (It predates the `opts.dir` option the functions above now
--- share, hence its positional `dir`.)
---@param dir string Absolute or relative path inside the target repo.
---@param git_cmd? string
---@return { branch: string|nil, version: string|nil, commit: string|nil }
function M.info(dir, git_cmd)
  local bin = git_cmd or "git"
  ---@internal
  local function run(args)
    local argv = { bin, "-C", dir }
    for _, a in ipairs(args) do
      argv[#argv + 1] = a
    end
    return git_system(argv)
  end
  return {
    -- `nil` in detached HEAD, same as `current_branch` above.
    branch = run({ "symbolic-ref", "--short", "HEAD" }),
    -- The nearest reachable tag, or the short hash if none exists yet
    -- (`--always`) — "version tag" and "there is no tag" both answered
    -- honestly rather than one masquerading as the other.
    version = run({ "describe", "--tags", "--always" }),
    commit = run({ "rev-parse", "--short", "HEAD" }),
  }
end

--- List the repository's named revisions: local branches, then remote
--- branches, then tags — each group sorted by most recent commit first, and
--- the whole list deduplicated in that order.
---
--- Built for `<Tab>` completion of a "which revision?" argument, which is why
--- the ordering matters more than it looks: `git for-each-ref` defaults to
--- refname order, so a plain listing puts whatever starts with "a" in front
--- of the branch you were on ten seconds ago. `-creatordate` puts the
--- answer the user most likely wants within the first few candidates. It is
--- `creatordate`, not `committerdate`: an *annotated* tag has no committer, so
--- `committerdate` left every annotated tag undated and sorted them all to the
--- bottom of the list; for a branch or a lightweight tag the two are the same.
---
--- Remote branches are offered with their remote prefix (`origin/main`) and
--- local ones without, because that is exactly how git itself accepts them
--- as a revision — no normalization, so every candidate is directly usable.
---
--- Takes an explicit `dir` for the same reason `info` above does: a caller
--- completing a revision for *a particular repository* usually does not mean
--- the editor's cwd.
---@param dir? string Path inside the target repo. Defaults to the cwd.
---@param opts? { branches?: boolean, remotes?: boolean, tags?: boolean, limit?: integer } Which groups to include (all three default to true) and a cap on the total.
---@param git_cmd? string
---@return string[] # Possibly empty — a fresh repo with no commits has no refs, and neither does a non-repo.
function M.refs(dir, opts, git_cmd)
  opts = opts or {}
  local bin = git_cmd or "git"

  ---@param pattern string
  ---@param strip integer How many leading ref path components to drop.
  ---@return string[]
  local function for_each_ref(pattern, strip)
    local argv = { bin }
    if dir and dir ~= "" then
      argv[#argv + 1] = "-C"
      argv[#argv + 1] = dir
    end
    vim.list_extend(argv, {
      "for-each-ref",
      "--sort=-creatordate",
      ("--format=%%(refname:strip=%d)"):format(strip),
      pattern,
    })
    local out = git_system(argv)
    if not out then
      return {}
    end
    return vim.split(out, "\n", { trimempty = true })
  end

  local groups = {}
  if opts.branches ~= false then
    groups[#groups + 1] = for_each_ref("refs/heads/", 2)
  end
  if opts.remotes ~= false then
    -- strip=2 leaves "origin/main", which is what git accepts as a revision;
    -- strip=3 would leave a bare "main" that collides with the local branch.
    groups[#groups + 1] = for_each_ref("refs/remotes/", 2)
  end
  if opts.tags ~= false then
    groups[#groups + 1] = for_each_ref("refs/tags/", 2)
  end

  local out, seen = {}, {}
  for _, group in ipairs(groups) do
    for _, ref in ipairs(group) do
      if not seen[ref] then
        seen[ref] = true
        out[#out + 1] = ref
        if opts.limit and #out >= opts.limit then
          return out
        end
      end
    end
  end
  return out
end

--- One path's entry in a `status_porcelain` map.
---@class Lib.Git.StatusEntry
---@field code string          Two-character XY status (`" M"`, `"A "`, `"??"`, `"UU"`, ...)
---@field orig_path string|nil Source path of a rename/copy, nil for every other entry

--- Repo-root-relative path -> status entry. `git status --porcelain` never
--- honours `status.relativePaths`: paths are always relative to the repository
--- root, whatever directory git was started in.
---@alias Lib.Git.StatusMap table<string, Lib.Git.StatusEntry>

--- Parse `git status --porcelain -z -u` output into a path -> entry map.
---
--- Pure (no process), so it is headless-testable and reusable by a caller that
--- runs git itself. Takes the **NUL-separated** (`-z`) form: without `-z` git
--- C-quotes any path containing a space or a non-ASCII byte (`"a b.txt"`,
--- `"\303\274.txt"`), and undoing that is guesswork; with it, paths arrive raw.
---
--- Handles ordinary XY codes (M/A/D/R/C/U, "??" untracked, "!!" ignored) and
--- rename/copy entries. In `-z` form those are `XY new NUL old NUL` -- the
--- **destination first** -- and are keyed by the new path with the old one in
--- `orig_path`. An `R`/`C` in either column marks a two-path entry.
---@param raw string Output of `git status --porcelain -z`.
---@return Lib.Git.StatusMap
function M.parse_status(raw)
  local result = {} ---@type Lib.Git.StatusMap
  if type(raw) ~= "string" or raw == "" then
    return result
  end

  local fields = vim.split(raw, "\0", { plain = true })
  local i, n = 1, #fields
  while i <= n do
    local entry = fields[i]
    i = i + 1
    if #entry >= 4 and entry:sub(3, 3) == " " then
      local code, path = entry:sub(1, 2), entry:sub(4)
      local x, y = code:sub(1, 1), code:sub(2, 2)
      if x == "R" or x == "C" or y == "R" or y == "C" then
        local orig = fields[i]
        i = i + 1
        result[path] = { code = code, orig_path = (orig and orig ~= "") and orig or nil }
      else
        result[path] = { code = code, orig_path = nil }
      end
    end
  end
  return result
end

---@internal
--- `vim.system` raises when it cannot start the command at all, and raises
--- with level 1, so the reason arrives as `vim/_core/system.lua:324: ENOENT: ...`:
--- Neovim's own source position, noise to the person reading the message.
--- Removes exactly that leading stamp, once -- and only a stamp at the very front that points into
--- Neovim's runtime (`vim/...:N: `, with or without the `.lua` extension: a build that embeds the
--- runtime reports `vim/_core/system:324:`; 0.11 reports the whole path, `.../lua/vim/_system.lua:254: `),
--- so a message without one that merely quotes a `something.lua:12:` from the command is left alone. Only ever
--- applied to a spawn failure (code `-1`); `docs/conventions.md` explains why
--- this is the one place the "no pattern stripping" rule gives way: the stamp
--- is created by Neovim's code, which this library cannot ask to raise with
--- level 0.
---@param msg string
---@return string
local function unstamp(msg)
  local stamp = msg:match("^[^\n]-[/\\]lua[/\\]vim[/\\][%w_/\\.]*:%d+: ")
  -- A `: ` before the end is a sentence that quotes such a path, not a stamp.
  if stamp and not stamp:sub(1, -3):find(": ", 1, true) then
    return msg:sub(#stamp + 1)
  end
  return (msg:gsub("^vim[/\\][%w_/\\.]*:%d+: ", "", 1))
end

---@internal
--- Make a spawn failure look the same from the blocking and the async runner:
--- code `-1`, empty stdout, the reason in stderr without Neovim's position.
--- (`run_async_captured` reports that reason in the stdout slot.)
---@param res Lib.RunArgv.Result
---@return Lib.RunArgv.Result
local function normalize_result(res)
  if res.code == -1 then
    local reason = res.stderr
    if reason == nil or reason == "" then
      reason = res.stdout
    end
    res.stdout = ""
    res.stderr = unstamp(reason or "")
    res.timed_out = false
  end
  return res
end

---@internal
--- Run an argv through `run_argv` and normalise the result.
---@param argv string[]
---@param input string|nil
---@param ropts Lib.RunArgv.Opts
---@return Lib.RunArgv.Result
local function exec(argv, input, ropts)
  return normalize_result(
    require("lib.nvim.cross.run_argv").run_blocking_result(argv, input, ropts)
  )
end

---@internal
--- The outcome of one `run_async_captured` run, as a normalised result. The async
--- runner reports `ok` from the exit code alone, so a process killed by a signal
--- (a `stop()`, the OOM killer: exit code 0 with `signal` 15 or 9 on POSIX) reads
--- as a success; it is turned into a failure here (`code = 128 + signal`),
--- exactly what `run_blocking_result` does for the blocking runner. A spawn
--- failure (code `-1`) gets its reason into `stderr` (`normalize_result`).
---@param ok boolean
---@param stdout string
---@param code integer
---@param stderr string|nil `nil` only on the legacy (pre-`vim.system`) fallback.
---@param signal integer|nil
---@param ropts Lib.RunArgv.Opts|nil Only its `timeout_ms` matters: it is what makes exit code 124 a timeout.
---@return Lib.RunArgv.Result
local function async_result(ok, stdout, code, stderr, signal, ropts)
  signal = signal or 0
  if code == 0 and signal ~= 0 then
    ok, code = false, 128 + signal
  end
  return normalize_result({
    ok = ok,
    code = code,
    signal = signal,
    stdout = stdout,
    stderr = stderr,
    -- killed for the timeout (signal set); a process exiting 124 by itself is not one
    timed_out = ropts ~= nil and ropts.timeout_ms ~= nil and code == 124 and signal ~= 0,
  })
end

---@internal
--- `run_async_captured` for the sync verbs (`fetch`, `pull`, `push`,
--- `rev-parse HEAD`), with the two outcomes `async_result` knows turned into
--- the failures they are -- the very ones `exec_async` already reports for
--- `run_async`:
---  * a process killed by a signal arrives as exit code 0 with `signal` set on
---    POSIX, so `ok` alone would report a `stop()`-killed or OOM-killed `git
---    push` that never finished as a success; it is `ok = false`,
---    `code = 128 + signal` here;
---  * a spawn failure (code `-1`, e.g. `git` not on `$PATH`) delivers its reason
---    in the stdout slot, where "git fetch failed (exit code -1)" would hide
---    it; it is in `stderr` here, without Neovim's own `file:line` stamp.
---@param argv string[]
---@param on_done fun(ok: boolean, stdout: string, code: integer, stderr: string|nil, timed_out: boolean|nil)
---@param input string|nil
---@param ropts Lib.RunArgv.Opts|nil e.g. `{ binary = true }`
---@return { stop: fun() } handle
local function run_sync_async(argv, on_done, input, ropts)
  return require("lib.nvim.cross.run_argv").run_async_captured(
    argv,
    function(ok, stdout, code, stderr, signal)
      local res = async_result(ok, stdout, code, stderr, signal, ropts)
      on_done(res.ok, res.stdout, res.code, res.stderr, res.timed_out)
    end,
    input,
    ropts
  )
end

--- Deadline of one network git process (`fetch`, `pull`, `push`) when the caller
--- passes no `opts.timeout_ms`.
local NET_TIMEOUT_MS = 120000

---@internal
--- Runner options of the network verbs. Neovim has no terminal to type into, so
--- a prompt git raises itself (https credentials, `Username for ...`) would hang
--- the job forever: `GIT_TERMINAL_PROMPT=0` makes git fail instead. Credential
--- helpers are untouched. `opts.env` wins over the default, `opts.timeout_ms`
--- replaces the deadline (`false` = none).
---@param opts Lib.Git.NetOpts|nil
---@return Lib.RunArgv.Opts
local function net_ropts(opts)
  opts = opts or {}
  local ms = opts.timeout_ms
  if ms == nil then
    ms = NET_TIMEOUT_MS
  elseif ms == false then
    ms = nil
  end
  return {
    timeout_ms = ms,
    env = vim.tbl_extend("force", { GIT_TERMINAL_PROMPT = "0" }, opts.env or {}),
  }
end

---@internal
--- The failure text of a network verb: the deadline when it was the cause (git's
--- stderr is empty after the kill, and whatever progress text it left must not
--- hide the reason), else git's own stderr, else the exit code. The deadline reads
--- "git fetch timed out after 120s" (whole seconds), "... after 1.5s" (fractional)
--- and "... after 500 ms" (below one second, where whole seconds would print 0).
---@param verb string
---@param stderr string|nil
---@param code integer
---@param timed_out boolean|nil
---@param ropts Lib.RunArgv.Opts
---@return string
local function net_err(verb, stderr, code, timed_out, ropts)
  if timed_out then
    local ms = ropts.timeout_ms
    if ms < 1000 then
      return ("git %s timed out after %d ms"):format(verb, ms)
    end
    return ("git %s timed out after %gs"):format(verb, ms / 1000)
  end
  if stderr and stderr ~= "" then
    return stderr
  end
  return ("git %s failed (exit code %d)"):format(verb, code)
end

---@internal
--- `run_sync_async` for the readers that only look at stdout (`status`, `show`,
--- `blame`): `on_done(ok, out)` where `out` is stdout on success and, on failure,
--- the reason a spawn failure carries (`""` otherwise, so the caller's generic
--- message is used). A signal-killed run is a failure, never an empty success.
---@param argv string[]
---@param on_done fun(ok: boolean, out: string)
---@param input string|nil
---@param ropts Lib.RunArgv.Opts|nil
---@return { stop: fun() } handle
local function run_out_async(argv, on_done, input, ropts)
  return run_sync_async(argv, function(ok, stdout, code, stderr)
    if ok then
      on_done(true, stdout)
    else
      on_done(false, code == -1 and stderr or "")
    end
  end, input, ropts)
end

---@internal
---@param opts Lib.Git.Opts|nil
---@param bin string
---@return string[]
local function status_argv(opts, bin)
  local args = { "status", "--porcelain", "-z", "-u" }
  if opts and opts.ignored then
    args[#args + 1] = "--ignored"
  end
  return git_argv(bin, opts, args, true)
end

---@internal
---@param ok boolean
---@param out any
---@return Lib.Git.StatusMap|nil map
---@return string|nil err
local function status_result(ok, out)
  if not ok or type(out) ~= "string" then
    -- On a failed call `out` is usually empty (git writes its complaint to
    -- stderr), but a spawn failure (git not on $PATH) puts the reason there.
    return nil, (type(out) == "string" and vim.trim(out) ~= "") and out or "git status failed"
  end
  return M.parse_status(out), nil
end

--- The working tree's status as a path -> entry map (see `parse_status` for the
--- shape and the rename handling).
---
--- Synchronous: the underlying `run_blocking_captured` freezes the UI for the
--- call's duration, and `git status` on a large tree is not instant -- prefer
--- `status_porcelain_async` on any repeated or automatic trigger.
---@param opts? Lib.Git.Opts
---@param git_cmd? string
---@return Lib.Git.StatusMap|nil map  nil only on a git failure (not a repo, git missing); a clean tree is `{}`
---@return string|nil err
function M.status_porcelain(opts, git_cmd)
  local argv = status_argv(opts, git_cmd or "git")
  return status_result(require("lib.nvim.cross.run_argv").run_blocking_captured(argv))
end

--- Async counterpart to `status_porcelain` -- for a tree refresh that fires on
--- every save/focus, where a blocking call adds up.
---@param opts Lib.Git.Opts|nil
---@param on_done fun(map: Lib.Git.StatusMap|nil, err: string|nil) Always invoked via `vim.schedule` -- safe to touch buffers, windows and `vim.fn.*`.
---@param git_cmd? string
---@return { stop: fun() } handle Kills the underlying job; harmless to call after it has finished.
function M.status_porcelain_async(opts, on_done, git_cmd)
  local argv = status_argv(opts, git_cmd or "git")
  return run_out_async(argv, function(ok, out)
    on_done(status_result(ok, out))
  end)
end

--- Get a configured remote's URL.
---@param remote? string Remote name, defaults to "origin".
---@param opts? Lib.Git.Opts `dir` runs as `git -C <dir>` instead of the cwd.
---@param git_cmd? string
---@return string|nil
function M.remote_url(remote, opts, git_cmd)
  -- `--`: a remote name is caller data and must not be readable as an option.
  return git_system(
    git_argv(git_cmd or "git", opts, { "remote", "get-url", "--", remote or "origin" })
  )
end

--- Resolve a path's repository-relative form via `git ls-files --full-name`.
--- Only tracked files resolve (an untracked or ignored path returns nil) --
--- the intended use is "where does this file live inside the repo", and an
--- untracked file has no meaningful answer to that (it also cannot be
--- browsed on the remote, which is this function's original motivation).
---@param path string A basename (resolved relative to `opts.dir`) or an absolute path.
---@param opts? Lib.Git.Opts
---@param git_cmd? string
---@return string|nil
function M.relative_path(path, opts, git_cmd)
  return git_system(git_argv(git_cmd or "git", opts, { "ls-files", "--full-name", "--", path }))
end

--- The current ref for an explicit directory: the branch name, or (detached
--- HEAD) the short commit hash. Two git calls, not three -- prefer this over
--- `info(dir)` when the tag/version field isn't needed (e.g. deciding what
--- to link against for a browse URL), since `info` always pays for a third,
--- unused `git describe --tags --always` call on top.
---@param dir string
---@param git_cmd? string
---@return string|nil
function M.current_ref(dir, git_cmd)
  local bin = git_cmd or "git"
  local branch = git_system({ bin, "-C", dir, "symbolic-ref", "--short", "HEAD" })
  if branch then
    return branch
  end
  return git_system({ bin, "-C", dir, "rev-parse", "--short", "HEAD" })
end

---@internal
---@param path string
---@return boolean
local function is_absolute(path)
  return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil or path:sub(1, 2) == "\\\\"
end

---@internal
--- Build the argv for `git show <rev>:./<path>`.
---
--- `./` makes git resolve `path` against `-C <dir>`/the cwd instead of the
--- repository root (the default of the bare `rev:path` form), so a relative
--- path means the same here as in `blame_porcelain` or `is_tracked`. An
--- absolute path names its own directory, which becomes `-C` -- no extra
--- process to find the repository root.
---
--- `rev` is caller data glued to the front of one argument, so a leading `-`
--- would make git read it as an option (`--output=<file>` writes a file):
--- refused here rather than escaped.
---@param rev string
---@param path string
---@param opts Lib.Git.Opts|nil
---@param bin string
---@return string[]|nil argv nil when the arguments are unusable.
---@return string what `<rev>:<path>` for messages, or the reason when argv is nil.
local function show_argv(rev, path, opts, bin)
  if type(rev) ~= "string" or rev:sub(1, 1) == "-" or rev:find("[%z\r\n]") then
    return nil, ("git show: invalid revision %s"):format(vim.inspect(rev))
  end
  if type(path) ~= "string" or path == "" then
    return nil, ("git show: invalid path %s"):format(vim.inspect(path))
  end

  local where, rel = opts, path
  if is_absolute(path) then
    where, rel = { dir = vim.fs.dirname(path) }, vim.fs.basename(path)
  elseif vim.fn.has("win32") == 1 then
    rel = (rel:gsub("\\", "/"))
  end
  return git_argv(bin, where, { "show", ("%s:./%s"):format(rev, rel) }), ("%s:%s"):format(rev, path)
end

---@internal
---@param ok boolean
---@param out any
---@param what string
---@return string|nil content
---@return string|nil err
local function show_result(ok, out, what)
  if not ok or type(out) ~= "string" then
    -- A failed `git show` writes nothing to stdout, so a non-empty `out` is a
    -- spawn failure's reason (git not on $PATH).
    if type(out) == "string" and out ~= "" then
      return nil, out
    end
    return nil,
      ("git show %s failed (unknown revision, path not in that revision, or not a repository)"):format(
        what
      )
  end
  return out, nil
end

--- The content of a file at a revision -- `git show <rev>:<path>` -- **byte for
--- byte**: a CRLF file keeps its `\r\n`, a binary blob keeps every byte
--- (including `NUL`). An empty file is `""`, which is why the result is not
--- collapsed to `nil` the way the other helpers here collapse empty output.
---
--- `path` is relative to `opts.dir`/the cwd (like `blame_porcelain`), or
--- absolute. `rev` is anything `git show` resolves -- `HEAD~1`, a branch, a tag,
--- a hash -- plus the index: `""` is the staged version and `":1"`/`":2"`/`":3"`
--- are the base/ours/theirs versions of a file in a merge conflict.
---
--- Synchronous (like most of this module); `show_async` for a repeated or
--- interactive trigger.
---@param rev string A revision, `""` for the index, or `":<stage>"`. Must not start with `-`.
---@param path string Relative to `opts.dir`/the cwd, or absolute.
---@param opts? Lib.Git.Opts
---@param git_cmd? string
---@return string|nil content nil on failure (unknown revision, path not in that revision, not a repo)
---@return string|nil err
function M.show(rev, path, opts, git_cmd)
  local argv, what = show_argv(rev, path, opts, git_cmd or "git")
  if not argv then
    return nil, what
  end
  local ok, out =
    require("lib.nvim.cross.run_argv").run_blocking_captured(argv, nil, { binary = true })
  return show_result(ok, out, what)
end

--- Async counterpart to `show`.
---@param rev string
---@param path string
---@param opts Lib.Git.Opts|nil
---@param on_done fun(content: string|nil, err: string|nil) Always invoked via `vim.schedule` -- safe to touch buffers, windows and `vim.fn.*`.
---@param git_cmd? string
---@return { stop: fun() } handle Kills the underlying job; harmless to call after it has finished.
function M.show_async(rev, path, opts, on_done, git_cmd)
  local argv, what = show_argv(rev, path, opts, git_cmd or "git")
  if not argv then
    vim.schedule(function()
      on_done(nil, what)
    end)
    return { stop = function() end }
  end
  return run_out_async(argv, function(ok, out)
    on_done(show_result(ok, out, what))
  end, nil, { binary = true })
end

-- =========================================================
-- Running git, history and tags
-- =========================================================
--
-- Added for consumers that read the history of *other people's* repositories
-- (a plugin manager's clones): they need a timeout, an environment, the exit
-- code and stderr, none of which the helpers above expose. Every function in
-- this section takes `Lib.Git.RunOpts`; apart from `run`/`run_async` (which
-- run whatever they are handed) none of them writes to the repository.

---@internal
--- The pathspec switches, all off. An inherited `GIT_LITERAL_PATHSPECS` would
--- turn the `:(literal)` prefix of `log_argv` into part of the name (and together
--- with another one is a fatal "incompatible global pathspec settings"); an
--- inherited `GIT_NOGLOB_PATHSPECS` would break `opts.pathspecs = true`. A
--- caller's own `opts.env` entry of the same name wins.
local PATHSPEC_ENV = {
  GIT_LITERAL_PATHSPECS = "0",
  GIT_GLOB_PATHSPECS = "0",
  GIT_NOGLOB_PATHSPECS = "0",
  GIT_ICASE_PATHSPECS = "0",
}

---@internal
---@param ropts Lib.RunArgv.Opts
---@return Lib.RunArgv.Opts
local function with_pathspec_env(ropts)
  ropts.env = vim.tbl_extend("keep", ropts.env or {}, PATHSPEC_ENV)
  return ropts
end

---@internal
--- `Lib.Git.RunOpts` -> the `lib.nvim.cross.run_argv` options. `no_lazy_fetch`
--- is sugar for two environment variables (and a `-c` in `git_argv`):
--- `GIT_NO_LAZY_FETCH=1` (git 2.44+) and `GIT_ALLOW_PROTOCOL=none`, which on
--- older git -- and against a `protocol.<name>.allow` in the repository's config
--- -- is what actually keeps a lazy fetch from reaching a transport. An explicit
--- `opts.env` entry of the same name wins over them.
---@param opts Lib.Git.RunOpts|nil
---@return Lib.RunArgv.Opts
local function runner_opts(opts)
  opts = opts or {}
  local env = opts.env
  if opts.no_lazy_fetch then
    env = vim.tbl_extend("force", {
      GIT_NO_LAZY_FETCH = "1",
      GIT_ALLOW_PROTOCOL = "none",
    }, env or {})
  end
  return {
    binary = opts.binary,
    timeout_ms = opts.timeout_ms,
    max_output_bytes = opts.max_output_bytes,
    env = env,
  }
end

---@internal
--- Options for a function that only reads: `--no-optional-locks` (a query must
--- never make the user's own `git add` fail with "index.lock exists") on top of
--- whatever the caller passed.
---@param opts Lib.Git.RunOpts|nil
---@return Lib.Git.RunOpts
local function read_opts(opts)
  return vim.tbl_extend("force", opts or {}, { read_only = true })
end

---@internal
--- The full argv for `M.run`/`M.run_async`.
---@param args any
---@param opts Lib.Git.RunOpts|nil
---@param git_cmd string|nil
---@return string[]
local function run_argv_for(args, opts, git_cmd)
  if type(args) ~= "table" or #args == 0 then
    error('lib.nvim.git.run: `args` must be a non-empty list of strings, e.g. { "log", "-1" }', 3)
  end
  return git_argv(git_cmd or "git", opts, args, opts ~= nil and opts.read_only == true)
end

---@internal
--- Refuse a revision that cannot safely be glued into an argv: one starting
--- with `-` would be read by git as an option (`--output=<file>` writes a
--- file), one with a line break or `NUL` is never a revision.
---@param rev any
---@param what string The git subcommand, for the message.
---@return string|nil err
local function bad_rev(rev, what)
  if type(rev) ~= "string" or rev == "" or rev:sub(1, 1) == "-" or rev:find("[%z\r\n]") then
    return ("git %s: invalid revision %s"):format(what, vim.inspect(rev))
  end
  return nil
end

---@internal
--- Async counterpart of `exec`: `on_done` gets the normalised result.
---@param argv string[]
---@param input string|nil
---@param ropts Lib.RunArgv.Opts
---@param on_done fun(res: Lib.RunArgv.Result)
---@return { stop: fun() }
local function exec_async(argv, input, ropts, on_done)
  return require("lib.nvim.cross.run_argv").run_async_captured(
    argv,
    function(ok, stdout, code, stderr, signal)
      on_done(async_result(ok, stdout, code, stderr, signal, ropts))
    end,
    input,
    ropts
  )
end

---@internal
--- The reason a failed run goes to the user with: a timeout says so, a signal
--- says so, otherwise git's own stderr (also the reason of a spawn failure),
--- otherwise the code.
---@param res Lib.RunArgv.Result
---@param what string e.g. "git log"
---@param opts Lib.Git.RunOpts|nil
---@return string
local function failure_message(res, what, opts)
  if res.timed_out then
    return ("%s timed out after %d ms"):format(what, opts and opts.timeout_ms or 0)
  end
  if
    res.code == require("lib.nvim.cross.run_argv").OUTPUT_LIMIT_CODE
    and opts
    and opts.max_output_bytes
  then
    local why = vim.trim(res.stderr or "")
    return why ~= "" and why or ("%s printed more than max_output_bytes"):format(what)
  end
  if (res.signal or 0) ~= 0 then
    return ("%s was terminated by signal %d"):format(what, res.signal)
  end
  local detail = vim.trim(res.stderr or "")
  if detail ~= "" then
    return detail
  end
  return ("%s failed (exit code %d)"):format(what, res.code)
end

--- Run `git <args>` and report **everything** it did: exit code, both streams
--- and whether it ran into `opts.timeout_ms`. The generic runner the helpers
--- above are too specialised to be -- for a caller that needs a timeout, an
--- environment, git's stderr or the exit code.
---
--- `args` is what comes after `git` (and after `-C <opts.dir>`, which is added
--- for you). Nothing here validates the subcommand: this is the escape hatch,
--- so a caller that must stay read-only restricts the verbs itself.
---
--- Blocks the caller; `run_async` for anything that can take a moment.
---@param args string[] E.g. `{ "log", "-1", "--format=%H" }`.
---@param opts? Lib.Git.RunOpts
---@param git_cmd? string
---@return Lib.Git.RunResult
function M.run(args, opts, git_cmd)
  local argv = run_argv_for(args, opts, git_cmd)
  return exec(argv, opts and opts.input or nil, runner_opts(opts))
end

--- Async counterpart to `run`.
---@param args string[]
---@param opts Lib.Git.RunOpts|nil
---@param on_done fun(result: Lib.Git.RunResult) Always invoked via `vim.schedule` -- safe to touch buffers, windows and `vim.fn.*`.
---@param git_cmd? string
---@return { stop: fun() } handle Kills the underlying job; harmless to call after it has finished.
function M.run_async(args, opts, on_done, git_cmd)
  local argv = run_argv_for(args, opts, git_cmd)
  return exec_async(argv, opts and opts.input or nil, runner_opts(opts), on_done)
end

---@internal
--- Refuse a path that cannot be one: not a string, empty, or with a line break or `NUL` in it. (A leading
--- `-` is harmless: the path always comes after `--`.)
---@param path any
---@param what string The git subcommand, for the message.
---@return string|nil err
local function bad_path(path, what)
  if type(path) ~= "string" or path == "" or path:find("[%z\r\n]") then
    return ("git %s: invalid path %s"):format(what, vim.inspect(path))
  end
  return nil
end

--- Whether a tracked file is marked `skip-worktree`: git then ignores local modifications of it (a config
--- repo that holds a personal or transient file, such as a session).
---
--- `git ls-files -v` tags such a file `S` (`s` when it is also marked assume-unchanged).
---
--- The path is a file name, not a pathspec (`*.vim` is not a glob here), and must name ONE tracked file: a
--- directory is `nil` + an error. In a sparse checkout git marks the files outside the cone `skip-worktree`
--- itself: this reports `true` for them, and clearing the mark takes them back into the work tree.
---@param path string Absolute path, or relative to `opts.dir`/the cwd.
---@param opts? Lib.Git.Opts
---@param git_cmd? string
---@return boolean|nil skipped nil when the state is unknown: the path is not tracked, or git failed
---@return string|nil err
function M.is_skip_worktree(path, opts, git_cmd)
  local bad = bad_path(path, "ls-files")
  if bad then
    return nil, bad
  end
  -- A directory has no single state (`ls-files` would answer for the file inside it, or the first of many).
  local abs = path
  if vim.fn.isabsolutepath(path) ~= 1 then
    abs = vim.fs.joinpath((opts and opts.dir ~= "" and opts.dir) or vim.uv.cwd() or ".", path)
  end
  local lst = vim.uv.fs_lstat(abs)
  if lst and lst.type == "directory" then
    return nil, ("git ls-files: %s is a directory, not a file"):format(path)
  end
  -- literal: `*.vim` or `:(top)x` is a file name here, not a pathspec that answers for the first match
  local res =
    M.run({ "--literal-pathspecs", "ls-files", "-v", "--", path }, read_opts(opts), git_cmd)
  if not res.ok then
    return nil, failure_message(res, "git ls-files", opts)
  end
  local lines = {}
  for line in (res.stdout or ""):gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  if #lines == 0 then
    return nil, ("git ls-files: %s is not tracked"):format(path)
  end
  if #lines > 1 then
    -- a directory: no single state to report
    return nil, ("git ls-files: %s names %d files, not one"):format(path, #lines)
  end
  local tag = lines[1]:sub(1, 1)
  return tag == "S" or tag == "s", nil
end

--- Mark (`on = true`) or unmark (`on = false`) a tracked file `skip-worktree`
--- (`git update-index --[no-]skip-worktree`). A real index mutation.
---@param path string Absolute path, or relative to `opts.dir`/the cwd.
---@param on boolean
---@param opts? Lib.Git.Opts
---@param git_cmd? string
---@return boolean ok
---@return string|nil err Git's own stderr on failure.
function M.set_skip_worktree(path, on, opts, git_cmd)
  local bad = bad_path(path, "update-index")
  if bad then
    return false, bad
  end
  local flag = on and "--skip-worktree" or "--no-skip-worktree"
  local res = M.run({ "update-index", flag, "--", path }, opts, git_cmd)
  if not res.ok then
    return false, failure_message(res, "git update-index", opts)
  end
  return true, nil
end

--- Flip the `skip-worktree` mark of a tracked file.
---@param path string Absolute path, or relative to `opts.dir`/the cwd.
---@param opts? Lib.Git.Opts
---@param git_cmd? string
---@return boolean|nil skipped The state after the toggle; nil when it failed.
---@return string|nil err
function M.toggle_skip_worktree(path, opts, git_cmd)
  local was, err = M.is_skip_worktree(path, opts, git_cmd)
  if was == nil then
    return nil, err
  end
  local ok, set_err = M.set_skip_worktree(path, not was, opts, git_cmd)
  if not ok then
    return nil, set_err
  end
  return not was, nil
end

---@internal
--- Split on `NUL`, keeping empty tokens; a trailing `NUL` does not add one.
---@param raw string
---@return string[]
local function split_nul(raw)
  local out, pos, len = {}, 1, #raw
  while pos <= len do
    local nul = raw:find("\0", pos, true)
    if not nul then
      out[#out + 1] = raw:sub(pos)
      break
    end
    out[#out + 1] = raw:sub(pos, nul - 1)
    pos = nul + 1
  end
  return out
end

---@internal
--- `\r\n` -> `\n` and no trailing whitespace: a commit authored on Windows
--- carries `\r` in its subject and body. The trailing whitespace is cut by
--- scanning back from the end: the obvious `gsub("%s+$", "")` retries at every
--- position of a whitespace run and is quadratic in its length, so one hostile
--- commit with a body of 100 000 spaces would freeze the editor for seconds.
---@param text string
---@return string
local function clean_message(text)
  text = text:gsub("\r\n", "\n")
  local last = #text
  while last > 0 do
    local byte = text:byte(last)
    if byte == 32 or (byte >= 9 and byte <= 13) then
      last = last - 1
    else
      break
    end
  end
  return text:sub(1, last)
end

-- One record per commit: a `RS` marker, ten `NUL`-terminated fields, then (with
-- `name_status`) the `--name-status` entries. `NUL` is the separator on purpose:
-- git's message buffer ends at the first `NUL`, so a commit message can never
-- contain one -- unlike `RS`/`US`, which a hostile repository could put into a
-- subject to forge a second record.
local LOG_FORMAT = "--format=%x1e%H%x00%P%x00%an%x00%ae%x00%at%x00%ct%x00%m%x00%D%x00%s%x00%b%x00"
local LOG_RECORD_MARK = "\30"

---@internal
--- A Unix time from git's output, or nil. A hostile commit can carry a date with
--- hundreds of digits, which `tonumber` turns into `inf`: a value no JSON
--- encoder takes and no date formatter prints.
---@param s any
---@return number|nil
local function finite_time(s)
  local n = tonumber(s)
  if n == nil or n ~= n or n < 0 or n > 253402300799 then
    return nil
  end
  return n
end

--- The `--format=` argument `M.log` passes. Exported so a caller that runs
--- `git log -z` itself and hands the output to `parse_log` cannot drift from it.
M.LOG_FORMAT = LOG_FORMAT

--- Parse the output of the `git log` that `M.log` runs -- the pure half, for a
--- caller that runs git itself. The expected command is
--- `git log -z M.LOG_FORMAT [--name-status --no-renames]`.
---
--- Strict on purpose: the format is fixed, so anything that does not fit
--- (a stray token, a record cut short, a hash that is not 40/64 hex digits)
--- means a different git or a broken pipe, and is an error rather than a
--- guess. A hostile commit message cannot trip it -- see `LOG_FORMAT`.
---@param raw string
---@param opts? { left_right?: boolean, name_status?: boolean } Which flags the log was run with; they decide whether `side` and `files` exist.
---@return Lib.Git.LogEntry[]|nil entries
---@return string|nil err
function M.parse_log(raw, opts)
  if type(raw) ~= "string" then
    return nil, "git log: output is not a string"
  end
  opts = opts or {}
  local tokens = split_nul(raw)
  local n = #tokens
  local entries = {}
  local i = 1
  while i <= n do
    local sha = tokens[i]:match("^" .. LOG_RECORD_MARK .. "(%x+)$")
    if not sha or (#sha ~= 40 and #sha ~= 64) then
      return nil, ("git log: malformed output (token %d is not a commit record)"):format(i)
    end
    -- ten fields and the record terminator (an empty token)
    if i + 10 > n then
      return nil, "git log: truncated output"
    end
    if tokens[i + 10] ~= "" then
      return nil, ("git log: malformed output (record %s is not terminated)"):format(sha:sub(1, 8))
    end

    ---@type Lib.Git.LogEntry
    local entry = {
      sha = sha,
      parents = vim.split(tokens[i + 1], " ", { plain = true, trimempty = true }),
      author = tokens[i + 2],
      email = tokens[i + 3],
      author_time = finite_time(tokens[i + 4]),
      commit_time = finite_time(tokens[i + 5]),
      refs = vim.split(tokens[i + 7], ", ", { plain = true, trimempty = true }),
      subject = clean_message(tokens[i + 8]),
      body = clean_message(tokens[i + 9]),
    }
    if opts.left_right then
      local side = tokens[i + 6]
      entry.side = (side == "<" or side == ">" or side == "-") and side or nil
    end
    i = i + 11

    if opts.name_status then
      local files = {}
      while i <= n do
        -- The first entry of a record carries the blank line git prints between
        -- the message and the file list as a leading "\n".
        local status = tokens[i]:match("^\n?([ACDMRTUXB]%d*)$")
        if not status then
          break
        end
        local kind = status:sub(1, 1)
        if kind == "R" or kind == "C" then
          local old_path, new_path = tokens[i + 1], tokens[i + 2]
          if not new_path then
            return nil, "git log: truncated output"
          end
          files[#files + 1] = { status = status, path = new_path, orig_path = old_path }
          i = i + 3
        else
          local path = tokens[i + 1]
          if not path then
            return nil, "git log: truncated output"
          end
          files[#files + 1] = { status = status, path = path }
          i = i + 2
        end
      end
      entry.files = files
    end

    entries[#entries + 1] = entry
  end
  return entries, nil
end

---@internal
--- A count `git` takes as an integer: whole, not negative, and small enough to
--- print as one (no `inf`, no exponent form).
---@param v any
---@return boolean
local function is_count(v)
  return type(v) == "number" and v >= 0 and v == math.floor(v) and v <= 2 ^ 53
end

---@internal
--- The argv for `M.log`/`M.log_async`.
---@param range string|nil
---@param opts Lib.Git.LogOpts
---@param bin string
---@return string[]|nil argv nil when the arguments are unusable
---@return string|nil err
local function log_argv(range, opts, bin)
  if range ~= nil and range ~= "" then
    local err = bad_rev(range, "log")
    if err then
      return nil, err
    end
  else
    range = nil
  end
  for _, key in ipairs({ "max_count", "skip" }) do
    if opts[key] ~= nil and not is_count(opts[key]) then
      return nil,
        ("git log: `%s` must be a non-negative integer, got %s"):format(key, vim.inspect(opts[key]))
    end
  end

  -- `--encoding` and `--root` pin two things the user's config could change
  -- (`i18n.logOutputEncoding`, `log.showRoot`) and break the result.
  local args = { "log", "-z", "--no-color", "--no-show-signature", "--encoding=UTF-8", LOG_FORMAT }
  if opts.name_status then
    -- `--no-renames` also keeps this working in a blobless clone: rename
    -- detection needs file contents, and a clone without them fails halfway
    -- through the output. `-O/dev/null` pins the order file: `diff.orderFile`
    -- may name a file that does not exist from this repository (a relative path
    -- valid in another one, a hostile config), and git then fails the whole log;
    -- `-c diff.orderFile=` does not neutralise it.
    vim.list_extend(args, { "--name-status", "--no-renames", "--root", "-O/dev/null" })
  end
  if opts.left_right then
    args[#args + 1] = "--left-right"
  end
  if opts.reverse then
    args[#args + 1] = "--reverse"
  end
  if opts.topo_order then
    args[#args + 1] = "--topo-order"
  end
  if opts.no_merges then
    args[#args + 1] = "--no-merges"
  end
  if opts.first_parent then
    args[#args + 1] = "--first-parent"
  end
  if opts.max_count ~= nil then
    args[#args + 1] = ("--max-count=%d"):format(opts.max_count)
  end
  if opts.skip ~= nil then
    args[#args + 1] = ("--skip=%d"):format(opts.skip)
  end
  if range then
    args[#args + 1] = range
  end
  -- Always the `--`: without it git refuses a range as "ambiguous" the moment a
  -- file of the same name exists in the work tree (a `doc` directory next to a
  -- `doc` branch, a `v1` file next to a `v1` tag).
  args[#args + 1] = "--"
  for _, path in ipairs(opts.paths or {}) do
    if type(path) ~= "string" or path == "" or path:find("%z") then
      return nil, ("git log: invalid path %s"):format(vim.inspect(path))
    end
    -- Literal by default: git reads what follows `--` as a PATHSPEC, so
    -- `a[1].txt` would also match `a1.txt`, `*` everything, `:(exclude)x` is
    -- magic. `opts.pathspecs = true` asks for that on purpose.
    args[#args + 1] = opts.pathspecs and path or (":(literal)" .. path)
  end
  return git_argv(bin, opts, args, true)
end

---@internal
---@param res Lib.RunArgv.Result
---@param opts Lib.Git.LogOpts
---@return Lib.Git.LogEntry[]|nil
---@return string|nil
local function log_result(res, opts)
  if not res.ok then
    return nil, failure_message(res, "git log", opts)
  end
  return M.parse_log(res.stdout, opts)
end

--- The commits of a revision range, parsed (`git log`). Built for reading the
--- history of repositories the editor does not own: safe against hostile commit
--- text, boundable with `opts.timeout_ms` (there is no default), and cheap --
--- **one** process for the commits, their bodies and (with `name_status`)
--- their changed files.
---
--- `range` is anything `git log` takes as one argument: `HEAD`, `main`,
--- `v1..v2`, `A..B`, or `A...B` with `left_right` (then `entry.side` says on
--- which side of the symmetric difference a commit lies -- `>` only in `B`,
--- `<` only in `A`). `nil` is `HEAD`. A range with no commits is `{}`; `nil`
--- plus a reason means git failed (unknown revision, no commits yet, not a
--- repository, timeout).
---
--- Order is git's default (newest first); `reverse` and `topo_order` change it.
--- `commit_time` is the *committer* time -- after a rebase the author time can
--- be years older than the commit's place in the history.
---
--- In a **blobless clone** (`--filter=blob:none`) this works offline, also with
--- `name_status` -- but only with `no_lazy_fetch = true` is it *guaranteed* never
--- to fetch: pair the two when reading someone else's clones.
---@param range? string
---@param opts? Lib.Git.LogOpts
---@param git_cmd? string
---@return Lib.Git.LogEntry[]|nil entries
---@return string|nil err
function M.log(range, opts, git_cmd)
  opts = opts or {}
  local argv, err = log_argv(range, opts, git_cmd or "git")
  if not argv then
    return nil, err
  end
  local ropts = with_pathspec_env(runner_opts(opts))
  ropts.binary = true
  return log_result(exec(argv, nil, ropts), opts)
end

---@internal
--- Report a refused call the way a run would: through `on_done`, scheduled.
---@param on_done function
---@param err string
---@return { stop: fun() }
local function refused(on_done, err)
  vim.schedule(function()
    on_done(nil, err)
  end)
  return { stop = function() end }
end

--- Async counterpart to `log` -- prefer it on any trigger that can fire for
--- many repositories at once.
---@param range string|nil
---@param opts Lib.Git.LogOpts|nil
---@param on_done fun(entries: Lib.Git.LogEntry[]|nil, err: string|nil) Always invoked via `vim.schedule` -- safe to touch buffers, windows and `vim.fn.*`.
---@param git_cmd? string
---@return { stop: fun() } handle Kills the underlying job; harmless to call after it has finished.
function M.log_async(range, opts, on_done, git_cmd)
  opts = opts or {}
  local argv, err = log_argv(range, opts, git_cmd or "git")
  if not argv then
    return refused(on_done, err)
  end
  local ropts = with_pathspec_env(runner_opts(opts))
  ropts.binary = true
  return exec_async(argv, nil, ropts, function(res)
    on_done(log_result(res, opts))
  end)
end

-- Each query below is a pair of functions: one that builds the git arguments
-- (or refuses with a reason) and one that reads the result. The blocking
-- function and its `_async` twin share both, so they cannot drift apart.

---@internal
--- Run a query's arguments and read the result. `args` is `nil` when the call
--- was refused, and `interpret` is then the reason.
---@param args string[]|nil
---@param interpret function|string
---@param opts Lib.Git.RunOpts|nil
---@param git_cmd string|nil
---@return any
---@return string|nil
local function query(args, interpret, opts, git_cmd)
  if not args then
    return nil, interpret
  end
  return interpret(M.run(args, read_opts(opts), git_cmd))
end

---@internal
---@param args string[]|nil
---@param interpret function|string
---@param opts Lib.Git.RunOpts|nil
---@param on_done function
---@param git_cmd string|nil
---@return { stop: fun() }
local function query_async(args, interpret, opts, on_done, git_cmd)
  if not args then
    return refused(on_done, interpret)
  end
  return M.run_async(args, read_opts(opts), function(res)
    on_done(interpret(res))
  end, git_cmd)
end

---@internal
---@param rev string
---@param opts Lib.Git.RevParseOpts|nil
---@return string[]|nil args
---@return function|string interpret
local function rev_parse_job(rev, opts)
  local bad = bad_rev(rev, "rev-parse")
  if bad then
    return nil, bad
  end
  opts = opts or {}
  local args = { "rev-parse", "--verify" }
  if opts.short then
    args[#args + 1] = type(opts.short) == "number" and ("--short=%d"):format(opts.short)
      or "--short"
  end
  local spec = rev
  if opts.commit then
    spec = rev .. "^{commit}"
  elseif rev:match("^%x+$") and (#rev == 40 or #rev == 64) then
    -- `rev-parse --verify <full hash>` echoes any well-formed hash without
    -- looking for the object; `^{object}` makes git check that it exists.
    spec = rev .. "^{object}"
  end
  args[#args + 1] = spec
  return args,
    function(res)
      if not res.ok then
        return nil, failure_message(res, "git rev-parse", opts)
      end
      local sha = vim.trim(res.stdout)
      if sha == "" then
        return nil, "git rev-parse printed nothing"
      end
      return sha, nil
    end
end

--- Resolve a revision to its full object name (`git rev-parse --verify`).
---@param rev string A branch, tag, hash, `HEAD~3`, ... Must not start with `-`.
---@param opts? Lib.Git.RevParseOpts
---@param git_cmd? string
---@return string|nil sha nil when `rev` does not resolve (or git failed)
---@return string|nil err
function M.rev_parse(rev, opts, git_cmd)
  local args, interpret = rev_parse_job(rev, opts)
  return query(args, interpret, opts, git_cmd)
end

--- Async counterpart to `rev_parse`.
---@param rev string
---@param opts Lib.Git.RevParseOpts|nil
---@param on_done fun(sha: string|nil, err: string|nil) Always invoked via `vim.schedule`.
---@param git_cmd? string
---@return { stop: fun() } handle
function M.rev_parse_async(rev, opts, on_done, git_cmd)
  local args, interpret = rev_parse_job(rev, opts)
  return query_async(args, interpret, opts, on_done, git_cmd)
end

---@internal
---@param a string
---@param b string
---@param opts Lib.Git.RunOpts|nil
---@return string[]|nil args
---@return function|string interpret
local function merge_base_job(a, b, opts)
  local bad = bad_rev(a, "merge-base") or bad_rev(b, "merge-base")
  if bad then
    return nil, bad
  end
  return { "merge-base", a, b }, function(res)
    if not res.ok then
      -- Exit 1 without a message is git's "no common ancestor", not a failure --
      -- unless the process was killed (Windows reports a stop() as code 1 with a
      -- signal) or timed out: then the answer is unknown, not "none".
      if
        res.code == 1
        and (res.signal or 0) == 0
        and not res.timed_out
        and vim.trim(res.stderr or "") == ""
      then
        return nil, "no common ancestor"
      end
      return nil, failure_message(res, "git merge-base", opts)
    end
    local sha = vim.trim(res.stdout)
    if sha == "" then
      return nil, "no common ancestor"
    end
    return sha, nil
  end
end

--- The best common ancestor of two revisions (`git merge-base`).
---@param a string
---@param b string
---@param opts? Lib.Git.RunOpts
---@param git_cmd? string
---@return string|nil sha nil when there is none (unrelated histories) or git failed
---@return string|nil err
function M.merge_base(a, b, opts, git_cmd)
  local args, interpret = merge_base_job(a, b, opts)
  return query(args, interpret, opts, git_cmd)
end

--- Async counterpart to `merge_base`.
---@param a string
---@param b string
---@param opts Lib.Git.RunOpts|nil
---@param on_done fun(sha: string|nil, err: string|nil) Always invoked via `vim.schedule`.
---@param git_cmd? string
---@return { stop: fun() } handle
function M.merge_base_async(a, b, opts, on_done, git_cmd)
  local args, interpret = merge_base_job(a, b, opts)
  return query_async(args, interpret, opts, on_done, git_cmd)
end

---@internal
---@param ancestor string
---@param rev string
---@param opts Lib.Git.RunOpts|nil
---@return string[]|nil args
---@return function|string interpret
local function is_ancestor_job(ancestor, rev, opts)
  local bad = bad_rev(ancestor, "merge-base") or bad_rev(rev, "merge-base")
  if bad then
    return nil, bad
  end
  return { "merge-base", "--is-ancestor", ancestor, rev }, function(res)
    if res.ok then
      return true, nil
    end
    -- Only a clean exit 1 is "no"; a signal, a timeout and a spawn failure all
    -- leave the answer unknown.
    if res.code == 1 and (res.signal or 0) == 0 then
      return false, nil
    end
    return nil, failure_message(res, "git merge-base", opts)
  end
end

--- Whether `ancestor` is reachable from `rev` (`git merge-base --is-ancestor`):
--- `true` for a fast-forward away, `false` for a rewound or diverged history.
--- A revision counts as its own ancestor.
---@param ancestor string
---@param rev string
---@param opts? Lib.Git.RunOpts
---@param git_cmd? string
---@return boolean|nil answer nil when git could not tell (unknown revision, not a repository, timeout)
---@return string|nil err
function M.is_ancestor(ancestor, rev, opts, git_cmd)
  local args, interpret = is_ancestor_job(ancestor, rev, opts)
  return query(args, interpret, opts, git_cmd)
end

--- Async counterpart to `is_ancestor`.
---@param ancestor string
---@param rev string
---@param opts Lib.Git.RunOpts|nil
---@param on_done fun(answer: boolean|nil, err: string|nil) Always invoked via `vim.schedule`.
---@param git_cmd? string
---@return { stop: fun() } handle
function M.is_ancestor_async(ancestor, rev, opts, on_done, git_cmd)
  local args, interpret = is_ancestor_job(ancestor, rev, opts)
  return query_async(args, interpret, opts, on_done, git_cmd)
end

local TAG_FORMAT = "--format=%(refname:strip=2)%00%(objectname)%00%(*objectname)%00"
  .. "%(objecttype)%00%(*objecttype)%00%(creatordate:unix)%00%(contents:subject)"
local TAG_SORTS = { newest = "-creatordate", oldest = "creatordate", version = "-v:refname" }

--- Tags whose `%(*objecttype)` named another tag: an older git (2.43) peels one level only, so
--- what such a tag finally points at needs more questions (`peel_nested`). Keyed weakly by the
--- tag record, which is a plain data table the caller owns.
---@type table<table, true>
local NESTED_TAGS = setmetatable({}, { __mode = "k" })

--- `cat-file --batch` answers "<sha> <type> <size>" and the object per sha read from stdin. Only
--- the tag objects on the way are read (their `object`/`type` headers say where the next hop
--- goes), never the thing finally pointed at: asking for `<tag>^{}` would read that object and
--- fetch it from the remote in a partial clone.
local PEEL_ARGS = { "cat-file", "--batch" }

--- No tag chain is this long; a ring of tags cannot exist (an object names its target by hash).
local PEEL_MAX_ROUNDS = 64

---@class Lib.Git.PeelItem
---@field tag Lib.Git.Tag
---@field cur string The tag object to read next.

---@internal
---@param tags Lib.Git.Tag[]
---@return Lib.Git.PeelItem[] pending
local function nested_tags(tags)
  local list = {}
  for _, t in ipairs(tags) do
    if NESTED_TAGS[t] then
      list[#list + 1] = { tag = t, cur = t.sha }
    end
  end
  return list
end

---@internal
---@param pending Lib.Git.PeelItem[]
---@param opts Lib.Git.TagsOpts
---@return Lib.Git.TagsOpts
local function peel_opts(pending, opts)
  local shas = {}
  for i, item in ipairs(pending) do
    shas[i] = item.cur
  end
  -- no_lazy_fetch: a missing tag object fails here instead of being fetched from a remote
  return vim.tbl_extend("force", opts, {
    input = table.concat(shas, "\n") .. "\n",
    no_lazy_fetch = true,
  })
end

---@internal
--- Read one round of `PEEL_ARGS` output: for each tag object the next hop. Finished tags get
--- their `commit` and `sha`; the ones whose next hop is a tag again stay pending.
---@param pending Lib.Git.PeelItem[]
---@param stdout string
---@return Lib.Git.PeelItem[]|nil still_pending
---@return string|nil err
local function apply_peel(pending, stdout)
  local still, pos = {}, 1
  for _, item in ipairs(pending) do
    local nl = stdout:find("\n", pos, true)
    local _, kind, size = (nl and stdout:sub(pos, nl - 1) or ""):match("^(%x+) (%S+) (%d+)$")
    if not kind then
      return nil, ("git cat-file: could not read the tag object %s"):format(item.cur)
    end
    size = tonumber(size) --[[@as integer]]
    local body = stdout:sub(nl + 1, nl + size)
    pos = nl + size + 2 -- the object and the LF git writes after it
    local object, target_kind = body:match("^object (%x+)\ntype (%S+)\n")
    if kind ~= "tag" or not object then
      return nil, ("git cat-file: %s is not a readable tag object"):format(item.cur)
    end
    if target_kind == "tag" then
      item.cur = object
      still[#still + 1] = item
    else
      item.tag.commit = target_kind == "commit"
      item.tag.sha = object
    end
  end
  return still, nil
end

---@internal
---@param opts Lib.Git.TagsOpts|nil
---@return Lib.Git.TagsOpts
local function tags_opts(opts)
  -- binary: the NUL-separated format must reach us byte for byte.
  return vim.tbl_extend("force", opts or {}, { binary = true })
end

---@internal
---@param opts Lib.Git.TagsOpts
---@return string[]|nil args
---@return function|string interpret
local function tags_job(opts)
  local sort = TAG_SORTS[opts.sort or "newest"]
  if not sort then
    return nil, ("git tags: unknown sort %s"):format(vim.inspect(opts.sort))
  end
  local args = { "for-each-ref", "--sort=" .. sort, TAG_FORMAT }
  if opts.limit ~= nil then
    if not is_count(opts.limit) then
      return nil,
        ("git tags: `limit` must be a non-negative integer, got %s"):format(vim.inspect(opts.limit))
    end
    -- `--count=0` means "no limit" to git, the opposite of what was asked.
    if opts.limit > 0 then
      args[#args + 1] = ("--count=%d"):format(opts.limit)
    end
  end
  for _, key in ipairs({ "merged", "no_merged" }) do
    if opts[key] ~= nil then
      local bad = bad_rev(opts[key], "for-each-ref")
      if bad then
        return nil, bad
      end
      args[#args + 1] = (key == "merged" and "--merged=" or "--no-merged=") .. opts[key]
    end
  end
  if opts.pattern ~= nil and (type(opts.pattern) ~= "string" or opts.pattern:find("[%z\r\n]")) then
    return nil, ("git tags: invalid pattern %s"):format(vim.inspect(opts.pattern))
  end
  args[#args + 1] = "refs/tags/" .. (opts.pattern or "")

  return args,
    function(res)
      if not res.ok then
        return nil, failure_message(res, "git for-each-ref", opts)
      end
      if opts.limit == 0 then
        return {}, nil
      end
      local tags = {}
      for line in res.stdout:gmatch("[^\n]+") do
        local f = split_nul((line:gsub("\r$", "")))
        local peeled = f[3] or ""
        -- The thing the tag finally points at: a lightweight tag IS that object
        -- (`%(objecttype)`), an annotated one names it as `%(*objecttype)`.
        local final_type = (f[4] == "tag") and (f[5] or "") or (f[4] or "")
        local time = tonumber(f[6])
        local record = {
          name = f[1] or "",
          sha = peeled ~= "" and peeled or (f[2] or ""),
          object = f[2] or "",
          annotated = f[4] == "tag",
          commit = final_type == "commit",
          time = time and time == time and time < 1e15 and time or nil,
          subject = f[7] or "",
        }
        if final_type == "tag" then
          NESTED_TAGS[record] = true
        end
        tags[#tags + 1] = record
      end
      return tags, nil
    end
end

--- The repository's tags with the metadata a changelog view needs, one
--- `git for-each-ref` process. Annotated tags are told apart from lightweight
--- ones, the commit a tag *points to* is peeled out of an annotated tag, and
--- `merged`/`no_merged` answer "which tags does this range contain" --
--- `{ merged = new, no_merged = old }` is the release list of an update.
---
--- Reads ref and tag objects; `for-each-ref` needs the type of what a ref points at, so a tag
--- (annotated or not) on a blob that a blobless clone does not hold fetches that blob (a tag on
--- a commit or a tree does not). One
--- `git for-each-ref` process; a git that peels a tag on a tag one level only (2.43) gets
--- `git cat-file --batch` rounds on the tag objects on top, one per hop.
---@param opts? Lib.Git.TagsOpts
---@param git_cmd? string
---@return Lib.Git.Tag[]|nil tags nil when git failed; no tags is `{}`
---@return string|nil err
function M.tags(opts, git_cmd)
  opts = tags_opts(opts)
  local args, interpret = tags_job(opts)
  local tags, err = query(args, interpret, opts, git_cmd)
  if not tags then
    return nil, err
  end
  local pending = nested_tags(tags)
  for _ = 1, PEEL_MAX_ROUNDS do
    if #pending == 0 then
      return tags, nil
    end
    local res = M.run(PEEL_ARGS, read_opts(peel_opts(pending, opts)), git_cmd)
    if not res.ok then
      return nil, failure_message(res, "git cat-file", opts)
    end
    pending, err = apply_peel(pending, res.stdout)
    if not pending then
      return nil, err
    end
  end
  if #pending == 0 then
    return tags, nil
  end
  return nil, "git tags: a tag chain longer than " .. PEEL_MAX_ROUNDS
end

--- Async counterpart to `tags`.
---@param opts Lib.Git.TagsOpts|nil
---@param on_done fun(tags: Lib.Git.Tag[]|nil, err: string|nil) Always invoked via `vim.schedule`.
---@param git_cmd? string
---@return { stop: fun() } handle
function M.tags_async(opts, on_done, git_cmd)
  opts = tags_opts(opts)
  local args, interpret = tags_job(opts)
  local current ---@type { stop: fun() }|nil
  local stopped, rounds = false, 0
  ---@param tags Lib.Git.Tag[]
  ---@param pending Lib.Git.PeelItem[]
  local function peel(tags, pending)
    -- a stop() that arrived while this callback was already queued cannot reach the process
    -- that has finished: it must keep the next round from starting
    if stopped then
      on_done(nil, "git tags: stopped")
      return
    end
    if #pending == 0 then
      on_done(tags, nil)
      return
    end
    rounds = rounds + 1
    if rounds > PEEL_MAX_ROUNDS then
      on_done(nil, "git tags: a tag chain longer than " .. PEEL_MAX_ROUNDS)
      return
    end
    current = M.run_async(PEEL_ARGS, read_opts(peel_opts(pending, opts)), function(res)
      if not res.ok then
        on_done(nil, failure_message(res, "git cat-file", opts))
        return
      end
      local still, err = apply_peel(pending, res.stdout)
      if not still then
        on_done(nil, err)
        return
      end
      peel(tags, still)
    end, git_cmd)
  end
  current = query_async(args, interpret, opts, function(tags, err)
    if not tags then
      on_done(nil, err)
      return
    end
    peel(tags, nested_tags(tags))
  end, git_cmd)
  return {
    stop = function()
      stopped = true
      if current then
        current.stop()
      end
    end,
  }
end

--- One blamed line, as `blame_porcelain` returns it.
---@class Lib.Git.BlameEntry
---@field line integer          1-based final line number in the current file
---@field sha string            Full commit hash ("0000000000000000000000000000000000000000" for an uncommitted/working-tree line)
---@field author string|nil
---@field author_time integer|nil  Unix timestamp
---@field summary string|nil

---@internal
--- Parse `git blame --porcelain` output into one entry per line.
---
--- The porcelain format gives a full metadata block (author, author-time,
--- summary, ...) only the FIRST time a commit is mentioned; every later line
--- attributed to the same commit repeats just the header
--- (`<sha> <orig-line> <final-line>`) followed directly by the tab-prefixed
--- content line -- so metadata is cached per sha and reused for repeats,
--- rather than re-parsed or left nil.
---@param text string
---@return Lib.Git.BlameEntry[]
local function parse_blame_porcelain(text)
  local entries = {}
  local commits = {} ---@type table<string, { author: string|nil, author_time: integer|nil, summary: string|nil }>
  local lines = vim.split(text, "\n", { plain = true })
  local i, n = 1, #lines

  while i <= n do
    local line = lines[i]
    -- orig_line (the line number in the commit that introduced it) is
    -- unused here, so it is matched but not captured.
    local sha, final_line = line:match("^(%x+)%s+%d+%s+(%d+)")
    if not sha then
      i = i + 1
    else
      commits[sha] = commits[sha] or {}
      local c = commits[sha]
      i = i + 1
      while i <= n do
        local sub = lines[i]
        if sub:sub(1, 1) == "\t" then
          -- Content line: this entry is complete.
          entries[#entries + 1] = {
            line = tonumber(final_line),
            sha = sha,
            author = c.author,
            author_time = c.author_time,
            summary = c.summary,
          }
          i = i + 1
          break
        end
        local key, val = sub:match("^(%S+)%s(.*)$")
        if key == "author" then
          c.author = val
        elseif key == "author-time" then
          c.author_time = tonumber(val)
        elseif key == "summary" then
          c.summary = val
        end
        -- Every other porcelain key (author-mail, committer*, previous,
        -- filename, boundary, ...) is intentionally ignored: callers that
        -- need more than author/author-time/summary should parse the raw
        -- output themselves rather than growing this struct unboundedly.
        i = i + 1
      end
    end
  end

  return entries
end

---@internal
---@param path string
---@param opts { first?: integer, last?: integer, dir?: string }
---@param bin string
---@return string[]
local function blame_argv(path, opts, bin)
  local argv = { bin }
  if opts.dir and opts.dir ~= "" then
    vim.list_extend(argv, { "-C", opts.dir })
  end
  vim.list_extend(argv, { "blame", "--porcelain" })
  if opts.first and opts.last then
    argv[#argv + 1] = "-L"
    argv[#argv + 1] = ("%d,%d"):format(opts.first, opts.last)
  end
  vim.list_extend(argv, { "--", path })
  return argv
end

---@internal
---@param ok boolean
---@param out string
---@return Lib.Git.BlameEntry[]|nil entries
---@return string|nil err
local function blame_result(ok, out)
  if not ok then
    return nil, (type(out) == "string" and vim.trim(out) ~= "") and out or "git blame failed"
  end
  if type(out) ~= "string" or vim.trim(out) == "" then
    return {}, nil
  end
  return parse_blame_porcelain(out), nil
end

--- Blame a file (or a line range within it) via `git blame --porcelain`.
---
--- Synchronous, like every other function in this module (`ERR-01`: the
--- underlying `run_blocking_captured` call is a system-boundary shell-out,
--- and `git blame` on a large file can be slow -- prefer `blame_porcelain_async`
--- on a hot/repeated path, e.g. a `CursorHold`-driven refresh).
---@param path string File path, relative to `opts.dir`/the cwd, or absolute.
---@param opts? { first?: integer, last?: integer, dir?: string } `first`/`last` (both required together) restrict to a 1-based inclusive line range; `dir` runs as `git -C <dir>` instead of the cwd.
---@param git_cmd? string
---@return Lib.Git.BlameEntry[]|nil entries  nil only on a git-invocation failure (ERR-10/11: an empty file is `{}`, not nil)
---@return string|nil err
function M.blame_porcelain(path, opts, git_cmd)
  opts = opts or {}
  local argv = blame_argv(path, opts, git_cmd or "git")
  local ok, out = require("lib.nvim.cross.run_argv").run_blocking_captured(argv)
  return blame_result(ok, out)
end

--- Async counterpart to `blame_porcelain` -- LUA-15: prefer this over the
--- blocking version for any repeated/automatic trigger (a `CursorHold`-
--- driven current-line blame refresh, in particular), since
--- `run_blocking_captured` freezes the UI for the call's duration and a
--- refresh firing on every cursor move is exactly the repeated-blocking-call
--- pattern that adds up.
---@param path string File path, relative to `opts.dir`/the cwd, or absolute.
---@param opts? { first?: integer, last?: integer, dir?: string }
---@param on_done fun(entries: Lib.Git.BlameEntry[]|nil, err: string|nil)  Always invoked via `vim.schedule` (`run_async_captured`'s own guarantee) -- safe to touch buffers/windows/`vim.fn.*` from it.
---@param git_cmd? string
---@return { stop: fun() } handle  Kills the underlying job; harmless to call after it has already finished.
function M.blame_porcelain_async(path, opts, on_done, git_cmd)
  opts = opts or {}
  local argv = blame_argv(path, opts, git_cmd or "git")
  return run_out_async(argv, function(ok, out)
    on_done(blame_result(ok, out))
  end)
end

---@internal
--- Whether `git fetch`'s stderr reports a moved ref. Only git's ref-update lines count
--- (` <flag> <summary> <from> -> <to>`): flag ` ` fast-forward, `+` forced, `-` pruned,
--- `t` tag update, `*` new ref. A rejected (`!`) or up-to-date (`=`) line moves nothing,
--- and anything else git writes to stderr -- the `From <url>` header, a `warning:` or
--- `hint:` line, a background auto-gc note -- is not a ref update: "stderr is not empty"
--- reported `changed = true` for a fetch that brought nothing as soon as git warned.
---
--- A line whose target is `FETCH_HEAD` moves no ref either: a remote without a fetch
--- refspec (a push mirror, `git remote add --mirror=push`) gets its `HEAD` fetched into
--- `FETCH_HEAD` on every `--all`, printed as ` * branch HEAD -> FETCH_HEAD` each time.
---@param stderr string
---@return boolean
local function fetch_moved_ref(stderr)
  for line in stderr:gmatch("[^\r\n]+") do
    local to = line:match("^ [ %+%-t%*] .*%->%s*(%S+)")
    if to and to ~= "FETCH_HEAD" then
      return true
    end
  end
  return false
end

--- Fetch every remote's tracking refs and prune deleted ones
--- (`git fetch --all --prune`). Does not touch the working tree or `HEAD`.
---
--- Always async (`run_async_captured`, never a blocking counterpart): this is
--- a network call, and `lib.nvim.cross.run_argv`'s own reasoning for
--- `run_async_captured` -- "git over the network ... belongs here rather
--- than [blocking]" -- applies to every function in this section, not just
--- this one.
---
--- `changed` reports whether the fetch actually moved a remote-tracking ref:
--- git writes ref updates (`<old>..<new> main -> origin/main`) to stderr, and only
--- those lines count; warnings and other notes on stderr do not. A failed fetch never reaches this
--- branch (`on_done` returns early on `ok == false`), so a present `changed`
--- always means the call actually succeeded.
---
--- A fetch killed by a signal (the handle's own `stop()`, the OOM killer) is a
--- failure (`err` = "git fetch failed (exit code 143)" for SIGTERM), never a
--- success; so is a git that cannot be started (`err` = the reason). `on_done`
--- still fires once after `stop()` -- with that failure.
---@param opts? Lib.Git.NetOpts
---@param on_done fun(ok: boolean, err: string|nil, changed: boolean|nil)
---@param git_cmd? string
---@return { stop: fun() } handle
function M.fetch_async(opts, on_done, git_cmd)
  local argv = git_argv(git_cmd or "git", opts, { "fetch", "--all", "--prune" })
  local ropts = net_ropts(opts)
  return run_sync_async(argv, function(ok, _stdout, code, stderr, timed_out)
    if not ok then
      on_done(false, net_err("fetch", stderr, code, timed_out, ropts))
      return
    end
    -- `stderr` is `nil` only on the legacy (pre-`vim.system`) fallback,
    -- which cannot separate it from stdout at all (see run_argv's own
    -- doc comment) -- reporting `changed = false` there would be a
    -- confident-looking lie, so "unknown" stays `nil` instead of
    -- guessing either way. Deliberately an `if`, not `... and ... or
    -- nil`: the middle term is a real `false` on a successful, nothing-
    -- changed fetch, and `false or nil` in Lua evaluates to `nil` --
    -- that idiom would have silently turned every "nothing changed"
    -- result into "unknown" too.
    local changed
    if stderr ~= nil then
      changed = fetch_moved_ref(stderr)
    end
    on_done(true, nil, changed)
  end, nil, ropts)
end

---@internal
--- Async equivalent of `M.head_hash`, used by `M.pull_async` so its
--- before/after HEAD comparison never blocks the calling thread the way
--- `M.head_hash` (built on `run_blocking_captured`) does.
---
--- Reports `hash` as a bare `string|nil` first, matching the blocking
--- `M.head_hash`, plus a second `ok` value a caller MAY ignore and a third,
--- `unknown`: the read hit the deadline or was killed by a signal (exit code
--- 128 + signal), so the missing hash says nothing about the repository
--- (`M.pull_async` reports `changed = nil`), unlike an empty one, where `git
--- rev-parse HEAD` exits 128 itself. `git
--- rev-parse HEAD` exits non-zero for a *genuinely* empty repository (no
--- commits yet -- an entirely normal state to run this against, e.g. before
--- pulling into a freshly `git init`'d checkout) exactly the same way it
--- does for a process `run_async_captured`'s own `stop()` killed, or any
--- other unrelated failure -- verified directly: all three report `ok =
--- false` from the underlying job with no way to tell them apart from
--- `ok` alone. `M.pull_async`'s *before* read ignores `ok` for exactly
--- that reason (its own doc comment explains why); its *after* read does
--- not, because by the time it runs a *different* invariant applies (see
--- there).
---@param opts? Lib.Git.NetOpts
---@param on_done fun(hash: string|nil, ok: boolean, unknown: boolean|nil)
---@param git_cmd? string
---@return { stop: fun() } handle
local function head_hash_async(opts, on_done, git_cmd)
  local argv = git_argv(git_cmd or "git", opts, { "rev-parse", "HEAD" })
  -- same environment and deadline as the pull it brackets: a `GIT_DIR` in `opts.env`
  -- must not make the before/after comparison look at another repository
  return run_sync_async(argv, function(ok, stdout, code, _stderr, timed_out)
    if not ok or type(stdout) ~= "string" then
      -- 128 is what git itself answers for an empty repository (and for no repository at
      -- all, which the pull reports); a deadline or a signal kill (128 + signal, e.g. the
      -- OOM killer) is no statement about HEAD
      on_done(nil, false, timed_out or code ~= 128)
      return
    end
    stdout = vim.trim(stdout)
    on_done(stdout ~= "" and stdout or nil, true)
  end, nil, net_ropts(opts))
end

--- Fast-forward-only pull of the current branch (`git pull --ff-only`).
--- Fails loudly (reported via `err`) rather than creating a merge commit --
--- the same "never clobber local work" guarantee `checkout` gives for
--- switching branches.
---
--- `changed` reports whether anything actually fast-forwarded, by comparing
--- `HEAD` before and after the pull rather than pattern-matching git's own
--- ("Already up to date." vs "Updating <old>..<new>") message: that text is
--- translatable (a git build with NLS/gettext support under a non-English
--- `LANGUAGE`/`LC_ALL` would emit a localized string this never matches),
--- so a structural check is the only one that works regardless of the
--- caller's locale. Both HEAD reads go through `head_hash_async`, not
--- `M.head_hash` -- that one is a blocking `run_blocking_captured` call, and
--- spending two of those on every pull (one before dispatching the async
--- job, one inside its own completion callback) would reintroduce exactly
--- the main-thread stall this whole async API exists to avoid, doubly so
--- for a caller fanning this out over many repositories (`M.update_async`'s
--- own multi-repo-dashboard case).
---
--- The returned handle's `stop()` is honored at every stage of the
--- before-hash -> pull -> after-hash chain via an explicit `cancelled`
--- flag -- NOT by inspecting whether a stage's own git process reported
--- `ok`, since a killed process and a git command that simply failed on
--- its own (e.g. `head_hash_async`'s genuinely-empty-repo case) are
--- indistinguishable at that level (see `head_hash_async`'s own doc
--- comment). Once `stop()` has been called, every later stage's callback
--- returns immediately without invoking `on_done` at all -- otherwise
--- calling `stop()` while the before-hash read is still in flight would
--- only kill that cheap lookup and let the real pull start anyway,
--- untracked and uncancellable, and calling it during the after-hash read
--- would still report a guessed `changed` for a pull the caller no longer
--- wanted a result for.
---
--- A pull killed by a signal that did NOT come from `stop()` (the OOM killer)
--- is a failure (`err` = "git pull failed (exit code 137)" for SIGKILL), not a
--- success followed by a guessed `changed`.
---
--- The *after* read's `ok` IS checked, unlike the *before* read's: a
--- `git pull --ff-only` that exits 0 (the `ok` branch just above it)
--- proves the target upstream ref already resolved to a real commit --
--- an upstream with no commits at all makes the pull itself fail instead
--- of trivially no-opping (verified directly) -- so a failed read at this
--- specific point can only be a genuine error, never the legitimate
--- emptiness the *before* read can hit. Reports `changed = nil` (honestly
--- unknown) rather than comparing a real `before` hash against a `nil`
--- that would otherwise silently guess `true`.
---@param opts? Lib.Git.NetOpts
---@param on_done fun(ok: boolean, err: string|nil, changed: boolean|nil)
---@param git_cmd? string
---@return { stop: fun() } handle
function M.pull_async(opts, on_done, git_cmd)
  local cancelled = false
  local active = { stop = function() end }
  active.stop = head_hash_async(opts, function(before, _, before_unknown)
    if cancelled then
      return
    end
    local argv = git_argv(git_cmd or "git", opts, { "pull", "--ff-only" })
    local ropts = net_ropts(opts)
    active.stop = run_sync_async(argv, function(ok, _stdout, code, stderr, timed_out)
      if cancelled then
        return
      end
      if not ok then
        on_done(false, net_err("pull", stderr, code, timed_out, ropts))
        return
      end
      -- A before read that hit the deadline or was killed is "unknown", not "no hash":
      -- comparing its nil against the real after hash would report a move that never
      -- happened. Nothing the after read could say changes that, so it is not even started.
      if before_unknown then
        on_done(true, nil, nil)
        return
      end
      active.stop = head_hash_async(opts, function(after, after_ok)
        if cancelled then
          return
        end
        if not after_ok then
          on_done(true, nil, nil)
          return
        end
        on_done(true, nil, before ~= after)
      end, git_cmd).stop
    end, nil, ropts).stop
  end, git_cmd).stop
  return {
    stop = function()
      cancelled = true
      active.stop()
    end,
  }
end

--- Push the current branch to its upstream (`git push`).
---
--- A push killed by a signal (the handle's own `stop()`, the OOM killer) is a
--- failure (`err` = "git push failed (exit code 143)" for SIGTERM), never a
--- success: the push did not finish. `on_done` still fires once after `stop()`
--- -- with that failure.
---@param opts? Lib.Git.NetOpts
---@param on_done fun(ok: boolean, err: string|nil)
---@param git_cmd? string
---@return { stop: fun() } handle
function M.push_async(opts, on_done, git_cmd)
  local argv = git_argv(git_cmd or "git", opts, { "push" })
  local ropts = net_ropts(opts)
  return run_sync_async(argv, function(ok, _stdout, code, stderr, timed_out)
    if not ok then
      on_done(false, net_err("push", stderr, code, timed_out, ropts))
      return
    end
    on_done(true, nil)
  end, nil, ropts)
end

--- Fetch, then fast-forward pull -- the pair every "bring this repo level
--- with its upstream" caller wants (multi-repo dashboards, batch sync
--- tools), expressed once so they all agree on exactly what "update" means
--- instead of each spelling out the same two calls.
---
--- `changed` mirrors the pull's own -- that is what "did this checkout move
--- forward" means for the combined operation. A failed fetch short-circuits
--- before the pull ever runs.
---
--- The returned handle's `stop` is re-pointed from the fetch job to the
--- pull job once the fetch resolves and the pull actually starts: a caller
--- that stores the handle and calls `stop()` later (e.g. a multi-repo
--- dashboard cancelling every in-flight update when its window closes)
--- would otherwise kill an already-finished fetch and leave the real,
--- still-running `git pull` completely untracked and uncancellable.
---
--- Like `pull_async`, `on_done` never fires once `stop()` has been called, at
--- whichever stage it lands: the killed fetch's failure is swallowed, and the
--- pull does not start when the `stop()` arrived while the completion of an
--- already finished fetch was still queued -- the working tree must not move
--- after the caller cancelled. An explicit `cancelled` flag, set before the job
--- is killed, decides this, not the fetch's own `ok`: a killed process and a
--- git that failed on its own are not told apart by that alone (a kill reads
--- as exit code 1 on Windows, as exit code 0 with `signal` 15 on POSIX).
---@param opts? Lib.Git.NetOpts
---@param on_done fun(ok: boolean, err: string|nil, changed: boolean|nil)
---@param git_cmd? string
---@return { stop: fun() } handle
function M.update_async(opts, on_done, git_cmd)
  local cancelled = false
  local active = { stop = function() end }
  active.stop = M.fetch_async(opts, function(ok, err)
    if cancelled then
      return
    end
    if not ok then
      on_done(false, err)
      return
    end
    active.stop = M.pull_async(opts, on_done, git_cmd).stop
  end, git_cmd).stop
  return {
    stop = function()
      cancelled = true
      active.stop()
    end,
  }
end

--- Create a buffer-scoped function that clears all virtual text
--- in the given namespace.
---
--- This function binds the namespace once and returns a callback
--- suitable for autocmd usage.
---@param ns integer Namespace ID created via nvim_create_namespace
---@return fun(buf: integer): nil
function M.clear_line_diff(ns)
  return function(buf)
    -- Ensure the buffer is still valid before mutating it
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
end

---@type Lib.Git
return M
