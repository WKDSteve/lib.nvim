---@module 'lib.nvim.fs.fast'
---@brief Fast file listings for every plugin: deep list, folder size and recursive watch, with the file helper when there is one.
---@description
--- Three pieces of work that plugins used to do each on their own, behind one call each, with the
--- fastest means this machine has:
---
--- - `list(root, opts, on_batch, on_done)`: every file below a folder, streamed in batches and
---   cancellable. Tiers: the file helper (`lib.nvim.fs.helper`), `fd`, `rg --files`, a Lua walk.
--- - `size(dir, on_done)`: files and bytes below a folder, everything counted (as `du`). Tiers: the
---   helper, a Lua walk.
--- - `watch(root, opts, on_change)`: the folders below a root in which something changed. Tiers: the
---   helper, a recursive libuv handle (Windows, macOS), one libuv handle per folder (Linux).
---
--- The options of a listing are the switches of `fd`: `hidden`, `ignore` (`"gitignore"`, `"names"`,
--- `"none"`), `names`, `follow`, `exclude`, `max_depth`. `.git` is never entered. The Lua walk cannot
--- read `.gitignore`: it leaves out the folders of `lib.nvim.fs.ignore.list` (or `opts.skip`) instead,
--- the nearest thing it has. Measured (`lib.nvim/NOTES/2026-11-17_schnelle-dateilisten-recherche.md`
--- in the tasks vault): helper 11-42 ms, `fd` 197-336 ms, Lua 75-475 ms on the same trees.
---
--- A helper that ends during a listing hands it to the next tier, which leaves out what the helper had
--- handed over already. A helper that ends during a watch hands the watch to libuv and reports the
--- root once, so the caller reads everything again.
---
--- A tool is started by the program itself, not by a scoop shim in front of it (`resolve`): a shim
--- costs 40 to 70 ms per start, and ending it leaves the program it started running.
---
---```lua
--- local fast = require("lib.nvim.fs.fast")
--- local cancel = fast.list(root, { hidden = false }, function(paths) ... end, function(ok) ... end)
--- fast.size(dir, function(bytes, files) ... end)
--- local w = fast.watch(root, {}, function(dirs) ... end); w.stop()
---```

require("lib.nvim.fs.fast.@types")

local helper = require("lib.nvim.fs.helper")

local uv = vim.uv or vim.loop

local M = {}

--- How many paths the Lua walk hands over at most (the tools have no such limit: they stream).
M.WALK_LIMIT = 200000

--- How many folders the per-folder watch (Linux without helper) watches at most.
M.MAX_WATCHES = 4000

