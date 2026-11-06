# Installation

## Requirements

| | |
| --- | --- |
| Neovim | **0.11+** |
| Third-party plugins | none — only `vim` and itself |

Individual modules reach for external tools where one exists (git, a system
package manager for `lib.nvim.deps`), and every one of them is detected at
runtime and degrades to nothing when absent.

## When to install it

How you install `lib.nvim` depends on **when** it is needed.

## As a dependency of other plugins

If `lib.nvim` is only consumed *inside other plugins*, declare it as their
dependency — [lazy.nvim] loads it on demand:

```lua
{
  "you/my-plugin.nvim",
  dependencies = { "WKDSteve/lib.nvim" },
}
```

With [packer.nvim]:

```lua
use {
  "you/my-plugin.nvim",
  requires = { "WKDSteve/lib.nvim" },
}
```

> The `package.path` bootstrap trick described under [Config-wide
> use](#config-wide-use-bootstrap-required) below is specific to lazy.nvim's
> module loader. If you need `lib.*` before your plugin manager has finished
> loading specs under packer or another manager, adapt the same idea (prepend
> `lib.nvim`'s `lua/` dir to `package.path` before your first `require("lib.*")`).

Standalone (loaded lazily on first `require`):

```lua
{ "WKDSteve/lib.nvim", lazy = true }
```

## Config-wide use (bootstrap required)

If you use `lib.*` **directly in your own config** — in `nvim/lua/*`, `nvim/lua/plugins/*`, autocmds, mappings, etc. — it is needed **before** lazy.nvim
has even finished reading your plugin specs. A normal plugin spec is then too late.

> **Why a plain spec / `rtp:prepend` is not enough:**
> lazy.nvim installs its own > module loader during `setup()`. That loader does **not** search runtimepath entries you add afterwards, so `require("lib.*")` fails during the spec-import phase.
> You must also register `lib.nvim` on `package.path` — the C require searcher is the universal fallback that lazy does not replace.

Bootstrap it in your `init.lua`, **before** `require("lazy").setup()`, the same way lazy.nvim bootstraps itself:

```lua
-- init.lua — BEFORE require("lazy").setup(...)
local libpath = vim.fn.stdpath("data") .. "/lazy/lib.nvim"
if not (vim.uv or vim.loop).fs_stat(libpath) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/WKDSteve/lib.nvim.git", libpath,
  })
end
vim.opt.rtp:prepend(libpath)
-- Required: lazy.nvim's loader ignores rtp entries added here, so also expose
-- lib.nvim via package.path (the C require searcher, which lazy does not replace).
package.path = table.concat({
  libpath .. "/lua/?.lua",
  libpath .. "/lua/?/init.lua",
  package.path,
}, ";")
```

Then add a managed spec so `:Lazy update` keeps it current. Because the
bootstrap makes it effectively always loaded, use `lazy = false`:

```lua
{ "WKDSteve/lib.nvim", lazy = false, priority = 1000 }
```

See [Usage](usage.md) for how to require modules once `lib.nvim` is installed.
