---@module 'lib.nvim.json.sanitize'
---@brief Repair an already-decoded JSON value against a description: required fields that are missing become placeholders and a warning, not a crash.
---@description
--- External APIs return what they like: a repository without a `description`,
--- an `owner` that is `null`, a number where a string was promised. A plugin
--- that indexes such a response blindly crashes on the first odd item. `apply`
--- takes the decoded value and a description of what it must look like and
--- returns a repaired COPY plus the list of repairs; the input is never
--- changed and nothing is thrown for odd data.
---
--- Key responsibilities:
---  - fill missing / `null` / wrong-typed required fields with a placeholder
---    (the field's `default`, else a neutral value of its type) and report them
---  - descend into objects (`fields`) and arrays (`of`), reporting each repair
---    by path (`items[3].owner.login`)
---  - keep every key the description does not name (unless `strict`)
---
--- Not its job: parsing JSON text (`lib.nvim.json.decode`), schema languages
--- (no patterns, ranges, enums), notifying the user (the caller gets the
--- warnings and decides how loud to be).
---
---```lua
--- local sanitize = require("lib.nvim.json.sanitize")
---
--- local REPO = {
---   type = "table",
---   fields = {
---     name = { type = "string", required = true, default = "No name" },
---     owner = { type = "table", required = true, fields = {
---       login = { type = "string", required = true, default = "Unknown" },
---     } },
---     description = { type = "string", default = "No description" },
---   },
--- }
--- local clean, warnings = sanitize.apply(
---   decoded,
---   { type = "table", fields = { items = { type = "list", required = true, of = REPO } } }
--- )
--- for _, w in ipairs(warnings) do vim.notify(w.message, vim.log.levels.WARN) end
---```
---@see lib.nvim.json
---@see lib.nvim.normalize

require("lib.nvim.json.sanitize.@types")

local schema = require("lib.lua.config.schema")

local M = {}

local NEUTRAL = {
  string = function()
    return ""
  end,
  number = function()
    return 0
  end,
  boolean = function()
    return false
  end,
  table = function()
    return {}
  end,
  list = function()
    return {}
  end,
}

local VALID_TYPES =
  { string = true, number = true, boolean = true, table = true, list = true, any = true }

---@param v any
---@return boolean
local function is_missing(v)
  return v == nil or v == vim.NIL
end

---What a value is, in the vocabulary of the descriptions.
---@param v any
---@return string
local function kind(v)
  local t = type(v)
  if t ~= "table" then
    return t
  end
  if next(v) == nil then
    return "empty table"
  end
  return vim.islist(v) and "list" or "table"
end

---Does `v` fit `f`? A scalar is judged by `lib.lua.config.schema`, the one language lib.nvim has for
---what a value looks like (its bounds and `enum` included). `table` and `list` stay here: the schema
---has one `table`, and a repair has to tell a record from a list.
---@param v any
---@param f Lib.Json.Sanitize.Field
---@return boolean
local function matches(v, f)
  local want = f.type or "any"
  if want == "any" then
    return true
  elseif want == "table" then
    local k = kind(v)
    return k == "table" or k == "empty table"
  elseif want == "list" then
    local k = kind(v)
    return k == "list" or k == "empty table"
  end
  return schema.check(v, { want, min = f.min, max = f.max, enum = f.enum }, "value", {}) ~= nil
end

---@param v any
---@param want Lib.Json.Sanitize.Type
---@return any coerced
---@return boolean changed
local function coerce(v, want)
  if want == "string" and type(v) == "number" then
    return tostring(v), true
  elseif want == "number" and type(v) == "string" then
    local n = tonumber(v)
    -- JSON has no NaN / infinity, and one in the result breaks comparisons and encoding
    if n ~= nil and n == n and n ~= math.huge and n ~= -math.huge then
      return n, true
    end
  elseif want == "boolean" and type(v) == "string" then
    if v == "true" then
      return true, true
    elseif v == "false" then
      return false, true
    end
  end
  return v, false
end

---@param f Lib.Json.Sanitize.Field
---@return any placeholder
---@return boolean has
local function placeholder(f)
  local want = f.type or "any"
  local d = f.default
  if type(d) == "function" then
    -- a default that raises or has the wrong type must not break the repair: neutral value instead
    local made, v = pcall(d)
    if made and v ~= nil and matches(v, f) then
      return v, true
    end
  elseif d ~= nil and matches(d, f) then
    return vim.deepcopy(d), true
  end
  local make = NEUTRAL[want]
  if make then
    return make(), true
  end
  return nil, false
end

---@class Lib.Json.Sanitize.Ctx
---@field warnings Lib.Json.Sanitize.Warning[]
---@field dropped integer
---@field max integer
---@field count integer  warnings found so far (recorded or not)
---@field depth integer
---@field on_warning? fun(w: Lib.Json.Sanitize.Warning)

---@param ctx Lib.Json.Sanitize.Ctx
---@param path string
---@param code string
---@param message string
local function warn(ctx, path, code, message)
  ctx.count = ctx.count + 1
  local w = { path = path, code = code, message = path .. ": " .. message }
  if ctx.on_warning then
    pcall(ctx.on_warning, w)
  end
  if #ctx.warnings < ctx.max then
    ctx.warnings[#ctx.warnings + 1] = w
  else
    ctx.dropped = ctx.dropped + 1
  end
end

local walk, walk_inner
local MAX_DEPTH = 64

---Build the placeholder of `f` and repair what the description requires inside it, without a
---warning per nested field (the placeholder itself was reported).
---@param f Lib.Json.Sanitize.Field
---@param path string
---@param ctx Lib.Json.Sanitize.Ctx
---@return any
local function filled(f, path, ctx)
  local ph, has = placeholder(f)
  if not has then
    return nil
  end
  if type(ph) == "table" and f.type == "table" and f.fields then
    local quiet = { warnings = {}, dropped = 0, max = 0, count = 0, depth = ctx.depth }
    local fixed = walk(ph, f, path, quiet, true)
    return fixed
  end
  return ph
end

---@param v table
---@param f Lib.Json.Sanitize.Field
---@param path string
---@param ctx Lib.Json.Sanitize.Ctx
---@return table
local function walk_table(v, f, path, ctx)
  local out = {}
  local fields = f.fields
  if not f.strict then
    for k, x in pairs(v) do
      out[k] = x
    end
  end
  if fields then
    -- sorted, so the warnings come in the same order every time
    local names = vim.tbl_keys(fields)
    table.sort(names, function(x, y)
      return tostring(x) < tostring(y)
    end)
    for _, name in ipairs(names) do
      local fd = fields[name]
      local sub = path == "$" and ("$." .. tostring(name)) or (path .. "." .. tostring(name))
      local nv = walk(v[name], fd, sub, ctx, false)
      if nv == nil then
        out[name] = nil
      else
        out[name] = nv
      end
    end
  end
  return out
end

---@param v table
---@param f Lib.Json.Sanitize.Field
---@param path string
---@param ctx Lib.Json.Sanitize.Ctx
---@return table
local function walk_list(v, f, path, ctx)
  local of = f.of
  if not of then
    return vim.list_slice(v, 1, #v)
  end
  local out = {}
  local elem = of
  if not f.drop_invalid and not of.required then
    -- an element that cannot be used is replaced, so the list keeps its length and positions
    elem = vim.tbl_extend("force", of, { required = true })
  end
  for i = 1, #v do
    local sub = path .. "[" .. i .. "]"
    local before = ctx.count
    local nv = walk(v[i], elem, sub, ctx, false)
    if nv ~= nil then
      out[#out + 1] = nv
    elseif ctx.count == before then
      -- nothing was said about it yet (a null element of an `any` list, say)
      warn(ctx, sub, "dropped", "element left out")
    end
  end
  return out
end

---@param v any
---@param f Lib.Json.Sanitize.Field
---@param path string
---@param ctx Lib.Json.Sanitize.Ctx
---@param silent boolean  repairing inside a placeholder that was already reported
---@return any
function walk(v, f, path, ctx, silent)
  if ctx.depth > MAX_DEPTH then
    -- a recursive description over deeply nested data: stop repairing, keep what is there
    return v
  end
  ctx.depth = ctx.depth + 1
  local out = walk_inner(v, f, path, ctx, silent)
  ctx.depth = ctx.depth - 1
  return out
end

---@param v any
---@param f Lib.Json.Sanitize.Field
---@param path string
---@param ctx Lib.Json.Sanitize.Ctx
---@param silent boolean
---@return any
function walk_inner(v, f, path, ctx, silent)
  local want = f.type or "any"
  local say = not silent
  if is_missing(v) then
    if f.required then
      if say and f.warn ~= false then
        warn(ctx, path, "missing", ("required %s is missing, placeholder used"):format(want))
      end
      return filled(f, path, ctx)
    end
    if f.default ~= nil then
      return filled(f, path, ctx)
    end
    return nil
  end
  if not matches(v, f) then
    local cv, changed = v, false
    if f.coerce then
      cv, changed = coerce(v, want)
    end
    if changed and matches(cv, f) then
      if say then
        warn(ctx, path, "coerced", ("%s converted to %s"):format(kind(v), want))
      end
      v = cv
    else
      if say then
        -- The right type and still refused: a bound or `enum`, which "expected string, got string" does not say.
        local refused = want ~= "table" and type(v) == want
        warn(
          ctx,
          path,
          refused and "value" or "type",
          ("%s %s%s"):format(
            refused and "value not allowed for" or ("expected %s, got"):format(want),
            refused and want or kind(v),
            (f.required or f.default ~= nil) and ", placeholder used" or ", dropped"
          )
        )
      end
      if f.required or f.default ~= nil then
        return filled(f, path, ctx)
      end
      return nil
    end
  end
  if want == "table" then
    return walk_table(v, f, path, ctx)
  elseif want == "list" then
    return walk_list(v, f, path, ctx)
  end
  return v
end

---Repair `value` against the description `field`. The input is not changed.
---@param value any  a decoded JSON value
---@param field Lib.Json.Sanitize.Field
---@param opts? Lib.Json.Sanitize.Opts
---@return any clean  the repaired copy (`nil` only when the root is optional and absent)
---@return Lib.Json.Sanitize.Warning[] warnings
---@return integer dropped_warnings  repairs beyond `max_warnings`, counted but not recorded
function M.apply(value, field, opts)
  if type(field) ~= "table" then
    error("lib.nvim.json.sanitize: the description must be a table", 2)
  end
  if field.type ~= nil and not VALID_TYPES[field.type] then
    error(("lib.nvim.json.sanitize: unknown type '%s'"):format(tostring(field.type)), 2)
  end
  opts = opts or {}
  ---@type Lib.Json.Sanitize.Ctx
  local ctx = {
    warnings = {},
    dropped = 0,
    count = 0,
    depth = 0,
    max = opts.max_warnings or 100,
    on_warning = opts.on_warning,
  }
  local clean = walk(value, field, "$", ctx, false)
  return clean, ctx.warnings, ctx.dropped
end

---Would `apply` repair nothing?
---@param value any
---@param field Lib.Json.Sanitize.Field
---@return boolean
function M.check(value, field)
  local _, warnings, dropped = M.apply(value, field, { max_warnings = 1 })
  return #warnings == 0 and dropped == 0
end

---@type Lib.Json.Sanitize
return M
