---@module 'lib.nvim.deps.health'
--- Generic replacement for the `check_exe`/`probe` pattern hand-rolled in
--- every consuming plugin's own `health.lua` today (`pdfport.nvim`,
--- `images.nvim`, `mdview.nvim`, `migrate.nvim`, …): report executable or
--- Python-module availability via `:checkhealth`, with an optional human
--- install hint. Detection only — nothing here installs anything.

local core = require("lib.nvim.core")
local detect = require("lib.nvim.deps.detect")

local M = {}

local health = vim.health or require("health")
local h_ok = health.ok or health.report_ok
local h_err = health.error or health.report_error
local h_info = health.info or health.report_info

---@internal
---@param entry Lib.Deps.HealthEntry
local function report_one(entry)
  local label = entry.label or entry.bin or entry.python_module or "?"

  local found
  local found_as
  if entry.bin then
    found_as = detect.found_as(entry)
    found = found_as ~= nil
  elseif entry.python_module then
    local python = core.first_available({ "python3", "python", "py" })
    if not python then
      found = false
    else
      vim.fn.system({ python, "-c", "import " .. entry.python_module })
      found = vim.v.shell_error == 0
    end
  else
    h_err(label .. ": entry has neither 'bin' nor 'python_module'")
    return
  end

  if found then
    -- Naming the spelling that answered matters exactly when it is not the
    -- one asked for: "gs found" on a host that has `gswin64c` and no `gs` is
    -- true and misleading in the same line.
    if found_as and found_as ~= label then
      h_ok(("%s found (as %s)"):format(label, found_as))
    else
      h_ok(label .. " found")
    end
    return
  end

  if entry.required then
    -- `error`/`warn` take an advice list, rendered as its own bullet;
    -- `info` (the optional branch below) does not take a second argument at
    -- all -- LuaLS flags one as `redundant-parameter` for good reason, since
    -- `:checkhealth` never renders it.
    h_err(label .. " NOT found (required)", entry.hint and { entry.hint } or nil)
  else
    local suffix = entry.hint and ("  (" .. entry.hint .. ")") or ""
    h_info(label .. " NOT found (optional)" .. suffix)
  end
end

---Report availability for a flat list of health entries. Call from a
---plugin's own `health.lua` `M.check()`, replacing a hand-rolled
---`check_exe`/`probe` loop.
---@param entries Lib.Deps.HealthEntry[]
function M.report(entries)
  for _, entry in ipairs(entries) do
    report_one(entry)
  end
end

---Report availability directly from a parsed spec's `tools` list (see
---`lib.nvim.deps.spec.load`/`parse_markdown`/`parse_json`), reusing each
---tool's declared `why` as the health-report hint.
--- testing-perf: conditional: only for a tool with a `python_module`
---@param tools Lib.Deps.Tool[]
function M.from_tools(tools)
  local entries = {} ---@type Lib.Deps.HealthEntry[]
  for _, tool in ipairs(tools) do
    entries[#entries + 1] = {
      bin = tool.bin,
      bin_alternatives = tool.bin_alternatives,
      paths = tool.paths,
      required = tool.required,
      label = tool.bin,
      hint = tool.why,
    }
  end
  M.report(entries)
end

---Locate, parse, and report `plugin_name`'s own declared-tools spec via
---`:checkhealth`, ending with a pointer to `:Lib deps show` for the fuller
---report (why each tool matters, the install command). This is the
---one-line hook a plugin's own `health.lua` adds, instead of re-listing its
---tools by hand a second time:
---
---   require("lib.nvim.deps.health").report_for("pdfport.nvim")
---
---Silently does nothing when the plugin ships no spec (`spec.find` finds
---neither `docs/install.json` nor `docs/INSTALL.md`) or the spec declares no
---tools — a `:checkhealth` section for a plugin that declares nothing
---shouldn't print anything.
---@param plugin_name string
function M.report_for(plugin_name)
  local spec = require("lib.nvim.deps.spec")
  local path = spec.find(plugin_name)
  if not path then
    return
  end

  local result = spec.load(path)
  if not result or #result.tools == 0 then
    return
  end

  M.from_tools(result.tools)
  h_info(
    ("Run :Lib deps show %s for why each tool matters and how to install it."):format(plugin_name)
  )
end

---Same lookup and no-op guards as `report_for`, but without the per-tool
---loop: just the `:Lib deps show` pointer. For a plugin whose own
---`health.lua` already reports every declared tool through its own
---hand-rolled checks (richer messages, e.g. "pandoc producer: ready (engine:
---xelatex)"), calling `report_for` on top repeats each tool a second time in
---the generic, plainer wording -- confusing, not additive, since it covers
---no tool the hand-rolled checks did not already cover. This gives the same
---one-line discovery hint without that duplication.
---@param plugin_name string
function M.pointer_for(plugin_name)
  local spec = require("lib.nvim.deps.spec")
  local path = spec.find(plugin_name)
  if not path then
    return
  end

  local result = spec.load(path)
  if not result or #result.tools == 0 then
    return
  end

  h_info(
    ("Run :Lib deps show %s for why each tool matters and how to install it."):format(plugin_name)
  )
end

---@type Lib.Deps.Health
return M
