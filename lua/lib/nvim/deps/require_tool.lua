---@module 'lib.nvim.deps.require_tool'
--- The failure moment: a command is running, the tool it needs is not here,
--- and *this* is when the user finds out.
---
--- Everything else in `lib.nvim.deps` is forward-looking — `:checkhealth`,
--- the first-run popup, `:Lib deps show` all answer "what might I need?".
--- They are read before anything breaks, which is to say: usually not at
--- all. The moment that actually reaches the user is the one where a
--- keypress does nothing, and until this module existed that moment was
--- served by whatever string each call site happened to have written by
--- hand:
---
---   "curl not found"                          -- language.nvim
---   "curl executable not found on PATH"       -- diff.nvim
---   "tesseract not found — see :checkhealth images"
---
--- The third is the best of them and still only points at another plugin's
--- health check. Meanwhile the plugin's own `docs/install.json` holds a
--- one-sentence `why`, a package name for nine package managers, and
--- everything `deps.pm` needs to compose the exact command for *this* host.
--- All of it sitting unused at precisely the moment it answers the
--- question the user now has.
---
--- So: same detection as `deps.detect`, same spec as `deps.spec`, same
--- command composition as `deps.pm` — asked at a different time.
---
---   local curl = require("lib.nvim.deps").require_tool("language.nvim", "curl")
---   if not curl then return end
---   -- ... use `curl` as the binary name
---
--- **It returns the name, not a boolean.** A tool that declares
--- `bin_alternatives` is `gs` on Linux and `gswin64c` on Windows, and a
--- caller that has just been told "yes, it's here" still has to know which
--- spelling to spawn. Returning the found name answers both questions at
--- once, and stays truthy for the `if not ... then return end` guard that
--- is the whole point.
---
--- **Nothing here installs anything**, in keeping with the rest of the
--- module: the message names the command and points at `:Lib deps install`,
--- which is still the only route that touches the system, still
--- confirmation-gated. Offering to install *at* the failure moment would be
--- answering a question the user did not ask — they wanted to translate a
--- paragraph, not administer their machine.

local M = {}

---How long a given (plugin, tool) pair stays quiet after being reported.
---
---This is a burst guard, not a mute. A caller that checks one tool per file
---across a 200-file batch would otherwise produce 200 identical
---notifications; a user who runs `:Translate`, reads the message, and runs
---it again a minute later has deliberately asked a second time and should
---be told a second time. A short window separates those two cases without
---having to distinguish them.
---@type integer
local THROTTLE_MS = 5000

---@internal
---Last report time per `plugin\0bin`, in `vim.uv.now()` milliseconds.
---Session-local on purpose: unlike `deps.first_run`, nothing here is worth
---persisting across restarts.
---@type table<string, integer>
local last_reported = {}

---@internal
---Parsed spec per plugin name, or `false` for "looked, ships none".
---
---The spec has to be consulted *before* detection rather than only on
---failure: without it this module does not know that `gs` may also be
---`gswin64c`, and would report a tool as missing on the one platform where
---the alternative is the only spelling that exists. One file read per
---plugin per session is the price of that being correct.
---@type table<string, Lib.Deps.ParseResult|false>
local spec_cache = {}

---@internal
---This plugin's parsed spec, or nil when it ships none / it cannot be read.
---Silent on failure by design: a missing spec is the plugin author's
---problem, and the user staring at a broken command is not the person to
---tell about it.
---@param plugin_name string
---@return Lib.Deps.ParseResult|nil
local function spec_for(plugin_name)
  local cached = spec_cache[plugin_name]
  if cached ~= nil then
    return cached or nil
  end

  local spec = require("lib.nvim.deps.spec")
  local path = spec.find(plugin_name)
  if not path then
    spec_cache[plugin_name] = false
    return nil
  end

  local result = spec.load(path)
  spec_cache[plugin_name] = result or false
  return result
end

---@internal
---The declared entry for `bin` in `plugin_name`'s spec, or a bare stand-in
---when the plugin declares no such tool.
---
---The stand-in keeps every caller working before its plugin ships a spec —
---detection still runs, the message is still better than a hand-written
---string, it just has no `why` and no install command to offer. That
---matters for adoption: a plugin can move to `require_tool` first and
---declare its tools afterwards, rather than needing both at once.
---@param plugin_name string
---@param bin string
---@return Lib.Deps.Tool tool
---@return boolean declared whether it came from a spec
local function tool_for(plugin_name, bin)
  local result = spec_for(plugin_name)
  if result then
    for _, tool in ipairs(result.tools) do
      if tool.bin == bin then
        return tool, true
      end
    end
  end
  return { bin = bin, required = false, why = "", pkg = {} }, false
end

