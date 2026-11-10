-- TESTS/cli_script_template_spec.lua -- templates/cli_script.lua, run as a real child Neovim.
--
-- The rule it holds: the script is a thin wrapper. The arguments reach MODULE.run unchanged, its number is the exit
-- code, and only the two things the module cannot answer itself become exit 3: lib.nvim not found, the module raised.

return function(H)
  local ok = H.ok

  ---Deep comparison (the shared `H.eq` compares references).
  local function eq(a, b, msg)
    if not vim.deep_equal(a, b) then
      error(("FAIL %s: expected %s, got %s"):format(msg or "", vim.inspect(b), vim.inspect(a)), 2)
    end
  end

  local dir = vim.fn.tempname()
  H.after_spec(function()
    vim.fn.delete(dir, "rf")
  end)

  ---@param path string
  ---@param text string
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  -- answers with its arguments on stdout, a word on stderr, and the exit code named by the first argument
  local MODULE = [=[
local M = {}
function M.run(argv)
  if argv[1] == "raise" then
    error("boom from the module")
  end
  io.stdout:write(vim.json.encode(argv), "\n")
  io.stderr:write("a message\n")
  return tonumber(argv[1]) or 0
end
return M
]=]

  local template = assert(io.open(vim.fn.getcwd() .. "/templates/cli_script.lua", "rb")):read("*a")
  local text = template
    :gsub('local MODULE = "your_plugin.cli"', 'local MODULE = "spec_cli_plugin.cli"')
    :gsub('local PLUGIN = "your%-plugin.nvim"', 'local PLUGIN = "spec.nvim"')
  ok(
    text:find('local MODULE = "spec_cli_plugin.cli"', 1, true),
    "the template names its module where the spec replaces it"
  )
  ok(text:find('local PLUGIN = "spec.nvim"', 1, true), "and its plugin")
  write(dir .. "/plugin/lua/spec_cli_plugin/cli.lua", MODULE)
  local script = dir .. "/plugin/scripts/spec.lua"
  write(script, text)

  local lib_dir = vim.fn.getcwd()
  ok(
    vim.fn.isdirectory(lib_dir .. "/lua/lib/nvim") == 1,
    "the spec runs from the lib.nvim checkout"
  )

  ---Run the script in a child Neovim. Every place the template looks in is blank unless the case sets it, and the
  ---editor's data folder is moved under the spec's, so the machine's own lib.nvim is never found by accident.
  ---@param args string[]
  ---@param env table
  local function run(args, env)
    local data = dir .. "/data"
    vim.fn.mkdir(data, "p")
    local base = {
      NVIM = "",
      NVIM_LISTEN_ADDRESS = "",
      REPOS_DIR = "",
      LIB_NVIM_DIR = "",
      LIB_NVIM_PATH = "",
      XDG_DATA_HOME = data,
      LOCALAPPDATA = data,
    }
    local cmd = { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", script }
    vim.list_extend(cmd, args)
    return vim.system(cmd, { text = true, env = vim.tbl_extend("force", base, env) }):wait(60000)
  end

  -- the arguments reach the module unchanged, its stdout stays clean, the code is the module's
  local done = run({ "0", "--format=json", "two words" }, { LIB_NVIM_DIR = lib_dir })
  eq(done.code, 0, "the module's 0; stderr: " .. tostring(done.stderr))
  eq(
    vim.json.decode((done.stdout:gsub("\r", ""))),
    { "0", "--format=json", "two words" },
    "argv, unchanged"
  )
  ok(done.stderr:find("a message", 1, true), "the module's messages stay on stderr")

  eq(run({ "1" }, { LIB_NVIM_DIR = lib_dir }).code, 1, "the module's 1")
  eq(
    run({ "2" }, { LIB_NVIM_PATH = lib_dir }).code,
    2,
    "the module's 2, lib.nvim found through LIB_NVIM_PATH"
  )

  -- what the module cannot answer: it raised, lib.nvim is missing
  local raised = run({ "raise" }, { LIB_NVIM_DIR = lib_dir })
  eq(raised.code, 3, "a raising module is exit 3")
  ok(
    raised.stderr:find("spec.nvim", 1, true) and raised.stderr:find("boom from the module", 1, true),
    raised.stderr
  )
  eq(raised.stdout, "", "nothing on stdout")

  local no_lib = run({ "0" }, {})
  eq(no_lib.code, 3, "no lib.nvim is exit 3; stderr: " .. tostring(no_lib.stderr))
  ok(no_lib.stderr:find("lib.nvim not found for spec.nvim", 1, true), no_lib.stderr)
  eq(no_lib.stdout, "", "nothing on stdout")
end
