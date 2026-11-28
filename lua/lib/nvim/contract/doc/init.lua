---@module 'lib.nvim.contract.doc'
---@brief The documents of a machine contract: the head every one starts with, `seal`, `encode`, the error document.
---@description
--- `doc.new{ plugin, schema, ... }` returns the document builder of ONE plugin's contract (`tasks-export/1`,
--- `rules-export/1`). Moved here from the head/seal/encode part of `tasks_nvim.contract` (tasks.nvim@6bc8d99); what
--- a document CONTAINS (snapshot, list, a rule) stays with the plugin.
---
--- Every document starts with the same head (`schema`, `plugin`, `kind`, `generated_at`, `<scope_key>.id`, `engine`).
--- A document that comes from a scan is sealed with `rev` (what the source looked like) and `digest` (the hash of the
--- content WITHOUT `generated_at` and `engine`: two runs on an unchanged source have the same digest, whenever and by
--- whichever build of the engine they ran).
---
--- Rules the documents keep:
---  - **no path of this machine**: `relative`, `safe_path` and `redact` turn paths into source-relative ones, an
---    absolute one into `<external>/<name>`, the root inside a message into the placeholder (`<vault>`). The root
---    may be spelled with either slash and a trailing slash, an empty one is no root; case does not matter (Unicode
---    letters included); `.`/`..` segments are resolved as text, so a path that climbs out of the root is outside;
---  - **a document is at most `MAX_DOC_BYTES`** (8 MiB); a bigger one is the error `payload_too_large`, never a
---    cut-off document; an error document is exempt (the limit must never keep a client from being told why);
---  - the bytes are canonical (`lib.nvim.json.canonical`): same document, same bytes.
---
--- Seams for specs and golden files, read at CALL time so a spec can replace them on the instance: `clock`
--- (`generated_at`), `engine_info` (`engine`), `MAX_DOC_BYTES`. A plugin that exposes the seams on its own module
--- forwards them: `d.clock = function() return M.clock() end`.
---
---```lua
--- local json = require("lib.nvim.json.canonical")
--- local d = require("lib.nvim.contract.doc").new({
---   plugin = "rules.nvim", schema = 1, scope_key = "source", engine_version = "0.1.0",
---   plugin_root = plugin_root,
--- })
--- local doc = d.head("rules.hello", root)
--- doc.rules = json.memo(rules)   -- the big part: `seal` writes it for the digest, `encode` reuses that text
--- local text, err = d.encode(d.seal(doc, d.rev_of(lines)))
---```
---
--- Not its job: what a document contains, parsing a request and mapping an error to a code (`contract.api`).

require("lib.nvim.contract.doc.@types")

local json = require("lib.nvim.json.canonical")
local etag = require("lib.nvim.fs.etag")
local errors = require("lib.nvim.contract.errors")
local collapse_dots = require("lib.nvim.cross.fs.separators.collapse_dots")
local is_windows = require("lib.nvim.cross.platform.is_windows")

local uv = vim.uv or vim.loop

local M = {}

---@param s string
---@return string
local function lower_slash(s)
  return (s:gsub("\\", "/"))
end

---A root as the paths of this module are compared: forward slashes, no trailing slash (`/` becomes `""`, `C:/`
---becomes `C:`). The caller may spell it any way; `relative`, `redact` and the head all see the same root.
---@param root string
---@return string
local function bare(root)
  return (lower_slash(root):gsub("/+$", ""))
end

