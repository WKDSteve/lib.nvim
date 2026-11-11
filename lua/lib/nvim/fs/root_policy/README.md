# `lib.nvim.fs.root_policy`

Root-policy state machine for "which directory is the root right now": the part
of `filetree.nvim`'s `cwd_mode` that has nothing to do with a file tree.

```lua
local root_policy = require("lib.nvim.fs.root_policy")

local policy = root_policy.new({
  find_root = function(file, kind)           -- "project" = VCS root, "nearest" = package
    return vim.fs.root(file, kind == "project" and { ".git" } or { "package.json", ".git" })
  end,
  on_change = function(state) vim.cmd.redrawstatus() end,   -- only on a real change
})

policy.set_mode("project")
local d = policy.decide(vim.api.nvim_buf_get_name(0))   -- { root, chdir, reveal } or nil
if d and d.chdir then vim.cmd.cd(d.root) end

policy.set_mode("lock", "/repo")   -- pinned; foreign `:cd` is undone via dir_guard
policy.unlock()                    -- back to the mode before the lock
```

## Modes

| Mode         | `decide(file)`                                                                |
|--------------|-------------------------------------------------------------------------------|
| `follow`     | `nil`: no policy, the caller's own logic runs                                 |
| `project`    | hold the pinned root while files stay inside it; a file outside re-pins       |
| `nearest`    | like `project` with the finder's `"nearest"` kind (package boundary)          |
| `lock`       | always the pinned dir; `reveal` only for files inside it (or `reveal_outside`)|
| `manual`     | `{ root = pinned, chdir = false, reveal = false }`                            |
| `tree_leads` | the pin is the truth: `chdir = false`, `reveal` only inside it                |

`sticky` (default true): a file with no root of its own (a scratch file in
`/tmp`) keeps the current root instead of re-pinning to its parent.

## Diff-based updates

`on_change({ mode, pinned })` runs only when mode or pinned root differ from what
the listener saw last. A statusline hooked to it is not redrawn on each buffer
switch, only when something it shows changed. `repin(dir)` is the entry for a
manual re-root (the tree's `+`/`-`): it moves a lock's guard instead of being
reverted.

Built on [`dir_guard`](../dir_guard/README.md), [`chdir`](../chdir/README.md),
[`normkey`](../normkey/README.md) and [`is_subpath`](../is_subpath/README.md).
It never reads buffers by itself; `decide` is called by the owner. Persistence,
the badge and the commands stay in the consumer (`filetree.nvim`).
