---@module 'lib.strategies.lazy'
--- Lazy-loaded aggregator for lib utilities.
--- Modules are only loaded when first accessed.

local LIB = {}

-- ============================================================================
-- Lazy Loading Setup
-- ============================================================================

---@internal
---Create a lazy-loading proxy for a module
---@param module_path string
---@return any
local function lazy_module(module_path)
  local loaded = nil
  return setmetatable({}, {
    __index = function(_, key)
      if not loaded then
        loaded = require(module_path)
      end
      return loaded[key]
    end,
    __call = function(_, ...)
      if not loaded then
        loaded = require(module_path)
      end
      if type(loaded) == "function" then
        return loaded(...)
      end
      error(string.format("Module '%s' is not callable", module_path))
    end,
  })
end

-- ============================================================================
-- Core Utilities (always loaded - frequently used)
-- ============================================================================

-- Lazy and memo are used internally, so load them eagerly
LIB.lazy = require("lib.lua.lazy")
LIB.memo = require("lib.lua.memo")

-- ============================================================================
-- Lazy-loaded Modules
-- ============================================================================

-- === NVIM ===
LIB.simple_echo = lazy_module("lib.nvim.core.simple_echo")
LIB.has_exec = require("lib.nvim.core").has_exec

-- === CROSS-PLATFORM ===
LIB.is_windows = lazy_module("lib.nvim.cross.platform.is_windows")
LIB.is_wsl = lazy_module("lib.nvim.cross.platform.is_wsl")
LIB.is_macos = lazy_module("lib.nvim.cross.platform.is_macos")
LIB.is_linux = lazy_module("lib.nvim.cross.platform.is_linux")
LIB.case_blind = lazy_module("lib.nvim.cross.platform.case_blind")
LIB.is = lazy_module("lib.nvim.cross.platform.is")

-- Run
do
  local cross_run
  LIB.shell = function()
    cross_run = cross_run or require("lib.nvim.cross.run")
    return cross_run.shell()
  end
  LIB.run = function(...)
    cross_run = cross_run or require("lib.nvim.cross.run")
    return cross_run.run(...)
  end
  LIB.run_blocking = function(...)
    cross_run = cross_run or require("lib.nvim.cross.run")
    return cross_run.run_blocking(...)
  end
end
LIB.run_argv = require("lib.nvim.cross.run_argv")
LIB.spawn_env = lazy_module("lib.nvim.cross.run.env")

-- === Clipboard ===
LIB.copy_to_clipboard = lazy_module("lib.nvim.cross.copy_to_clipboard")

-- === FUNCTIONS ===

LIB.noop = lazy_module("lib.lua.functions.meta").noop
LIB.identity = lazy_module("lib.lua.functions.meta").identity
LIB.always_true = lazy_module("lib.lua.functions.meta").always_true
LIB.always_false = lazy_module("lib.lua.functions.meta").always_false
LIB.const = lazy_module("lib.lua.functions.meta").const
LIB.raise = lazy_module("lib.lua.functions.meta").raise

-- === FILESYSTEM ===
do
  local fs_path
  LIB.joinpath = function(...)
    fs_path = fs_path or require("lib.nvim.fs.path")
    return fs_path.joinpath(...)
  end
  LIB.ensure_dir = function(...)
    fs_path = fs_path or require("lib.nvim.fs.path")
    return fs_path.ensure_dir(...)
  end
end

LIB.is_subpath = lazy_module("lib.nvim.fs.is_subpath")
LIB.same_path = lazy_module("lib.nvim.fs.same_path")
LIB.is_dir = lazy_module("lib.nvim.fs.is_dir")
LIB.relpath = lazy_module("lib.nvim.fs.relpath")
LIB.find_upward_dir = lazy_module("lib.nvim.fs.find_upward_dir")
LIB.find_root = lazy_module("lib.nvim.fs.find_root")
LIB.mkdirp = lazy_module("lib.nvim.fs.mkdirp")
LIB.path_shorten = lazy_module("lib.nvim.fs.path_shorten")
LIB.globbable = lazy_module("lib.nvim.fs.globbable")
LIB.write_to_file = require("lib.nvim.fs.write.to_file")
LIB.write_append = require("lib.nvim.fs.write.append")

