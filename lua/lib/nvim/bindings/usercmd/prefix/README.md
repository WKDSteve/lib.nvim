# lib.nvim.bindings.usercmd.prefix

`prefix(cands, lead)` keeps the candidates that start with `lead`, in their order. The case is
significant. With an empty `lead` it returns `cands` itself, not a copy.

```lua
local prefix = require("lib.nvim.bindings.usercmd.prefix")
prefix({ "open", "on", "off" }, "o") --> { "open", "on", "off" }
prefix({ "open", "on", "off" }, "of") --> { "off" }
```
