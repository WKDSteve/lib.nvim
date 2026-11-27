---@module 'lib.nvim.require'
---Safe and extended require utilities

require("lib.nvim.require.@types")

local notify = require("lib.nvim.notify").create("[lib.nvim.require]")

local M = {}

---Safe require with structured error handling
---@param name string Module name
---@return boolean ok Success flag
---@return any result Module or error message
function M.safe(name)
  if type(name) ~= "string" then
    return false, "invalid module name"
  end

  local ok, mod = pcall(require, name)
  if not ok then
    return false, mod
  end
  return true, mod
end

---Load all `*.lua` files directly inside `lua/<dir>` (non-recursive,
---`init.lua` skipped) and dispatch `calls` on each loaded module. The
---calling module itself is skipped (detected via `debug.getinfo`), so a
---module inside `<dir>` that calls this on its own parent directory does
---not re-require itself into infinite recursion. All requires and
---function calls are `pcall`-wrapped; failures are reported via notify
---rather than raised.
---@param dir string Directory relative to lua/
---@param calls? string|string[]|"" Which function(s) to call on each loaded module: nil calls `setup({})` if present (default); a string calls exactly that function; a table calls each in order; `""` calls nothing, modules are only required.
---@return nil
function M.dir(dir, calls)
  -- Normalize `dir` (strip leading/trailing slashes and trailing dots)
  dir = tostring(dir):gsub("^/*", ""):gsub("/*$", ""):gsub("%.+$", "")

  -- Resolve absolute path to the directory under the user's config `lua/`.
  local full_dir = vim.fn.stdpath("config") .. "/lua/" .. dir

  -- Determine the calling module to avoid self-require recursion.
  -- debug.getinfo(2) points to the direct caller of this function.
  local caller_src = debug.getinfo(2, "S")
  local caller_module = nil
  if caller_src and type(caller_src.source) == "string" then
    local src = caller_src.source:gsub("^@", "")
    if src:find("/lua/") then
      local rel = src:match("/lua/(.+)%.lua$")
      if rel then
        caller_module = rel:gsub("/", ".")
      end
    end
  end

  -- Normalize `calls` argument.
  ---@type string[]|nil
  local call_list = nil
  if type(calls) == "string" then
    if calls ~= "" then
      call_list = { calls }
    else
      call_list = {}
    end
  elseif type(calls) == "table" then
    call_list = calls
  end

  -- Find all .lua files within that directory (non-recursive). `vim.fs.dir`
  -- reads its argument as a path; `vim.fn.glob` would read it as a pattern
  -- and silently list nothing for a config directory whose spelling contains
  -- `~` (an 8.3 short name), `[`, `*` or `?`.
  if vim.fn.isdirectory(full_dir) ~= 1 then
    notify.warn("[lib.require_dir] No such directory: " .. full_dir)
    return
  end
  ---@type string[]
  local files = {}
  for name, kind in vim.fs.dir(full_dir) do
    if (kind == "file" or kind == "link") and name:sub(-4) == ".lua" then
      files[#files + 1] = full_dir .. "/" .. name
    end
  end
  table.sort(files)

  if #files == 0 then
    notify.warn("[lib.require_dir] No .lua files in " .. full_dir)
    return
  end

  for _, file in ipairs(files) do
    local name = vim.fn.fnamemodify(file, ":t:r")

    -- Skip "init.lua" to avoid double-loading aggregators.
    if name ~= "init" then
      local module_name = dir .. "." .. name

      -- Skip the calling module itself to prevent recursion.
      if module_name ~= caller_module then
        local ok, mod = pcall(require, module_name)
        if not ok then
          notify.error(
            "[lib.require_dir] Failed to require " .. module_name .. ": " .. tostring(mod)
          )
        else
          -- Function dispatch logic.
          if type(mod) == "table" then
            if call_list == nil then
              -- Default behavior: call setup({})
              if type(mod.setup) == "function" then
                local ok_setup, err = pcall(mod.setup, {})
                if not ok_setup then
                  notify.error(
                    "[lib.require_dir] Setup error in " .. module_name .. ": " .. tostring(err)
                  )
                end
              end
            else
              -- Explicit function list (possibly empty)
              for _, fn in ipairs(call_list) do
                if type(mod[fn]) == "function" then
                  local ok_call, err = pcall(mod[fn], mod)
                  if not ok_call then
                    notify.error(
                      "[lib.require_dir] Error calling "
                        .. fn
                        .. " in "
                        .. module_name
                        .. ": "
                        .. tostring(err)
                    )
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end

--- CDX: reimplements `lib.lua.lazy`'s `LAZY.module(name).get` (cache-on-first-
--- access require) rather than delegating to it; the two now have to be kept
--- behaviorally in sync by hand. Real caller: `LIB.require_lazy` in
--- `lib/strategies/eager.lua`/`lazy.lua`.
---Lazy-loading wrapper
---@param module_name string
---@return fun(): table
function M.lazy(module_name)
  local cached = nil
  return function()
    if not cached then
      cached = require(module_name)
    end
    return cached
  end
