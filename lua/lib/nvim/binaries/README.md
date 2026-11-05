# `lib.nvim.binaries`

One setting for every own plugin that downloads a binary (a server, a release asset): may it do that on its own?

```lua
vim.g.lib_binaries = "manual"   -- "auto" (default) | "manual" | "never"
```

| Value | Downloads on first use | `fetch()` |
| --- | --- | --- |
| `"auto"` (default) | yes | works |
| `"manual"` | no, the plugin says how to fetch | works |
| `"never"` | no | refuses |

Anything else counts as `"manual"`: a typo must not switch downloads on.

## For a plugin that downloads

```lua
local binaries = require("lib.nvim.binaries")

-- once, at load time (cheap): how to download on request
binaries.register("mdview.nvim", {
  fetch = function() return download_everything() end, -- true, or false and why
  status = function() return "server installed" end,
})

-- right before the download
local ok, why = binaries.guard("mdview.nvim")
if not ok then
  return nil, why
end
```

`fetch()` raises the "explicit" flag while it runs, so `guard()` lets the download through in `"manual"`.

## For the user

`binaries.fetch()` (all registered plugins) or `binaries.fetch("mdview.nvim")` returns `{ [name] = { ok, err } }`;
`binaries.status()` says what is there. A user command, a CLI or a settings page calls these; this module has none of
its own.
