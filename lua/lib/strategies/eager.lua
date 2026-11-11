---@module 'lib.strategies.eager'
--- Aggregator module that re-exports single-function utilities under one namespace.

-- The common surface is the `Lib` class (@types/all_functions.lua); it is what
-- `---@type Lib` below checks against and what every strategy guarantees. This
-- strategy also keeps two eager-only extras that predate that class and are not
-- worth a breaking removal: `augroup` / `augroup_create_clear` (also on the
-- `lazy` strategy, declared on `Lib.Strategy.Lazy`) and a raw `json` module
-- handle. Consume those only via a direct `require` if you need them portably.
local LIB = {}

-- === NVIM ===
LIB.simple_echo = require("lib.nvim.core.simple_echo")
LIB.has_exec = require("lib.nvim.core").has_exec

-- === CROSS-PLATFORM ===
LIB.is_windows = require("lib.nvim.cross.platform.is_windows")
LIB.is_wsl = require("lib.nvim.cross.platform.is_wsl")
LIB.is_macos = require("lib.nvim.cross.platform.is_macos")
LIB.is_linux = require("lib.nvim.cross.platform.is_linux")
LIB.is = require("lib.nvim.cross.platform.is")
LIB.case_blind = require("lib.nvim.cross.platform.case_blind")
-- Run
local cross_run = require("lib.nvim.cross.run")
LIB.shell = cross_run.shell
LIB.run = cross_run.run
LIB.run_blocking = cross_run.run_blocking
LIB.run_argv = require("lib.nvim.cross.run_argv")
LIB.spawn_env = require("lib.nvim.cross.run.env")
-- Clipboard
LIB.copy_to_clipboard = require("lib.nvim.cross.copy_to_clipboard")

-- === FUNCTIONS ===

LIB.noop = require("lib.lua.functions.meta").noop
LIB.identity = require("lib.lua.functions.meta").identity
LIB.always_true = require("lib.lua.functions.meta").always_true
LIB.always_false = require("lib.lua.functions.meta").always_false
LIB.const = require("lib.lua.functions.meta").const
LIB.raise = require("lib.lua.functions.meta").raise

-- === FILESYSTEM ===
local fs_path = require("lib.nvim.fs.path")
LIB.joinpath = fs_path.joinpath
LIB.ensure_dir = fs_path.ensure_dir

LIB.is_subpath = require("lib.nvim.fs.is_subpath")
LIB.same_path = require("lib.nvim.fs.same_path")
LIB.is_dir = require("lib.nvim.fs.is_dir")
LIB.relpath = require("lib.nvim.fs.relpath")
LIB.find_upward_dir = require("lib.nvim.fs.find_upward_dir")
LIB.find_root = require("lib.nvim.fs.find_root")
LIB.mkdirp = require("lib.nvim.fs.mkdirp")
LIB.path_shorten = require("lib.nvim.fs.path_shorten")
LIB.globbable = require("lib.nvim.fs.globbable")
LIB.write_to_file = require("lib.nvim.fs.write.to_file")
LIB.write_append = require("lib.nvim.fs.write.append")

-- === REQUIRE ===
local lib_require = require("lib.nvim.require")
LIB.require_safe = lib_require.safe
LIB.require_dir = lib_require.dir
LIB.require_lazy = lib_require.lazy

-- === BUFFER ===
LIB.is_markdown_buf = require("lib.nvim.buffer.is_markdown_buf")
LIB.insert_lines = require("lib.nvim.buffer.insert_lines")
LIB.buffer_context = require("lib.nvim.buffer.context")

-- === WINDOW ===
LIB.window_context = require("lib.nvim.window.context")

-- === CACHE (disk + memory) ===
LIB.cache = require("lib.nvim.cache")

-- === TABLES ===
LIB.with = require("lib.lua.tables.with")
LIB.array = require("lib.lua.tables.array")
LIB.core = require("lib.lua.tables.core")
LIB.dict = require("lib.lua.tables.dict")
LIB.set = require("lib.lua.tables.set")
LIB.functional = require("lib.lua.tables.functional")
LIB.safe = require("lib.lua.tables.safe")
LIB.unique_table = require("lib.lua.tables.unique_table")