-- === REQUIRE ===
do
  local lib_require
  LIB.require_safe = function(...)
    lib_require = lib_require or require("lib.nvim.require")
    return lib_require.safe(...)
  end
  LIB.require_dir = function(...)
    lib_require = lib_require or require("lib.nvim.require")
    return lib_require.dir(...)
  end
  LIB.require_lazy = function(...)
    lib_require = lib_require or require("lib.nvim.require")
    return lib_require.lazy(...)
  end
end

-- === BUFFER ===
LIB.is_markdown_buf = lazy_module("lib.nvim.buffer.is_markdown_buf")
LIB.insert_lines = lazy_module("lib.nvim.buffer.insert_lines")
LIB.buffer_context = lazy_module("lib.nvim.buffer.context")

-- === WINDOW ===
LIB.window_context = lazy_module("lib.nvim.window.context")

-- === CACHE (disk + memory) ===
LIB.cache = lazy_module("lib.nvim.cache")

-- === TABLES ===

-- Direct helper
LIB.with = lazy_module("lib.lua.tables.with")
-- Table submodules (lazy proxies)
LIB.array = lazy_module("lib.lua.tables.array")
LIB.core = lazy_module("lib.lua.tables.core")
LIB.dict = lazy_module("lib.lua.tables.dict")
LIB.set = lazy_module("lib.lua.tables.set")
LIB.functional = lazy_module("lib.lua.tables.functional")
LIB.safe = lazy_module("lib.lua.tables.safe")

LIB.unique_table = lazy_module("lib.lua.tables.unique_table")
-- Optional ergonomic shortcuts (flattened access)
LIB.unique = function(...)
  return LIB.unique_table.unique(...)
end
LIB.unique_by = function(...)
  return LIB.unique_table.unique_by(...)
end
LIB.is_unique = function(...)
  return LIB.unique_table.is_unique(...)
end

-- === JSON ===
LIB.json_is_array_like = lazy_module("lib.lua.json.decode.to_string_array").is_array_like
LIB.json_ensure_string_array =
  lazy_module("lib.lua.json.decode.to_string_array").ensure_string_array
LIB.json_table_to_string_array =
  lazy_module("lib.lua.json.decode.to_string_array").table_to_string_array
-- Common `Lib` surface key (see @types/all_functions.lua): the canonical name
-- for `ensure_string_array`, also exported flat by the metatable/eager strategies.
LIB.json_decode_to_string_array =
  lazy_module("lib.lua.json.decode.to_string_array").ensure_string_array
LIB.json_encode = lazy_module("lib.lua.json.encode").encode

