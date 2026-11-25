# lib.nvim.fs.norm

`norm(path)` spells a path one way: `\` becomes `/`, a leading drive letter is upper case, and a
trailing `/` is dropped (a bare root keeps it: `/`, `C:/`).

```lua
local norm = require("lib.nvim.fs.norm")
norm("c:\Users\me\\") --> "C:/Users/me"
norm("C:/")             --> "C:/"
norm("/")               --> "/"
```

Pure string work with no requires. It does not expand `~`, resolve links or collapse `..`; for a
cache key that must survive those, use `lib.nvim.fs.normkey`. `lib.nvim.fs.fast.norm` is this
function.
