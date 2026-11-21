---@module 'lib.nvim.cross.copy_to_clipboard'
--- Cross-platform clipboard write. Tries the Neovim `+` register first, then
--- an OS-appropriate external tool as a fallback, piping `text` via stdin
--- (never interpolated into a shell command string — string interpolation
--- into `xclip`/`wl-copy` invocations was a real command-injection bug fixed
--- here: a `text` value containing shell metacharacters could execute
--- arbitrary commands).
---
--- Linux picks `wl-copy` under Wayland and `xclip`/`xsel` under X11 (checked
--- via `$WAYLAND_DISPLAY`/`$DISPLAY`), falling back to trying whichever
--- tool is actually on PATH if the display-server guess doesn't pan out.
---
--- Called as `copy(text)` it waits for the tool and returns whether the copy
--- took. Called as `copy(text, on_done)` it never waits for a tool: the
--- external fallback runs in the background (one write at a time, in order;
--- see `copy_to_clipboard.writer`) and `on_done(ok)` is called later on the
--- main loop. That is the form for a keypress: the Windows fallback
--- (`powershell ... Set-Clipboard`) alone froze the editor 150-800 ms per copy.

local core = require("lib.nvim.core")

---@internal
--- Set the `+` register and verify the write actually took, rather than
--- trusting `pcall`'s success as a proxy for it.
---
--- `vim.fn.setreg("+", text)` does not raise when there is no clipboard
--- provider -- it just silently does nothing, after printing "clipboard:
--- No provider" to `:messages`. So `pcall(vim.fn.setreg, ...)` was always
--- `true` on a machine with no provider AND no external tool, and this
--- function reported success while nothing was actually on the clipboard.
--- Every caller across this fleet trusted that return value to tell a user
--- "copied" -- that was the actual bug, not a CI quirk: any Linux session
--- with no `xclip`/`xsel`/`wl-copy` and no `g:clipboard` configured hit it.
---@param text string
---@return boolean
local function try_native_register(text)
  local ok = pcall(vim.fn.setreg, "+", text)
  if not ok then
    return false
  end
  local ok2, got = pcall(vim.fn.getreg, "+")
  return ok2 and got == text
end

---@internal
--- The external tools to try, in order, each as an argv that reads the text
--- from stdin. Tools not on PATH are left out up front.
---@return string[][]
local function candidates()
  local lib = require("lib")
  local list = {}
  local function add(argv)
    if core.has_exec(argv[1]) then
      list[#list + 1] = argv
    end
  end

  -- macOS
  if lib.is_macos() then
    add({ "pbcopy" })
  end

  -- Linux (not WSL): prefer the tool matching the detected display server,
  -- then fall back to trying every known candidate regardless.
  if lib.is_linux() and not lib.is_wsl() then
    local is_wayland = (vim.env.WAYLAND_DISPLAY or "") ~= ""
    local is_x11 = (vim.env.DISPLAY or "") ~= ""
    if is_wayland then
      add({ "wl-copy" })
    end
    if is_x11 then
      add({ "xclip", "-selection", "clipboard" })
      add({ "xsel", "--clipboard", "--input" })
    end
    add({ "wl-copy" })
    add({ "xclip", "-selection", "clipboard" })
    add({ "xsel", "--clipboard", "--input" })
  end

  -- Windows native PowerShell. Not checked with `has_exec`, as before:
  -- `vim.system` raising for a missing program counts as a failed try.
  if lib.is_windows() and not lib.is_wsl() then
    -- `cross.run.argv` keeps every shell argument, `-Command` included.
    list[#list + 1] = require("lib.nvim.cross.run").argv("$input | Set-Clipboard")
  end

  -- WSL → clip.exe (Windows clipboard), with an absolute-path fallback
  -- for the case where clip.exe isn't resolved via PATH.
  if lib.is_wsl() then
    add({ "clip.exe" })
    local clip_abs = "/mnt/c/Windows/System32/clip.exe"
    if vim.fn.filereadable(clip_abs) == 1 then
      list[#list + 1] = { clip_abs }
    end
  end
  return list
end

---@internal
---@param argv string[]
---@param text string
---@return boolean
local function run_with_stdin(argv, text)
  local ok, obj = pcall(function()
    return vim.system(argv, { stdin = text }):wait()
  end)
  return ok and obj ~= nil and obj.code == 0
end

--- Copy text to system clipboard using platform-appropriate backend.
---
--- Without `on_done`: blocks until the copy is done and returns whether it
--- took. With `on_done`: returns nil at once and calls `on_done(ok)` later
--- (always on a later tick, also when the `+` register took it right away).
--- A blocking copy first waits for background copies still running, so the
--- clipboard always ends with the text of the last call.
---@param text string
---@param on_done? fun(ok: boolean)
---@return boolean|nil
return function(text, on_done)
  local writer = require("lib.nvim.cross.copy_to_clipboard.writer")
  if on_done ~= nil and type(on_done) ~= "function" then
    error(("copy_to_clipboard: `on_done` must be a function, got %s"):format(type(on_done)), 2)
  end

  if on_done then
    if not writer.busy() and try_native_register(text) then
      vim.schedule(function()
        on_done(true)
      end)
      return nil
    end
    -- While a background write runs, this one queues behind it even if the
    -- register would take it now: the earlier write finishing later would
    -- otherwise leave its older text on the clipboard.
    writer.submit(text, candidates(), on_done)
    return nil
  end

  -- Blocking form: a background copy still in flight must land first.
  writer.flush()

  -- 1) Try Neovim register (+)
  if try_native_register(text) then
    return true
  end

  -- 2) the external tools
  if not vim.system then
    return false
  end
  for _, argv in ipairs(candidates()) do
    if run_with_stdin(argv, text) then
      return true
    end
  end
  return false
end
