---@module 'lib.nvim.deps.status'
--- Every declared tool, across every plugin that declares one, in a single
--- report.
---
--- `:Lib deps show <plugin>` answers "what does *this* plugin want", which
--- is the right question once you already suspect a plugin. It is the wrong
--- question after `git clone`ing a config onto a new machine, where the
--- question is "what is missing *here*" and the existing answer was to run
--- `show` once per plugin and hold the results in your head. `:Lib deps
--- show` with no argument didn't help either: it lists the plugins that
--- ship a spec, not what any of them is missing.
---
--- **It also fixes a timing problem it doesn't look like it fixes.** The
--- first-run popup rides on a plugin's `setup()`, so a lazy-loaded plugin
--- shows it whenever it first happens to load — which for a plugin bound to
--- a rare filetype can be weeks after installation. Measured against the
--- config this library was extracted from: 120 plugins configured, 44
--- loaded at startup, 76 pending. `spec.find` already reads lazy.nvim's
--- registry, so all 76 are reachable from here — this report sees them
--- without waiting for any of them to load.
---
--- **Rendering is `deps.view`'s, unchanged.** Merging the plugins produces
--- one tool list and one `Lib.Deps.ParseResult`, which is exactly what
--- `view.show` already takes — so the popup, the `i` / `I` install keymaps,
--- the live output streaming and the `[missing]` → `[ok]` flip all work
--- here for free, rather than existing twice in slightly different forms.
--- The only thing this module really does is the merge.

local M = {}

---The label the aggregate report is titled with, standing where a plugin
---name stands in the per-plugin view.
---@type string
local ALL = "all plugins"