-- === STRINGS ===
local strings = require("lib.lua.strings")
LIB.strings = strings

-- Export individual string functions
LIB.trim = strings.trim
LIB.slugify = strings.slugify
LIB.kebab_case = strings.kebab_case
LIB.starts_with = strings.starts_with
LIB.ends_with = strings.ends_with
LIB.contains = strings.contains
LIB.split = strings.split
LIB.join = strings.join
LIB.replace_all = strings.replace_all
LIB.capitalize = strings.capitalize
LIB.uncapitalize = strings.uncapitalize
LIB.snake_case = strings.snake_case
LIB.camel_case = strings.camel_case
LIB.pad_start = strings.pad_start
LIB.pad_end = strings.pad_end
LIB.pad_center = strings.pad_center
LIB.indent = strings.indent
LIB.dedent = strings.dedent
LIB.is_empty_or_space = strings.is_empty_or_space
LIB.remove_prefix = strings.remove_prefix
LIB.uri_decode = strings.uri_decode
LIB.normalize_anchor = strings.normalize_anchor
LIB.has_scheme = strings.has_scheme
LIB.is_web_url = strings.is_web_url
LIB.url_under_cursor = strings.url_under_cursor
LIB.escape_lua_magic = strings.escape_lua_magic
LIB.find_plain = strings.find_plain
LIB.replace_plain = strings.replace_plain
LIB.surround = strings.surround
LIB.hex_to_string = require("lib.lua.strings.convert.hex_to_string")
LIB.count_lines = strings.count_lines

-- === TERMINAL ===
local terminal = require("lib.nvim.terminal")
LIB.terminal_escape = terminal.escape
LIB.is_terminal_buf = terminal.is_terminal_buf
LIB.delete_terminal_buf = terminal.delete_terminal_buf

-- === UI ===
LIB.hl = require("lib.nvim.ui.hl")
LIB.kit = require("lib.nvim.ui.kit")

-- === AUTOCMD/KEYMAP ===
LIB.autocmd = require("lib.nvim.bindings.autocmd")
LIB.augroup = require("lib.nvim.bindings.autocmd.augroup")
LIB.augroup_create_clear = require("lib.nvim.bindings.autocmd.augroup").create.clear
LIB.map = require("lib.nvim.bindings.keymap")
LIB.usercmd = require("lib.nvim.bindings.usercmd")
LIB.composer = require("lib.nvim.bindings.usercmd.composer")

-- === NOTIFY ===
LIB.notify = require("lib.nvim.notify")
LIB.resolve_log_level = require("lib.nvim.notify.resolve_log_level")

-- === LOGGER ===
LIB.logger = require("lib.nvim.logger")

-- === DEPS ===
LIB.deps = require("lib.nvim.deps")

-- === LAZY ===
LIB.lazy = require("lib.lua.lazy")

-- === JSON ===
LIB.json = require("lib.lua.json")
LIB.json.is_array_like = require("lib.lua.json.decode.to_string_array").is_array_like
LIB.json.ensure_string_array = require("lib.lua.json.decode.to_string_array").ensure_string_array
LIB.json.table_to_string_array =
  require("lib.lua.json.decode.to_string_array").table_to_string_array
-- Flat keys that make up the common `Lib` surface (see @types/all_functions.lua).
LIB.json_decode_to_string_array = require("lib.lua.json.decode.to_string_array").ensure_string_array
LIB.json_encode = require("lib.lua.json.encode").encode

-- === MEMO ===
LIB.memo = require("lib.lua.memo")

-- === TIME ===
LIB.time_diff = require("lib.lua.time.diff")

-- === NORMALIZE ===
LIB.normalize = require("lib.nvim.normalize")

-- === SYSTEM ===
LIB.system = require("lib.nvim.system")
LIB.system_info = require("lib.nvim.system.info")

-- Plain table, everything already resolved: pairs() is the full key set and
-- there is nothing to invalidate.
require("lib.strategies.control").register({ name = "eager", table = LIB })

---@type Lib
return LIB
