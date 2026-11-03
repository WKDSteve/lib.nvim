# `lib.nvim.git`

Small, composable Git query helpers for editor features (autocommands,
status integrations, conditional behavior). Every function shells out to the
`git` CLI via `lib.nvim.cross.run_argv` (argv form, no shell); every function
accepts an optional `git_cmd` to override the `git` binary. `opts.dir` (see
[below](#querying-a-different-repo-than-the-editors-cwd)) runs any of the
cwd-implicit ones as `git -C <dir>`.

Every function here is side-effect free except `checkout` (see
[below](#checking-out-a-branch)), which is a real filesystem/index mutation
by design, the sync verbs `fetch_async`/`pull_async`/`push_async`/`update_async`
(see [Syncing with the remote](#syncing-with-the-remote-fetch_async-pull_async-push_async-update_async)),
and `run`/`run_async` (see [Running git](#running-git-and-reading-someone-elses-history)),
the generic escape hatch that runs whatever subcommand it is handed.

## Usage

```lua
local git = require("lib.nvim.git")

git.in_git_repo()          --> boolean
git.repo_root()            --> absolute path string, or nil
git.current_branch()       --> branch name, or nil in detached HEAD
git.checkout("main")       --> boolean ok, string|nil err (git's own stderr on failure)
git.is_detached_head()     --> boolean (false outside a repo: no HEAD to detach)
git.is_dirty()             --> boolean (any porcelain status output at all)
git.is_tracked("src/a.lua")  --> boolean
git.is_skip_worktree("session.vim")      --> true | false | nil, err   (nil: untracked / git failed)
git.set_skip_worktree("session.vim", true)  --> ok, err                (git update-index --skip-worktree)
git.toggle_skip_worktree("session.vim")  --> state after the flip | nil, err
git.upstream()             --> "origin/main"-style string, or nil (no upstream)
git.head_hash()            --> full hash string, or nil
git.head_short_hash()      --> short hash string, or nil
git.tree_hash()            --> tree id of HEAD (stable across amend), or nil
git.describe()             --> nearest tag, or the short hash (--always), or nil
git.ahead_behind()         --> boolean ahead, boolean behind (vs. @{u})
```

All of these (except `checkout`, see [below](#checking-out-a-branch)) return
`nil` (or `false`, for the boolean ones) rather than throwing when the
command fails or produces empty output — e.g. outside a Git repo,
`repo_root()`/`current_branch()`/etc. all just return `nil`.

`ahead_behind()` parses `git rev-list --left-right --count HEAD...@{u}`; if
the command fails, produces no output, or the output doesn't match
`"<n> <n>"`, both results are `false` rather than raising.

## Checking out a branch

```lua
local ok, err = git.checkout("some-branch")
if not ok then
  vim.notify("checkout failed: " .. err, vim.log.levels.ERROR)
end
```

Runs `git checkout <name>` — the one function in this module that mutates
the working tree/HEAD, so it goes through `run_blocking`, not
`run_blocking_captured` (what the read-only helpers above use): a failed
checkout writes its reason to **stderr**, and `run_blocking` is the runner
here that actually captures it, so `err` is git's own text ("pathspec
'<name>' did not match any file(s) known to git", "Your local changes to the
following files would be overwritten by checkout", ...) rather than a
generic message.

`name` is refused outright (`ok = false`) if it starts with `-` — read as an
option otherwise — rather than escaped. No `--` is inserted before it
either: that would tell `git checkout` to treat `name` as a pathspec
(restore a file from the index) instead of a branch, the opposite of what
this function does.

## Querying a different repo than the editor's cwd

Every function above reads the current working directory implicitly by
default — the right default for editor features, wrong for correlating data
with *a specific repo* (a plugin's own checkout, one row of a multi-repo
overview, the repo containing a given file). Pass `opts.dir` and the call runs
as `git -C <dir> ...` instead:

```lua
git.current_branch({ dir = "/path/to/some/plugin" })
git.status_porcelain({ dir = repo })
git.is_tracked("src/a.lua", { dir = repo })   -- path is relative to opts.dir
git.repo_root({ dir = "/repo/some/sub/dir" }) -- the root of *that* repo
```

`opts` comes **before** `git_cmd` in every signature (`is_tracked` takes its
`path` first). A nonexistent or non-repo `dir` behaves like any other
non-repo: `nil` / `false`, no error.

Passing a string where `opts` belongs — the old convention, where `git_cmd`
was the first parameter — **raises** instead of being ignored: silently
falling back to the default `git` would run a different binary than the one
the caller asked for.

`git.info(dir)` is the older, one-shot form of the same idea and keeps its
positional `dir`:

```lua
git.info("/path/to/some/plugin")
-- { branch = "main", version = "v1.2.3" or a short hash if untagged, commit = "abc1234" }
```

Runs `git -C <dir> ...` for each field; any field the command fails to
answer (detached HEAD for `branch`, no tags and no commits for `version`) is
`nil` rather than a guessed placeholder.

## Completing a revision argument

`git.refs(dir?, opts?)` lists the repository's named revisions — local
branches, then remote branches, then tags — for `<Tab>`-completing a "which
revision?" command argument.

```lua
git.refs()                                     -- cwd's repo, everything
git.refs("/path/to/repo", { limit = 20 })      -- another repo, capped
git.refs(nil, { remotes = false, tags = false })  -- local branches only
```

Two details matter more than they look:

- **Sorted by creator date, newest first.** `git for-each-ref` defaults to
  refname order, which puts whatever starts with `a` ahead of the branch you
  were on ten seconds ago. `-creatordate` puts the likely answer in the
  first few candidates. It is `creatordate`, not `committerdate`: an
  *annotated* tag has no committer, so `committerdate` left every annotated
  tag undated and sorted them all to the bottom; for a branch or a
  lightweight tag the two are the same.
- **Remote branches keep their prefix** (`origin/main`, not `main`), because
  that is how git itself accepts them as a revision. Stripping it would also
  collide with the identically named local branch.

Returns an empty list — never `nil` — for a non-repo, a nonexistent path, or
a repo with no commits, so a completion callback can return it directly.

## Status parsing

```lua
local status, err = git.status_porcelain({ dir = repo })   -- opts optional
-- table<string, { code: string, orig_path: string|nil }>, or nil, err

git.status_porcelain_async({ dir = repo }, function(status, err)
  -- runs on the main loop (vim.schedule): safe to touch buffers and windows
end)

git.parse_status(raw)   -- the pure parser, for a caller that runs git itself
```

Parses `git status --porcelain -z -u` into a path → status-code map. Handles
ordinary two-char XY codes (`M `, ` M`, `A `, `??`, `!!`, `UU`, …) as well as
rename/copy entries, which are keyed by the **new** path with `orig_path` set
to the old one; ordinary entries have `orig_path = nil`. Paths are always
relative to the **repository root**, whichever directory git was started in.

Ignored paths (`!!`) are **not** included unless `opts.ignored = true` adds
`--ignored` to the call — plain `-u` only controls untracked files, not
ignored ones.

A clean tree is `{}`; `nil` (plus an error string) means git itself failed —
not a repo, or `git` missing.

**Why `-z`.** Without it git C-quotes any path containing a space or a
non-ASCII byte: `a b.txt` arrives as `"a b.txt"` (quotes included) and `ü.txt`
as `"\303\274.txt"`, neither of which exists on disk. The NUL-separated form
delivers paths raw. In it a rename/copy is `XY new NUL old NUL` — destination
first — and an `R`/`C` in either status column marks such a two-path entry.

**Prefer `status_porcelain_async` on any automatic trigger** (a tree refresh on
every save or focus): the synchronous call freezes the UI for as long as
`git status` takes, which on a large tree is not nothing.

**Read-only by construction.** `status_porcelain`, its async twin and
`is_dirty` run `git --no-optional-locks status`. A plain `git status`
opportunistically refreshes — and rewrites — the index, taking `index.lock`
while it does; an automatic refresh that overlaps the user's own `git commit`
or `git add` would then make *that* command fail with "index.lock exists".
The trade-off is that stale stat data in the index is not repaired as a side
effect of these calls.

## Reading a file at a revision

```lua
local content, err = git.show("HEAD~1", "src/a.lua", { dir = repo })
git.show_async("v1.2.0", "assets/logo.png", { dir = repo }, function(blob, err) end)
```

`git show <rev>:<path>` with the content delivered **byte for byte**: a CRLF
file keeps its `\r\n`, a binary blob keeps every byte (including `NUL`), and an
empty file is `""` — deliberately not `nil`, which means *failure* here (unknown
revision, path not in that revision, not a repository), with the reason in the
second value. Text-mode handling of the output (what the other helpers here
use) would rewrite `\r\n` to `\n` and corrupt exactly the files a caller wants
to diff or hash, which is why this goes through `run_argv`'s `binary` option.

- `path` is relative to `opts.dir` (or the cwd), **not** to the repository
  root — the same meaning as in `blame_porcelain`/`is_tracked` — or absolute.
  An absolute path names its own directory, so `opts.dir` is ignored for it
  (and no extra process is needed to find the repository root).
- `rev` is anything `git show` resolves (`HEAD~1`, a branch, a tag, a hash),
  plus the index: `""` is the *staged* version (not the worktree), and during a
  merge conflict `":1"`, `":2"`, `":3"` are the base, ours and theirs versions.
- A `rev` that starts with `-` or contains a line break is **refused**
  (`nil, "…invalid revision…"`): it is glued to the front of one argument, and
  an option such as `--pretty=format:X` would make git succeed with output
  that is not the file.

## Running git and reading someone else's history

Added for consumers that read the history of repositories the editor does not
own — a plugin manager's clones, the rows of a multi-repo overview. They need
what the helpers above do not expose: a **timeout**, an **environment**, the
**exit code** and **stderr**. Everything in this section takes
`Lib.Git.RunOpts` — `opts.dir` plus:

| Option | Meaning |
| --- | --- |
| `timeout_ms` | Kill git after this long; the result is `timed_out` (exit code `124`). On POSIX the whole process group is killed, on Windows the whole process tree, so a transport helper such as `git-remote-https` does not outlive the deadline. The async runner answers at the deadline plus a short grace even when a descendant keeps the pipes open. The network verbs below take `false` here too (no deadline) and apply a default. |
| `max_output_bytes` | Stop git once its stdout exceeds this many bytes: the result is `ok = false`, `code = 125`, `stderr` says why. One commit with a huge message makes `log` print gigabytes from a tiny object; without a cap all of it is held in memory. |
| `env` | Extra environment variables, merged over the inherited ones. |
| `no_lazy_fetch` | Never fetch missing objects of a partial (**blobless**) clone: git then *fails* on a missing object instead of quietly fetching it from the remote — no network, no write into the clone. Sets `GIT_NO_LAZY_FETCH=1` (git 2.44+, the primary lock) and `GIT_ALLOW_PROTOCOL=none` (every git since 2.10; an explicit `env` entry of the same name wins) **and** passes `-c protocol.allow=never`. `GIT_ALLOW_PROTOCOL` is what holds on older git and against a `protocol.<name>.allow` in the repository's or the user's config, which beats `-c protocol.allow=never`. The same switch blocks every transport, so a command that really needs the network (`fetch`) fails under it. |
| `read_only` | `--no-optional-locks`. `run`/`run_async` only; the read functions below always set it. |
| `input`, `binary` | stdin / byte-exact stdout. `run`/`run_async` only. |

### `run` / `run_async` — the generic runner

```lua
local res = git.run({ "rev-parse", "HEAD" }, { dir = repo, timeout_ms = 5000 })
-- { ok = true, code = 0, stdout = "…\n", stderr = "", timed_out = false }

git.run_async({ "log", "--stat" }, { dir = repo, no_lazy_fetch = true }, function(res)
  -- runs on the main loop (vim.schedule)
end)
```

`args` is what comes after `git` (and after `-C <opts.dir>`, which is added for
you). **Nothing validates the subcommand** — a caller that must stay read-only
restricts the verbs itself. The result reports everything: `code` is `124`
after `timeout_ms` (`timed_out`; a git that merely exits 124 by itself is not a
timeout), `128 + signal` when a signal killed git (`signal` holds it — the OS
reports exit status 0 for such a process, which must not read as success; `ok`
is `false` then), and `-1` when git could not be started at all, in which case
`stdout` is `""` and `stderr` holds the reason (without Neovim's `file:line`
stamp). `stderr` is `nil` only on a Neovim without `vim.system`.

### `log` / `log_async` / `parse_log` — commits, bodies and files in one process

```lua
local commits, err = git.log("v1.2.0..v1.3.0", {
  dir = clone,
  name_status = true,   -- entry.files: { status, path, orig_path? } per commit
  no_lazy_fetch = true, -- never fetch missing blobs of a blobless clone
  timeout_ms = 30000,
})
-- { { sha, parents, author, email, author_time, commit_time,
--     refs = { "HEAD -> main", "tag: v1.3.0" }, subject, body, files }, … }
```

`range` is anything `git log` takes as one argument; `nil` is `HEAD`. A range
without commits is `{}`; `nil` plus a reason means git failed (unknown
revision, a repository without commits, not a repository, timeout). Newest
commit first; `reverse`, `topo_order`, `no_merges`, `first_parent`,
`max_count` and `skip` do what the git flags of the same name do; `paths` are taken **literally** (`a[1].txt` is that file, not a glob; pass `pathspecs = true` for git's pathspec semantics). `refs` is git's decoration list and also holds the pseudo-decorations `grafted` (shallow boundary) and `replaced`. A date with hundreds of digits in a hostile commit gives `nil`, not `inf`.

- **`A...B` with `left_right`** sets `entry.side`: `>` for a commit only
  reachable from `B`, `<` for one only reachable from `A`. One call tells a
  fast-forward (`<` empty) from a rewound or diverged history.
- **`commit_time` is the committer time.** After a rebase the author time can
  be years older than the commit's place in the history.
- **One process** for the commits, their bodies *and* (with `name_status`)
  their changed files. Renames are reported as a delete plus an add
  (`--no-renames`): rename detection needs file contents and breaks halfway
  through in a blobless clone.
- **`subject`/`body` are normalised** (`\r\n` → `\n`, no trailing whitespace);
  paths are exact (`-z`), never C-quoted.
- **Hostile commit text is safe.** Fields and records are separated by `NUL`,
  and a commit message can never contain one (git's message buffer ends at the
  first `NUL`), so a message cannot forge a second commit. Treat the *text* as
  untrusted all the same — it can still contain terminal escape sequences.
  Trimming a message is linear even for a body of a million blanks.
- **Blobless clones:** `log` (with `name_status`) reads only commit and tree
  objects, so it works offline. Pair it with `no_lazy_fetch = true` to
  *guarantee* nothing is fetched.
- **A range named like a file is fine.** `--` always follows the range, so a
  `doc` branch next to a `doc` directory is not "ambiguous".
- **`files` of a merge** are empty — unless `first_parent` is set, which diffs a
  merge against its first parent.
- **The user's git config is pinned where it would break the parse:** the
  output encoding (`--encoding=UTF-8`) and the root commit's files (`--root`).
  `log.excludeDecoration` cannot be overridden from the command line and still
  hides matching names from `refs`.
- **No default timeout** — pass `timeout_ms` for a repository you do not own.
  `git` inherits `GIT_DIR`/`GIT_WORK_TREE` from the editor's environment, which
  win over `-C`; and `dir` is only where git starts looking, so a plugin
  directory without its own `.git` inside another repository reads *that*
  one.

`parse_log(raw, { left_right, name_status })` is the pure parser, for a caller
that runs git itself (`git log -z git.LOG_FORMAT [--name-status --no-renames]`;
`git.LOG_FORMAT` is the `--format=` argument `log` uses). It is
strict — a stray token, a cut-short record or a hash that is not 40/64 hex
digits is `nil, err`, never a guess.

### `rev_parse`, `merge_base`, `is_ancestor`

```lua
git.rev_parse("v2", { dir = repo })                      --> full object name (the tag object)
git.rev_parse("v2", { dir = repo, commit = true })       --> the commit it points to
git.rev_parse("HEAD", { dir = repo, short = 8 })         --> 8 digits
git.merge_base("main", "feature", { dir = repo })        --> sha, or nil, "no common ancestor"
git.is_ancestor(old, new, { dir = repo })                --> true (fast-forward) | false | nil, err
```

`is_ancestor` is three-valued on purpose: `false` ("not an ancestor — rewound
or diverged") must not be confused with `nil` ("git could not tell": unknown
revision, not a repository, timeout, killed by a signal). A revision that starts
with `-` (`--all`) or contains a line break is refused rather than handed to git
as an option. `short = n` asks for `n` digits; git never goes below 4.

All four have an `_async` twin with the same arguments plus `on_done`
(`rev_parse_async`, `merge_base_async`, `is_ancestor_async`, `tags_async`),
`vim.schedule`-dispatched and returning a `{ stop }` handle — the form to hand
to `lib.nvim.async.map_limit` when many repositories are asked at once. A
refused call (a bad revision) reports through `on_done` asynchronously too.

### `tags` — one process (two or more for a tag on a tag), with the metadata a changelog needs

```lua
git.tags({ dir = repo })                                 --> newest creator date first
git.tags({ dir = repo, merged = new, no_merged = old })  --> the tags an update brought in
git.tags({ dir = repo, sort = "version", pattern = "v1.*", limit = 5 })
-- { { name, sha, object, annotated, commit, time, subject }, … }
```

`sha` is the object a tag points to (peeled out of an annotated tag) — a commit when `commit` is `true`; a tag on a tree or a blob has `commit = false` and no `time`.
`object` is the tag's own object (equal to `sha` for a lightweight tag). `time` is
the tagger date of an annotated tag and the commit date of a lightweight one;
`subject` the first line of the tag message (annotated) or of the commit.
`sort` is `"newest"` (default), `"oldest"` or `"version"` (so `v1.10` is above
`v1.2`). `limit = 0` is no tags (git's own `--count=0` would mean all). Reads
ref and tag objects and works in a blobless clone, offline, except for a tag (annotated or not) on a
*blob* that the clone does not hold: `for-each-ref` needs that object's type and fetches it (with
`no_lazy_fetch` the whole call fails instead). A git that peels a tag on a
tag one level only (2.43) gets `git cat-file --batch` on the tag objects on top, one process per
hop and only when such a tag exists; if that fails, so does `tags` (`nil, err`), it never answers
with the one-level data. On that path a chain longer than 64 hops is an error. `stop()` on
`tags_async` makes `on_done` report `nil, err` once (`"git tags: stopped"` when the process had
already exited, else the process error).

## Syncing with the remote: `fetch_async`, `pull_async`, `push_async`, `update_async`

```lua
git.fetch_async({ dir = repo }, function(ok, err, changed) end)   -- git fetch --all --prune
git.pull_async({ dir = repo }, function(ok, err, changed) end)    -- git pull --ff-only
git.push_async({ dir = repo }, function(ok, err) end)             -- git push
local handle = git.update_async({ dir = repo }, function(ok, err, changed) end)  -- fetch, then pull
handle.stop()
```

Network calls, so only async: `on_done` runs on the main loop (`vim.schedule`) and the
returned `{ stop }` handle kills the job with SIGTERM. `opts` and `git_cmd` are as everywhere
else in this module; `opts` is a `Lib.Git.NetOpts`: a `Lib.Git.RunOpts` whose `timeout_ms` may also
be `false` (no deadline). Of its fields these verbs use `dir`, `env` and `timeout_ms`;
`no_lazy_fetch` is honoured too, as `-c protocol.allow=never`, which blocks every transport, so a
verb that needs the network fails under it; `max_output_bytes`, `read_only`, `input` and `binary`
have no effect on them. Unlike the read functions, these change something: `fetch_async` moves
remote-tracking refs, `pull_async`/`update_async` the working tree and `HEAD`, `push_async` the
remote.

- **`ok = false` carries a reason.** `err` is git's own stderr, or "git pull failed (exit code
  N)" when git wrote nothing. A `pull_async` that cannot fast-forward (diverged history, local
  changes the pull would overwrite) fails with git's reason instead of creating a merge commit.
- **`changed`** is what the verb moved: for `fetch_async` a remote-tracking ref (read off git's
  ref-update lines on stderr; a warning, an auto-gc note or a push mirror's `-> FETCH_HEAD` line
  is no change; `nil` — unknown — on a Neovim without `vim.system`, which cannot separate the streams),
  for `pull_async` whether `HEAD` is a different commit afterwards (compared by hash, never by
  git's translatable message), for `update_async` the pull's. `nil` also when the answer could not
  be read, never a guess.
- **A killed git is a failure.** On POSIX the OS reports a process killed by a signal (`stop()`,
  the OOM killer) as exit code 0 plus a signal, which would read as a success: a half-finished
  push would be reported as pushed. All four verbs — and the async readers `status_porcelain_async`,
  `show_async` and `blame_porcelain_async` — turn it into `ok = false` (an `err`, no value) with
  `code = 128 + signal` (`err` = "git push failed (exit code 143)" for SIGTERM), as `run`/
  `run_async` already did. "Exit code 143" is the POSIX shape: on Windows (Neovim 0.12.2) libuv
  delivers a killed process as exit code 1 with signal 15, so the message names exit code 1 there.
- **A git that cannot be started is a failure with its reason** — `git_cmd` not found or not on
  `$PATH`: `err` is "ENOENT: no such file or directory (cmd): 'git'", without Neovim's
  `file:line` stamp, not "exit code -1".
- **No prompt, a deadline.** Neovim has no terminal to type into, so a prompt git raises itself
  (https credentials, `Username for ...`) would hang the job forever. The verbs run with
  `GIT_TERMINAL_PROMPT=0` (git fails instead; credential helpers are unaffected) and kill git
  after 120 s: `err` is "git fetch timed out after 120s". `opts.env` wins over the prompt
  default (`{ GIT_TERMINAL_PROMPT = "1" }` allows prompts), `opts.timeout_ms` replaces the
  deadline per git process (`pull_async` runs three: HEAD before, the pull, HEAD after, and
  `update_async` a fourth, the fetch, so the worst case is three or four deadlines; the HEAD
  reads share `opts.env` too), `false` waits forever. A HEAD-before read that hit the deadline or
  was killed by a signal makes `changed` `nil` (the HEAD-after read is then not run). An ssh host-key or passphrase prompt is not covered by
  `GIT_TERMINAL_PROMPT`; the deadline catches it.
- **After `stop()`.** `pull_async` and `update_async` are chains of processes (HEAD before, pull,
  HEAD after; fetch, then pull) and stay silent once `stop()` has been called: `on_done` never
  fires, at whichever stage the `stop()` lands, and `update_async` does not start its pull when
  the `stop()` arrived just as the fetch finished — the working tree does not move after the
  caller cancelled. `fetch_async` and `push_async` are a single process: their `on_done` still
  fires once after `stop()`, with the kill reported as the failure above. (On Windows that call can
  come late: libuv reports the exit only after helper processes such as `git-remote-http` have
  ended too, so do not wait for it to confirm a cancel.)

## Remote URLs: `lib.nvim.git.remote`

Pure — no process, no `vim.api` — parsing and building for GitHub, GitLab,
Codeberg and self-hosted instances a caller declares:

```lua
local remote = require("lib.nvim.git.remote")

local r = remote.parse_remote(git.remote_url(nil, { dir = repo })) --> { host, owner, repo }
local kind = remote.host_kind(r.host)                      --> "github" | "gitlab" | "codeberg" | nil
-- host_kind(host, hosts_cfg): hosts_cfg maps a self-hosted host name to its kind; optional

remote.build(kind, r, "main", "lua/a.lua", 10, 20)      -- a file with a line range
remote.commit_url(kind, r, sha)                          -- …/commit/<sha>      (GitLab: …/-/commit/<sha>)
remote.compare_url(kind, r, old, new)                    -- …/compare/old...new (GitLab: …/-/compare/…)
remote.tag_url(kind, r, "v1.2.3")                        -- …/releases/tag/v1.2.3 (GitLab: …/-/tags/v1.2.3)
```

`parse_remote` validates what it returns (a remote URL is text from a repository's own config): a plain DNS-style host (lower-cased, the ssh port dropped), owner segments and a repo name of letters, digits, `.`, `_`, `-`; anything else — `?`, `#`, spaces, control characters, `..` — gives `nil`. Every ref/path part is percent-encoded segment by segment (a `/` in a branch or
tag name stays the separator; `.` and `..` segments are dropped). Nothing is shelled out or fetched — the URL is
only built. The GitHub shapes are the ones every GitHub link uses; the
GitLab and Gitea/Forgejo (Codeberg) shapes are the documented ones, not
verified against a live instance here.

## Commit references: `lib.nvim.git.commit_ref`

Turns a commit reference in text into a commit: a bare hash (7 to 40 hex digits) or `repo@hash`, the form of the
`commits:` fields and notes of the task vaults. `repo@a..b` is accepted and resolves as its **first** commit
(`to` keeps the second hash; what a range means is the caller's call).

```lua
local cr = require("lib.nvim.git.commit_ref")

-- By form only: no git, cheap enough for a hover trigger.
cr.parse("tasks.nvim@a02ddae")        --> { repo = "tasks.nvim", sha = "a02ddae" }
cr.parse("deadbeef")                  --> nil  (a hex WORD: a bare hash needs a digit and a letter)
cr.token_at(line, col)                --> { sha, repo?, to?, first, last } | nil

cr.resolve_async(ref, { dir = buf_dir }, function(res)
  -- res.status: "local" | "missing" | "ambiguous" | "no_repo"
  -- local: res.dir, res.full, res.url (web URL, nil for an unknown host), res.remote
end)
cr.fetch_async(res, opts, function(ok, err) end)   -- `git fetch <remote> <hash>`, only on request
cr.lines_async(res, { patch = false }, function(lines, err) end)  -- summary + stat, or the whole `git show`
```

`repo@` looks for `<root>/<repo>` in `opts.roots` (default `$REPOS_DIR` and `$REPOS_DIR/repos`), wherever the buffer
is; a bare hash uses `opts.dir`, then the cwd. The web URL comes from the remote (`opts.remote`, default `origin`)
for the hosts `remote.host_kind` knows plus `opts.hosts`; an unknown host gives no URL and no error. A `local` result
is cached for the session, `missing` for 30 seconds (`opts.cache = false` skips the cache, `clear_cache()` drops it).
Every git call goes through `run_async`; a missing object is never lazily fetched. A server that refuses a fetch by
hash leaves the commit `missing` and `fetch_async` reports git's message. A short hash cannot be named to a server: `fetch_async` then fetches the remote's branches (resolve again afterwards).

## Diagnostics cleanup helper

```lua
local ns = vim.api.nvim_create_namespace("my-plugin-diff")
local clear = git.clear_line_diff(ns)   -- binds ns once

vim.api.nvim_create_autocmd("BufLeave", {
  callback = function(args) clear(args.buf) end,
})
```

`clear_line_diff(ns)` returns a `fun(buf: integer)` closure that clears all
virtual text in namespace `ns` for a given buffer — guards against an invalid
buffer (already wiped) before calling `nvim_buf_clear_namespace`.
