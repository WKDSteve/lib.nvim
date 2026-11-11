---@module 'lib.nvim.deps.view'
--- Render a plugin's declared external tools — with each tool's `why`, its
--- status on this host, and what would install it — into buffer lines, and
--- show them in a popup with `i`/`<CR>`/`I` install keymaps.
---
--- `render()` is pure and does the whole rendering job, including any
--- in-progress/finished install output attached via its `ui` state table;
--- `show()` only wires that state up to a live popup and keymaps. Split that
--- way because the interesting part (does a missing required tool actually
--- get flagged, does the output block render collapsed/expanded correctly)
--- is worth asserting on directly, and a function that opens a window isn't.
---
--- `show()` prefers `lib.nvim.ui.kit`'s `viewer` popup (soft dependency,
--- same pattern pdfport.nvim's mode picker uses) and falls back to a plain
--- scratch split when `kit` isn't installed. Only the popup path gets the
--- `i` (install the tool under the cursor) / `<CR>` (expand/collapse its
--- output) / `I` (install everything missing) keymaps — the split fallback
--- is read-only, matching how it behaved before this module had keymaps.
---
--- `i` does not always run inline: a manager that needs root
--- (`pm.needs_terminal`) has no interactive stdin to answer a `sudo`
--- password prompt from a plain backgrounded job, so that case still asks
--- and hands off to a real terminal via `deps.install.run` — same safety
--- rule as the bulk install, just reached from a different key. Only
--- managers that don't need elevation (brew, scoop, most winget) install
--- inline, with output streamed live into the popup.

local detect = require("lib.nvim.deps.detect")
local pm = require("lib.nvim.deps.pm")
local install = require("lib.nvim.deps.install")

local M = {}

--- A `why` this short says nothing a bare binary name didn't already say.
--- Flagged rather than rejected: the parser already enforces that `why`
--- exists and is non-empty (see `lib.nvim.deps.spec`), but "useful" isn't
--- something validation can decide — so this is a visible nudge in the one
--- place a plugin author is most likely to look, not a gate.
local WHY_TOO_SHORT = 20

---@internal
---@return Lib.Notify.Notifier
local function notify()
  return require("lib.nvim.notify").create("[lib.nvim.deps]")
end

-- `Lib.Deps.View.ToolUiState` -- one tool's live install state, keyed by
-- `tool.bin` in the `ui` table `render`/`show` pass around -- is declared
-- once, in `lib.nvim.deps.@types`. It used to be declared here as well,
-- which made every field a `duplicate-doc-field` in both files.

