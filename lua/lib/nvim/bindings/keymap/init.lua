---@module 'lib.nvim.bindings.keymap'
--- Keymaps: the one-off wrapper, and the named-action registry.
---@description
--- Two levels, and most plugins want both:
---
--- **`keymap(...)`** -- the validated `vim.keymap.set` wrapper this module has
--- always been. For the mappings that are not part of a plugin's public
--- surface: buffer-local keys inside a floating window, `q` to close a report,
--- anything a user has no reason to rebind.
---
--- ```lua
--- local keymap = require("lib.nvim.bindings.keymap")
--- keymap("n", "q", close, { buffer = true }, "close")
--- ```
---
--- **`keymap.register(...)`** -- named actions the user's spec can remap or
--- switch off, one by one. For everything that *is* public surface. See
--- `registry.lua` for the shape and for why the override table is keyed by
--- action name rather than by the current `lhs`.
---
--- ```lua
--- keymap.register("spotlight", {
---   prefix = "<leader>s",
---   which_key = { group = "Spotlight" },
---   actions = {
---     toggle = { default = "<leader>sK", rhs = api.toggle, desc = "toggle every occurrence" },
---   },
--- }, cfg.keymaps)
--- ```
---
--- The module stays **callable** so that the first form keeps working
--- unchanged: it is `require`d in over a hundred places across these plugins,
--- and turning it into a plain table would have broken every one of them for
--- no benefit.
---@see lib.nvim.bindings.keymap.registry
---@see lib.nvim.bindings.keymap.which_key

local set = require("lib.nvim.bindings.keymap.set")
local notify = require("lib.nvim.notify").create("[lib.nvim.bindings.keymap]")

local M = {}

--- Set one keymap. Identical to calling the module itself.
---@type fun(modes: string|string[], lhs: string, rhs: string|function, opts: Lib.Map.Opts|nil, desc: string?): nil
M.set = set

--- Register a plugin's named actions. See `registry.register`.
---@param plugin string
---@param spec Lib.Keymap.Spec
---@param user table|false|nil
---@param opts Lib.Keymap.RegisterOpts|nil
---@return Lib.Keymap.Registered[]
function M.register(plugin, spec, user, opts)
  return require("lib.nvim.bindings.keymap.registry").register(plugin, spec, user, opts)
end

--- Everything registered so far. See `registry.registered`.
---The two shapes are declared as an overload rather than one union return:
---with a union, `pairs(registered())` sees a `Registered[]` branch it cannot
---rule out, and every field read off an entry becomes an `undefined-field`.
---@param plugin string
---@return Lib.Keymap.Registered[]
---@overload fun(): table<string, Lib.Keymap.Registered[]>
function M.registered(plugin)
  return require("lib.nvim.bindings.keymap.registry").registered(plugin)
end

--- The lines (and highlight spans) of a `g?` cheatsheet for one plugin: grouped, aligned, only what is
--- really bound. See `cheatsheet.build`.
---@param plugin string
---@param opts? Lib.Keymap.CheatsheetOpts
---@return Lib.Keymap.Cheatsheet
function M.cheatsheet(plugin, opts)
  return require("lib.nvim.bindings.keymap.cheatsheet").build(plugin, opts)
end

--- Forget direct `set()` records. See `registry.forget`.
---@param plugin string|nil
---@return integer
function M.forget(plugin)
  return require("lib.nvim.bindings.keymap.registry").forget(plugin)
end

--- `lhs` values claimed by more than one plugin. See `registry.conflicts`
--- for the two scopes (`"registered"`, `"full"`) and the second result.
---@param opts? Lib.Keymap.ConflictsOpts
---@return Lib.Keymap.Conflict[]
---@return Lib.Keymap.ConflictsInfo
function M.conflicts(opts)
  return require("lib.nvim.bindings.keymap.registry").conflicts(opts)
end

---@internal
--- How many of lazy.nvim's tracked plugins are loaded right now, or `nil`
--- when lazy.nvim is not present or everything is already loaded.
--- `conflicts()` only sees registrations that already ran -- a plugin
--- lazy.nvim has not loaded yet cannot have bound anything, so a clean
--- report this early is not evidence of anything.
---@return string|nil
local function lazy_coverage_note()
  local ok, lazy_config = pcall(require, "lazy.core.config")
  if not ok then
    return nil
  end
  local total, loaded = 0, 0
  for _, spec in pairs(lazy_config.plugins) do
    total = total + 1
    if spec._ ~= nil and spec._.loaded ~= nil then
      loaded = loaded + 1
    end
  end
  if loaded >= total then
    return nil
  end
  return ("note: %d/%d lazy-loaded plugins loaded right now -- the rest have bound nothing yet."):format(
    loaded,
    total
  )
end

---@internal
---@param lines string[]
---@param title string
local function show(lines, title)
  local ok, kit = pcall(require, "lib.nvim.ui.kit")
  if ok then
    kit.viewer({
      lines = lines,
      title = " " .. title .. " ",
      width = math.min(120, vim.o.columns - 8),
    })
    return
  end
  print(table.concat(lines, "\n"))
end

