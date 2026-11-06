# `lib.nvim.cross.open_default`

Opens a path or URL with the system's default application — the
cross-platform equivalent of double-clicking it in a file manager (the
extension or URL scheme decides the app: PDF → PDF viewer, `.docx` → Word,
`https://` → default browser).

Upstreamed from open.nvim's `handlers/default.lua`, chosen as the most
complete of three independent copies the author had accumulated across
plugins (markdown.nvim's own copy, for one, has no WSL handling at all).

Platform dispatch:

- **Windows (native)**: a URL goes to `rundll32 url.dll,FileProtocolHandler
  <url>` (ShellExecute), a path to `explorer.exe <absolute backslashed path>`.
  Deliberately not `cmd.exe /C start`: its tokenizer treats a bare `&` as a
  command separator and cuts any link with 2+ query params. And a URL not to
  `explorer.exe`: given `?`, `&` or a `%xx` escape it opens the Documents folder
  instead of the browser.
- **WSL**: a URL goes straight to `rundll32`; a filesystem path is
  converted to its Windows equivalent via `wslpath -w` and handed to
  `explorer.exe`; if `wslpath` fails to produce a path, falls back to `xdg-open`
  for a Linux-side file with no Windows-side equivalent, or returns
  `false, "cannot determine how to open: " .. target"` if `xdg-open` isn't
  present either.
- **macOS**: `open <target>`.
- **Linux (other)**: `xdg-open <target>`; returns `false` with an error if
  `xdg-open` isn't on PATH.

`target` is passed through `lib.nvim.cross.fs.expand_path` before dispatch
(except the URL branches of Windows and WSL, which hand it over untouched). The
resolved command is always spawned detached via
`lib.nvim.cross.run.run_detached` — the browser/viewer keeps running after
Neovim exits.

## Usage

```lua
local open_default = require("lib.nvim.cross.open_default")

local ok, err = open_default("~/notes/report.pdf")
local ok2 = open_default("https://example.com/x?a=1&b=2")
if not ok then
  vim.notify("could not open: " .. tostring(err), vim.log.levels.WARN)
end
```

Returns `false, "empty target"` if `target` is not a non-empty string.

## `opts.schemes`

Every URI scheme reaches its registered handler by default, which `ssh:`,
`mailto:` and `magnet:` links need. When `target` comes from untrusted text (a
Markdown link, a search hit), that also includes handlers such as `ms-msdt:` or
`search-ms:` on Windows. Pass the schemes this call may open:

```lua
local ok, err = open_default(link, { schemes = { "http", "https", "mailto" } })
-- link = "ms-msdt:/id x" -> false, "URI scheme not allowed: ms-msdt"
```

Names match in any case, and a bare `www.` target counts as `https`. Paths are
not judged. A value that is not a list of strings returns `false` and opens
nothing, so a typo cannot turn the limit off.

## `opts.on_exit`

By default the opener is spawned detached (via `lib.nvim.cross.run.run_detached`)
and the `ok` return says only that a command was *dispatched*. Pass
`opts.on_exit` to run it **attached** (via `jobstart`) and observe the real
exit code:

```lua
open_default(url, {
  on_exit = function(code)
    if code ~= 0 then
      vim.notify("opener exited " .. code, vim.log.levels.WARN)
    end
  end,
})
```

This is the one piece of surface absorbed from this repo's former, less
complete URL-opener module, removed 2026-09-06 once every caller had
migrated to this function directly.
