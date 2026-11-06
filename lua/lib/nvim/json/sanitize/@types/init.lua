---@meta
---@module 'lib.nvim.json.sanitize.@types'

---@alias Lib.Json.Sanitize.Type "string"|"number"|"boolean"|"table"|"list"|"any"

---What one field of a decoded JSON value must look like.
---@class Lib.Json.Sanitize.Field
---@field type? Lib.Json.Sanitize.Type  Expected kind (default `"any"`: anything but a missing value / JSON null). `"table"` is an object, `"list"` an array.
---@field required? boolean  A missing / null / wrong-typed value is replaced and reported (default: it is left absent, a wrong type is still reported and dropped).
---@field default? any  The placeholder (a function is called to make a fresh one). Default by type: `""`, `0`, `false`, `{}`, `{}`; none for `any`.
---@field coerce? boolean  Turn a number into a string, a numeric string into a number, `"true"`/`"false"` into a boolean before judging the type.
---@field fields? table<string, Lib.Json.Sanitize.Field>  For `"table"`: the described keys. Other keys are kept as they are (unless `strict`).
---@field strict? boolean  For `"table"`: drop the keys `fields` does not name.
---@field of? Lib.Json.Sanitize.Field  For `"list"`: what every element must look like.
---@field drop_invalid? boolean  For `"list"`: leave out an element that was missing / of the wrong type instead of putting the placeholder in its place.
---@field min? number  For `"number"`: inclusive lower bound, as in `lib.lua.config.schema`.
---@field max? number  For `"number"`: inclusive upper bound.
---@field enum? string[]  For `"string"`: the values allowed.
---@field warn? boolean  Report the placeholder of a missing value (default `true`; `false` for a field whose absence is normal).

---One thing `apply` had to repair.
---@class Lib.Json.Sanitize.Warning
---@field path string  `items[3].owner.login`; the root is `$`
---@field code "missing"|"type"|"value"|"coerced"|"dropped"
---@field message string  Human-readable, names the path, the expected and the found kind

---@class Lib.Json.Sanitize.Opts
---@field on_warning? fun(w: Lib.Json.Sanitize.Warning)  Called for every warning as it is found
---@field max_warnings? integer  Stop recording after this many (the repair goes on); default 100. The rest is counted in `dropped_warnings`.

---@class Lib.Json.Sanitize
---@field apply fun(value: any, field: Lib.Json.Sanitize.Field, opts?: Lib.Json.Sanitize.Opts): any, Lib.Json.Sanitize.Warning[], integer
---@field check fun(value: any, field: Lib.Json.Sanitize.Field): boolean  True when `apply` would repair nothing.

return {}