---Render the report for one plugin's parsed spec, optionally overlaying
---live install state from `ui` (keyed by `tool.bin`; omit or pass `{}` for
---the plain, non-interactive report — this is what `lines()` does).
---@param plugin_name string
---@param result Lib.Deps.ParseResult
---@param opts? Lib.Deps.ManagerOpts
---@param ui? table<string, Lib.Deps.View.ToolUiState>
---@return { lines: string[], line_tools: (Lib.Deps.Tool|nil)[] } line_tools is one entry per line, the tool that line belongs to (or nil)
function M.render(plugin_name, result, opts, ui)
  ui = ui or {}
  local plan = install.plan(result.tools, opts)
  local out, line_tools = {}, {}
  -- An explicit counter, not `#out + 1`: `line_tools[#line_tools + 1] = nil`
  -- is a Lua no-op (assigning nil never grows a table's length), so every
  -- nil-tool line would silently fail to reserve its slot and every
  -- following real tool would shift one index earlier — `out` and
  -- `line_tools` would drift out of sync the first time a non-tool line
  -- appeared before a tool line. Indexing by an explicit counter sidesteps
  -- the length operator entirely.
  local n = 0

  ---@param s string
  ---@param tool Lib.Deps.Tool|nil
  local function add(s, tool)
    n = n + 1
    out[n] = s
    line_tools[n] = tool
  end

  add("# " .. plugin_name .. " — external tools", nil)
  add("", nil)

  if plan.manager then
    add(("Package manager: %s"):format(plan.manager.id), nil)
  else
    add("Package manager: none detected — install commands unavailable.", nil)
  end
  add(
    ("Tools declared: %d  ·  present: %d  ·  missing: %d"):format(
      #result.tools,
      #plan.present,
      #plan.missing
    ),
    nil
  )
  add("", nil)

  if #result.tools == 0 then
    add("This plugin declares no external tools.", nil)
  end

  ---@param tool Lib.Deps.Tool
  ---@param found boolean
  local function add_tool(tool, found)
    local state = ui[tool.bin]
    local suffix = ""
    if state and state.running then
      suffix = "  (installing… <CR> to " .. (state.collapsed and "expand" or "collapse") .. ")"
    elseif state and state.done then
      suffix = ("  (exit %d — <CR> to %s)"):format(
        state.exit_code or -1,
        state.collapsed and "expand" or "collapse"
      )
    end

    local mark = found and "[ok]" or (tool.required and "[MISSING, required]" or "[missing]")
    add(("%s %s%s"):format(mark, tool.bin, suffix), tool)
    add("    " .. tool.why, tool)
    if #tool.why < WHY_TOO_SHORT then
      add("    ^ this 'why' is very short — say what the tool actually unlocks", tool)
    end
    if tool.see then
      add("    see: " .. tool.see, tool)
    end
    if tool.files then
      add("    needs files: " .. table.concat(detect.required_files(tool), ", "), tool)
    end
    if tool.probe then
      add("    probe: " .. table.concat(tool.probe, " ") .. "  (must exit 0)", tool)
    end
    if not found then
      local via, pkg = pm.resolve(tool, plan.manager or false)
      if via and pkg then
        add("    " .. pm.render(pm.commands(via, { pkg })[1]), tool)
      elseif plan.manager then
        add(("    no %s package declared for this tool"):format(plan.manager.id), tool)
      end
    end
    if state and not state.collapsed and #state.lines > 0 then
      for _, l in ipairs(state.lines) do
        add("      | " .. l, tool)
      end
    end
    add("", tool)
  end

  -- Missing first: the reason anyone opens this view is to find out what
  -- isn't there, and required-but-missing is the most urgent line of all.
  for _, tool in ipairs(plan.missing) do
    if tool.required then
      add_tool(tool, false)
    end
  end
  for _, tool in ipairs(plan.missing) do
    if not tool.required then
      add_tool(tool, false)
    end
  end
  for _, tool in ipairs(plan.present) do
    add_tool(tool, true)
  end

  if #result.errors > 0 then
    add("## Spec problems", nil)
    add("", nil)
    for _, err in ipairs(result.errors) do
      if err.index == 0 then
        add(("- %s"):format(err.message), nil)
      else
        add(("- entry #%d (%s): %s"):format(err.index, err.field or "?", err.message), nil)
      end
    end
    add("", nil)
  end

  if #plan.commands > 0 then
    add("## Install everything missing", nil)
    add("", nil)
    for _, argv in ipairs(plan.commands) do
      add("    " .. pm.render(argv), nil)
    end
    add("", nil)
    add(("Run  :Lib deps install %s  to open this in a terminal."):format(plugin_name), nil)
  end

  return { lines = out, line_tools = line_tools }
end

---Plain report lines, no live install state — what `render` produces with
---an empty `ui` table.
---@param plugin_name string
---@param result Lib.Deps.ParseResult
---@param opts? Lib.Deps.ManagerOpts
---@return string[] lines
function M.lines(plugin_name, result, opts)
  return M.render(plugin_name, result, opts, {}).lines
end

---Fallback report: a named scratch split, read-only, no install keymaps.
---Used directly, or by `show()` when `lib.nvim.ui.kit` isn't installed.
---@param plugin_name string
---@param result Lib.Deps.ParseResult
---@return integer bufnr
---@return integer winid
function M.show_split(plugin_name, result)
  local open_named_scratch = require("lib.nvim.window.open_named_scratch")
  return open_named_scratch(
    "lib.nvim://deps/" .. plugin_name,
    M.lines(plugin_name, result),
    { filetype = "markdown", modifiable = false }
  )
end

---@internal
---Install one tool inline: stream its command's stdout/stderr into `ui`,
---live, via `rerender`. Only called once the caller has already confirmed
---and established `pm.needs_terminal(plan.manager)` is false — see `show`.
---@param tool Lib.Deps.Tool
---@param plan Lib.Deps.Plan single-tool plan, `#plan.commands == 1`
---@param ui table<string, Lib.Deps.View.ToolUiState>
---@param rerender fun()
---@param is_valid fun(): boolean
local function run_inline(tool, plan, ui, rerender, is_valid)
  local spawn_stream = require("lib.nvim.cross.uv.spawn_stream")

  ui[tool.bin] = { lines = {}, running = true, done = false, collapsed = false }
  rerender()

  spawn_stream(plan.commands[1], {}, function(line)
    vim.schedule(function()
      local state = ui[tool.bin]
      if not state then
        return
      end
      state.lines[#state.lines + 1] = line
      if is_valid() then
        rerender()
      end
    end)
  end, function(res)
    local state = ui[tool.bin]
    if not state then
      return
    end
    state.running = false
    state.done = true
    state.exit_code = res.code
    if res.ok then
      -- Without this, the header stays on `[missing]`: `render` classifies
      -- present/missing via `install.plan` -> `core.has_exec`, which
      -- memoizes "not found" — a fact that just changed.
      detect.forget(tool)
    end
    if is_valid() then
      rerender()
    end
    if res.ok then
      notify().info(tool.bin .. " installed (exit 0).")
    else
      notify().warn(
        ("%s: install exited %d — see the output in the panel."):format(tool.bin, res.code)
      )
    end
  end)
end

---@internal
---Handle `i` on the tool under the cursor: refuse (already installed /
---already running / nothing this manager can do), hand off to a terminal
---when elevation is needed, or start an inline stream otherwise.
---@param tool Lib.Deps.Tool
---@param opts? Lib.Deps.ManagerOpts
---@param ui table<string, Lib.Deps.View.ToolUiState>
---@param rerender fun()
---@param is_valid fun(): boolean
local function install_under_cursor(tool, opts, ui, rerender, is_valid)
  if detect.found(tool) then
    notify().info(tool.bin .. " is already installed.")
    return
  end

  local existing = ui[tool.bin]
  if existing and existing.running then
    notify().info(tool.bin .. " is already installing.")
    return
  end

  local one_plan = install.plan({ tool }, opts)
  if not one_plan.manager then
    notify().warn("No supported package manager found on this host.")
    return
  end
  if #one_plan.commands == 0 then
    notify().warn(("No %s package declared for %s."):format(one_plan.manager.id, tool.bin))
    return
  end

  if pm.needs_terminal(one_plan.manager) then
    notify().info(tool.bin .. " needs elevated privileges — opening a terminal to run it.")
    install.run(one_plan)
    return
  end

  require("lib.nvim.ui.dialog").yesno(
    "Install " .. tool.bin .. "?\n\n  " .. pm.render(one_plan.commands[1]),
    "install",
    function(yes)
      if yes then
        run_inline(tool, one_plan, ui, rerender, is_valid)
      end
    end
  )
end

---Show `plugin_name`'s declared tools in a popup (or a scratch split when
---`lib.nvim.ui.kit` is unavailable): `i` installs the tool under the
---cursor (inline with live output when safe, a confirmed terminal handoff
---when the package manager needs elevation), `<CR>` expands/collapses that
---output, `I` installs everything missing. `q`/`<Esc>` closes (via `kit`'s
---`nice_quit`, or `open_named_scratch`'s own split).
---@param plugin_name string
---@param result Lib.Deps.ParseResult
---@param opts? Lib.Deps.ManagerOpts
---@return integer bufnr
---@return integer winid
function M.show(plugin_name, result, opts)
  local ok_kit, kit = pcall(require, "lib.nvim.ui.kit")
  if not ok_kit then
    return M.show_split(plugin_name, result)
  end

  ---@type table<string, Lib.Deps.View.ToolUiState>
  local ui = {}
  local line_tools = {}

  local surf = kit.viewer({
    lines = M.render(plugin_name, result, opts, ui).lines,
    title = plugin_name .. " — external tools",
    filetype = "lib-deps-view",
    width = 84,
  })
  if not surf then
    return M.show_split(plugin_name, result)
  end

  local function is_valid()
    return surf:is_valid()
  end

  local function rerender()
    local r = M.render(plugin_name, result, opts, ui)
    line_tools = r.line_tools
    surf:set_lines(r.lines)
  end

  local function tool_at_cursor()
    if not is_valid() then
      return nil
    end
    local lnum = vim.api.nvim_win_get_cursor(surf.winid)[1]
    return line_tools[lnum]
  end

  vim.keymap.set("n", "i", function()
    local tool = tool_at_cursor()
    if tool then
      install_under_cursor(tool, opts, ui, rerender, is_valid)
    end
  end, { buffer = surf.bufnr, desc = "Install the tool under the cursor" })

  vim.keymap.set("n", "<CR>", function()
    local tool = tool_at_cursor()
    if tool and ui[tool.bin] then
      ui[tool.bin].collapsed = not ui[tool.bin].collapsed
      rerender()
    end
  end, { buffer = surf.bufnr, desc = "Expand/collapse this tool's install output" })

  vim.keymap.set("n", "I", function()
    install.run(install.plan(result.tools, opts))
  end, { buffer = surf.bufnr, desc = "Install everything missing" })

  return surf.bufnr, surf.winid
end

---@type Lib.Deps.View
return M
