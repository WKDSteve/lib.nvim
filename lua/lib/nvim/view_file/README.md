# `lib.nvim.view_file`

The shape of a saved view: a small Markdown file with frontmatter that holds a selection, a grouping and a way to
draw it, and no data of its own. `rules.nvim` and `tasks.nvim` share it; what differs is a parameter of `new`.

| Part | What it does |
| --- | --- |
| `normalize(def)` | checks a view as a caller gives it (title, display, `group_by`/`group_by2`, collapsed groups, selection lists, query) |
| `pairs_of(view, dates, patch)` | the frontmatter as `{ key, value }` pairs in file order; with `patch` a key the view lacks is `frontmatter.REMOVE` |
| `parse_text(text, default_title)` | a file's text read as a view (with `created`/`updated`) |

```lua
local view_file = require("lib.nvim.view_file").new({
  displays = { "list", "matrix" },
  is_field = function(field) return field == "status" or field == "prio" end,
  fields_hint = "status, prio",
  select = { { name = "statuses", key = "sel_statuses" } },
})
local view = assert(view_file.normalize({ title = "Open", display = "list", group_by = "status" }))
local pairs = view_file.pairs_of(view, { created = "2026-01-01", updated = "2026-01-01" }, false)
```

Config: `displays`, `is_field`, `fields_hint` (said when `group_by` is no field), `select` (`{ name, key }` each),
`allow_empty_word` (default false), `max_list` (100), `max_entry` (300).

Not here: where the files live, the id, locking, atomic writes, symbolic links and the errors of saving and deleting;
those depend on the plugin's file layer and stay with it.
