-- TESTS/git_files_spec.lua — git.current_ref_fast / git.remote_url_fast
--
-- The branch and the remote URL read from `.git/HEAD` and `.git/config`
-- instead of a git process each. Pinned on real fixture repositories, every
-- answer compared with git's own (`current_ref`, `remote_url`), and every
-- `vim.system` start counted: the usual cases start nothing, the cases the
-- files cannot answer exactly go to git once per file content.
--
-- HOME / XDG_CONFIG_HOME point at an empty directory for the whole spec, so
-- the runner's own global git config (a global `insteadOf`) cannot change
-- what is being measured; one case writes a global config there on purpose.

return function(H)
  local git = require("lib.nvim.git")
  local files = require("lib.nvim.git.files")
  local dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
  local F = dofile(dir .. "git_fixture.lua")(H)

  --- `fn` with every `vim.system` start counted.
  ---@return integer starts
  ---@return any result
  local function counted(fn)
    local n = 0
    local real = vim.system
    local result
    H.with_patched(vim, "system", function(...)
      n = n + 1
      return real(...)
    end, function()
      result = fn()
    end)
    return n, result
  end

  local home = F.tmpdir("-home")
  local env = {
    { "HOME", home },
    { "USERPROFILE", home },
    { "XDG_CONFIG_HOME", home .. "/xdg" },
    { "GIT_DIR", nil },
    { "GIT_WORK_TREE", nil },
    { "GIT_COMMON_DIR", nil },
    { "GIT_CONFIG", nil },
    { "GIT_CONFIG_GLOBAL", nil },
    { "GIT_CONFIG_COUNT", nil },
    { "GIT_CONFIG_PARAMETERS", nil },
  }
  local saved = {}
  for _, e in ipairs(env) do
    saved[e[1]] = vim.env[e[1]]
    vim.env[e[1]] = e[2]
  end

  local ok, err = pcall(function()
    files.clear()

    -- ── a normal checkout ──────────────────────────────────────────────
    local repo = F.init("-files-normal")
    F.commit(repo, "one")
    F.git(repo, { "remote", "add", "origin", "https://github.com/acme/widget.git" })
    F.git(repo, { "remote", "add", "fork", "git@github.com:me/widget.git" })
    F.git(repo, { "checkout", "-q", "-b", "feature/x" })

    local n, ref = counted(function()
      return git.current_ref_fast(repo)
    end)
    H.eq(ref, git.current_ref(repo), "branch: same as git")
    H.eq(ref, "feature/x", "branch: a name with a slash")
    H.eq(n, 0, "branch: no process")

    local n2, url = counted(function()
      return git.remote_url_fast("origin", { dir = repo })
    end)
    H.eq(url, git.remote_url("origin", { dir = repo }), "origin: same as git")
    H.eq(n2, 0, "origin: no process")
    H.eq(
      git.remote_url_fast("fork", { dir = repo }),
      "git@github.com:me/widget.git",
      "another remote by name"
    )
    H.eq(git.remote_url_fast(nil, { dir = repo }), url, "origin is the default")

    local n3, missing = counted(function()
      return git.remote_url_fast("nope", { dir = repo })
    end)
    H.eq(missing, git.remote_url("nope", { dir = repo }), "unknown remote: nil like git")
    H.eq(n3, 0, "unknown remote: no process")

    -- From a subdirectory, and with the cwd as default.
    vim.fn.mkdir(repo .. "/sub/deeper", "p")
    H.eq(git.current_ref_fast(repo .. "/sub/deeper"), "feature/x", "found from a subdirectory")
    local cwd = vim.uv.cwd()
    vim.cmd.cd(vim.fn.fnameescape(repo .. "/sub"))
    local ok_cwd, cwd_ref, cwd_url = pcall(function()
      return git.current_ref_fast(), git.remote_url_fast()
    end)
    vim.cmd.cd(vim.fn.fnameescape(cwd))
    H.ok(ok_cwd, tostring(cwd_ref))
    H.eq(cwd_ref, "feature/x", "no dir: the cwd")
    H.eq(cwd_url, url, "no opts: the cwd")

    -- ── a linked worktree: `.git` is a file, config in the common dir ─────
    local wt = F.tmpdir("-files-wt")
    vim.fn.delete(wt, "rf")
    F.git(repo, { "worktree", "add", "-q", "-b", "wt-branch", wt })
    local n4, wt_ref = counted(function()
      return git.current_ref_fast(wt)
    end)
    H.eq(wt_ref, git.current_ref(wt), "worktree branch: same as git")
    H.eq(wt_ref, "wt-branch", "worktree: its own HEAD, not the main one")
    H.eq(git.remote_url_fast("origin", { dir = wt }), url, "worktree: the shared config")
    H.eq(n4, 0, "worktree: no process")

    -- ── a `.git` file with a relative gitdir (how submodules look) ───────
    local sub = F.tmpdir("-files-submodule")
    local real_gitdir = sub .. "/modules/inner"
    vim.fn.mkdir(sub .. "/modules", "p")
    F.git(sub, { "init", "-q", "-b", "inner-main", "--separate-git-dir", real_gitdir, "inner" })
    local text = table.concat(vim.fn.readfile(sub .. "/inner/.git"), "\n")
    -- git writes this file hidden on Windows: replace it, do not open it for writing.
    vim.fn.delete(sub .. "/inner/.git")
    F.write(sub .. "/inner/.git", "gitdir: ../modules/inner\n")
    H.ok(text:find("gitdir:", 1, true), "fixture: separate git dir")
    H.eq(git.current_ref_fast(sub .. "/inner"), git.current_ref(sub .. "/inner"), "relative gitdir")

    -- ── detached HEAD: git once per HEAD content ──────────────────────────
    F.git(repo, { "checkout", "-q", "--detach" })
    local n5, det = counted(function()
      return git.current_ref_fast(repo)
    end)
    H.eq(det, git.current_ref(repo), "detached: git's short sha")
    H.eq(n5, 1, "detached: one process (not symbolic-ref + rev-parse)")
    local n6, det2 = counted(function()
      return git.current_ref_fast(repo)
    end)
    H.eq(det2, det, "detached again: same answer")
    H.eq(n6, 0, "detached again: remembered")
    F.commit(repo, "two")
    local det3 = git.current_ref_fast(repo)
    H.eq(det3, git.current_ref(repo), "HEAD moved: the new sha, never the remembered one")
    H.ok(det3 ~= det, "HEAD moved: a different answer")
    F.git(repo, { "checkout", "-q", "feature/x" })
    H.eq(git.current_ref_fast(repo), "feature/x", "back on a branch")

    -- ── insteadOf in the repository: git rewrites, so git answers ────────
    F.git(repo, { "config", "url.ssh://git@example.org/.insteadOf", "https://github.com/" })
    local n7, rew = counted(function()
      return git.remote_url_fast("origin", { dir = repo })
    end)
    H.eq(rew, git.remote_url("origin", { dir = repo }), "insteadOf: git's rewritten URL")
    H.eq(rew, "ssh://git@example.org/acme/widget.git", "insteadOf applied")
    H.eq(n7, 1, "insteadOf: one process")
    local n8 = counted(function()
      return git.remote_url_fast("origin", { dir = repo })
    end)
    H.eq(n8, 0, "insteadOf: remembered per config content")
    F.git(repo, { "config", "--unset", "url.ssh://git@example.org/.insteadOf" })
    H.eq(git.remote_url_fast("origin", { dir = repo }), url, "config changed: read again")

    -- ── insteadOf in the global config ────────────────────────────────────
    F.write(
      home .. "/.gitconfig",
      '[url "https://mirror.example/"]\n\tinsteadOf = https://github.com/\n'
    )
    local n9, grew = counted(function()
      return git.remote_url_fast("origin", { dir = repo })
    end)
    H.eq(grew, git.remote_url("origin", { dir = repo }), "global insteadOf: git's answer")
    H.eq(grew, "https://mirror.example/acme/widget.git", "global insteadOf applied")
    H.eq(n9, 1, "global insteadOf: one process")
    vim.fn.delete(home .. "/.gitconfig")
    H.eq(git.remote_url_fast("origin", { dir = repo }), url, "global config gone: read again")

    -- ── a URL value the reader does not parse: quoted ────────────────────
    local q = F.init("-files-quoted")
    F.write(
      q .. "/.git/config",
      '[core]\n\tbare = false\n[remote "origin"]\n\turl = "https://h.example/a/b.git"\n'
    )
    local n10, qurl = counted(function()
      return git.remote_url_fast("origin", { dir = q })
    end)
    H.eq(qurl, git.remote_url("origin", { dir = q }), "quoted value: git's answer")
    H.eq(n10, 1, "quoted value: git asked")

    -- ── GIT_DIR in the environment: git decides ──────────────────────────
    vim.env.GIT_DIR = repo .. "/.git"
    local n11, envref = counted(function()
      return git.current_ref_fast(q)
    end)
    vim.env.GIT_DIR = nil
    H.eq(envref, "feature/x", "GIT_DIR: git's answer for that repository")
    H.eq(n11, 1, "GIT_DIR: git asked")

    -- ── reftable: the HEAD file is a stub, git answers every time ─────────
    local rt = F.tmpdir("-files-reftable")
    local _, rt_code = F.git(
      rt,
      { "init", "-q", "-b", "rt-main", "--ref-format=reftable" },
      { allow_fail = true }
    )
    if rt_code == 0 then
      F.commit(rt, "one")
      F.git(rt, { "checkout", "-q", "-b", "rt-other" })
      local n_rt, rt_ref = counted(function()
        return git.current_ref_fast(rt)
      end)
      H.eq(rt_ref, "rt-other", "reftable: git's answer, not the stub's '.invalid'")
      H.eq(n_rt, 1, "reftable: git asked")
      F.git(rt, { "checkout", "-q", "rt-main" })
      H.eq(git.current_ref_fast(rt), "rt-main", "reftable: never remembered")
    else
      H.skipped("git_files_spec reftable", "this git cannot init a reftable repository")
    end

    -- ── not a repository ─────────────────────────────────────────────────
    local none = F.tmpdir("-files-none")
    local n12, r1 = counted(function()
      return git.current_ref_fast(none)
    end)
    H.eq(r1, nil, "no repository: nil")
    H.eq(git.remote_url_fast("origin", { dir = none }), nil, "no repository: no URL")
    H.eq(n12, 0, "no repository: no process")

    -- ── the config reader on its own ─────────────────────────────────────
    local function cu(t)
      return { files.config_url(t, "origin") }
    end
    H.eq(cu('[remote "origin"]\n  URL = x:y/z\n')[1], "x:y/z", "key case-insensitive")
    H.eq(cu('[Remote "origin"]\nurl = a\n')[1], "a", "section case-insensitive")
    H.eq(cu('[remote "Origin"]\nurl = a\n')[1], nil, "subsection case-sensitive")
    H.eq(cu('[remote "origin"]\nurl = a\nurl = b\n')[1], "a", "the first url, like get-url")
    H.eq(cu('[remote "origin"] url = a\n')[2], true, "key on the header line: unsure")
    H.eq(cu("[remote.origin]\nurl = a\n")[2], true, "old section form: unsure")
    H.eq(cu('[remote "origin"]\nurl = a ; c\n')[2], true, "comment in value: unsure")
    H.eq(cu('[include]\npath = x\n[remote "origin"]\nurl = a\n')[2], true, "include: unsure")
    H.eq(cu("[extensions]\nworktreeConfig = true\n")[2], true, "worktree config: unsure")
  end)

  for _, e in ipairs(env) do
    vim.env[e[1]] = saved[e[1]]
  end
  files.clear()
  F.cleanup()
  if not ok then
    error(err, 0)
  end
end