---Lower case for a comparison that has the SAME byte length as `s`, so a position found in the folded text is a
---position in `s`. `string.lower` only folds ASCII (`Ö` and `ö` are one folder on NTFS); a letter beyond ASCII goes
---through `vim.fn.tolower` (Vim's simple case mapping; it may be called in a fast event). The few letters whose
---lower case has another length (`İ` 2 bytes -> `i` 1, `Ⱥ` 2 -> `ⱥ` 3, the Kelvin sign) and a byte that is no UTF-8
---(`vim.fn.tolower` reads it as Latin-1 and writes two bytes) stay as they are.
---@param s string
---@return string
local function fold(s)
  if not s:find("[\128-\255]") then
    return (s:lower())
  end
  local out, pos = {}, 1
  while pos <= #s do
    local from, to = s:find("^[^\128-\255]+", pos)
    if from then
      out[#out + 1] = s:sub(from, to):lower()
    else
      from, to = s:find("^[\128-\255][\128-\191]*", pos)
      local char = s:sub(from, to)
      local folded = vim.fn.tolower(char)
      out[#out + 1] = #folded == #char and folded or char
    end
    pos = to + 1
  end
  return table.concat(out)
end

---The name the head gives the source: the last part of the root. A root without a name (`""`, `/`, `C:/`) has none.
---@param root string
---@return string
local function scope_id(root)
  local name = bare(root)
  if name:match("^%a:$") then
    return ""
  end
  return name:match("[^/]*$")
end

---The variables that make git look at another repository than the one `-C` names (they win over `-C`).
---@type table<string, true>
local GIT_REDIRECTS = {
  GIT_DIR = true,
  GIT_WORK_TREE = true,
  GIT_COMMON_DIR = true,
  GIT_INDEX_FILE = true,
  GIT_OBJECT_DIRECTORY = true,
  GIT_ALTERNATE_OBJECT_DIRECTORIES = true,
  GIT_NAMESPACE = true,
}

---Disks that compare names without case by default (NTFS, APFS). Asked once: `same_folder` runs in the callback of
---`prewarm`, a fast-event context, where `vim.fn.has` cannot be called.
local FOLD_CASE = is_windows() or uv.os_uname().sysname == "Darwin"

---Whether git's top level (`--show-toplevel`, forward slashes) is the folder `root` names: both resolved
---(`fs_realpath`: a symlink, a short 8.3 name, another case of the name on Windows) when they exist, compared as text
---otherwise (case-insensitive on Windows and macOS, whose disks are by default).
---@param top string
---@param root string
---@return boolean
local function same_folder(top, root)
  local function norm(p)
    local real = uv.fs_realpath(p)
    local text = bare(real or p)
    if FOLD_CASE then
      text = fold(text)
    end
    return text
  end
  return norm(top) == norm(root)
end

---A document is never bigger than this unless the plugin says so.
M.DEFAULT_MAX_DOC_BYTES = 8 * 1024 * 1024

---The head, seal and error fields of a document: a `scope_key` of one of these names would overwrite it.
---@type table<string, true>
local DOCUMENT_FIELDS = {}
for _, field in ipairs({
  "schema",
  "plugin",
  "kind",
  "generated_at",
  "engine",
  "rev",
  "digest",
  "code",
  "message",
  "retryable",
  "details",
}) do
  DOCUMENT_FIELDS[field] = true
end

---@param key string
---@param what string
local function refuse(key, what)
  error(("contract.doc.new: %s must be %s"):format(key, what), 3) -- 3: the caller of `new`
end

--- testing-perf: conditional: a factory: git runs when the doc is read
---@param cfg Lib.Contract.DocConfig
---@return Lib.Contract.Doc
function M.new(cfg)
  if type(cfg) ~= "table" then
    error("contract.doc.new needs a table", 2)
  end
  if type(cfg.plugin) ~= "string" or cfg.plugin == "" then
    error("contract.doc.new: plugin must be a non-empty string", 2)
  end
  if
    type(cfg.schema) ~= "number"
    or cfg.schema < 1
    or cfg.schema ~= math.floor(cfg.schema)
    or cfg.schema == math.huge
  then
    error("contract.doc.new: schema must be a whole number from 1", 2)
  end
  for _, key in ipairs({ "kind_prefix", "scope_key", "placeholder", "plugin_root" }) do
    local value = cfg[key]
    if value ~= nil and (type(value) ~= "string" or value == "") then
      refuse(key, "a non-empty string")
    end
  end
  for _, key in ipairs({ "engine_version", "too_large_hint" }) do
    if cfg[key] ~= nil and type(cfg[key]) ~= "string" then
      refuse(key, "a string")
    end
  end
  if cfg.scope_key and DOCUMENT_FIELDS[cfg.scope_key] then
    refuse(
      "scope_key",
      ("not a field of the documents themselves ('%s' is one)"):format(cfg.scope_key)
    )
  end
  if cfg.prewarm ~= nil and type(cfg.prewarm) ~= "boolean" then
    refuse("prewarm", "a boolean")
  end
  local max_bytes = cfg.max_bytes
  if
    max_bytes ~= nil
    and (type(max_bytes) ~= "number" or max_bytes < 1 or max_bytes ~= math.floor(max_bytes))
  then
    refuse("max_bytes", "a whole number from 1")
  end

  local kind_prefix = cfg.kind_prefix or (cfg.plugin:gsub("%.nvim$", ""))
  local scope_key = cfg.scope_key or "vault"
  local placeholder = cfg.placeholder or ("<" .. scope_key .. ">")
  local hint = cfg.too_large_hint or "ask for a page or an area"
  local error_kind = kind_prefix .. ".error"
  -- trailing slashes go, but a root keeps its own: `git -C ""` (and `-C C:`) would mean the current directory
  local plugin_root = cfg.plugin_root and (lower_slash(cfg.plugin_root):gsub("([^:/])/+$", "%1"))
    or nil

  local d = {
    SCHEMA = cfg.schema,
    PLUGIN = cfg.plugin,
    ENGINE_VERSION = cfg.engine_version or "0.0.0",
    MAX_DOC_BYTES = cfg.max_bytes or M.DEFAULT_MAX_DOC_BYTES,
    ERROR_KIND = error_kind,
    PLACEHOLDER = placeholder,
  }

  ---`<prefix>.<name>`: the `kind` of a document.
  ---@param name string
  ---@return string
  function d.kind(name)
    return kind_prefix .. "." .. name
  end

  -- ── the engine ───────────────────────────────────────────────────────────────

  local git_cache
  local git_tries = 0
  local git_running = false -- a `prewarm` lookup has started and not called back yet

  ---@return string[]
  local function git_argv()
    -- `--show-toplevel` too: `-C` walks UP to the next repository, and a `plugin_root` that is no checkout of its own
    -- (a plugin copied into the folder of another repo) would be stamped with the commit of that repo
    return { "git", "-C", plugin_root, "rev-parse", "--show-toplevel", "--short", "HEAD" }
  end

  ---The options of the git process: the environment of this one without the variables that point git at another
  ---repository (`GIT_DIR`, `GIT_WORK_TREE`, ...). A host started from inside a git hook or by `git rebase --exec`
  ---inherits them, and they win over `-C`.
  ---@param extra table
  ---@return table
  local function git_opts(extra)
    local env = {}
    for key, value in pairs(uv.os_environ()) do
      if not GIT_REDIRECTS[key:upper()] then
        env[key] = value
      end
    end
    return vim.tbl_extend("force", { text = true, env = env, clear_env = true }, extra)
  end

  ---The wait of the next look: the first one gets the full 2 s, a retry 0.5 s.
  ---@return integer
  local function git_wait()
    return git_tries == 0 and 2000 or 500
  end

  ---Take the outcome of one look (synchronous or the callback of `prewarm`) into the cache: a commit is kept, an
  ---answer of git that is none (code 1.., no hash) is kept as "unknown"; no answer in time (the code 124 of a
  ---timeout, the signal of a kill, an error of the start) counts one try and is asked again, three looks at most.
  ---@param ok boolean the start did not raise
  ---@param res? vim.SystemCompleted
  ---@return string
  local function git_settle(ok, res)
    if ok and res and res.code == 0 then
      local top, sha = vim.trim(res.stdout or ""):match("^([^\n]-)\r?\n%s*(%x+)$")
      if top and same_folder(top, plugin_root) then
        git_cache = sha
        return git_cache
      end
    end
    git_tries = git_tries + 1
    local answered = ok and res and res.code ~= 124 and (res.signal or 0) == 0
    if answered or git_tries >= 3 then
      git_cache = "unknown"
      return git_cache
    end
    return "unknown"
  end

  ---Short commit of the plugin checkout; "unknown" when there is no git, no checkout, a `plugin_root` that is no
  ---checkout of its own (git's top level is another folder) or no `plugin_root`. A definite
  ---answer is kept for the life of the process. A lookup that did not finish in time (a loaded machine, a slow start
  ---of git) is not: it is asked again, three times at most, so a long-lived host does not stay "unknown" because of
  ---one slow moment. Only the first look gets the full wait; a retry is quick (a warm git answers in about 100 ms),
  ---so a machine that stays loaded holds a request for 3 s in all, not 6. While a `prewarm` lookup runs, the answer
  ---is "unknown" at once: nothing waits, nothing is cached and no try is counted.
  ---@return string
  local function engine_git()
    if git_cache then
      return git_cache
    end
    if not plugin_root then
      git_cache = "unknown"
      return git_cache
    end
    if git_running then
      return "unknown"
    end
    local wait_ms = git_wait()
    local ok, res = pcall(function()
      return vim.system(git_argv(), git_opts({})):wait(wait_ms)
    end)
    return git_settle(ok, res)
  end

  ---Start the git lookup of `engine.git` in the background (`vim.system` with a callback) so that no later `head()`
  ---or `engine_info()` waits for it: an editor host that answers on its UI loop calls it once at start (or passes
  ---`prewarm = true` to `new`). The callback fills the same cache under the same rules (a timeout is one of the
  ---three tries). Does nothing when the answer is known, a lookup runs already, or there is no `plugin_root`.
  function d.prewarm()
    if git_cache or git_running then
      return
    end
    if not plugin_root then
      git_cache = "unknown"
      return
    end
    git_running = true
    local function on_exit(res)
      git_running = false
      git_settle(true, res)
    end
    if not pcall(vim.system, git_argv(), git_opts({ timeout = git_wait() }), on_exit) then
      git_running = false
      git_settle(false) -- an error of the start: one try, asked again on a later look
    end
  end

  ---The time a document is stamped with (UTC, `YYYY-MM-DDTHH:MM:SSZ`). A seam: golden files and reproducible runs
  ---set a fixed one; nothing else changes it.
  ---@return string
  function d.clock()
    return os.date("!%Y-%m-%dT%H:%M:%SZ") --[[@as string]]
  end

  local nvim_version -- `vim.version()` asks Neovim over its API (0.7 ms) and cannot change in a process

  ---What the head says about the engine (same seam, same reason).
  ---@return { version: string, git: string, nvim: string }
  function d.engine_info()
    nvim_version = nvim_version or tostring(vim.version())
    return { version = d.ENGINE_VERSION, git = engine_git(), nvim = nvim_version }
  end

  ---The head every document starts with. The root names the source by its last part, whatever its slashes.
  ---@param kind string
  ---@param root? string
  ---@return table
  function d.head(kind, root)
    return {
      schema = d.SCHEMA,
      plugin = d.PLUGIN,
      kind = kind,
      generated_at = d.clock(),
      [scope_key] = json.object({ id = root and scope_id(root) or "" }),
      engine = json.object(d.engine_info()),
    }
  end

  -- ── paths: nothing of this machine in a document ────────────────────────────

  ---`path` relative to the root, with `/`; `nil` when it is not inside it (case-insensitive: a Windows path). The
  ---root may end in a slash or use backslashes. An empty root is no root: nothing is inside it (`/` is the root of
  ---the file system and everything absolute is inside that). `.` and `..` segments (and doubled slashes) are resolved
  ---as text first, in the root and in the path: `<root>/../x` starts with the root but is NOT inside it. (As text:
  ---a symlink inside the root that points out of it is not followed; the document only must not show the path.)
  ---@param root string
  ---@param path string
  ---@return string|nil
  function d.relative(root, path)
    if root == "" then
      return nil
    end
    local p = collapse_dots(path)
    local r = bare(collapse_dots(root))
    if fold(p:sub(1, #r + 1)) == fold(r) .. "/" then
      return p:sub(#r + 2)
    end
    return nil
  end

  ---A reference or a path in a message without anything that belongs to this machine: inside the root it is
  ---relative, an absolute or `~` path is `<external>/<name>`, anything else stays as it is.
  ---@param root string
  ---@param s string
  ---@return string
  function d.safe_path(root, s)
    local text = lower_slash(s)
    if text:find("^%a:/") or text:find("^/") then
      -- an absolute path is resolved before its name is taken: `<root>/a/..` is `<external>/<root's name>`, not `..`
      text = collapse_dots(text)
    end
    local rel = d.relative(root, text)
    if rel then
      return rel
    end
    if text:match("^%a:/") or text:match("^/") or text:match("^~") then
      return "<external>/" .. (text:match("([^/]+)/*$") or "")
    end
    return text
  end

  ---Free text (a message of the engine) with the root named by the placeholder, in any spelling of the path (either
  ---slash, mixed) and whatever the case; the root itself may end in a slash or use backslashes. A root without a
  ---name (`""`, `/`) hides nothing. One pass over the text, so the cost follows its length, not the number of hits.
  ---@param root string
  ---@param s string
  ---@return string
  function d.redact(root, s)
    local needle = fold(bare(root))
    if needle == "" then
      return s
    end
    local hay = fold(lower_slash(s)) -- the same length as `s`: a position in one is a position in the other
    local parts, from, at = {}, 1, 1
    while true do
      local i, j = hay:find(needle, at, true)
      if not i then
        break
      end
      parts[#parts + 1] = s:sub(from, i - 1)
      parts[#parts + 1] = placeholder
      from, at = j + 1, j + 1
    end
    if from == 1 then
      return s
    end
    parts[#parts + 1] = s:sub(from)
    return table.concat(parts)
  end

  -- ── sealing and encoding ─────────────────────────────────────────────────────

  ---`rev`: what the source looked like, from lines the plugin builds (an id and a version tag each). The order of
  ---the lines does not matter. They are sorted by byte value, not by the language's `<` (on plain Lua 5.1 that
  ---follows the locale), so the same source has the same rev on every machine.
  ---@param lines string[]
  ---@return string
  function d.rev_of(lines)
    local sorted = vim.list_slice(lines, 1)
    table.sort(sorted, json.bytes_less)
    return "rev:" .. etag.sha256(table.concat(sorted, "\n")):sub(1, 6)
  end

  ---Put `rev` and `digest` on a document. The digest is the hash of the compact document without `generated_at` and
  ---without `engine`. It writes the whole document once: memoise the big part with `json.memo` and `encode` reuses
  ---that text instead of writing it a second time.
  ---
  ---A value JSON cannot hold (NaN, a function, a cycle) makes `seal` RAISE, with the message `encode` would give
  ---(the path in the document, no position) and leaves the document as it was (time, engine, `rev`, `digest`).
  ---Anyone who builds a document from foreign values and wants an error to return calls `encode` first, or `pcall`s
  ---the seal.
  ---@param doc table
  ---@param rev? string
  ---@return table
  function d.seal(doc, rev)
    local was_rev, was_digest, at, engine = doc.rev, doc.digest, doc.generated_at, doc.engine
    doc.rev, doc.generated_at, doc.engine, doc.digest = rev, nil, nil, nil
    local written, text = pcall(json.encode, doc)
    doc.generated_at, doc.engine = at, engine
    if not written then
      doc.rev, doc.digest = was_rev, was_digest
      error(text, 0) -- the message names the path in the document and carries no file:line
    end
    doc.digest = "sha256:" .. etag.sha256(text):sub(1, 16)
    return doc
  end

  ---The canonical bytes of a document; one bigger than the limit is an error, never a cut-off document.
  ---@param doc table
  ---@param opts? Lib.Json.CanonicalOpts
  ---@return string|nil text
  ---@return Lib.Contract.Error|nil err
  function d.encode(doc, opts)
    local ok, text = pcall(json.encode, doc, opts)
    if not ok then
      return nil, { code = "internal", message = tostring(text), retryable = false }
    end
    -- an error document is exempt: the limit must never keep a client from being told why
    if #text > d.MAX_DOC_BYTES and doc.kind ~= error_kind then
      return nil,
        {
          code = "payload_too_large",
          message = ("the document is %d bytes, more than the %d the contract allows; %s"):format(
            #text,
            d.MAX_DOC_BYTES,
            hint
          ),
          retryable = false,
        }
    end
    return text, nil
  end

  ---An error document. A malformed `err` is made into one, never a throw: a value that is no table is an `internal`
  ---error with its text, a `message` that is no text is shown as one (the `code` when there is none), a `code` that
  ---is no text is `internal` (a document always has a code a client can match), `details` that is no table is left
  ---out.
  ---@param err Lib.Contract.Error
  ---@param root? string
  ---@return table
  function d.error_doc(err, root)
    if type(err) ~= "table" then
      err = errors.fail("internal", errors.text(err))
    end
    local message = err.message
    if type(message) ~= "string" then
      message = errors.text(message == nil and err.code or message)
    end
    local doc = d.head(error_kind, root)
    doc.code = type(err.code) == "string" and err.code or "internal"
    doc.message = root and d.redact(root, message) or message
    doc.retryable = err.retryable == true
    if type(err.details) == "table" then
      doc.details = json.object(err.details)
    end
    return doc
  end

  if cfg.prewarm then
    d.prewarm()
  end

  return d --[[@as Lib.Contract.Doc]]
end

return M
