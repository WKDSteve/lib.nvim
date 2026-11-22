# `lib.nvim.clipboard_image`

Save the image on the system clipboard as a PNG: `save` waits for the tool,
`save_async` does not.

```lua
local ci = require("lib.nvim.clipboard_image")
local ok, err = ci.save("/tmp/shot.png")   -- false, "no image in the clipboard" when there is none
local tool, why = ci.tool()                -- the tool this platform would use, or the reason there is none

-- From a keypress: on Windows the tool is a PowerShell start (100-450 ms of a frozen editor with `save`).
ci.save_async("/tmp/shot.png", nil, function(ok, err)
  -- later, on the main loop; the same answer `save` gives
end)
```

| Platform | Tool |
| -------- | ---- |
| Windows | `powershell.exe -STA` (WinForms clipboard) |
| macOS | `pngpaste` |
| Linux | `wl-paste`, else `xclip` |

Tools are detected, not assumed; a missing one is an error message. Nothing is
written when the clipboard holds no image, and the result must carry the PNG
signature. `opts.platform`, `opts.has` and `opts.system` replace the platform
check, the executable check and the process runner for specs.

`save_async(path, opts, on_done)` starts the tool with the exit callback of
`vim.system` and returns at once; `on_done(ok, err)` always runs on a later
tick of the main loop, also when there is no path or no tool. Dropping a late
answer (a newer call, a closed window) is the caller's part. With
`opts.system` the replaced runner is called at once and its result is read as
the tool's exit. A caller that may meet an older lib.nvim checks for the field
(`if ci.save_async then`) and falls back to `save`.
