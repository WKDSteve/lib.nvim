---@module 'lib.nvim.cross.open_default'
--- Open a path or URL with the system's default application — the
--- cross-platform equivalent of double-clicking it in a file manager
--- (extension/URL-scheme decides the app: PDF → PDF viewer, .docx → Word,
--- https:// → default browser).
---
--- Platform dispatch:
---   Windows → URL: rundll32 url.dll,FileProtocolHandler <url>
---             path: explorer.exe <absolute backslashed path>
---   WSL     → converts path to a Windows path via `wslpath`, then same as
---             Windows; a URL skips straight to rundll32 (no path to
---             convert); falls back to `xdg-open` for a Linux-side file with
---             no Windows-side equivalent.
---   macOS   → open <target>
---   Linux   → xdg-open <target>
---
--- Upstreamed from open.nvim's `handlers/default.lua` (the most complete of
--- three independent copies found across the author's plugins —
--- markdown.nvim's own version, for one, has no WSL handling at all). Spawns
--- detached via `lib.nvim.cross.run.run_detached`, matching how that helper
--- was itself upstreamed from open.nvim previously.

local run = require("lib.nvim.cross.run")
local expand_path = require("lib.nvim.cross.fs.expand_path")

---@internal
---@param text string
---@return boolean
local function looks_like_url(text)
  -- Any URI scheme (`ssh:`, `mailto:`, `file:`, `magnet:`); at least two characters, so a
  -- drive letter (`C:\x`) stays a path.
  return text:match("^%a[%w+.-]+:") ~= nil or text:match("^www%.") ~= nil
end

--- Whether `opts.schemes` lets `target` through. Only a URL is judged: a path has no scheme. A
--- value that is not a list of strings fails closed, because the caller asked for a limit and a
--- typo must not turn it into no limit at all.
---@internal
---@param target string
---@param schemes string[]
---@return boolean ok
---@return string|nil err
local function scheme_allowed(target, schemes)
  if type(schemes) ~= "table" or not vim.islist(schemes) then
    return false, "opts.schemes must be a list of strings"
  end
  local wanted = {}
  for _, name in ipairs(schemes) do
    if type(name) ~= "string" then
      return false, "opts.schemes must be a list of strings"
    end
    wanted[name:lower()] = true
  end
  if not looks_like_url(target) then
    return true
  end
  -- A bare `www.` target has no scheme of its own; the browser reads it as https.
  local scheme = (target:match("^(%a[%w+.-]+):") or "https"):lower()
  if wanted[scheme] then
    return true
  end
  return false, "URI scheme not allowed: " .. scheme
end

---@internal
---@param unix_path string
---@return string|nil
local function wsl_to_win_path(unix_path)
  return require("lib.nvim.cross.fs.wslpath").to_win(unix_path)
end

--- A path `explorer.exe` will actually resolve: absolute, and spelled with
--- backslashes.
---
--- Both halves are load-bearing, and the failure is the same either way:
--- given something it cannot resolve to a file, `explorer.exe` does not
--- report an error -- it opens a **folder window**. So a relative path (which
--- `expand_path` leaves relative: `./clip.mp4` stays `./clip.mp4`) or a
--- forward-slashed one silently turns "open this video in the registered
--- player" into "here is a file browser", which reads as the default-app
--- association being wrong when it is not. Measured 2026-09-08 against a
--- `.mp4` with VLC registered.
---
--- URLs are handed over untouched: `:p` on `https://example.com/x` would
--- prefix the working directory and destroy it.
---@param target string
---@return string
local function windows_target(target)
  if looks_like_url(target) then
    return target
  end
  local path = expand_path(target)
  -- `:p` also collapses `.` and `..`, which explorer.exe does not resolve.
  local absolute = vim.fn.fnamemodify(path, ":p")
  if absolute == "" then
    absolute = path
  end
  return (absolute:gsub("/", "\\"))
end

---Open `target` (a filesystem path or URL) with the system default handler.
---
---`opts.on_exit`, when given, runs the opener **attached** (via `jobstart`)
---and reports its exit code — the opposite of the default fire-and-forget
---`run_detached` path, whose `ok` return says only that a command was
---dispatched. Absorbed from this repo's former, less complete URL-opener
---module (removed 2026-09-06 once every caller migrated to this function).
---
---`opts.schemes`, when given, is the list of URI schemes this call may open (any case; a bare
---`www.` target counts as `https`). Pass it when `target` comes from untrusted text such as a
---Markdown link: without it every scheme reaches the registered handler, on Windows also
---`ms-msdt:` or `search-ms:`. Paths are not affected.
---@param target string
---@param opts? { on_exit?: fun(code: integer), schemes?: string[] }
---@return boolean ok
---@return string|nil err
return function(target, opts)
  if type(target) ~= "string" or target == "" then
    return false, "empty target"
  end

  opts = opts or {}

  if opts.schemes ~= nil then
    local allowed, why = scheme_allowed(target, opts.schemes)
    if not allowed then
      return false, why
    end
  end

  local is_windows = require("lib.nvim.cross.platform.is_windows")()
  local is_wsl = require("lib.nvim.cross.platform.is_wsl")()
  local is_macos = require("lib.nvim.cross.platform.is_macos")()

  local cmd

  if is_windows and not is_wsl then
    if looks_like_url(target) then
      -- ShellExecute in-process: `?`, `&`, `%xx` and long URLs arrive intact and the exit
      -- code is reliable. Not `cmd.exe /C start` (its tokenizer cuts a bare `&`: any link
      -- with 2+ query params) and not `explorer.exe`: that is a folder browser which, given
      -- a URL with `?`, `&` or a `%xx` escape, takes the argument for a path pattern, drops
      -- it and opens the Documents folder instead -- in a hidden window, since children
      -- start hidden -- while exiting 1 exactly as on success. Measured 2026-10-14 against
      -- Chrome: `https://x/plain` opened, `https://x/?q=1` and `https://x/a&b=1` did not.
      cmd = { "rundll32.exe", "url.dll,FileProtocolHandler", target }
    else
      -- a file or folder: explorer.exe hands it to the registered handler with no cmd.exe
      -- re-tokenizing in between
      cmd = { "explorer.exe", windows_target(target) }
    end
  elseif is_wsl then
    if looks_like_url(target) then
      cmd = { "rundll32.exe", "url.dll,FileProtocolHandler", target }
    else
      local win_path = wsl_to_win_path(expand_path(target))
      if win_path then
        cmd = { "explorer.exe", win_path }
      elseif vim.fn.executable("xdg-open") == 1 then
        cmd = { "xdg-open", target }
      else
        return false, "cannot determine how to open: " .. target
      end
    end
  elseif is_macos then
    cmd = { "open", expand_path(target) }
  else
    if vim.fn.executable("xdg-open") ~= 1 then
      return false, "xdg-open not found — install xdg-utils"
    end
    cmd = { "xdg-open", expand_path(target) }
  end

  if opts.on_exit then
    local jid = vim.fn.jobstart(cmd, {
      on_exit = function(_, code)
        opts.on_exit(code)
      end,
    })
    if jid <= 0 then
      return false, "jobstart failed"
    end
    return true
  end

  return run.run_detached(cmd)
end