-- === STRINGS ===
-- Strings module is frequently used, but we still lazy-load it
do
  local strings
  local function get_strings()
    strings = strings or require("lib.lua.strings")
    return strings
  end

  -- Export strings module
  LIB.strings = setmetatable({}, {
    __index = function(_, key)
      return get_strings()[key]
    end,
  })

  -- Individual string functions (lazy-loaded)
  LIB.trim = function(...)
    return get_strings().trim(...)
  end
  LIB.slugify = function(...)
    return get_strings().slugify(...)
  end
  LIB.kebab_case = function(...)
    return get_strings().kebab_case(...)
  end
  LIB.starts_with = function(...)
    return get_strings().starts_with(...)
  end
  LIB.ends_with = function(...)
    return get_strings().ends_with(...)
  end
  LIB.contains = function(...)
    return get_strings().contains(...)
  end
  LIB.split = function(...)
    return get_strings().split(...)
  end
  LIB.join = function(...)
    return get_strings().join(...)
  end
  LIB.replace_all = function(...)
    return get_strings().replace_all(...)
  end
  LIB.capitalize = function(...)
    return get_strings().capitalize(...)
  end
  LIB.uncapitalize = function(...)
    return get_strings().uncapitalize(...)
  end
  LIB.snake_case = function(...)
    return get_strings().snake_case(...)
  end
  LIB.camel_case = function(...)
    return get_strings().camel_case(...)
  end
  LIB.pad_start = function(...)
    return get_strings().pad_start(...)
  end
  LIB.pad_end = function(...)
    return get_strings().pad_end(...)
  end
  LIB.pad_center = function(...)
    return get_strings().pad_center(...)
  end
  LIB.indent = function(...)
    return get_strings().indent(...)
  end
  LIB.dedent = function(...)
    return get_strings().dedent(...)
  end
  LIB.is_empty_or_space = function(...)
    return get_strings().is_empty_or_space(...)
  end
  LIB.remove_prefix = function(...)
    return get_strings().remove_prefix(...)
  end
  LIB.uri_decode = function(...)
    return get_strings().uri_decode(...)
  end
  LIB.normalize_anchor = function(...)
    return get_strings().normalize_anchor(...)
  end
  LIB.has_scheme = function(...)
    return get_strings().has_scheme(...)
  end
  LIB.is_web_url = function(...)
    return get_strings().is_web_url(...)
  end
  LIB.url_under_cursor = function(...)
    return get_strings().url_under_cursor(...)
  end
  LIB.escape_lua_magic = function(...)
    return get_strings().escape_lua_magic(...)
  end
  LIB.find_plain = function(...)
    return get_strings().find_plain(...)
  end
  LIB.replace_plain = function(...)
    return get_strings().replace_plain(...)
  end
  LIB.surround = function(...)
    return get_strings().surround(...)
  end
  LIB.count_lines = function(...)
    return get_strings().count_lines(...)
  end
end

LIB.hex_to_string = lazy_module("lib.lua.strings.convert.hex_to_string")

-- === TERMINAL ===
do
  local terminal
  LIB.terminal_escape = function(...)
    terminal = terminal or require("lib.nvim.terminal")
    return terminal.escape(...)
  end
  LIB.is_terminal_buf = function(...)
    terminal = terminal or require("lib.nvim.terminal")
    return terminal.is_terminal_buf(...)
  end
  LIB.delete_terminal_buf = function(...)
    terminal = terminal or require("lib.nvim.terminal")
    return terminal.delete_terminal_buf(...)
  end
end

-- === UI ===
LIB.hl = lazy_module("lib.nvim.ui.hl")
LIB.kit = lazy_module("lib.nvim.ui.kit")

-- === AUTOCMD/KEYMAP ===
LIB.autocmd = lazy_module("lib.nvim.bindings.autocmd")
LIB.augroup = lazy_module("lib.nvim.bindings.autocmd.augroup")
LIB.augroup_create_clear = lazy_module("lib.nvim.bindings.autocmd.augroup").create.clear
LIB.map = lazy_module("lib.nvim.bindings.keymap")
LIB.usercmd = lazy_module("lib.nvim.bindings.usercmd")
LIB.composer = lazy_module("lib.nvim.bindings.usercmd.composer")

-- === NOTIFY ===
LIB.notify = lazy_module("lib.nvim.notify")
LIB.resolve_log_level = lazy_module("lib.nvim.notify.resolve_log_level")

-- === LOGGER ===
LIB.logger = lazy_module("lib.nvim.logger")

-- === DEPS ===
LIB.deps = lazy_module("lib.nvim.deps")

-- === TIME ===
LIB.time_diff = lazy_module("lib.lua.time.diff")

-- === NORMALIZE ===
LIB.normalize = lazy_module("lib.nvim.normalize")

-- === SYSTEM ===
LIB.system = lazy_module("lib.nvim.system")
LIB.system_info = lazy_module("lib.nvim.system.info")

-- Plain table: `control.keys()` can enumerate it via pairs(), and there is no
-- resolved-key cache to invalidate (each proxy memoizes its own module).
require("lib.strategies.control").register({ name = "lazy", table = LIB })

---@type Lib.Strategy.Lazy
return LIB
