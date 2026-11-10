-- templates/cli_script.lua -- copy to `scripts/<plugin>.lua` of a plugin that gets a command line without the editor.
--
--   nvim --headless -u NONE -l scripts/<plugin>.lua <command> [options]
--
-- A thin wrapper and nothing else: it puts the plugin and lib.nvim on the runtimepath (`-u NONE` loads neither), hands
-- the arguments to the plugin's CLI module and exits with the number that module returns. Every rule lives in the
-- plugin's `lua/`; there is no second implementation here.
--
-- Replace the two names below, nothing else:
--   MODULE   the Lua module with `run(argv: string[]): integer`, e.g. "github_stats.cli"
--   PLUGIN   the plugin's folder name, only for the message, e.g. "github_stats.nvim"
--
-- The exit codes of the fleet's command lines (tasks.lua, testing.lua, github_stats.lua):
--   0 done, 1 the work found or hit a failure (a red check, a failed fetch), 2 usage or configuration,
--   3 the environment (lib.nvim or a program missing, a timeout, the module raised)
-- MODULE.run returns 0, 1 or 2 (or 3 for what it detects itself); this script adds 3 for lib.nvim and for an error
-- the module raised, which is printed to stderr. Results go to stdout, messages to stderr, so `--format=json` output
-- stays parseable.
--
-- Why this is a copy and not a module of lib.nvim: the script runs BEFORE lib.nvim is on the runtimepath, so it cannot
-- `require` anything of it to find it. Like every `nvim -l` script it reads its arguments from the global `arg`
-- (`...` is empty on current Neovim).
local MODULE = "your_plugin.cli"
local PLUGIN = "your-plugin.nvim"

-- Absolute: `nvim -l` from inside scripts/ gives a bare relative name, and a relative plugin root would leave the
-- plugin's modules to be found in whatever runtimepath Neovim has (another checkout).
local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(script)))

---A path as ONE runtimepath entry: 'runtimepath' is a comma list, so a comma in a folder name must be escaped or the
---path is split in two.
---@param path string
---@return string
local function rtp_entry(path)
  return (vim.fn.escape(path, ","))
end

vim.opt.rtp:prepend(rtp_entry(plugin_root))

---@param dir string|nil
---@return boolean
local function has_lib(dir)
  return dir ~= nil and dir ~= "" and vim.fn.isdirectory(dir .. "/lua/lib/nvim") == 1
end

---The checkout of lib.nvim: `$LIB_NVIM_DIR`, `$LIB_NVIM_PATH`, `$REPOS_DIR/lib.nvim`, `.deps/lib.nvim` of the plugin, a
---sibling checkout, then lazy.nvim's data folder.
---@return string|nil
local function find_lib()
  local repos = vim.env.REPOS_DIR
  -- Not a list literal: `ipairs` would stop at the first unset variable.
  local candidates = {
    LIB_NVIM_DIR = vim.env.LIB_NVIM_DIR,
    LIB_NVIM_PATH = vim.env.LIB_NVIM_PATH,
    REPOS_DIR = (repos and repos ~= "") and (repos .. "/lib.nvim") or nil,
    deps = plugin_root .. "/.deps/lib.nvim",
    sibling = vim.fs.dirname(plugin_root) .. "/lib.nvim",
    lazy = vim.fn.stdpath("data") .. "/lazy/lib.nvim",
  }
  for _, key in ipairs({ "LIB_NVIM_DIR", "LIB_NVIM_PATH", "REPOS_DIR", "deps", "sibling", "lazy" }) do
    if has_lib(candidates[key]) then
      return candidates[key]
    end
  end
  return nil
end

local lib = find_lib()
if not lib then
  io.stderr:write(
    ("error: lib.nvim not found for %s (set LIB_NVIM_DIR, or REPOS_DIR with a lib.nvim checkout)\n"):format(
      PLUGIN
    )
  )
  os.exit(3)
end
vim.opt.rtp:append(rtp_entry(lib))

local argv = {}
for i = 1, #(arg or {}) do
  argv[#argv + 1] = arg[i]
end

local ok, code = pcall(function()
  return require(MODULE).run(argv)
end)
if not ok then
  io.stderr:write(("error: %s: %s\n"):format(PLUGIN, tostring(code)))
  code = 3
end
io.stdout:flush()
io.stderr:flush()
os.exit(tonumber(code) or 3)