end

---@param path string
---@param kind "file"|"directory"
---@return boolean
local function stat_is(path, kind)
  local uv = vim.uv or vim.loop
  local ok, st = pcall(uv.fs_stat, path)
  return ok and st ~= nil and st.type == kind
end

---Whether `dir` ships the module at `path` (`lua/<path>.lua` or `lua/<path>/init.lua`).
---@param dir string
---@param path string  the module name with `/` for `.`
---@return boolean
local function dir_has_module(dir, path)
  -- A nested module (`ui/contextmenu`) needs `lua/<top>/`: one stat rules most plugins out.
  local top = path:match("^[^/]+")
  if top ~= path and not stat_is(dir .. "/lua/" .. top, "directory") then
    return false
  end
  local base = dir .. "/lua/" .. path
  return stat_is(base .. ".lua", "file") or stat_is(base .. "/init.lua", "file")
end

---Whether the module of a plugin is installed, asked without loading it where possible.
---
---Under lazy.nvim a bare `require` of a plugin that is not loaded yet loads it, `config` and
---all, so asking "is it there?" that way loads every plugin it is asked about. The order:
---  1. `package.loaded[mod]` -- already loaded.
---  2. lazy.nvim's registry, only if lazy.nvim itself is loaded (`package.loaded`, it is never
---     required from here): the plugin listed as `opts.repo` with an existing directory, or any
---     listed plugin whose directory ships `lua/<mod>`; not one with `cond = false`. An unloaded
---     plugin stays unloaded.
---  3. `runtimepath`: `lua/<mod>.lua` or `lua/<mod>/init.lua` (other plugin managers, dev
---     checkouts, everything lazy.nvim has loaded).
---  4. `require` last, for what only a loader knows (`package.preload`, `package.path`).
---@param mod string  the plugin's main module (`filetree`, `ui.contextmenu`)
---@param opts? { repo?: string }  `repo`: the name lazy.nvim lists the plugin under (`filetree.nvim`)
---@return boolean
function M.installed(mod, opts)
  if type(mod) ~= "string" or mod == "" then
    return false
  end
  if package.loaded[mod] ~= nil then
    return true
  end
  local path = mod:gsub("%.", "/")
  local cfg = package.loaded["lazy.core.config"]
  if type(cfg) == "table" and type(cfg.plugins) == "table" then
    local repo = opts and opts.repo
    local named = repo and cfg.plugins[repo]
    if
      type(named) == "table"
      and type(named.dir) == "string"
      and not (type(named._) == "table" and named._.cond == false)
      and stat_is(named.dir, "directory")
    then
      return true
    end
    for _, plugin in pairs(cfg.plugins) do
      if
        type(plugin) == "table"
        and type(plugin.dir) == "string"
        -- `cond = false`: listed, never loaded
        and not (type(plugin._) == "table" and plugin._.cond == false)
        and dir_has_module(plugin.dir, path)
      then
        return true
      end
    end
  end
  if
    #vim.api.nvim_get_runtime_file("lua/" .. path .. ".lua", false) > 0
    or #vim.api.nvim_get_runtime_file("lua/" .. path .. "/init.lua", false) > 0
  then
    return true
  end
  return (pcall(require, mod))
end

---@type Lib.Require
return M
