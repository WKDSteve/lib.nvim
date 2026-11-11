# lib.nvim.fs.same_path

`same_path(a, b, opts?)` answers whether two path strings name one location.

```lua
local same_path = require("lib.nvim.fs.same_path")
same_path("C:/Repo/", "c:\repo")          --> true on Windows/macOS, false on Linux
same_path("/a/b", "/a//b/")                --> true everywhere
same_path(x, y, { ignore_case = false })   --> force a case-sensitive compare
same_path(x, y, { realpath = true })       --> resolve symlinks / 8.3 names first
```

- Both sides go through [`normkey`](../normkey/README.md), then trailing
  separators are dropped.
- `ignore_case` defaults to
  [`lib.nvim.cross.platform.case_blind()`](../../cross/platform/case_blind.lua): `true` on native
  Windows and macOS, `false` on Linux and WSL.
- `realpath` defaults to `false` (no syscalls). Switch it on for paths from
  a foreign source.
- Non-string arguments return `false`.

`case_blind()` is a platform default, not a probe of one directory.