---`conflicts()` as printable lines, for `:checkhealth` and a report command.
---
---With `scope = "full"` the report says what it could not see (no tap
---installed) and how many Neovim mappings are live, so a clean answer is
---never mistaken for a thorough one.
---@param opts? Lib.Keymap.ConflictsOpts
---@return string[]
function M.conflict_lines(opts)
  local conflicts, info = M.conflicts(opts)
  local out = {}
  local coverage = lazy_coverage_note()
  if coverage then
    out[#out + 1] = coverage
    out[#out + 1] = ""
  end
  for _, note in ipairs(info.notes) do
    out[#out + 1] = "note: " .. note
    out[#out + 1] = ""
  end
  if info.scope == "full" then
    local counts = { builtin = 0, lib = 0, other = 0 }
    for _, e in ipairs(require("lib.nvim.bindings.keymap.runtime").snapshot()) do
      counts[e.origin] = counts[e.origin] + 1
    end
    out[#out + 1] = ("full check: %d live global mappings (%d Neovim defaults, %d lib.nvim, %d other)."):format(
      counts.builtin + counts.lib + counts.other,
      counts.builtin,
      counts.lib,
      counts.other
    )
    if info.benign_hidden > 0 then
      out[#out + 1] = ("%d benign (lazy.nvim placeholder) collision(s) hidden."):format(
        info.benign_hidden
      )
    end
    out[#out + 1] = ""
  end
  if #conflicts == 0 then
    out[#out + 1] = "no keymap conflicts -- every lhs is claimed once per mode+scope."
    return out
  end
  out[#out + 1] = ("%d lhs claimed by more than one registration:"):format(#conflicts)
  for _, c in ipairs(conflicts) do
    out[#out + 1] = ("  %-4s %s"):format(c.mode, c.lhs)
    for _, cl in ipairs(c.claimants) do
      local who = cl.direct and (cl.src or cl.source or (cl.plugin .. " (direct)"))
        or (cl.plugin .. "." .. cl.name)
      if cl.via then
        who = who .. " [" .. cl.via .. "]"
      end
      out[#out + 1] = ("       %s%s"):format(who, cl.desc and (" -- " .. cl.desc) or "")
    end
  end
  return out
end

---The live-mapping reports, as printable lines.
---
--- - `"defaults"` (default): Neovim's own default mappings set against this
---   session -- which were overridden, which are gone.
--- - `"duplicates"`: one action on several keys, by description or target.
---
---A failure to read the pristine defaults is reported as a line, not raised.
---@param what? "defaults"|"duplicates"
---@return string[]
function M.runtime_lines(what)
  local rt = require("lib.nvim.bindings.keymap.runtime")
  what = what or "defaults"
  if what == "duplicates" then
    return rt.duplicate_lines(rt.action_duplicates(rt.snapshot()))
  end
  if what ~= "defaults" then
    return { ("unknown report '%s' -- expected defaults or duplicates."):format(tostring(what)) }
  end
  local pristine, err = rt.pristine_defaults()
  if not pristine then
    return { "cannot read the pristine Neovim defaults: " .. tostring(err) }
  end
  local diff = rt.diff_defaults(pristine, rt.snapshot({ defaults = pristine }))
  return rt.defaults_lines(diff, { version = rt.version_tag(), total = #pristine })
end

---Expose `:<name>` for `conflicts()` and `:<runtime_name>` for the live
---reports. Put this call in **your own config**, not in a library -- same
---reasoning `bindings.usercmd.docs.create_usercmd` and
---`bindings.audit.create_usercmd` give.
---
--- - `:LibKeymapConflicts` -- what lib.nvim bound (scope `"registered"`).
--- - `:LibKeymapConflicts!` -- the full check (scope `"full"`): plus the
---   keymap tap's recording of raw and lazy.nvim bindings.
--- - `:LibKeymapRuntime [defaults|duplicates]` -- Neovim's defaults that were
---   overridden or removed, or one action on several keys.
--- testing-perf: conditional: creates commands; `:LibKeymapRuntime defaults` starts the probe editor
---@param name string|nil  # Default `LibKeymapConflicts`.
---@param runtime_name string|nil  # Default `LibKeymapRuntime`.
---@return nil
function M.create_usercmd(name, runtime_name)
  local base = name or "LibKeymapConflicts"
  local runtime_cmd = runtime_name or "LibKeymapRuntime"
  local usercmd = require("lib.nvim.bindings.usercmd")

  usercmd.create(base, function(args)
    local full = args.bang == true
    show(
      M.conflict_lines({ scope = full and "full" or "registered" }),
      base .. (full and "!" or "")
    )
  end, {
    bang = true,
    desc = "lhs values claimed by more than one plugin/registration in this session; ! = full check",
  })

  local reports = { "defaults", "duplicates" }
  usercmd.create(runtime_cmd, function(args)
    local what = args.fargs[1] or "defaults"
    if not vim.tbl_contains(reports, what) then
      notify.warn(
        ("%s: unknown report '%s' (expected %s)"):format(
          runtime_cmd,
          what,
          table.concat(reports, "|")
        )
      )
      return
    end
    show(M.runtime_lines(what), runtime_cmd .. " " .. what)
  end, {
    nargs = "?",
    desc = "live keymaps: Neovim defaults overridden/removed, or one action on several keys",
    complete = function(lead)
      return vim.tbl_filter(function(r)
        return vim.startswith(r, lead)
      end, reports)
    end,
  })
end

---@type Lib.Keymap
return setmetatable(M, {
  __call = function(_, modes, lhs, rhs, opts, desc)
    return set(modes, lhs, rhs, opts, desc)
  end,
})
