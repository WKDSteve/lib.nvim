---@module 'lib.nvim.bindings.usercmd'
--- User command helper utilities.
---
--- Standardized wrapper around nvim_create_user_command with sane defaults,
--- defensive execution and LuaLS annotations.

local notify = require("lib.nvim.notify").create("[lib.nvim.bindings.usercmd]")
local util = require("lib.nvim.bindings.docs_util")

local M = {}

--- Every user command this module created, in creation order.
---
--- Recorded rather than catalogued by hand, for the reason
--- `lib.nvim.bindings.autocmd` spells out at its own registry: a hand-kept list
--- is a mirror, and mirrors drift.
---
--- `nvim_get_commands()` already answers "what commands exist", so the point
--- here is the half it cannot: **where each one was created**. "Something
--- defines `:CwdHere`" is not an answer a reader can act on without the file.
---
--- The composer keeps its own registry for verb trees (`:Verb sub ARG`); this
--- one is for the plain `create()` calls, which had nothing.
---@type Lib.UserCommand.Record[]
local records = {}

--- Register a user command with sane defaults (`force = true`, pcall-wrapped
--- callback, `desc`/`nargs` defaults) and optional buffer-local registration.
---@param name string
---@param callback string|fun(args:Lib.UserCommand.Args)
---@param opts LibUserCommandOpts|nil
function M.create(name, callback, opts)
  opts = opts or {}

  if opts.desc == nil then
    opts.desc = ""
  end

  if opts.nargs == nil then
    opts.nargs = 0
  end

  -- Default to Neovim's native behavior (`force = true`): overwrite an
  -- existing command instead of raising E174. This keeps command creation
  -- idempotent under config hot-reload (e.g. NvChad's ReloadNvChad
  -- BufWritePost autocmd re-sources chadrc on every save).
  if opts.force == nil then
    opts.force = true
  end

  -- Buffer-local registration: opts.buffer = true (current buffer) or an
  -- explicit bufnr routes to nvim_buf_create_user_command instead of the
  -- global nvim_create_user_command. Extracted before the real API call
  -- since `buffer` isn't a real nvim_create_user_command opts field.
  local bufnr = opts.buffer
  opts.buffer = nil

  -- Also a lib option, not a native one: `nvim_create_user_command` rejects an
  -- unknown key outright ("invalid key: src"). It lets a wrapper that creates
  -- a command on a caller's behalf say whose it is -- without it, every
  -- command such a wrapper makes is recorded at the wrapper's own line.
  local src = opts.src
  opts.src = nil

  -- Resolved here rather than inline in the record below: `type(...)` on a
  -- field read narrows nothing, so the record would inherit the function
  -- half of `complete`'s type.
  local complete = opts.complete
  local complete_kind = type(complete) == "string" and complete
    or (complete ~= nil and "<function>" or nil)

  -- Neovim's own `complete = "dir"` lists files as well on Windows (measured, nvim 0.12.2), while
  -- getcompletion(lead, "dir") answers directories only. The composer's DIR type completes through the
  -- latter on every system, completes a lead with a backtick (a command substitution to the wildcard
  -- expansion) to nothing and knows the named roots, so a "dir" command gets that one. The record keeps
  -- "dir": it describes what the command completes, not how.
  if complete == "dir" then
    ---@type Lib.UserCmd.Composer.ArgSpec
    local spec = { name = "dir", type = "DIR" }
    opts.complete = function(arg_lead)
      return require("lib.nvim.bindings.usercmd.composer.argtypes").complete(arg_lead, spec)
    end
  end

  if type(callback) == "function" then
    local user_cb = callback
    callback = function(args)
      local ok, err = pcall(user_cb, args)
      if not ok then
        notify.error(("UserCommand '%s' failed:\n%s"):format(name, err))
      end
    end
  end

  -- Both lib-only keys are off the table by now, which is what makes this a
  -- native options table -- `opts` keeps its declared type across the two
  -- `nil` assignments above, so the annotation cannot say it.
  local native = opts --[[@as vim.api.keyset.user_command]]

  if bufnr then
    local buf = type(bufnr) == "number" and bufnr or vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_create_user_command(buf, name, callback, native)
  else
    vim.api.nvim_create_user_command(name, callback, native)
  end

  -- After the real call: a command nvim refused is not recorded as existing.
  --
  -- `force = true` is the default here, so re-creating a command is normal and
  -- must replace its record rather than add a second one -- otherwise a
  -- re-`setup()` would describe every command as many times as setup has run.
  for i, r in ipairs(records) do
    if r.name == name and r.buffer == bufnr then
      table.remove(records, i)
      break
    end
  end

  records[#records + 1] = {
    name = name,
    desc = opts.desc ~= "" and opts.desc or nil,
    nargs = opts.nargs,
    bang = opts.bang == true,
    range = opts.range ~= nil and opts.range ~= false,
    complete = complete_kind,
    buffer = bufnr,
    -- Level 3: getinfo -> caller_site -> M.create -> the caller.
    src = src or util.caller_site(3),
  }
end

---Every user command created through this module, newest last.
---
---What `:checkhealth`, a generated bindings page and "who defines `:Foo`?" all
---need, without any of them re-deriving it from source.
---@param filter { name?: string, buffer?: integer|boolean }|nil
---@return Lib.UserCommand.Record[]
function M.registered(filter)
  if not filter then
    return vim.deepcopy(records)
  end
  local out = {}
  for _, r in ipairs(records) do
    local ok = true
    if filter.name and r.name ~= filter.name then
      ok = false
    end
    if ok and filter.buffer ~= nil and r.buffer ~= filter.buffer then
      ok = false
    end
    if ok then
      out[#out + 1] = vim.deepcopy(r)
    end
  end
  return out
end

---Delete a user command **and** forget its record.
---
---`nvim_del_user_command` alone leaves the record behind, so a generated page
---goes on listing a command that no longer exists -- the same failure
---`lib.nvim.bindings.autocmd.delete` exists to prevent for autocmds.
---@param name string
---@param bufnr integer|nil  # Delete a buffer-local command instead.
---@return boolean deleted
function M.delete(name, bufnr)
  local deleted
  if bufnr then
    deleted = pcall(vim.api.nvim_buf_del_user_command, bufnr, name)
  else
    deleted = pcall(vim.api.nvim_del_user_command, name)
  end

  local kept = {}
  for _, r in ipairs(records) do
    if r.name ~= name then
      kept[#kept + 1] = r
    end
  end
  records = kept

  return deleted
end

--- Generated `bindings/usercmd/` markdown, from the registry above.
M.docs = require("lib.lua.lazy").require("lib.nvim.bindings.usercmd.docs")

-- Subcommand composer (`:Verb sub sub ARG` + completion + docgen). Exposed
-- lazily to avoid a require cycle: the composer needs `usercmd.create`, so it
-- must be reachable from here without eagerly loading it at module scope.
---@type Lib.UserCmd.Composer
M.composer = setmetatable({}, {
  __index = function(_, k)
    return require("lib.nvim.bindings.usercmd.composer")[k]
  end,
})

---@type Lib.UsrCmd
return M
