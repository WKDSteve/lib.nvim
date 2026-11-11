# `lib.nvim.diffmode`

Native diffmode for N buffers: the layout, plus the discipline around it.

```lua
local dm = require("lib.nvim.diffmode")
local res, err = dm.open_n_way({ ours, base, theirs }, "vsplit", { origin_win = vim.api.nvim_get_current_win() })
-- res.windows  every window in the diff, in buffer order
-- res.opened   the windows this call opened (never the origin window)
dm.close(res)  -- diff off everywhere, closes res.opened
```

- `view`: `"vsplit"` (side by side), `"split"` (stacked), `"tab"` (a fresh tab, existing layout untouched).
- `opts.origin_win`: `bufs[1]` is already shown there (a live, editable buffer: `:diffget`/`:diffput` write
  into the file you will save). It joins the diff but is **not** in `opened`, so a caller closing "what it
  opened" cannot close the user's window. Without it, `bufs[1]` gets its own window.
- `'diff'` is set **window-locally** (`dm.set(win, on)`): `vim.wo[win].diff = v` also writes the global value,
  and every window opened afterwards inherits it.
- A split that fails (E36, E86 for a wiped buffer) is detected by checking the new window's buffer; everything
  this call opened is closed again and the answer is `nil, err`. Diffmode is never enabled on the wrong window.

Neovim diffs three or more diff windows against each other; no extra logic is needed beyond the layout.
