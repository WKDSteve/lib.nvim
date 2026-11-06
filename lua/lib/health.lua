---@module 'lib.health'
--- Health check for lib.nvim. Run with `:checkhealth lib`.

local M = {}

-- vim.health shim (start/ok/warn/error/info exist on all supported versions).
local H = vim.health or {}
local h_start = H.start or H.report_start
local h_ok = H.ok or H.report_ok
local h_warn = H.warn or H.report_warn
local h_error = H.error or H.report_error
local h_info = H.info or H.report_info

local MIN_NVIM = { 0, 11, 0 }

local version_ok = require("lib.nvim.health").version_ok

---@type string[] Representative modules spanning both namespaces; each must load.
local PROBE = {
  "lib.lua.tables.array",
  "lib.lua.strings",
  "lib.lua.functions.meta",
  "lib.nvim.notify",
  "lib.nvim.logger",
  "lib.nvim.progress",
  "lib.nvim.ui.kit",
  "lib.nvim.bindings.keymap",
  "lib.nvim.fs.is_dir",
  "lib.nvim.store.project",
  "lib.nvim.frecency",
  "lib.nvim.core",
  "lib.nvim.bindings.usercmd.composer",
  "lib.nvim.bindings.autocmd.dispatcher",
}

---Named roots (`lib.nvim.fs.roots`): a root that is unset or points at nothing makes every
---`$NAME/...` path of every plugin that uses the registry fail the same quiet way.
function M.check_roots()
  h_start("lib.nvim: named roots")
  local ok_roots, roots = pcall(require, "lib.nvim.fs.roots")
  if not ok_roots then
    h_error("lib.nvim.fs.roots failed to load: " .. tostring(roots))
    return
  end

  for _, st in ipairs(roots.status()) do
    local p = st.problem
    if p == "unset" then
      if st.kind == "nvim_config" then
        h_warn(("$%s is not available"):format(st.name))
      elseif st.kind == "extra" or st.kind == "registered" then
        h_warn(("$%s (%s root) resolved to nothing"):format(st.name, st.kind))
      else
        h_warn(("$%s is not set"):format(st.name), {
          ("Set the environment variable %s, or define it with"):format(st.name)
            .. ' require("lib.nvim.fs.roots").setup({ extra = { '
            .. st.name
            .. ' = "..." } })',
          "Inside a testing.nvim child the variable also has to be listed in `env_allow`.",
        })
      end
    elseif p == "unresolved_var" then
      h_warn(
        ("$%s: %s starts with `%s`, which has no value"):format(
          st.name,
          tostring(st.raw),
          tostring(st.detail)
        )
      )
    elseif p == "error" then
      h_warn(("$%s: its function raised: %s"):format(st.name, tostring(st.detail)))
    elseif p == "bad_type" then
      h_warn(
        ("$%s: the value is a %s, expected a path or a function returning one"):format(
          st.name,
          tostring(st.detail)
        )
      )
    elseif p == "invalid_name" then
      h_warn(
        ("root name %q is ignored"):format(st.name),
        { "A root name must be letters, digits and underscores, not starting with a digit." }
      )
    elseif p == "not_absolute" then
      h_warn(("$%s is not an absolute path: %s"):format(st.name, tostring(st.raw)))
    elseif p == "too_broad" then
      h_warn(
        ("$%s is the filesystem root or a whole drive (%s): refused as a root"):format(
          st.name,
          tostring(st.raw)
        )
      )
    elseif p == "invalid_path" then
      h_warn(("$%s contains a NUL byte and is ignored"):format(st.name))
    elseif p == "missing_dir" then
      h_warn(("$%s points at a directory that does not exist: %s"):format(st.name, st.root))
    else
      h_ok(("$%s = %s"):format(st.name, st.root))
    end
    if st.env then
      h_warn(
        ("$%s in the environment is %s, but stdpath('config') is %s"):format(
          st.name,
          st.env,
          tostring(st.root)
        ),
        {
          "lib.nvim uses stdpath('config'); `vim.fn.expand('$"
            .. st.name
            .. "')` uses the environment.",
          "Usually a value inherited from a parent Neovim with another NVIM_APPNAME.",
        }
      )
    end
  end
  if not roots.enabled() then
    h_info("fold/remap are disabled (roots.setup({ enable = false }))")
  end
end

