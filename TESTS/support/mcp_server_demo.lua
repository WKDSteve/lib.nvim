-- A demo server on lib.nvim.mcp.server for TESTS/mcp_server_spec.lua, run as a real process:
--   nvim --headless -u NONE -l TESTS/support/mcp_server_demo.lua
-- Its tools print and notify on purpose: neither may reach stdout, which carries the protocol only.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
vim.opt.rtp:prepend(vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(here))))

local mcp_server = require("lib.nvim.mcp.server")

local s = mcp_server.new({ name = "demo.nvim", version = "9.9.9", instructions = "demo tools" })
s:add("demo_echo", {
  description = "Echo the arguments",
  input_schema = { type = "object", properties = { text = { type = "string" } } },
  run = function(args)
    print("a stray print")
    vim.notify("a stray notify")
    return mcp_server.text({ echoed = args.text })
  end,
})
s:add("demo_boom", {
  description = "Fails",
  run = function()
    error("boom on purpose", 0)
  end,
})

os.exit(s:serve())
