-- TESTS/container/open_default_linux.lua -- runs INSIDE the Linux container (testing.container), started by
-- TESTS/cross_open_default_container_spec.lua:
--
--   nvim --headless --clean -u NONE -l TESTS/container/open_default_linux.lua <repos dir>
--
-- cross.open_default on real Linux must hand the target to `xdg-open` as ONE untouched argument. A stub
-- `xdg-open` in front of PATH records its argument vector. Prints `OPEN_OK` on success.

local repos = assert(arg and arg[1], "usage: open_default_linux.lua <repos dir>")
vim.opt.rtp:prepend(repos .. "/lib.nvim")

-- The container shares the WSL2 kernel of the podman machine ("microsoft" in the release string); the
-- userland is plain Linux, so the WSL branch (wslpath, explorer.exe) must not be taken.
package.loaded["lib.nvim.cross.platform.is_wsl"] = function()
  return false
end

local home = assert(vim.env.HOME)
local bin, log = home .. "/bin", home .. "/xdg-open.log"
vim.fn.mkdir(bin, "p")
local stub = bin .. "/xdg-open"
vim.fn.writefile(
  { "#!/bin/sh", 'for a in "$@"; do printf "%s\n" "$a" >> ' .. log .. "; done" },
  stub
)
vim.uv.fs_chmod(stub, tonumber("755", 8))

local open_default = require("lib.nvim.cross.open_default")

local function open(target)
  vim.fn.delete(log)
  local code
  local okc, err = open_default(target, {
    on_exit = function(c)
      code = c
    end,
  })
  assert(okc, "open_default refused: " .. tostring(err))
  assert(
    vim.wait(10000, function()
      return code ~= nil
    end, 50),
    "xdg-open never exited"
  )
  assert(code == 0, "xdg-open exit " .. code)
  return vim.fn.readfile(log)
end

vim.env.PATH = bin .. ":" .. vim.env.PATH

local url = "https://example.com/a?b=1&c=%3F"
assert(vim.deep_equal(open(url), { url }), "the URL must arrive as one untouched argument")

local file = home .. "/my doc & notes.pdf"
vim.fn.writefile({ "x" }, file)
assert(
  vim.deep_equal(open(file), { file }),
  "a path with a space and & must arrive as one argument"
)

-- without xdg-open the call says so and starts nothing
vim.env.PATH = "/nonexistent"
local okn, err = open_default(file)
assert(
  okn == false and tostring(err):find("xdg-open not found", 1, true),
  "missing xdg-open must be reported: " .. tostring(err)
)

print("OPEN_OK")