---One spelling for a path: `/`-separated, drive letter upper case, no trailing `/` (the helper's).
---@type fun(path: string): string
M.norm = require("lib.nvim.fs.norm")

---@param dir string
---@param name string
---@return string
local function join(dir, name)
  if dir:sub(-1) == "/" then
    return dir .. name
  end
  return dir .. "/" .. name
end

-- ── tools ────────────────────────────────────────────────────────────────────

---The program behind a launcher. Scoop puts `<name>.exe` next to `<name>.shim`, a text file that
---names the real program (`path = "..."`); started through the shim, the program is a grandchild.
---@param path string  The full path of the executable that was found.
---@return string exe  The program to start: the one the shim names, else `path`.
---@return boolean direct  false when a launcher stays in between (a shim with arguments of its own, or one whose target is gone).
function M.resolve(path)
  local shim = (path:gsub("%.[^.\\/]+$", "")) .. ".shim"
  local file = io.open(shim, "r")
  if not file then
    return path, true
  end
  local text = file:read("*a") or ""
  file:close()
  local target = text:match('path%s*=%s*"([^"\r\n]+)"') or text:match("path%s*=%s*([^\r\n]+)")
  -- a shim that brings arguments is not the program alone: it stays
  if target and not text:match("args%s*=") and uv.fs_stat(target) then
    return target, true
  end
  return path, false
end

---@type table<string, { exe: string, direct: boolean }>  by the name asked for; a tool does not move while Neovim runs
local resolved = {}

---@param name string
---@return string exe
---@return boolean direct
local function program(name)
  local hit = resolved[name]
  if not hit then
    local path = vim.fn.exepath(name)
    if path == "" then
      hit = { exe = name, direct = true }
    else
      local exe, direct = M.resolve(path)
      hit = { exe = exe, direct = direct }
    end
    resolved[name] = hit
  end
  return hit.exe, hit.direct
end

--- Tools started by `list` that have not ended yet.
local live = 0

---How many tools started for a listing are still running (a cancelled one ends at once).
---@return integer
function M.running()
  return live
end

---Which external tool (or the walk) lists files, the helper left aside.
---@return Lib.Fs.Fast.Tier tier
---@return string|nil exe
local function tool_tier()
  for _, exe in ipairs({ "fd", "fdfind" }) do
    if vim.fn.executable(exe) == 1 then
      return "fd", exe
    end
  end
  if vim.fn.executable("rg") == 1 then
    return "rg", "rg"
  end
  return "lua", nil
end

---Which tier lists files on this machine.
---@return Lib.Fs.Fast.Tier tier
---@return string|nil exe
function M.tier()
  if helper.available() then
    return "helper", (helper.find())
  end
  return tool_tier()
end

-- ── options ──────────────────────────────────────────────────────────────────

---@class Lib.Fs.Fast.Resolved
---@field hidden boolean
---@field ignore "gitignore"|"names"|"none"
---@field names string[]
---@field follow boolean
---@field exclude string[]
---@field max_depth integer|nil
---@field skip (fun(name: string, is_dir: boolean): boolean)|nil

---@param opts Lib.Fs.Fast.ListOpts|nil
---@return Lib.Fs.Fast.Resolved
local function resolve_opts(opts)
  opts = opts or {}
  local ignore = opts.ignore
  if ignore == nil then
    ignore = opts.no_ignore and "none" or "gitignore"
  end
  assert(
    ignore == "gitignore" or ignore == "names" or ignore == "none",
    'lib.nvim.fs.fast: ignore must be "gitignore", "names" or "none"'
  )
  return {
    hidden = opts.hidden ~= false,
    ignore = ignore,
    names = opts.names or require("lib.nvim.fs.ignore.list").basenames,
    follow = opts.follow == true,
    exclude = opts.exclude or {},
    max_depth = opts.max_depth,
    skip = opts.skip,
  }
end

---The options the helper gets: nil when they are the defaults (a listing as protocol 2 knew it).
---@param o Lib.Fs.Fast.Resolved
---@return Lib.Fs.Helper.WalkOpts|nil
local function helper_opts(o)
  local out = {}
  if not o.hidden then
    out.hidden = false
  end
  if o.ignore ~= "gitignore" then
    out.ignore = o.ignore
  end
  if o.ignore == "names" then
    out.names = o.names
  end
  if o.follow then
    out.follow = true
  end
  if #o.exclude > 0 then
    out.exclude = o.exclude
  end
  if o.max_depth then
    out.max_depth = o.max_depth
  end
  return next(out) and out or nil
end

---@param tier Lib.Fs.Fast.Tier|string  "fd" or "rg"
---@param exe string
---@param root string
---@param o Lib.Fs.Fast.Resolved
---@param kind? "f"|"l"  For `fd`: files (default) or links.
---@return string[]
local function command(tier, exe, root, o, kind)
  local cmd
  if tier == "fd" then
    cmd = { exe, "--type", kind or "f", "--color", "never", "--absolute-path", "--exclude", ".git" }
  else
    cmd = { exe, "--files", "--color", "never", "--glob", "!.git" }
  end
  local function exclude(glob)
    if tier == "fd" then
      vim.list_extend(cmd, { "--exclude", glob })
    else
      vim.list_extend(cmd, { "--glob", "!" .. glob })
    end
  end
  if o.hidden then
    cmd[#cmd + 1] = "--hidden"
  end
  if o.ignore ~= "gitignore" then
    cmd[#cmd + 1] = "--no-ignore"
  end
  if o.ignore == "names" then
    for _, name in ipairs(o.names) do
      exclude(name)
    end
  end
  for _, glob in ipairs(o.exclude) do
    exclude(glob)
  end
  if o.follow then
    cmd[#cmd + 1] = "--follow"
  end
  if o.max_depth then
    vim.list_extend(cmd, { "--max-depth", tostring(o.max_depth) })
  end
  if tier == "fd" then
    vim.list_extend(cmd, { ".", root })
  else
    cmd[#cmd + 1] = root
  end
  return cmd
end

---The command lines `list` would run for a tool tier (specs, `:checkhealth`).
---@param tier Lib.Fs.Fast.Tier|string  "fd" or "rg"
---@param exe string
---@param root string
---@param opts? Lib.Fs.Fast.ListOpts
---@param kind? "f"|"l"
---@return string[]
function M.command(tier, exe, root, opts, kind)
  return command(tier, exe, root, resolve_opts(opts), kind)
end

-- ── tiers of a listing ───────────────────────────────────────────────────────

---List through an external tool.
---@param cmd string[]
---@param on_batch fun(paths: string[])
---@param on_done fun(ok: boolean)
---@return fun() cancel
local function spawn(cmd, on_batch, on_done)
  local cancelled = false
  local tail = ""
  cmd = vim.list_slice(cmd)
  cmd[1] = program(cmd[1])
  local ok, job = pcall(vim.system, cmd, {
    text = true,
    stdout = function(_, data)
      if cancelled or not data then
        return
      end
      local text = tail .. data
      local batch = {}
      local last = 1
      for line, stop in text:gmatch("([^\r\n]*)\r?\n()") do
        if line ~= "" then
          batch[#batch + 1] = M.norm(line)
        end
        last = stop
      end
      tail = text:sub(last)
      if #batch > 0 then
        vim.schedule(function()
          if not cancelled then
            on_batch(batch)
          end
        end)
      end
    end,
  }, function(result)
    live = live - 1
    vim.schedule(function()
      if cancelled then
        return
      end
      if tail ~= "" then
        on_batch({ M.norm(tail) })
      end
      on_done(result.code == 0)
    end)
  end)
  if not ok then
    vim.schedule(function()
      if not cancelled then
        on_done(false)
      end
    end)
    return function()
      cancelled = true
    end
  end
  live = live + 1
  local proc = job --[[@as vim.SystemObj]]
  return function()
    if cancelled then
      return
    end
    cancelled = true
    pcall(proc.kill, proc, 15)
  end
end

---@type table<string, any>  compiled exclude globs
local globs = {}

---@param glob string
---@return any|nil  an lpeg pattern, nil when the glob does not compile
local function compiled(glob)
  local hit = globs[glob]
  if hit == nil then
    local ok, pattern = pcall(vim.glob.to_lpeg, glob)
    hit = ok and pattern or false
    globs[glob] = hit
  end
  return hit or nil
end

---Does an exclude glob name this entry? As `fd --exclude`: a glob without `/` matches the name at any
---depth, one with `/` matches the path below the root.
---@param o Lib.Fs.Fast.Resolved
---@param name string
---@param rel string
---@return boolean
local function excluded(o, name, rel)
  for _, glob in ipairs(o.exclude) do
    local pattern = compiled(glob)
    if pattern and pattern:match(glob:find("/", 1, true) and rel or name) then
      return true
    end
  end
  return false
end

---List by walking the folders. One folder is read at a time, each without blocking.
---@param root string
---@param o Lib.Fs.Fast.Resolved
---@param on_batch fun(paths: string[])
---@param on_done fun(ok: boolean)
---@return fun() cancel
local function walk(root, o, on_batch, on_done)
  local cancelled = false
  local names = {}
  if o.ignore == "names" or (o.ignore == "gitignore" and not o.skip) then
    for _, name in ipairs(o.names) do
      names[name] = true
    end
  end
  local skip = o.ignore == "gitignore" and o.skip or nil
  ---@type { dir: string, depth: integer }[]
  local queue = { { dir = root, depth = 0 } }
  local seen = {}
  if o.follow then
    seen[uv.fs_realpath(root) or root] = true
  end
  local head = 1
  local count = 0
  local base = #root + (root:sub(-1) == "/" and 1 or 2)

  ---@param path string
  ---@param name string
  ---@param is_dir boolean
  ---@return boolean
  local function left_out(path, name, is_dir)
    if name == ".git" then
      return true
    end
    if not o.hidden and name:sub(1, 1) == "." then
      return true
    end
    if is_dir and names[name] then
      return true
    end
    if skip and skip(name, is_dir) then
      return true
    end
    return #o.exclude > 0 and excluded(o, name, path:sub(base))
  end

  local function step()
    if cancelled then
      return
    end
    local item = queue[head]
    if not item or count >= M.WALK_LIMIT then
      on_done(item == nil)
      return
    end
    head = head + 1
    local depth = item.depth + 1
    uv.fs_scandir(item.dir, function(_, handle)
      local batch = {}
      if handle then
        while true do
          local name, kind = uv.fs_scandir_next(handle)
          if not name then
            break
          end
          local path = join(item.dir, name)
          local to_dir = kind == "directory"
          if kind == "link" then
            to_dir = (uv.fs_stat(path) or {}).type == "directory"
          end
          if not left_out(path, name, to_dir) then
            if to_dir then
              local enter = kind == "directory"
              if kind == "link" and o.follow then
                -- a followed link may point back up: each real folder once
                local real = uv.fs_realpath(path)
                enter = real ~= nil and not seen[real]
                if enter then
                  seen[
                    real --[[@as string]]
                  ] = true
                end
              end
              if enter and (not o.max_depth or depth < o.max_depth) then
                queue[#queue + 1] = { dir = path, depth = depth }
              end
            elseif not o.max_depth or depth <= o.max_depth then
              -- a link to a file (or a broken one) is a file
              batch[#batch + 1] = path
            end
          end
        end
      end
      vim.schedule(function()
        if cancelled then
          return
        end
        count = count + #batch
        if #batch > 0 then
          on_batch(batch)
        end
        step()
      end)
    end)
  end
  step()
  return function()
    cancelled = true
  end
end

---List through the helper. Nil when it cannot take the request.
---@param root string
---@param o Lib.Fs.Fast.Resolved
---@param on_batch fun(paths: string[])
---@param on_done fun(ok: boolean)
---@param rest fun(on_batch: fun(paths: string[]), on_done: fun(ok: boolean)): fun()  The next tier, for a helper that ends on the way.
---@return (fun())|nil cancel
local function via_helper(root, o, on_batch, on_done, rest)
  local cancelled = false
  ---@type table<string, true>  what was handed over: the next tier must not hand it over again
  local given = {}
  ---@type (fun())|nil
  local cancel_rest = nil
  local gen = helper.request("walk", root, function(kind, payload)
    if cancelled then
      return false
    end
    if kind == "files" then
      for _, path in ipairs(payload) do
        given[path] = true
      end
      vim.schedule(function()
        if not cancelled then
          on_batch(payload)
        end
      end)
      return true
    elseif kind == "done" then
      vim.schedule(function()
        if not cancelled then
          on_done(type(payload) ~= "table" or payload.ok ~= false)
        end
      end)
    elseif kind == "error" then
      -- an option the program does not take (a glob that does not parse): no listing
      vim.schedule(function()
        if not cancelled then
          on_done(false)
        end
      end)
    elseif kind == "lost" then
      -- after the batches already on their way: the rest from the next tier
      vim.schedule(function()
        if cancelled then
          return
        end
        cancel_rest = rest(function(paths)
          local fresh = {}
          for _, path in ipairs(paths) do
            if not given[path] then
              fresh[#fresh + 1] = path
            end
          end
          if #fresh > 0 then
            on_batch(fresh)
          end
        end, on_done)
      end)
    end
    return false
  end, helper_opts(o))
  if not gen then
    return nil
  end
  return function()
    if cancelled then
      return
    end
    cancelled = true
    helper.drop(gen, "cancel")
    if cancel_rest then
      cancel_rest()
    end
  end
end

---@param root string
---@param o Lib.Fs.Fast.Resolved
---@param forced Lib.Fs.Fast.Tier|nil
---@param on_batch fun(paths: string[])
---@param on_done fun(ok: boolean)
---@return fun() cancel
local function list(root, o, forced, on_batch, on_done)
  local tier, exe = M.tier()
  if forced then
    tier = forced
    if tier ~= "lua" and tier ~= "helper" then
      local found, found_exe = tool_tier()
      -- a forced tool that is not installed: the walk, which every machine has
      exe = found == tier and found_exe or (vim.fn.executable(tier) == 1 and tier or nil)
      if not exe then
        tier = "lua"
      end
    end
  end
  if tier == "helper" then
    local cancel = via_helper(root, o, on_batch, on_done, function(batch, done)
      return list(root, o, (tool_tier()), batch, done)
    end)
    if cancel then
      return cancel
    end
    -- no helper after all (forced, or it could not start): the tools
    tier, exe = tool_tier()
  end
  if tier == "lua" or not exe then
    return walk(root, o, on_batch, on_done)
  end
  -- `fd --type f` leaves every link out (unless it follows them); a second run lists the links, and
  -- what points at a folder is dropped here, as the walk drops it
  if tier ~= "fd" or o.follow then
    return spawn(command(tier, exe, root, o), on_batch, on_done)
  end
  ---@param paths string[]
  local function links(paths)
    local batch = {}
    for _, path in ipairs(paths) do
      if (uv.fs_stat(path) or {}).type ~= "directory" then
        batch[#batch + 1] = path
      end
    end
    if #batch > 0 then
      on_batch(batch)
    end
  end
  local cancelled = false
  local _, direct = program(exe)
  if direct then
    -- the program itself: both runs side by side, the listing takes as long as the longer one
    local left, all_ok = 2, true
    ---@param ok boolean
    local function one_done(ok)
      all_ok = all_ok and ok
      left = left - 1
      if left == 0 and not cancelled then
        on_done(all_ok)
      end
    end
    local cancel_files = spawn(command(tier, exe, root, o), on_batch, one_done)
    local cancel_links = spawn(command(tier, exe, root, o, "l"), links, one_done)
    return function()
      cancelled = true
      cancel_files()
      cancel_links()
    end
  end
  -- A launcher in between: one run after the other, never both at once. With two children started
  -- side by side, ending the first left its `fd` behind for good on Windows.
  local cancel_run
  cancel_run = spawn(command(tier, exe, root, o), on_batch, function(files_ok)
    if cancelled then
      return
    end
    cancel_run = spawn(command(tier, exe, root, o, "l"), links, function(links_ok)
      on_done(files_ok and links_ok)
    end)
  end)
  return function()
    cancelled = true
    cancel_run()
  end
end

---List every file below `root`, streamed.
---@param root string
---@param opts Lib.Fs.Fast.ListOpts|nil
---@param on_batch fun(paths: string[])  Normalized absolute paths, in the order they are found.
---@param on_done fun(ok: boolean)  Called once, after the last batch; false when the tool failed, an option was wrong or the walk hit its limit.
---@return fun() cancel  After it nothing more is called.
function M.list(root, opts, on_batch, on_done)
  local o = resolve_opts(opts)
  return list(M.norm(root), o, opts and opts.tier or nil, on_batch, on_done)
end

---`list` collected: every path at once.
---@param root string
---@param opts Lib.Fs.Fast.ListOpts|nil
---@param on_done fun(paths: string[], ok: boolean)
---@return fun() cancel
function M.list_all(root, opts, on_done)
  local all = {}
  return M.list(root, opts, function(batch)
    vim.list_extend(all, batch)
  end, function(ok)
    on_done(all, ok)
  end)
end

-- ── size ─────────────────────────────────────────────────────────────────────

---Files and bytes below `dir` by walking it: everything counted, links as themselves.
---@param dir string
---@param on_done fun(bytes: integer|nil, files: integer|nil)
---@return fun() cancel
local function size_walk(dir, on_done)
  local cancelled = false
  local queue, head = { dir }, 1
  local files, bytes = 0, 0
  local function step()
    if cancelled then
      return
    end
    local current = queue[head]
    if not current then
      on_done(bytes, files)
      return
    end
    head = head + 1
    uv.fs_scandir(current, function(err, handle)
      if head == 2 and (err or not handle) then
        -- the root itself cannot be read
        vim.schedule(function()
          if not cancelled then
            on_done(nil, nil)
          end
        end)
        return
      end
      if handle then
        while true do
          local name, kind = uv.fs_scandir_next(handle)
          if not name then
            break
          end
          local path = join(current, name)
          if kind == "directory" then
            queue[#queue + 1] = path
          else
            local stat = uv.fs_lstat(path)
            if stat then
              files = files + 1
              bytes = bytes + stat.size
            end
          end
        end
      end
      vim.schedule(step)
    end)
  end
  step()
  return function()
    cancelled = true
  end
end

---The size of a folder: every file below it, ignored ones and `.git` too (as `du`).
---@param dir string
---@param on_done fun(bytes: integer|nil, files: integer|nil, tier: "helper"|"lua")  On the main loop; nil when the folder cannot be read.
---@param opts? { tier?: "helper"|"lua" }
---@return fun() cancel
function M.size(dir, on_done, opts)
  dir = M.norm(dir)
  local cancelled = false
  local cancel_walk
  local function by_lua()
    cancel_walk = size_walk(dir, function(bytes, files)
      if not cancelled then
        on_done(bytes, files, "lua")
      end
    end)
  end
  local gen
  if not (opts and opts.tier == "lua") then
    gen = helper.request("size", dir, function(kind, payload)
      if cancelled then
        return false
      end
      if kind == "size" and type(payload) == "table" then
        vim.schedule(function()
          if not cancelled then
            on_done(payload.bytes, payload.files, "helper")
          end
        end)
      elseif kind == "lost" then
        vim.schedule(function()
          if not cancelled then
            by_lua()
          end
        end)
      end
      return false
    end)
  end
  if not gen then
    by_lua()
  end
  return function()
    cancelled = true
    if gen then
      helper.drop(gen)
    end
    if cancel_walk then
      cancel_walk()
    end
  end
end

-- ── watch ────────────────────────────────────────────────────────────────────

---@param path string
---@return string
local function parent(path)
  return (path:match("^(.*)/[^/]*$") or path)
end

---A watch through libuv: one recursive handle where the system has them, else one per folder.
---@param root string
---@param o { hidden: boolean, names: string[], max_watches: integer }
---@param report fun(dir: string)
---@return { stop: fun(), handles: fun(): integer }
local function watch_libuv(root, o, report)
  local recursive = uv.os_uname().sysname ~= "Linux"
  ---@type table<string, uv.uv_fs_event_t>
  local handles = {}
  local count = 0
  local stopped = false
  local names = {}
  for _, name in ipairs(o.names) do
    names[name] = true
  end
  names[".git"] = true

  local add
  ---@param dir string
  local function on_event(dir)
    return function(err, filename)
      if stopped then
        return
      end
      if err then
        local handle = handles[dir]
        handles[dir] = nil
        if handle then
          count = count - 1
          pcall(handle.stop, handle)
          if not handle:is_closing() then
            handle:close()
          end
        end
        report(dir)
        return
      end
      local changed = dir
      if filename and filename ~= "" then
        local path = M.norm(join(dir, filename))
        changed = recursive and parent(path) or dir
        if not recursive then
          -- a folder that appeared is watched too
          local stat = uv.fs_stat(path)
          if stat and stat.type == "directory" and not handles[path] then
            vim.schedule(function()
              add(path)
            end)
          end
        end
      end
      report(changed)
    end
  end

  ---@param dir string
  ---@return boolean
  local function watch_one(dir)
    if handles[dir] or count >= o.max_watches then
      return false
    end
    local handle = uv.new_fs_event()
    if not handle then
      return false
    end
    local ok = handle:start(dir, { recursive = recursive }, on_event(dir))
    if not ok then
      if not handle:is_closing() then
        handle:close()
      end
      return false
    end
    handles[dir] = handle
    count = count + 1
    return true
  end

  ---@param dir string
  add = function(dir)
    if stopped or not watch_one(dir) or recursive then
      return
    end
    local below = require("lib.nvim.fs.collect_recursive").dirs(dir, {
      ignore = function(path)
        local name = path:match("[^/\\]+$") or path
        return names[name] == true or (not o.hidden and name:sub(1, 1) == ".")
      end,
    })
    for _, sub in ipairs(below) do
      if not watch_one(M.norm(sub)) then
        break
      end
    end
  end

  add(root)
  return {
    stop = function()
      stopped = true
      for dir, handle in pairs(handles) do
        handles[dir] = nil
        pcall(handle.stop, handle)
        if not handle:is_closing() then
          handle:close()
        end
      end
      count = 0
    end,
    handles = function()
      return count
    end,
  }
end

---Watch a folder tree: `on_change(dirs)` gets the folders in which something changed, after a quiet.
---@param root string
---@param opts Lib.Fs.Fast.WatchOpts|nil
---@param on_change fun(dirs: string[])  On the main loop.
---@return Lib.Fs.Fast.Watch
function M.watch(root, opts, on_change)
  opts = opts or {}
  root = M.norm(root)
  local quiet = opts.debounce_ms or 200
  local o = {
    hidden = opts.hidden ~= false,
    names = opts.names or require("lib.nvim.fs.ignore.list").basenames,
    max_watches = opts.max_watches or M.MAX_WATCHES,
  }
  local stopped = false
  ---@type table<string, true>
  local pending = {}
  local timer = uv.new_timer()
  local tier ---@type "helper"|"libuv"
  local gen ---@type integer|nil
  local fallback ---@type { stop: fun(), handles: fun(): integer }|nil

  local function flush()
    if stopped then
      return
    end
    local dirs = vim.tbl_keys(pending)
    pending = {}
    if #dirs > 0 then
      table.sort(dirs)
      on_change(dirs)
    end
  end

  ---@param dir string
  local function report(dir)
    pending[dir] = true
    if timer then
      timer:stop()
      timer:start(quiet, 0, vim.schedule_wrap(flush))
    end
  end

  local function to_libuv()
    tier = "libuv"
    fallback = watch_libuv(root, o, report)
  end

  if opts.tier ~= "libuv" then
    gen = helper.request("watch", root, function(kind, payload)
      if stopped then
        return false
      end
      if kind == "changed" and type(payload) == "table" then
        vim.schedule(function()
          if stopped then
            return
          end
          for _, dir in ipairs(payload) do
            pending[M.norm(dir)] = true
          end
          flush()
        end)
        return true
      elseif kind == "watching" then
        return true
      elseif kind == "error" or kind == "lost" then
        -- the helper cannot watch (any more): libuv takes over, and the caller reads the root again
        vim.schedule(function()
          if stopped then
            return
          end
          gen = nil
          to_libuv()
          report(root)
        end)
      end
      return false
    end)
  end
  if gen then
    tier = "helper"
  else
    to_libuv()
  end

  return {
    stop = function()
      if stopped then
        return
      end
      stopped = true
      if gen then
        helper.drop(gen, "unwatch")
      end
      if fallback then
        fallback.stop()
      end
      if timer then
        timer:stop()
        if not timer:is_closing() then
          timer:close()
        end
      end
    end,
    tier = function()
      return tier
    end,
    handles = function()
      return fallback and fallback.handles() or 0
    end,
  }
end

return M
