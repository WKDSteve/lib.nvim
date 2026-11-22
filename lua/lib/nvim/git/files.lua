---@module 'lib.nvim.git.files'
--- A repository's current branch and remote URL, read from the files in
--- `.git` instead of asking a `git` process.
---
--- `git symbolic-ref` and `git remote get-url` cost a synchronous process each
--- (25-100 ms on Windows) for answers that sit in two small files: `HEAD`
--- (`ref: refs/heads/<branch>`) and `config` (`[remote "origin"] url = ...`).
--- This module reads them directly (`git.current_ref_fast`,
--- `git.remote_url_fast` are the public entry points) and hands everything it
--- cannot answer exactly the way git would back to git, remembered per file
--- content (a changed `HEAD` or `config` is a new key, so a remembered answer
--- is never stale):
---   * a detached HEAD (git abbreviates the sha to a length only it knows),
---     a HEAD outside `refs/heads/`, a reftable repository (its `HEAD` file is
---     a stub);
---   * a config that includes other files, rewrites URLs (`insteadOf`, also
---     in the global config), has per-worktree config, or a URL value with
---     quoting, escapes or comments;
---   * `GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR` or `GIT_CONFIG*` in the
---     environment (git would look elsewhere).
--- Not followed (git may answer differently): the system config
--- (`/etc/gitconfig`, `<git>/etc/gitconfig`) rewriting URLs, a bare
--- repository (no `.git` to find: nil), `safe.directory` refusals, and a
--- branch name that is also a tag name (`symbolic-ref --short` then says
--- `heads/<name>`, this reader `<name>`).
---
--- The commit of HEAD and of its upstream come from the same files plus the
--- refs (`ref_sha`, `head`, `head_sha`, `upstream`; `git.head_hash_fast`,
--- `git.ahead_behind_fast`); what they cannot answer says `unsure`.
---
--- Plain `io` and `string` for the reading, so the functions are cheap enough
--- for a statusline or a scan over many repositories.

local M = {}

---Remembered git answers, keyed by the file content they were asked for.
---Emptied in place once it grows past `CACHE_MAX`.
---@type table<string, string|false>
local cache = {}
local cache_size = 0
local CACHE_MAX = 64

---@param path string
---@return string|nil
local function read(path)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local ok, text = pcall(fd.read, fd, "*a")
  fd:close()
  if ok and type(text) == "string" then
    return text
  end
  return nil
end

---@param s string
---@return string
local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---@param p string
---@return boolean
local function is_absolute(p)
  return p:sub(1, 1) == "/" or p:match("^%a:[/\\]") ~= nil
end

---@param base string
---@param p string
---@return string
local function resolve(base, p)
  p = p:gsub("\\", "/")
  if is_absolute(p) then
    return p
  end
  return base .. "/" .. p
end

---@param name string
---@return boolean
local function env_set(name)
  local v = vim.env[name]
  return v ~= nil and v ~= ""
end

--- True when the environment points git somewhere this reader does not look.
---@return boolean
function M.env_redirects()
  return env_set("GIT_DIR")
    or env_set("GIT_WORK_TREE")
    or env_set("GIT_COMMON_DIR")
    or env_set("GIT_CONFIG")
    or env_set("GIT_CONFIG_GLOBAL")
    or env_set("GIT_CONFIG_COUNT")
    or env_set("GIT_CONFIG_PARAMETERS")
end

---@class Lib.Git.Files.Info
---@field gitdir string    This worktree's git directory (`HEAD` lives here).
---@field commondir string The shared git directory (`config` lives here).
---@field top string       The directory holding `.git`.

---Where the repository's files live for `dir`: the nearest `.git` at or
---above it, a `.git` *file* (`gitdir: ...`, a linked worktree or submodule)
---followed, `commondir` honoured. nil when there is none.
---@param dir string An absolute directory (forward or back slashes).
---@return Lib.Git.Files.Info|nil
function M.find(dir)
  dir = dir:gsub("\\", "/"):gsub("/+$", "")
  while dir ~= "" do
    local gitdir
    if read(dir .. "/.git/HEAD") then
      gitdir = dir .. "/.git"
    else
      local text = read(dir .. "/.git")
      local target = text and text:match("^gitdir:%s*(.-)%s*$")
      if target and target ~= "" then
        gitdir = resolve(dir, target)
      end
    end
    if gitdir then
      local common = read(gitdir .. "/commondir")
      common = common and trim(common) or ""
      local commondir = common ~= "" and resolve(gitdir, common) or gitdir
      return { gitdir = gitdir, commondir = commondir, top = dir }
    end
    local parent = dir:match("^(.*)/[^/]*$")
    if not parent or parent == dir then
      break
    end
    dir = parent
  end
  return nil