---Which backend answers `lib.nvim.ui.dialog` (the one every plugin's yes/no, choice and text prompt
---goes through): ui.nvim's `ui.kit`, the copy that ships here, or the native fallback.
function M.check_dialog()
  h_start("lib.nvim: dialogs")
  local ok_dialog, dialog = pcall(require, "lib.nvim.ui.dialog")
  if not ok_dialog then
    h_error("lib.nvim.ui.dialog failed to load: " .. tostring(dialog))
    return
  end
  -- A kit that is installed but raises when required is not an absent kit: say what it raised.
  local errors = dialog.load_errors()
  local names = vim.tbl_keys(errors)
  table.sort(names)
  for _, name in ipairs(names) do
    h_warn(("%s is installed but failed to load: %s"):format(name, errors[name]))
  end
  -- The kit is chosen per function, so each is reported: an older ui.nvim may lack one of them.
  local native = {}
  for _, fn in ipairs({ "confirm", "ask", "input" }) do
    local backend = dialog.backend(fn)
    if backend == "ui.kit" then
      h_ok(("%s: asked through ui.nvim's ui.kit (your preset applies)"):format(fn))
    elseif backend == "lib.nvim.ui.kit" then
      h_info(
        ("%s: asked through the kit copy in lib.nvim (the default theme); "):format(fn)
          .. "install or update ui.nvim to use your own preset"
      )
    else
      native[#native + 1] = fn
    end
  end
  if #native > 0 then
    h_warn(
      ("no kit provides %s: those fall back to vim.ui.select / vim.ui.input"):format(
        table.concat(native, ", ")
      ),
      {
        "Neither ui.kit nor lib.nvim.ui.kit loaded; run :checkhealth lib for the module probe above.",
      }
    )
  end
end

---Deprecated Neovim calls still in the user's config (`lib.nvim.dev.deprecations`): the
---on-demand counterpart of its `watch()` save hook, which only sees the file just saved.
function M.check_deprecations()
  local ok_dep, dep = pcall(require, "lib.nvim.dev.deprecations")
  if not ok_dep then
    h_start("lib.nvim: deprecated API calls")
    h_error("lib.nvim.dev.deprecations failed to load: " .. tostring(dep))
    return
  end
  dep.health({ vim.fn.stdpath("config") })
end

---Runs all lib.nvim health checks and reports via vim.health.
function M.check()
  -- Neovim version --------------------------------------------------------
  h_start("lib.nvim: environment")
  local v = vim.version()
  local vstr = ("%d.%d.%d"):format(v.major, v.minor, v.patch)
  if version_ok(MIN_NVIM) then
    h_ok(("Neovim %s (>= %d.%d.%d)"):format(vstr, MIN_NVIM[1], MIN_NVIM[2], MIN_NVIM[3]))
  else
    h_warn(
      ("Neovim %s is older than the recommended %d.%d.%d"):format(
        vstr,
        MIN_NVIM[1],
        MIN_NVIM[2],
        MIN_NVIM[3]
      ),
      { "Some lib.nvim modules need the single-value vim.validate form and will fail." }
    )
  end
  if vim.uv or vim.loop then
    h_ok("libuv bridge available (vim.uv)")
  else
    h_error("vim.uv / vim.loop missing", { "Upgrade to a Neovim build with libuv support" })
  end

  -- Configuration ---------------------------------------------------------
  h_start("lib.nvim: configuration")
  local ok_cfg, cfg = pcall(require, "lib.config")
  if ok_cfg then
    local strat = cfg.get().strategy
    h_ok(("aggregator strategy: %q"):format(strat))
    h_info(('require("lib") -> %s'):format(cfg.strategy_module()))
  else
    h_error("lib.config failed to load: " .. tostring(cfg))
  end

  -- Module resolution -----------------------------------------------------
  h_start("lib.nvim: module resolution")
  local failed = 0
  for _, mod in ipairs(PROBE) do
    local ok, err = pcall(require, mod)
    if ok then
      h_ok(mod)
    else
      failed = failed + 1
      h_error(mod .. " failed to load", { tostring(err):gsub("\n.*", "") })
    end
  end
  if failed == 0 then
    h_ok(("all %d probed modules load"):format(#PROBE))
  end

  -- Aggregator surface ----------------------------------------------------
  h_start("lib.nvim: aggregator")
  local ok_lib, lib = pcall(require, "lib")
  if ok_lib then
    local ok_access = pcall(function()
      return lib.notify and lib.map and lib.is_windows
    end)
    if ok_access then
      h_ok('require("lib") resolves keys (notify, map, is_windows, …)')
    else
      h_warn('require("lib") loaded but key access failed')
    end
  else
    h_error('require("lib") failed: ' .. tostring(lib))
  end

  M.check_roots()

  -- Active loggers --------------------------------------------------------
  -- Reports what each plugin registered via lib.nvim.logger.new(), so a bug
  -- report can name the log file to attach without the user having to know
  -- where it lives.
  h_start("lib.nvim: loggers")
  local ok_logger, logger = pcall(require, "lib.nvim.logger")
  if not ok_logger then
    h_error("lib.nvim.logger failed to load: " .. tostring(logger))
  elseif not logger.is_enabled() then
    h_info("logging is globally disabled (logger.set_enabled(false))")
  else
    local loggers = logger.loggers()
    if #loggers == 0 then
      h_info("no loggers created yet (a plugin creates one on its first setup)")
    else
      for _, inst in ipairs(loggers) do
        h_info(
          ("%s — level %d, file: %s"):format(
            tostring(inst.name),
            tonumber(inst.level) or -1,
            inst.file or "disabled"
          )
        )
      end
    end
  end

  M.check_dialog()
  M.check_deprecations()
end

return M
