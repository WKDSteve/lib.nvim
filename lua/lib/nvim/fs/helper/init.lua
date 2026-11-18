---@module 'lib.nvim.fs.helper'
---@brief The file helper process: one child of this Neovim that lists, sizes and watches folders, for every plugin.
---@description
--- `filetree-helper` is a small read-only program (Rust, built and released by filetree.nvim) that lists
--- the files below a folder with the ignore rules of ripgrep, adds up the size of a folder and watches a
--- folder tree, also on Linux. This module finds it, starts it on first need, talks to it over
--- msgpack-RPC on stdin/stdout and hands its answers to whoever asked. One process serves every plugin.
--- Most callers want `lib.nvim.fs.fast`, which falls back to `fd`, `rg` and Lua when there is no helper.
---
--- Key responsibilities:
--- - `find()` / `available()`: is there a helper to use, and if not, why (for `:checkhealth`)
--- - `request(method, arg, handler, opts?)`: a generation per request; an answer of a dropped request is
---   thrown away before anybody sees it; `drop(gen, method?)` forgets one (and tells the helper);
---   `tell(gen, method, arg)` says something more about one that is open (`"follow"` for a watch)
--- - A helper that ends or cannot start is not started again in this session: every request still
---   open gets `"lost"`, the callers go on without it, and the user is told once
--- - `state()`: everything at once, plain data
---
--- The mode decides, first match wins: `configure(mode)`, the provider a plugin set with
--- `set_mode_provider(fn)` (filetree.nvim hands over its option `native.fs.helper`),
--- `vim.g.lib_fs_helper`, else `"auto"`. `"auto"` uses `default_path()` (below `stdpath("data")`, where
--- filetree's `build()` puts it) when it is there, except on a machine with
--- `NVIM_MACHINE_ROLE=workstation` (nothing native runs there until the EDR check clears it); `false`
--- never uses one; a path uses exactly that program.
---
--- The helper answers by having this Neovim run `require('lib.nvim.fs.helper').on(kind, gen, payload)`
--- (it is started with `FILETREE_HELPER_SINK=lib.nvim.fs.helper`); that is the only thing it can make
--- the editor do.

require("lib.nvim.fs.helper.@types")

local uv = vim.uv or vim.loop

local M = {}

--- The protocol this module speaks (`filetree-helper --version` names its own); 3 has walk options.
M.PROTOCOL = 3

--- The module the helper calls back (`FILETREE_HELPER_SINK`).
M.SINK = "lib.nvim.fs.helper"

local state = {
  ---@type integer|nil
  chan = nil,
  ---@type integer|nil
  pid = nil,
  ---@type string|nil  why the helper is out for the rest of the session
  lost = nil,
  told = false,
  stopping = false,
  generation = 0,
  ---@type table<integer, fun(kind: string, payload: any): boolean|nil>
  handlers = {},
  ---@type Lib.Fs.Helper.Mode|nil  set by `configure`; nil: from the provider, the global, "auto"
  override = nil,
  ---@type (fun(): Lib.Fs.Helper.Mode|nil)|nil
  provider = nil,
  ---@type { key: string, exe: string|nil, why: string|nil }|nil
  found = nil,
}

---@return string
function M.binary_name()
  return uv.os_uname().sysname == "Windows_NT" and "filetree-helper.exe" or "filetree-helper"
end

---The folder `"auto"` looks in, `stdpath("data") .. "/filetree-helper"`.
---@return string
function M.install_dir()
  return ((vim.fn.stdpath("data") .. "/filetree-helper"):gsub("\\", "/"))
end

---Where `"auto"` looks for the program.
---@return string
function M.default_path()
  return M.install_dir() .. "/" .. M.binary_name()
end

---Is this the workstation, where nothing native may run until the EDR check clears it?
---@return boolean
function M.workstation()
  return (vim.env.NVIM_MACHINE_ROLE or ""):lower() == "workstation"
end

---Let a plugin hand over its own option (nil from it: the next source decides).
---@param fn (fun(): Lib.Fs.Helper.Mode|nil)|nil
function M.set_mode_provider(fn)
  state.provider = fn
  state.found = nil
end

---@return Lib.Fs.Helper.Mode
function M.mode()
  if state.override ~= nil then
    return state.override
  end
  if state.provider then
    local ok, value = pcall(state.provider)
    if ok and value ~= nil then
      return value
    end
  end
  if vim.g.lib_fs_helper ~= nil then
    return vim.g.lib_fs_helper
  end
  return "auto"
end

---Which program would be used, without starting it.
---@return string|nil exe
---@return string|nil why  Why none, when none.
function M.find()
  local mode = M.mode()
  local key = tostring(mode) .. "|" .. tostring(vim.env.NVIM_MACHINE_ROLE)
  if state.found and state.found.key == key then
    return state.found.exe, state.found.why
  end
  local exe, why
  if mode == false then
    why = "off (mode false)"
  elseif mode == "auto" then
    if M.workstation() then
      why =
        "off on the workstation (NVIM_MACHINE_ROLE=workstation): nothing native runs there before the EDR check"
    elseif uv.fs_stat(M.default_path()) then
      exe = M.default_path()
    else
      why = "not installed (no "
        .. M.default_path()
        .. '; require("filetree.native.fs.helper").build() puts it there)'
    end
  elseif type(mode) == "string" and mode ~= "" then
    if uv.fs_stat(mode) then
      exe = mode
    else
      why = "the helper path names no program: " .. mode
    end
  else
    why = 'the helper mode must be "auto", false or the path of the program'
  end
  state.found = { key = key, exe = exe, why = why }
  return exe, why
end

---Can the helper be used now? False after it ended in this session.
---@return boolean ok
---@return string|nil why  Why not.
function M.available()
  if state.lost then
    return false, state.lost
  end
  local exe, why = M.find()
  return exe ~= nil, why
end

---@param reason string
local function lose(reason)
  state.lost = reason
  state.chan, state.pid = nil, nil
  local waiting = state.handlers
  state.handlers = {}
  for _, handler in pairs(waiting) do
    pcall(handler, "lost", reason)
  end
  if not state.told then
    state.told = true
    vim.schedule(function()
      vim.notify(
        ("[lib.nvim] the file helper %s; listings fall back to fd and Lua for the rest of this session"):format(
          reason
        ),
        vim.log.levels.WARN
      )
    end)
  end
end

---Start the helper if it is not running. Nothing when it is not available.
---@return integer|nil channel
local function start()
  if state.chan then
    return state.chan
  end
  if not M.available() then
    return nil
  end
  local exe = assert(M.find())
  local chan
  local ok, result = pcall(vim.fn.jobstart, { exe }, {
    rpc = true,
    env = { FILETREE_HELPER_SINK = M.SINK },
    on_exit = function(_, code)
      if state.chan ~= chan then
        return
      end
      -- stopped on purpose, or Neovim is quitting and took it along: no end to report
      if state.stopping or vim.v.exiting ~= vim.NIL then
        state.chan, state.pid = nil, nil
        return
      end
      lose(("ended (exit code %s)"):format(tostring(code)))
    end,
  })
  if not ok or type(result) ~= "number" or result <= 0 then
    lose(("could not be started (%s): %s"):format(exe, tostring(result)))
    return nil
  end
  chan = result
  state.chan = chan
  state.stopping = false
  local pid_ok, pid = pcall(vim.fn.jobpid, chan)
  state.pid = pid_ok and pid or nil
  return chan
end

---Ask the helper for something. `handler(kind, payload)` gets every answer of this request, on the main
---loop; it returns true to hear more (a listing comes in batches), anything else ends the request. A
---helper that ends meanwhile calls it once more with `"lost"` and the reason.
---@param method "walk"|"size"|"watch"
---@param arg string  The folder.
---@param handler fun(kind: string, payload: any): boolean|nil
---@param opts? Lib.Fs.Helper.WalkOpts  For `"walk"`: nil lists as protocol 2 did; a wrong option is answered with `"error"`.
---@return integer|nil generation  Nil when there is no helper (the handler is not called then).
function M.request(method, arg, handler, opts)
  local chan = start()
  if not chan then
    return nil
  end
  state.generation = state.generation + 1
  local gen = state.generation
  state.handlers[gen] = handler
  local ok, err
  if opts ~= nil then
    ok, err = pcall(vim.rpcnotify, chan, method, gen, arg, opts)
  else
    ok, err = pcall(vim.rpcnotify, chan, method, gen, arg)
  end
  if not ok then
    state.handlers[gen] = nil
    lose("could not be reached: " .. tostring(err))
    return nil
  end
  return gen
end

---Forget a request: nothing more of it reaches anybody. With `method` the helper is told too
---(`"cancel"` for a listing, `"unwatch"` for a watch).
---@param gen integer
---@param method? "cancel"|"unwatch"
function M.drop(gen, method)
  state.handlers[gen] = nil
  if method and state.chan then
    pcall(vim.rpcnotify, state.chan, method, gen)
  end
end

---Say something more about a request that is still open: `"follow"` makes the watch `gen` watch the
---folder `arg` too, whatever the ignore rules say about it. Nothing when the request is over.
---@param gen integer
---@param method "follow"
---@param arg string
function M.tell(gen, method, arg)
  if state.handlers[gen] and state.chan then
    pcall(vim.rpcnotify, state.chan, method, gen, arg)
  end
end

---An answer of the helper. Called by the helper itself (through `nvim_exec_lua`), never by a plugin.
---@param kind string
---@param gen integer
---@param payload any
function M.on(kind, gen, payload)
  local handler = state.handlers[gen]
  -- an answer of a request somebody dropped, or of an older helper
  if not handler then
    return
  end
  local ok, more = pcall(handler, kind, payload)
  if not ok then
    state.handlers[gen] = nil
    vim.schedule(function()
      vim.notify("[lib.nvim] a file helper answer failed: " .. tostring(more), vim.log.levels.WARN)
    end)
  elseif not more then
    state.handlers[gen] = nil
  end
end

---Stop the helper (not counted as its end: it is started again on the next request). Every request
---still open gets `"lost"`.
function M.stop()
  local chan = state.chan
  if not chan then
    return
  end
  state.stopping = true
  local waiting = state.handlers
  state.handlers = {}
  for _, handler in pairs(waiting) do
    pcall(handler, "lost", "stopped")
  end
  pcall(vim.fn.jobstop, chan)
  state.chan, state.pid = nil, nil
end

---Use `mode` instead of the provider and the global (nil: back to them), and forget an earlier end.
---For specs, and for a user who installed the program during the session.
---@param mode? Lib.Fs.Helper.Mode
function M.configure(mode)
  M.stop()
  state.override = mode
  state.found = nil
  state.lost = nil
  state.told = false
end

---@return Lib.Fs.Helper.State
function M.state()
  local exe, why = M.find()
  return {
    mode = M.mode(),
    exe = exe,
    running = state.chan ~= nil,
    pid = state.pid,
    off = why,
    lost = state.lost,
    requests = vim.tbl_count(state.handlers),
  }
end

---`:checkhealth`: what the helper does on this machine.
---@param ok fun(msg: string)
---@param info fun(msg: string)
---@param warn fun(msg: string)
function M.health(ok, info, warn)
  local s = M.state()
  if s.lost then
    warn("file helper: the process " .. s.lost .. "; fd and Lua serve this session")
  elseif s.exe then
    ok(
      ("file helper: %s (%s)"):format(
        s.running and ("running, pid " .. tostring(s.pid)) or "found, starts on first need",
        s.exe
      )
    )
  else
    info("file helper: " .. (s.off or "off"))
  end
end

return M