end

---Ask git once per `key` and remember the answer (`false`: git had none).
---@param key string
---@param ask fun(): string|nil
---@return string|nil
function M.remembered(key, ask)
  local hit = cache[key]
  if hit == nil then
    local ok, value = pcall(ask)
    hit = (ok and type(value) == "string" and value ~= "") and value or false
    if cache_size >= CACHE_MAX then
      for k in pairs(cache) do
        cache[k] = nil
      end
      cache_size = 0
    end
    cache[key] = hit
    cache_size = cache_size + 1
  end
  return hit or nil
end

---Forget every remembered git answer.
function M.clear()
  for k in pairs(cache) do
    cache[k] = nil
  end
  cache_size = 0
end

---@param text string|nil
---@return boolean
local function rewrites_urls(text)
  if not text then
    return false
  end
  local lower = text:lower()
  return lower:find("insteadof", 1, true) ~= nil or lower:find("%[%s*include") ~= nil
end

---The global config files git reads (`~/.gitconfig`, the XDG one).
---@return string[]
local function global_configs()
  local home = vim.env.HOME
  if (home == nil or home == "") and vim.fn.has("win32") == 1 then
    home = vim.env.USERPROFILE
  end
  local list = {}
  if home and home ~= "" then
    list[#list + 1] = home .. "/.gitconfig"
  end
  local xdg = vim.env.XDG_CONFIG_HOME
  if xdg and xdg ~= "" then
    list[#list + 1] = xdg .. "/git/config"
  elseif home and home ~= "" then
    list[#list + 1] = home .. "/.config/git/config"
  end
  return list
end

---The `url` of `[remote "<name>"]` in a config text, the first one like
---`git remote get-url`. `unsure` when the text could change the answer in a
---way this reader does not follow (includes, URL rewrites, per-worktree
---config, quoting, a key on the header line, the old `[remote.x]` form).
---@param text string
---@param name string
---@return string|nil url
---@return boolean unsure
function M.config_url(text, name)
  local lower = text:lower()
  if rewrites_urls(text) or lower:find("worktreeconfig", 1, true) then
    return nil, true
  end
  local in_section = false
  for line in text:gmatch("[^\r\n]+") do
    local header, rest = line:match("^%s*%[(.-)%](.*)$")
    if header then
      if trim(rest) ~= "" and not trim(rest):match("^[#;]") then
        return nil, true -- `[remote "x"] url = ...` on one line
      end
      local kind, sub = header:match('^%s*(%S+)%s+"(.*)"%s*$')
      if not kind and header:lower():match("^%s*remote%.") then
        return nil, true -- the old `[remote.origin]` spelling
      end
      in_section = kind ~= nil and kind:lower() == "remote" and sub == name
    elseif in_section then
      local key, value = line:match("^%s*([%w%-]+)%s*=%s*(.-)%s*$")
      if key and key:lower() == "url" then
        if value == "" or value:find('["\\]') or value:find("[#;]") then
          return nil, true
        end
        return value, false
      end
    end
  end
  return nil, false
end

---The URL of remote `name` for the repository at or above `dir`, like
---`git remote get-url -- <name>`. `ask_git` answers what the files cannot
---(called at most once per config content).
---@param dir string Absolute directory.
---@param name string
---@param ask_git fun(): string|nil
---@return string|nil
function M.remote_url(dir, name, ask_git)
  if M.env_redirects() then
    return ask_git()
  end
  local info = M.find(dir)
  if not info then
    return nil
  end
  local text = read(info.commondir .. "/config") or ""
  local url, unsure = M.config_url(text, name)
  -- The global config takes part in the key too: a changed `insteadOf` there
  -- must not leave an old rewritten answer behind.
  local key = { "remote", info.commondir, info.gitdir, name, text }
  for _, path in ipairs(global_configs()) do
    local global = read(path)
    key[#key + 1] = global or ""
    if rewrites_urls(global) then
      unsure = true
    end
  end
  if not unsure then
    return url
  end
  return M.remembered(table.concat(key, "\0"), ask_git)
end

---The current branch of the repository at or above `dir`, or for a detached
---HEAD git's short sha (what `git.current_ref` answers); nil outside a
---repository. `ask_git` answers what the files cannot (detached or unusual
---HEAD, reftable), once per `HEAD` content.
---@param dir string Absolute directory.
---@param ask_git fun(detached: boolean): string|nil
---@return string|nil
function M.current_ref(dir, ask_git)
  if M.env_redirects() then
    return ask_git(false)
  end
  local info = M.find(dir)
  if not info then
    return nil
  end
  local head = read(info.gitdir .. "/HEAD")
  if not head then
    return nil
  end
  head = trim(head)
  local branch = head:match("^ref:%s*refs/heads/(.+)$")
  if branch == ".invalid" then
    -- A reftable repository keeps a stub `HEAD` naming `.invalid`; the real
    -- one is in the reftable. Its content never changes, so it is no key.
    return ask_git(false)
  end
  if branch then
    return branch
  end
  local detached = head:match("^%x+$") ~= nil
  return M.remembered(table.concat({ "ref", info.gitdir, head }, "\0"), function()
    return ask_git(detached)
  end)
end

---@param s string|nil
---@return boolean
local function is_sha(s)
  return s ~= nil and (#s == 40 or #s == 64) and s:match("^%x+$") ~= nil
end

---The refs that live in a worktree's own git directory, not in the common
---one: git's `refs/worktree/`, `refs/bisect/`, `refs/rewritten/` and the
---pseudo refs at the top (`HEAD`, `ORIG_HEAD`, ...).
---@param ref string
---@return boolean
local function per_worktree(ref)
  return not ref:find("/")
    or ref:match("^refs/worktree/") ~= nil
    or ref:match("^refs/bisect/") ~= nil
    or ref:match("^refs/rewritten/") ~= nil
end

---Whether the repository keeps its refs in a reftable (its `HEAD` file is a
---stub then, and loose refs and `packed-refs` say nothing).
---@param info Lib.Git.Files.Info
---@return boolean
local function is_reftable(info)
  return read(info.commondir .. "/reftable/tables.list") ~= nil
end

---The commit a ref names, as git resolves it: the loose file first (it wins
---over `packed-refs`), then `packed-refs`; a symbolic ref (`ref: ...`) is
---followed, five steps at most. A per-worktree ref is read from the
---worktree's own git directory.
---@param info Lib.Git.Files.Info What `find` answered.
---@param ref string A full ref name, e.g. `refs/heads/main`.
---@return string|nil sha Lower case; nil: the ref does not exist (an unborn branch, an upstream never fetched) or `unsure`.
---@return boolean|nil unsure The files do not answer it the way git would (a reftable, a ref file that is neither a sha nor a ref, a name with `..`); ask git.
function M.ref_sha(info, ref)
  if is_reftable(info) then
    return nil, true
  end
  for _ = 1, 5 do
    if type(ref) ~= "string" or ref:find("%.%.") or ref:find("[%z\r\n]") then
      return nil, true
    end
    local base = per_worktree(ref) and info.gitdir or info.commondir
    local loose = read(base .. "/" .. ref)
    if loose then
      local text = trim(loose)
      if is_sha(text) then
        return text:lower(), nil
      end
      local next_ref = text:match("^ref:%s*(%S+)$")
      if not next_ref then
        return nil, true
      end
      ref = next_ref
    else
      local packed = read(info.commondir .. "/packed-refs")
      if packed then
        for line in packed:gmatch("[^\r\n]+") do
          local sha, name = line:match("^(%x+) (%S+)$")
          if name == ref and is_sha(sha) then
            return sha:lower(), nil
          end
        end
      end
      return nil, nil
    end
  end
  return nil, true
end

---@class Lib.Git.Files.Head
---@field sha string|nil    The commit of HEAD; nil on an unborn branch.
---@field branch string|nil The branch HEAD is on (`main`); nil when HEAD is detached.
---@field info Lib.Git.Files.Info

---The commit HEAD is at and the branch it is on, from the files.
---@param dir string An absolute directory inside the work tree.
---@return Lib.Git.Files.Head|nil head nil: no repository, or `unsure`.
---@return boolean|nil unsure The files do not answer it the way git would (`GIT_DIR` and friends in the environment, a reftable, a HEAD outside `refs/heads/`); ask git.
function M.head(dir)
  if M.env_redirects() then
    return nil, true
  end
  local info = M.find(dir)
  if not info then
    return nil, nil
  end
  if is_reftable(info) then
    return nil, true
  end
  local text = read(info.gitdir .. "/HEAD")
  if not text then
    return nil, true
  end
  text = trim(text)
  if is_sha(text) then
    return { sha = text:lower(), info = info }, nil
  end
  local branch = text:match("^ref:%s*refs/heads/(%S+)$")
  if not branch or branch == ".invalid" then
    return nil, true
  end
  local sha, unsure = M.ref_sha(info, "refs/heads/" .. branch)
  if unsure then
    return nil, true
  end
  return { sha = sha, branch = branch, info = info }, nil
end

---The full commit of HEAD (`git rev-parse HEAD`), from the files.
---@param dir string An absolute directory inside the work tree.
---@return string|nil sha nil: no repository, an unborn branch, or `unsure`.
---@return boolean|nil unsure Ask git (see `head`).
function M.head_sha(dir)
  local head, unsure = M.head(dir)
  if unsure then
    return nil, true
  end
  return head and head.sha or nil, nil
end

---The keys of one `[section "sub"]` of a git config text, as git reads them:
---section names and keys without case, the subsection with it, a comment
---after a value dropped. `unsure` when the text could change the answer in a
---way this reader does not follow: an `include`/`includeIf`, per-worktree
---config, the old `[section.sub]` form, a line it cannot parse.
---
---A key whose value this reader cannot take literally -- quoted or escaped
---(a Windows path in a `url` is written with `\\`), or given more than once
---(a multi-valued key such as a second `fetch`) -- is left out of `values`
---and named in `unclear`: it does not make the other keys unsure.
---@param text string
---@param section string Lower case, e.g. `branch`.
---@param sub string
---@return table<string, string> values Keys lower case.
---@return boolean unsure
---@return table<string, true> unclear Keys (lower case) whose value is not in `values` for the reasons above.
function M.config_section(text, section, sub)
  local lower = text:lower()
  if lower:find("%[%s*include") or lower:find("worktreeconfig") then
    return {}, true, {}
  end
  local values, unclear, inside = {}, {}, false
  for line in text:gmatch("[^\r\n]+") do
    local stripped = trim(line)
    if stripped:sub(1, 1) == "[" then
      local name, quoted = stripped:match('^%[%s*([%w%.%-]+)%s+"(.-)"%s*%]$')
      if name then
        inside = name:lower() == section and quoted == sub
      elseif stripped:match("^%[%s*[%w%.%-]+%s*%]$") then
        inside = false
        if stripped:match("^%[%s*[%w%-]+%.") then
          return {}, true, {} -- `[branch.main]`: a case-folded subsection
        end
      else
        return {}, true, {}
      end
    elseif inside and stripped ~= "" and not stripped:match("^[#;]") then
      local key, value = stripped:match("^([%w%-]+)%s*=%s*(.-)$")
      if not key then
        return {}, true, {}
      end
      key = key:lower()
      value = value:gsub("%s+[#;].*$", "")
      if unclear[key] or values[key] ~= nil or value:find('["\\]') then
        values[key] = nil
        unclear[key] = true
      else
        values[key] = trim(value)
      end
    end
  end
  return values, false, unclear
end

---@class Lib.Git.Files.Upstream
---@field head string     The commit of HEAD.
---@field upstream string The commit of the branch HEAD tracks (`@{u}`), as the last fetch left it.
---@field branch string   The branch HEAD is on.

---The commits of HEAD and of its upstream (`@{u}`), from the files: the
---branch in `branch.<name>.merge`, from the remote in `branch.<name>.remote`
---through the default fetch refspec (`refs/remotes/<remote>/<branch>`), or a
---local branch (`remote = .`).
---@param dir string An absolute directory inside the work tree.
---@return Lib.Git.Files.Upstream|nil pair nil: no repository, an unborn or detached HEAD, an upstream never fetched -- or `unsure`.
---@return boolean|nil unsure Ask git: see `head` and `config_section`; also a fetch refspec other than the default, and a branch without an upstream in this repository's config (the global config may still name one).
function M.upstream(dir)
  local head, unsure = M.head(dir)
  if unsure then
    return nil, true
  end
  if not head or not head.sha or not head.branch then
    return nil, nil
  end
  local config = read(head.info.commondir .. "/config")
  if not config then
    return nil, true
  end
  -- a missing key is unsure too: the global config may still name the upstream
  local branch, bad = M.config_section(config, "branch", head.branch)
  if bad or not branch.merge or not branch.remote then
    return nil, true
  end
  local merged = branch.merge:match("^refs/heads/(.+)$")
  if not merged then
    return nil, true
  end
  local ref
  if branch.remote == "." then
    ref = "refs/heads/" .. merged
  else
    local remote, rbad = M.config_section(config, "remote", branch.remote)
    if rbad or remote.fetch ~= ("+refs/heads/*:refs/remotes/%s/*"):format(branch.remote) then
      return nil, true
    end
    ref = ("refs/remotes/%s/%s"):format(branch.remote, merged)
  end
  local upstream, uns = M.ref_sha(head.info, ref)
  if uns then
    return nil, true
  end
  if not upstream then
    return nil, nil
  end
  return { head = head.sha, upstream = upstream, branch = head.branch }, nil
end

return M
