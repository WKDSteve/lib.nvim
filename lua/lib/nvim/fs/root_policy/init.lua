---@module 'lib.nvim.fs.root_policy'
--- Root-policy state machine: which directory should the working directory and
--- a tree/explorer root be, as the user moves between buffers?
---
--- Extracted from `filetree.nvim` (`features/nav/cwd_mode`) so a plugin that
--- pins the cwd (a project lock, a per-tab workspace) does not need a file tree
--- to get the same behaviour. Six modes:
---
---   follow      no policy; `decide` answers nil and the caller's own logic runs
---   project     hold the current project root until a file outside it is opened
---   nearest     like project, but the nearest package boundary (a second finder)
---   lock        pin one directory; buffer switches never move it (enforced by
---               `lib.nvim.fs.dir_guard` unless `enforce = false`)
---   manual      nothing automatic
---   tree_leads  the pinned root is the truth; the cwd follows it, not the buffer
---
--- The module holds state and answers questions; it never reads buffers on its
--- own. The caller asks `decide(file)` when a buffer is entered and applies the
--- `Decision` (`root`, `chdir`, `reveal`).
---
--- `on_change` is diff-based: it runs only when the observable state (mode or
--- pinned root) really changed, so a statusline refresh hooked to it is not
--- redrawn on every buffer switch.
---
---```lua
--- local policy = require("lib.nvim.fs.root_policy").new({
---   find_root = function(file, kind) return my_finder(file, kind) end,
---   on_change = function(state) vim.cmd.redrawstatus() end,
--- })
--- policy.set_mode("project")
--- local d = policy.decide(vim.api.nvim_buf_get_name(0))
---```
---
--- See @types/init.lua for Lib.Fs.RootPolicy.*.

require("lib.nvim.fs.root_policy.@types")

local chdir = require("lib.nvim.fs.chdir")
local normkey = require("lib.nvim.fs.normkey")
local is_subpath = require("lib.nvim.fs.is_subpath")
local dir_guard = require("lib.nvim.fs.dir_guard")

local M = {}

---@type table<string, true>
M.MODES = {
  follow = true,
  project = true,
  nearest = true,
  lock = true,
  manual = true,
  tree_leads = true,
}

---@param dir string|nil
---@return string|nil
local function canon(dir)
  if type(dir) ~= "string" or dir == "" then
    return nil
  end
  local out = normkey(dir)
  return out ~= "" and out or nil
end

---Directory of a path (the path itself when it is a directory).
---@param p string
---@return string
local function dir_of(p)
  if vim.fn.isdirectory(p) == 1 then
    return p
  end
  return vim.fs.dirname(p) or p
end

---@param file string
---@param root string|nil
---@return boolean
local function inside(file, root)
  if not root then
    return false
  end
  return is_subpath(normkey(file), root)
end