---@internal
---Merge one plugin's tool into the accumulating set, keyed by `bin`.
---
---The interesting case is a tool several plugins want — `curl` is declared
---by three. It has to appear once (a report listing it three times buries
---what else is missing) while still saying who wants it, so the merge is
---per-field rather than last-one-wins:
---
--- * `required` is true if *any* declarer needs it: the strictest claim is
---   the honest one, since installing it satisfies everyone and skipping it
---   breaks at least that plugin outright.
--- * `pkg` maps are unioned, first declaration winning a key. Two plugins
---   naming different packages for one binary is a bug in one of them, and
---   silently preferring the later one would hide it.
--- * `bin_alternatives` are unioned: a spelling that counts as "found" for
---   one plugin counts for all of them, since it is the same program.
--- * `paths` are unioned per platform, same reasoning as `bin_alternatives`
---   — dropping it here (rather than just at the per-tool level) would leave
---   the AGGREGATE report (`:Lib deps show`/`install` with no plugin name)
---   reporting a `paths`-rescued tool as missing even though the per-plugin
---   view of the very same spec would not.
--- * `why` keeps the first declarer's sentence. Concatenating several would
---   produce a paragraph per tool and bury the list; `see` names everyone.
---@param acc table<string, Lib.Deps.Tool>
---@param order string[]
---@param sources table<string, string[]>
---@param tool Lib.Deps.Tool
---@param plugin_name string
---@return nil
local function merge(acc, order, sources, tool, plugin_name)
  local existing = acc[tool.bin]
  if not existing then
    order[#order + 1] = tool.bin
    acc[tool.bin] = {
      bin = tool.bin,
      bin_alternatives = vim.deepcopy(tool.bin_alternatives),
      paths = vim.deepcopy(tool.paths),
      files = vim.deepcopy(tool.files),
      probe = vim.deepcopy(tool.probe),
      required = tool.required,
      why = tool.why,
      see = tool.see,
      pkg = vim.deepcopy(tool.pkg) or {},
    }
    sources[tool.bin] = { plugin_name }
    return
  end

  existing.required = existing.required or tool.required

  for id, pkg in pairs(tool.pkg or {}) do
    if existing.pkg[id] == nil then
      existing.pkg[id] = pkg
    end
  end

  if tool.bin_alternatives then
    existing.bin_alternatives = existing.bin_alternatives or {}
    for _, alt in ipairs(tool.bin_alternatives) do
      local seen = false
      for _, have in ipairs(existing.bin_alternatives) do
        if have == alt then
          seen = true
        end
      end
      if not seen then
        existing.bin_alternatives[#existing.bin_alternatives + 1] = alt
      end
    end
  end

  if tool.paths then
    existing.paths = existing.paths or {}
    for _, platform in ipairs({ "win", "mac", "linux" }) do
      local incoming = tool.paths[platform]
      if incoming then
        existing.paths[platform] = existing.paths[platform] or {}
        for _, path in ipairs(incoming) do
          local seen = false
          for _, have in ipairs(existing.paths[platform]) do
            if have == path then
              seen = true
            end
          end
          if not seen then
            existing.paths[platform][#existing.paths[platform] + 1] = path
          end
        end
      end
    end
  end

  local list = sources[tool.bin]
  for _, name in ipairs(list) do
    if name == plugin_name then
      return
    end
  end
  list[#list + 1] = plugin_name
end

---Every declared tool across every plugin that ships a spec, merged.
---
---Pure apart from reading the spec files: no window, no notification, no
---PATH probing (that is `install.plan`'s job, on the result of this).
---@return Lib.Deps.Status.Collected
function M.collect()
  local spec = require("lib.nvim.deps.spec")

  local acc, order, sources = {}, {}, {}
  local plugins, failed = {}, {}

  for _, name in ipairs(spec.plugins()) do
    local path = spec.find(name)
    local result = path and spec.load(path) or nil
    if result then
      plugins[#plugins + 1] = name
      for _, tool in ipairs(result.tools) do
        merge(acc, order, sources, tool, name)
      end
    else
      -- Listed by `plugins()` but unreadable here: a spec whose file went
      -- away between the two calls, or one that fails to parse. Naming it
      -- beats dropping it, since "absent from the report" and "declares
      -- nothing" would otherwise look identical.
      failed[#failed + 1] = name
    end
  end

  local tools = {}
  for _, bin in ipairs(order) do
    local tool = acc[bin]
    -- `see` carries the declarers into the existing renderer, which already
    -- prints it as a "see:" line — no view change needed to answer "who
    -- wants this?". A tool declared once keeps whatever `see` its spec set.
    local list = sources[bin]
    if #list > 1 then
      tool.see = ("wanted by %s"):format(table.concat(list, ", "))
    elseif not tool.see then
      tool.see = ("wanted by %s"):format(list[1])
    end
    tools[#tools + 1] = tool
  end

  return { tools = tools, sources = sources, plugins = plugins, failed = failed }
end

---The aggregate report as lines, without opening anything.
---@param opts? Lib.Deps.ManagerOpts
---@return string[]
function M.lines(opts)
  local collected = M.collect()
  return require("lib.nvim.deps.view").lines(ALL, { tools = collected.tools, errors = {} }, opts)
end

---Show the aggregate report, with the same popup and install keymaps
---`:Lib deps show <plugin>` opens.
---@param opts? Lib.Deps.ManagerOpts
---@return boolean shown
function M.show(opts)
  local notify = require("lib.nvim.notify").create("[lib.nvim.deps]")
  local collected = M.collect()

  if #collected.plugins == 0 then
    notify.info("No plugin on runtimepath or in lazy.nvim's registry ships a deps spec.")
    return false
  end
  if #collected.failed > 0 then
    notify.warn("spec could not be read for: " .. table.concat(collected.failed, ", "))
  end

  require("lib.nvim.deps.view").show(ALL, { tools = collected.tools, errors = {} }, opts)
  return true
end

---Plan the install of everything missing across every plugin, and hand it
---off the same way `:Lib deps install <plugin>` does — confirmation and a
---terminal the user submits themselves.
---@param opts? Lib.Deps.ManagerOpts
---@return boolean started
function M.install(opts)
  local collected = M.collect()
  local install = require("lib.nvim.deps.install")
  return install.run(install.plan(collected.tools, opts))
end

---@type Lib.Deps.Status
return M
