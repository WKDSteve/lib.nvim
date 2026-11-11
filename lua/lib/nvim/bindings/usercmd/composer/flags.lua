---@module 'lib.nvim.bindings.usercmd.composer.flags'
--- --flag / --flag=value / -x parsing, shared by dispatch and completion so a
--- route's flags stay one declaration read by both (same principle as the
--- route tree itself). Modeled on replacer.nvim's BOOL_FLAGS/VALUE_FLAGS
--- tokenizer split.
---
--- Strictly opt-in per route: every function here is a no-op passthrough when
--- `route.flags` is nil/empty, so a route that never declares flags behaves
--- exactly as it always has — a leading "--" or "-" in one of its positional
--- values is not treated specially.

local argtypes = require("lib.nvim.bindings.usercmd.composer.argtypes")

local M = {}

---@param route Lib.UserCmd.Composer.Route
---@param name string
---@return Lib.UserCmd.Composer.FlagSpec|nil
local function find_spec(route, name)
  for _, f in ipairs(route.flags or {}) do
    if f.name == name then
      return f
    end
  end
  return nil
end
M.find_spec = find_spec

--- A flag-shaped long token (`--name` or `--name=value`) — excludes the bare
--- `--` stop sentinel, which is a token of its own.
---@param tok string
---@return boolean
local function is_flag_token(tok)
  return tok:sub(1, 2) == "--" and tok ~= "--"
end
M.is_flag_token = is_flag_token

--- A short-flag-shaped token: exactly "-" + one character, where that
--- character matches a declared FlagSpec.short on this route. Lenient on
--- non-matches (e.g. `-5` as a negative number) — unlike `--name`, an
--- unrecognized short token is left as an ordinary positional, not an error,
--- since single-dash prefixes collide far more easily with real values (a
--- signed number, a passthrough CLI arg, ...).
---@param route Lib.UserCmd.Composer.Route
---@param tok string
---@return Lib.UserCmd.Composer.FlagSpec|nil
local function find_short_spec(route, tok)
  if #tok ~= 2 or tok:sub(1, 1) ~= "-" or tok:sub(1, 2) == "--" then
    return nil
  end
  local ch = tok:sub(2, 2)
  for _, f in ipairs(route.flags or {}) do
    if f.short == ch then
      return f
    end
  end
  return nil
end
M.find_short_spec = find_short_spec

---@internal
--- Consume one resolved flag occurrence (long or short) starting at
--- `tokens[i]`, applying it to `flags`. `inline_val` is the `--name=value`
--- payload when present (never set for short flags — those only take the
--- next token as a value, no `-x=value` form).
---@param route Lib.UserCmd.Composer.Route
---@param spec Lib.UserCmd.Composer.FlagSpec
---@param label string        # "--name" or "-x", for error messages
---@param inline_val string|nil
---@param tokens string[]
---@param i integer
---@param stopped boolean
---@param flags table<string, any>
---@return integer next_i, string|nil err
local function consume_flag(route, spec, label, inline_val, tokens, i, stopped, flags)
  if spec.bool then
    if inline_val then
      return i, ("flag '%s' takes no value"):format(label)
    end
    flags[spec.name] = true
    return i, nil
  end

  local raw = inline_val
  if raw == nil and spec.optional_value then
    -- `--name` on its own is legal and binds `true`: "given, no value
    -- specified", which the caller reads as its own default. It deliberately
    -- never reaches for the next token -- that is the entire point of this
    -- flavor. A flag whose value is optional cannot also be greedy, because
    -- the token after it may be a legitimate positional (replacer's
    -- `:Replace a b --changed cwd`, where `cwd` is the scope). Only the
    -- inline `--name=value` form specifies a value.
    -- `spec.bare_value` replaces `true` with a declared value (`--file` meaning
    -- "the current buffer", `--file=a,b` a list); it is bound as given, not
    -- run through the type validator.
    local bare = true
    if spec.bare_value ~= nil then
      bare = spec.bare_value
    end
    if spec.repeatable then
      flags[spec.name] = flags[spec.name] or {}
      table.insert(flags[spec.name], bare)
    else
      flags[spec.name] = bare
    end
    return i, nil
  end

  if raw == nil then
    local nxt = tokens[i + 1]
    if
      nxt == nil
      or nxt == "--"
      or (not stopped and (is_flag_token(nxt) or find_short_spec(route, nxt)))
    then
      return i, ("flag '%s' requires a value"):format(label)
    end
    raw = nxt
    i = i + 1
  end
  local ok, value, verr = argtypes.validate(raw, spec)
  if not ok then
    return i, ("flag '%s': %s"):format(label, verr)
  end
  if spec.repeatable then
    flags[spec.name] = flags[spec.name] or {}
    table.insert(flags[spec.name], value)
  else
    flags[spec.name] = value
  end
  return i, nil
