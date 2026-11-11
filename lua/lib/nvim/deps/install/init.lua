---@module 'lib.nvim.deps.install'
--- Turn a parsed tool spec into an install plan, and — only on an explicit,
--- confirmed call — put the composed command in front of the user in a
--- terminal buffer.
---
--- `plan()` is pure: it probes PATH and the host's package manager, and
--- returns what *would* happen. Nothing about it touches the system.
---
--- `run()` is the one function in `lib.nvim.deps` that opens anything. Its
--- contract, which the rest of the module's safety argument rests on:
---
---   1. It is never called from `require` or a `setup()` — only from an
---      explicit user action (`:Lib deps install <plugin>`).
---   2. It asks for confirmation, showing the exact command(s) first.
---   3. It opens a terminal running the user's shell and *types* the command
---      into it **without a trailing newline**. The user presses Enter.
---      Nothing is executed by this library, so a `sudo` password prompt is
---      answered at a real terminal the user opened, not by Neovim.
---
--- Point 3 is why this doesn't use `jobstart`/`vim.system`: a backgrounded
--- privileged install with its prompt swallowed is precisely the failure mode
--- worth designing out.

local detect = require("lib.nvim.deps.detect")
local pm = require("lib.nvim.deps.pm")

local M = {}

---Compute what installing `tools` would involve on this host: which are
---already present, which are missing, which of the missing ones this host's
---package manager has a package name for, and the command(s) that would
---install them.
---
---`opts.manager` overrides detection (mainly so this is testable without
---depending on what the test machine happens to have installed).
---@param tools Lib.Deps.Tool[]
---@param opts? Lib.Deps.ManagerOpts
---@return Lib.Deps.Plan
function M.plan(tools, opts)
  opts = opts or {}
  local manager = opts.manager or pm.detect()

  local present, missing, installable, unsupported, packages = {}, {}, {}, {}, {}
  -- Packages of a language-level manager (pipx/pip), grouped per manager in
  -- first-seen order; the OS manager's stay in `packages`.
  local lang_order, lang_pkgs, lang_seen = {}, {}, {}
  -- Several tools routinely ship in ONE package — pdftotext and pdftoppm are
  -- both poppler-utils. Without this, a plan missing both would compose
  -- `apt install poppler-utils poppler-utils`. Each tool still appears in
  -- `installable` on its own (the report lists tools, not packages); only
  -- the package list is de-duplicated.
  local seen_pkg = {}

  for _, tool in ipairs(tools) do
    if detect.found(tool) then
      present[#present + 1] = tool
    else
      missing[#missing + 1] = tool
      local via, pkg = pm.resolve(tool, manager or false)
      if via and pkg then
        installable[#installable + 1] = tool
        if manager and via.id == manager.id then
          if not seen_pkg[pkg] then
            seen_pkg[pkg] = true
            packages[#packages + 1] = pkg
          end
        else
          lang_pkgs[via.id] = lang_pkgs[via.id] or {}
          lang_seen[via.id] = lang_seen[via.id] or {}
          if not lang_seen[via.id][pkg] then
            lang_seen[via.id][pkg] = true
            table.insert(lang_pkgs[via.id], pkg)
          end
          if #lang_pkgs[via.id] == 1 then
            lang_order[#lang_order + 1] = via
          end
        end
      else
        unsupported[#unsupported + 1] = tool
      end
    end
  end

  local commands = manager and pm.commands(manager, packages) or {}
  for _, via in ipairs(lang_order) do
    for _, argv in ipairs(pm.commands(via, lang_pkgs[via.id])) do
      commands[#commands + 1] = argv
    end
  end

  return {
    manager = manager,
    present = present,
    missing = missing,
    installable = installable,
    unsupported = unsupported,
    packages = packages,
    commands = commands,
  }
end

---@internal
---The lines shown in the confirmation prompt: one per command, plus a note
---about any missing tool this host's manager has no package name for (those
---are silently left out of the command otherwise, which would look like the
---plan simply forgot them).
---@param plan Lib.Deps.Plan
---@return string
local function confirm_text(plan)
  local lines = { "Run the following to install the missing tools?", "" }
  for _, argv in ipairs(plan.commands) do
    lines[#lines + 1] = "  " .. pm.render(argv)
  end
  if #plan.unsupported > 0 then
    lines[#lines + 1] = ""
    local names = {}
    for _, tool in ipairs(plan.unsupported) do
      names[#names + 1] = tool.bin
    end
    lines[#lines + 1] = ("Not covered (no %s package declared): %s"):format(
      plan.manager and plan.manager.id or "?",
      table.concat(names, ", ")
    )
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] =
    "The command is typed into a terminal for you to submit — nothing runs on its own."
  return table.concat(lines, "\n")
end

---@internal
---Open a terminal split running the user's shell, and type `text` into it
---without submitting. Returns the buffer, or nil if the terminal could not
---be started.
---@param text string
---@return integer|nil bufnr
local function open_terminal_with(text)
  local term = require("lib.nvim.terminal").spawn({
    argv = { vim.o.shell },
    layout = "split",
    -- No trailing newline, on purpose: the user submits it (see module header).
    on_open = function(_, _, job)
      vim.fn.chansend(job, text)
    end,
  })
  return term and term.bufnr or nil
end

---Offer to install everything in `plan` that this host's package manager can.
---
---Always asks first (showing the exact command), then opens a terminal with
---the command typed but not submitted. `opts.confirm = false` skips only the
---prompt — it does **not** submit the command, which stays the user's
---keystroke either way; it exists for callers that already asked in their own
---UI, and for tests.
---
---The question is the shared dialog (`lib.nvim.ui.dialog.yesno`, "No" first and
---focused), so the answer comes on a later loop turn: the return value is `nil`
---while it is open and `opts.on_done(started)` says how it ended. When nothing is
---asked, the result is the return value and `on_done` runs before this returns.
---@param plan Lib.Deps.Plan
---@param opts? { confirm?: boolean, on_done?: fun(started: boolean) }
---@return boolean|nil started true when a terminal was opened; nil while the question is open
function M.run(plan, opts)
  opts = opts or {}
  local notify = require("lib.nvim.notify").create("[lib.nvim.deps]")

  ---@param started boolean
  ---@return boolean
  local function done(started)
    if opts.on_done then
      opts.on_done(started)
    end
    return started
  end

  if not plan.manager and #plan.commands == 0 then
    notify.warn("No supported package manager found on this host — install the tools manually.")
    return done(false)
  end
  if #plan.commands == 0 then
    if #plan.missing == 0 then
      notify.info("All declared tools are already installed.")
    else
      notify.warn(
        ("Nothing to install: no %s package name is declared for the missing tool(s)."):format(
          plan.manager.id
        )
      )
    end
    return done(false)
  end

  local function start()
    local parts = {}
    for _, argv in ipairs(plan.commands) do
      parts[#parts + 1] = pm.render(argv)
    end
    -- `&&` rather than `;`: a failed first install shouldn't be followed by the
    -- rest running against a half-set-up system.
    local text = table.concat(parts, " && ")

    if not open_terminal_with(text) then
      notify.error("Could not open a terminal; run manually:  " .. text)
      return done(false)
    end
    return done(true)
  end

  if opts.confirm ~= false then
    require("lib.nvim.ui.dialog").yesno(confirm_text(plan), "open terminal", function(yes)
      if yes then
        start()
      else
        done(false)
      end
    end)
    return nil
  end
  return start()
end

---@type Lib.Deps.Install
return M
