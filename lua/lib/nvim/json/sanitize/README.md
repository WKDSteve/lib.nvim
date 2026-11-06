# `lib.nvim.json.sanitize`

Repair an already-decoded JSON value against a **description**: a required
field that is missing, `null` or of the wrong type becomes a placeholder and a
warning, not a crash. For any plugin that consumes an external JSON API
(a repository search result, a backend's reply).

```
lib.nvim.json.sanitize/
├── init.lua       -- apply, check
└── @types/        -- LuaLS types (Lib.Json.Sanitize.*)
```

```lua
local sanitize = require("lib.nvim.json.sanitize")

local REPO = {
  type = "table",
  fields = {
    name = { type = "string", required = true, default = "No name" },
    owner = {
      type = "table",
      required = true,
      fields = { login = { type = "string", required = true, default = "Unknown" } },
    },
    description = { type = "string", default = "No description" },
  },
}

local clean, warnings = sanitize.apply(
  vim.json.decode(body),
  { type = "table", required = true, fields = { items = { type = "list", required = true, of = REPO } } }
)
for _, w in ipairs(warnings) do
  vim.notify(w.message, vim.log.levels.WARN) -- "$.items[3].owner: required table is missing, placeholder used"
end
-- `clean.items[i].owner.login` can be indexed without a nil check
```

`apply` never throws for odd *data* (it throws only for a broken description:
not a table, unknown `type`), never changes its input (the result is a copy; a
part the description does not touch is shared with the input) and reports every
repair by path.

## The description

| Field | Meaning |
|-------|---------|
| `type` | `"string"`, `"number"`, `"boolean"`, `"table"` (an object), `"list"` (an array) or `"any"` (default). An empty table is both an object and a list |
| `required` | missing / `null` / wrong type -> placeholder **and** a warning. Without it: a missing value stays absent, a wrong type is reported and dropped |
| `default` | the placeholder (a function is called to make a fresh one; a table is copied). Default by type: `""`, `0`, `false`, `{}`. On an optional field it fills a missing value silently |
| `coerce` | number -> string, numeric string -> number, `"true"`/`"false"` -> boolean (reported as `coerced`) |
| `fields` | for `"table"`: the described keys, repaired recursively. Keys not named are kept |
| `strict` | for `"table"`: drop the keys `fields` does not name |
| `of` | for `"list"`: what every element looks like. A bad element is replaced by its placeholder, so the list keeps its length and positions |
| `drop_invalid` | for `"list"`: leave a bad element out instead |
| `min`, `max` | for `"number"`: inclusive bounds. Out of bounds counts as wrong (code `value`) |
| `enum` | for `"string"`: the values allowed. Any other counts as wrong (code `value`) |
| `warn` | `false`: repair a missing value without reporting it |

A scalar is judged by [`lib.lua.config.schema`](../../../lua/config/schema/README.md),
so `min`, `max` and `enum` mean what they mean in a config schema, and a NaN or an
infinity is not a number. `table` and `list` stay here: that schema has one `table`,
and a repair has to tell a record from a list.

A `default` that raises or does not have the field's `type` is ignored (the neutral
value of the type is used). `"nan"`, `"inf"` and `"1e999"` are not coerced to numbers.
A list element of type `any` has no placeholder: a `null` there is left out and
reported as `missing`, so positions shift (describe the element with a concrete
`type` to keep them). A description that nests deeper than 64 levels is not
followed further (the data is kept as it is).

A placeholder table is repaired too (a missing `owner` becomes `{ login =
"Unknown" }`), without one warning per nested field.

## Warnings

`{ path, code, message }`; `path` is `$` for the root, then `.key` / `[i]`.
`code` is `missing`, `type`, `value`, `coerced` or `dropped` (an element left out that no other warning explained); one warning per repair. They come in a stable
order (keys sorted). Options:

- `on_warning(w)` is called for each as it is found (a throwing callback is ignored)
- `max_warnings` (default 100) caps what is *recorded*; the repair goes on and
  the rest is the third return value, so a response of 50 000 broken items does
  not build 50 000 messages

`check(value, field)` is `true` when `apply` would repair nothing.

## Not this module's job

Parsing text (`lib.nvim.json.decode`), patterns, notifying the user. For config tables with coercion and enums see
[`lib.nvim.normalize`](../../normalize/README.md).
