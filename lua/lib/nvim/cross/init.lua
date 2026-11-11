---@module 'lib.nvim.cross'
---Cross-platform utilities for Neovim/Lua
---Provides platform detection, path normalization, and shell helpers

local M = {}

-- Platform Detection
M.is_windows = require("lib.nvim.cross.platform.is_windows")
M.is_wsl = require("lib.nvim.cross.platform.is_wsl")
M.is_macos = require("lib.nvim.cross.platform.is_macos")
M.is_linux = require("lib.nvim.cross.platform.is_linux")
M.is = require("lib.nvim.cross.platform.is")
M.case_blind = require("lib.nvim.cross.platform.case_blind")

M.executable = require("lib.nvim.cross.executable")

-- Git Bash on Windows (never the WSL launcher), `bash` elsewhere; memoized.
M.bash = require("lib.nvim.cross.bash").find

-- Filesystem
M.fs = {
  cwd = require("lib.nvim.cross.fs._cwd"),
}

M.separators = {
  has_win_sep = require("lib.nvim.cross.fs.separators.has_win_sep"),
  normalize = require("lib.nvim.cross.fs.separators.normalize"),
  unify_slashes = require("lib.nvim.cross.fs.separators.unify_slashes"),
  collapse_dots = require("lib.nvim.cross.fs.separators.collapse_dots"),
  drive_upper = require("lib.nvim.cross.fs.separators.drive_upper"),
}

M.fs.expand_path = require("lib.nvim.cross.fs.expand_path")
M.fs.mutate = require("lib.nvim.cross.fs.mutate")
M.fs.wslpath = require("lib.nvim.cross.fs.wslpath")

-- UV/Loop compatibility
M.uv = {
  spawn_command = require("lib.nvim.cross.uv.spawn_command"),
  spawn_shell_command = require("lib.nvim.cross.uv.spawn_shell_command"),
  spawn_capture = require("lib.nvim.cross.uv.spawn_capture"),
  spawn_stream = require("lib.nvim.cross.uv.spawn_stream"),
  wait_until = require("lib.nvim.cross.uv.wait_until"),
}

M.run = {
  shell = require("lib.nvim.cross.run").shell,
  run = require("lib.nvim.cross.run").run,
  run_blocking = require("lib.nvim.cross.run").run_blocking,
  run_detached = require("lib.nvim.cross.run").run_detached,
  run_argv = require("lib.nvim.cross.run_argv"),
  env = require("lib.nvim.cross.run.env"),
}

M.open_default = require("lib.nvim.cross.open_default")
M.reveal_in_fm = require("lib.nvim.cross.reveal_in_fm")

---@type Lib.Cross
return M