---The lines reported for a missing `tool`, most important first.
---
---Pure, so the wording is testable without a notification anywhere near it
---— the same reason `deps.view.lines` is split out from `deps.view.show`.
---@param plugin_name string
---@param tool Lib.Deps.Tool
---@param opts? Lib.Deps.ManagerOpts
---@return string[]
function M.message(plugin_name, tool, opts)
  local lines = {}

  -- The `why` is the spec's own sentence about what this tool buys the
  -- user, which is exactly what someone who just hit the wall wants to
  -- know: not only that it is missing, but whether they care.
  if tool.why and tool.why ~= "" then
    lines[#lines + 1] = ("%s not found — %s"):format(tool.bin, tool.why)
  else
    lines[#lines + 1] = ("%s not found on PATH"):format(tool.bin)
  end

  local pm = require("lib.nvim.deps.pm")
  local manager = (opts or {}).manager or pm.detect()
  local via, pkg = pm.resolve(tool, manager or false)

  if via and pkg then
    for _, argv in ipairs(pm.commands(via, { pkg })) do
      lines[#lines + 1] = "  install:  " .. pm.render(argv)
    end
    lines[#lines + 1] = ("  or run:   :Lib deps install %s"):format(plugin_name)
  elseif tool.pkg and next(tool.pkg) ~= nil then
    -- Declared, but not for this host's manager (or there is no manager).
    -- Saying so beats silence: "no install line" would otherwise read as
    -- "this tool cannot be installed", when the truth is narrower.
    lines[#lines + 1] = ("  no package known for this host — see :Lib deps show %s"):format(
      plugin_name
    )
  end

  return lines
end

---The lines `check` would report for `bin`, without reporting anything.
---
---For the failure paths that do not notify: a callback taking `(value,
---err)`, a `result.errors` list, an `on_done({ ok = false, err = ... })`.
---Those are common — `diff.nvim`'s URL resolver and the case desk's export
---and OCR runs all hand their error *upwards* rather than to the user
---directly — and for them `check`'s notification would be a second message
---next to the one the caller is already about to show.
---
---Takes a binary name rather than a `Lib.Deps.Tool`, so a call site needs
---to know nothing about specs to get the spec's wording:
---
---   on_done({ ok = false, err = table.concat(rt.lines("nvim", "pandoc"), " ") })
---
---@param plugin_name string
---@param bin string
---@param opts? Lib.Deps.ManagerOpts
---@return string[]
function M.lines(plugin_name, bin, opts)
  return M.message(plugin_name, tool_for(plugin_name, bin), opts)
end

---@internal
---Whether this (plugin, tool) pair may be reported right now, marking it
---reported when it may.
---
---handrolled-ok: a synchronous per-key yes/no with a reset, not a rate-limited
---call; `patterns.throttle` wraps one function and has no per-key decision.
---@param plugin_name string
---@param bin string
---@param throttle_ms integer
---@return boolean
local function may_report(plugin_name, bin, throttle_ms)
  if throttle_ms <= 0 then
    return true
  end
  local key = plugin_name .. "\0" .. bin
  local now = vim.uv.now()
  local last = last_reported[key]
  if last and (now - last) < throttle_ms then
    return false
  end
  last_reported[key] = now
  return true
end

---Is `bin` available for `plugin_name` right now — and if not, say so
---usefully.
---
---Returns the binary name to actually spawn (which is `bin` itself unless
---the spec declares `bin_alternatives` and a different spelling is what
---this host has), or nil when the tool is absent. On absence it reports
---once per `opts.throttle_ms` window; see `M.message` for the wording.
---
---`opts.silent` suppresses the report while still answering the question —
---for a caller that wants the alternatives-aware lookup but has its own
---error path, e.g. one collecting several failures into a single summary.
---@param plugin_name string plugin the tool is declared by, e.g. "language.nvim"
---@param bin string canonical binary name, matching the spec's `bin`
---@param opts? { silent?: boolean, throttle_ms?: integer, manager?: Lib.Deps.Manager }
---@return string|nil found_as the name it was found under, nil when missing
function M.check(plugin_name, bin, opts)
  opts = opts or {}

  local tool = tool_for(plugin_name, bin)
  local found = require("lib.nvim.deps.detect").found_as(tool)
  if found then
    return found
  end

  if not opts.silent then
    local throttle = opts.throttle_ms or THROTTLE_MS
    if may_report(plugin_name, bin, throttle) then
      local lines = M.message(plugin_name, tool, { manager = opts.manager })
      require("lib.nvim.notify").create("[" .. plugin_name .. "]").warn(table.concat(lines, "\n"))
    end
  end

  return nil
end

---Forget the throttle state, and the memoized specs behind it.
---
---For tests, and for the case a `:Lib deps install` has just changed the
---answer: the PATH memo is cleared by `deps.detect.forget`, but a stale
---"already reported" entry would still swallow the next report.
---@param plugin_name? string one plugin, or every plugin when omitted
---@return nil
function M.reset(plugin_name)
  if not plugin_name then
    last_reported = {}
    spec_cache = {}
    return
  end
  spec_cache[plugin_name] = nil
  local prefix = plugin_name .. "\0"
  for key in pairs(last_reported) do
    if key:sub(1, #prefix) == prefix then
      last_reported[key] = nil
    end
  end
end

---@type Lib.Deps.RequireTool
return M