end

--- Split `tokens` into (positionals, flags), honoring a literal `--` as "stop
--- parsing flags — everything after is positional" (mirrors replacer.nvim's
--- `flags_done` sentinel). An undeclared `--name` is a hard error, same
--- fail-loud stance as a bad positional arg — silently downgrading it to a
--- positional would surprise a caller who mistyped a flag name. An
--- unrecognized `-x` is left as an ordinary positional (see find_short_spec).
---@param route Lib.UserCmd.Composer.Route
---@param tokens string[]
---@return string[]|nil positionals
---@return table<string, any>|nil flags
---@return string|nil err
function M.split(route, tokens)
  if not route.flags or #route.flags == 0 then
    return tokens, {}, nil
  end

  local positionals, flags = {}, {}
  local stopped = false
  local i = 1
  while i <= #tokens do
    local tok = tokens[i]
    local short_spec = (not stopped) and find_short_spec(route, tok) or nil

    if not stopped and tok == "--" then
      stopped = true
    elseif not stopped and short_spec then
      local next_i, err = consume_flag(route, short_spec, tok, nil, tokens, i, stopped, flags)
      if err then
        return nil, nil, err
      end
      i = next_i
    elseif not stopped and is_flag_token(tok) then
      local body = tok:sub(3)
      local eq = body:find("=", 1, true)
      local name = eq and body:sub(1, eq - 1) or body
      local inline_val = eq and body:sub(eq + 1) or nil

      local spec = find_spec(route, name)
      if not spec then
        return nil, nil, ("unknown flag '--%s'"):format(name)
      end
      local next_i, err =
        consume_flag(route, spec, "--" .. name, inline_val, tokens, i, stopped, flags)
      if err then
        return nil, nil, err
      end
      i = next_i
    else
      positionals[#positionals + 1] = tok
    end
    i = i + 1
  end

  for _, spec in ipairs(route.flags) do
    if flags[spec.name] == nil and spec.default ~= nil then
      flags[spec.name] = spec.default
    end
  end

  return positionals, flags, nil
end

--- Lenient, non-validating strip of flag-shaped tokens (and the value token a
--- declared non-bool flag consumes) — used by completion to compute which
--- positional slot is being typed without miscounting a `--flag value` pair.
--- Never errors: an unknown or malformed flag while mid-typing just isn't
--- stripped (best-effort), rather than blowing up completion.
---@param route Lib.UserCmd.Composer.Route
---@param tokens string[]
---@return string[]
function M.strip(route, tokens)
  if not route.flags or #route.flags == 0 then
    return tokens
  end

  local out = {}
  local stopped = false
  local i = 1
  while i <= #tokens do
    local tok = tokens[i]
    local short_spec = (not stopped) and find_short_spec(route, tok) or nil

    if not stopped and tok == "--" then
      stopped = true
    elseif not stopped and short_spec then
      if not short_spec.bool and not short_spec.optional_value then
        i = i + 1 -- also skip the value token
      end
    elseif not stopped and is_flag_token(tok) then
      local body = tok:sub(3)
      if not body:find("=", 1, true) then
        local spec = find_spec(route, body)
        if spec and not spec.bool and not spec.optional_value then
          i = i + 1 -- also skip the value token
        end
      end
    else
      out[#out + 1] = tok
    end
    i = i + 1
  end
  return out
end

--- Completion candidates for a flag-shaped `arg_lead` (route must declare
--- flags; returns {} otherwise). Short flags (`-x`) are offered as exact
--- tokens once their prefix ("-") is typed, alongside the long `--name` forms.
---@param route Lib.UserCmd.Composer.Route|nil
---@param arg_lead string
---@return string[]
function M.candidates(route, arg_lead)
  if not route or not route.flags or #route.flags == 0 then
    return {}
  end

  if arg_lead:sub(1, 2) == "--" then
    local eq = arg_lead:find("=", 1, true)
    if eq then
      local name = arg_lead:sub(3, eq - 1)
      local value_lead = arg_lead:sub(eq + 1)
      local spec = find_spec(route, name)
      if not spec or spec.bool then
        return {}
      end
      local out = {}
      for _, v in ipairs(argtypes.complete(value_lead, spec)) do
        out[#out + 1] = ("--%s=%s"):format(name, v)
      end
      return out
    end

    local prefix = arg_lead:sub(3)
    local out = {}
    for _, f in ipairs(route.flags) do
      if f.name:sub(1, #prefix) == prefix then
        out[#out + 1] = "--" .. f.name
      end
    end
    return out
  end

  -- Bare "-": offer every declared short flag.
  if arg_lead == "-" then
    local out = {}
    for _, f in ipairs(route.flags) do
      if f.short then
        out[#out + 1] = "-" .. f.short
      end
    end
    return out
  end

  return {}
end

return M