---Create a policy.
---@param opts? Lib.Fs.RootPolicy.Opts
---@return Lib.Fs.RootPolicy.Handle
function M.new(opts)
  opts = opts or {}
  local scope = opts.scope or "global"
  local sticky = opts.sticky ~= false
  local enforce = opts.enforce ~= false
  local do_chdir = opts.chdir ~= false
  local reveal_outside = opts.reveal_outside == "reveal"

  local mode = opts.mode or "follow"
  assert(M.MODES[mode], "root_policy: unknown mode " .. tostring(mode))
  local pinned ---@type string|nil
  local prev_mode = "follow"
  local guard ---@type Lib.Fs.DirGuard.Handle|nil
  local last_seen ---@type string|nil

  ---@return string
  local function snapshot()
    return mode .. "\0" .. (pinned or "")
  end

  -- Diff-based change notification: runs `on_change` only when mode or pinned
  -- root differ from what the listener saw last.
  local function announce()
    local now = snapshot()
    if now == last_seen then
      return
    end
    last_seen = now
    if opts.on_change then
      pcall(opts.on_change, { mode = mode, pinned = pinned })
    end
  end
  last_seen = snapshot()

  local function drop_guard()
    if guard then
      pcall(guard.release)
      guard = nil
    end
  end

  ---@param root string
  ---@return boolean ok, string|nil err
  local function move_cwd(root)
    if not do_chdir then
      return true, nil
    end
    return chdir(root, { scope = scope })
  end

  ---@param root string
  ---@return boolean ok, string|nil err
  local function install_guard(root)
    if not enforce then
      drop_guard()
      return move_cwd(root)
    end
    if guard and guard.is_held() then
      return guard.update(root)
    end
    local handle, err = dir_guard.hold(root, {
      scope = scope,
      on_error = opts.on_error,
    })
    if not handle then
      return false, err
    end
    guard = handle
    return true, nil
  end

  ---@param file string
  ---@param kind "project"|"nearest"
  ---@return string|nil
  local function root_of(file, kind)
    if not opts.find_root then
      return nil
    end
    local ok, root = pcall(opts.find_root, file, kind)
    if not ok then
      return nil
    end
    return canon(root)
  end

  ---@type Lib.Fs.RootPolicy.Handle
  local handle = {}

  function handle.mode()
    return mode
  end

  function handle.pinned()
    return pinned
  end

  function handle.decide(file)
    if type(file) ~= "string" or file == "" or mode == "follow" then
      return nil
    end

    if mode == "manual" then
      return { root = pinned, chdir = false, reveal = false }
    end

    if mode == "lock" then
      if not pinned then
        return nil -- nothing pinned yet: behave like follow rather than freeze
      end
      if inside(file, pinned) then
        return { root = pinned, chdir = true, reveal = true }
      end
      return { root = pinned, chdir = true, reveal = reveal_outside }
    end

    if mode == "tree_leads" then
      if not pinned then
        return nil
      end
      return { root = pinned, chdir = false, reveal = inside(file, pinned) }
    end

    -- project / nearest
    if inside(file, pinned) then
      return { root = pinned, chdir = true, reveal = true }
    end
    local root = root_of(file, mode --[[@as "project"|"nearest"]])
    if root then
      pinned = root
      announce()
      return { root = root, chdir = true, reveal = true }
    end
    if sticky and pinned then
      return { root = pinned, chdir = true, reveal = reveal_outside }
    end
    local parent = canon(dir_of(file))
    pinned = parent
    announce()
    return { root = parent, chdir = true, reveal = true }
  end

  function handle.set_mode(new_mode, dir)
    if not M.MODES[new_mode] then
      return false, "unknown mode: " .. tostring(new_mode)
    end

    if new_mode == "lock" then
      local target = canon(dir) or canon(vim.fn.getcwd())
      if not target then
        return false, "cannot lock: no usable directory"
      end
      local ok, err = install_guard(target)
      if not ok then
        return false, err
      end
      if mode ~= "lock" then
        prev_mode = mode
      end
      mode, pinned = "lock", target
      announce()
      return true, nil
    end

    drop_guard()
    if mode ~= new_mode then
      prev_mode = mode
    end
    mode = new_mode

    local err
    if new_mode == "project" or new_mode == "nearest" then
      -- Seed from the current buffer so `pinned()` is meaningful at once.
      local seed = opts.seed and opts.seed(new_mode) or nil
      if type(seed) ~= "string" or seed == "" then
        local name = vim.api.nvim_buf_get_name(0)
        seed = name ~= "" and name or vim.fn.getcwd()
      end
      pinned = root_of(seed, new_mode) or canon(dir_of(seed))
      if pinned then
        local ok, e = move_cwd(pinned)
        err = (not ok) and e or nil
      end
    elseif new_mode == "tree_leads" then
      local from = opts.seed and opts.seed(new_mode) or nil
      pinned = canon(from) or canon(vim.fn.getcwd())
      if pinned then
        local ok, e = move_cwd(pinned)
        err = (not ok) and e or nil
      end
    elseif new_mode == "follow" then
      pinned = nil
    end
    -- manual keeps whatever was pinned
    announce()
    return true, err
  end

  function handle.unlock()
    if mode ~= "lock" then
      return false, "not locked"
    end
    local back = prev_mode ~= "lock" and prev_mode or "follow"
    return handle.set_mode(back)
  end

  function handle.cycle(list)
    if type(list) ~= "table" or #list == 0 then
      return false, "empty cycle"
    end
    local index = 1
    for i, name in ipairs(list) do
      if name == mode then
        index = i % #list + 1
        break
      end
    end
    local ok, err = handle.set_mode(list[index])
    return ok, err
  end

  function handle.repin(dir)
    local target = canon(dir)
    if not target then
      return false, "no usable directory"
    end
    if mode == "lock" and guard and guard.is_held() then
      local ok, err = guard.update(target)
      if not ok then
        return false, err
      end
    end
    pinned = target
    announce()
    return true, nil
  end

  function handle.bypass(fn)
    if guard and guard.is_held() then
      return guard.bypass(fn)
    end
    return pcall(fn)
  end

  function handle.release()
    drop_guard()
  end

  return handle
end

return M
