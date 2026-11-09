-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read, a uv handle -- this file must crash and name it. The nil
-- guards LuaLS asks for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
-- TESTS/usercmd_registry_spec.lua — lib.nvim.bindings.usercmd's registry + docs
--
-- `nvim_get_commands()` already answers "what commands exist", so the registry
-- earns its keep on the half it cannot: where each one was created. Everything
-- below is about that answer staying true.

return function(H)
  local eq, ok = H.eq, H.ok

  local usercmd = require("lib.nvim.bindings.usercmd")

  ---@param name string
  ---@return Lib.UserCommand.Record|nil
  local function record(name)
    return usercmd.registered({ name = name })[1]
  end

  -- ------------------------------------------------------------- recording
  do
    usercmd.create("SpecUsercmdA", function() end, {
      desc = "spec command A",
      nargs = "*",
      bang = true,
    })

    local r = record("SpecUsercmdA")
    ok(r ~= nil, "create() records the command")
    eq(r.desc, "spec command A", "the desc is recorded")
    eq(r.nargs, "*", "nargs is recorded")
    eq(r.bang, true, "bang is recorded")
    ok(
      r.src:find("usercmd_registry_spec") ~= nil,
      "the call site is recorded, which is the half nvim_get_commands cannot answer"
    )

    -- A completion function is not useful in a document; that it HAS one is.
    usercmd.create("SpecUsercmdB", function() end, {
      desc = "spec command B",
      nargs = 1,
      complete = function()
        return {}
      end,
    })
    eq(record("SpecUsercmdB").complete, "<function>", "a custom completion is recorded as such")

    usercmd.create("SpecUsercmdC", function() end, { desc = "C", nargs = 1, complete = "file" })
    eq(record("SpecUsercmdC").complete, "file", "a builtin completion keeps its name")
  end

  -- `complete = "dir"`: Neovim's own completion lists files as well on Windows (nvim 0.12.2), so create()
  -- completes such a command through getcompletion(lead, "dir") -- on every system, directories only.
  do
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/subdir", "p")
    vim.fn.writefile({ "x" }, dir .. "/afile.txt")
    local cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(dir))
    local ok_cmp, list = pcall(function()
      usercmd.create(
        "SpecUsercmdDir",
        function() end,
        { desc = "D", nargs = "?", complete = "dir" }
      )
      return vim.fn.getcompletion("SpecUsercmdDir ", "cmdline")
    end)
    local ok_tick, ticked = pcall(vim.fn.getcompletion, "SpecUsercmdDir `echo x`", "cmdline")
    vim.cmd("cd " .. vim.fn.fnameescape(cwd))
    ok(ok_cmp, "completing a dir command does not raise: " .. tostring(list))
    eq(#list, 1, "only the directory is offered, not the file: " .. vim.inspect(list))
    eq((vim.fs.normalize(list[1]):gsub("/$", "")), "subdir", "the one candidate is the directory")
    ok(ok_tick, "a lead with a backtick does not raise")
    eq(#ticked, 0, "a lead with a backtick completes to nothing")
    eq(record("SpecUsercmdDir").complete, "dir", "the record still says dir")
    usercmd.delete("SpecUsercmdDir")
    vim.fn.delete(dir, "rf")
  end

  -- `force = true` is the default, so re-creating is normal -- and must
  -- replace the record rather than add a second one, or a re-setup() would
  -- describe every command as many times as setup has run.
  do
    usercmd.create("SpecUsercmdA", function() end, { desc = "replaced" })
    eq(#usercmd.registered({ name = "SpecUsercmdA" }), 1, "re-creating replaces the record")
    eq(record("SpecUsercmdA").desc, "replaced", "the surviving record is the newer one")
  end

  -- ---------------------------------------------------------------- delete
  -- `nvim_del_user_command` alone leaves the record, so a generated page goes
  -- on listing a command that no longer exists.
  do
    eq(usercmd.delete("SpecUsercmdC"), true, "delete() reports success")
    eq(record("SpecUsercmdC"), nil, "delete() forgets the record too")
    eq(
      vim.api.nvim_get_commands({}).SpecUsercmdC,
      nil,
      "delete() removed the command from nvim as well"
    )
  end

  -- ------------------------------------------------------------------ docs
  -- The page is filtered by SOURCE, not by name prefix: a record belongs to a
  -- repo if it was created from a file inside it, whatever it is called.
  do
    local base = (vim.fn.tempname():gsub("\\", "/"))
    local out = base .. "/out"
    vim.fn.mkdir(base .. "/lua/specplugin", "p")
    vim.fn.mkdir(out, "p")

    local file = base .. "/lua/specplugin/init.lua"
    local fd = assert(io.open(file, "w"))
    fd:write([[
      require("lib.nvim.bindings.usercmd").create("SpecDocsCmd", function() end, {
        desc = "spec docs marker",
        nargs = "?",
      })
    ]])
    fd:close()
    dofile(file)

    -- A Windows-shaped root has to match too: every path compared here is
    -- forward-slashed, and `vim.fn.fnamemodify()` does not return one.
    local written_ok, err = usercmd.docs.write({ dir = out, root = base:gsub("/", "\\") })
    eq(written_ok, true, "write() succeeds for a backslashed root: " .. tostring(err))

    local body = assert(io.open(out .. "/commands.md")):read("*a")
    ok(body:find("`:SpecDocsCmd`", 1, true) ~= nil, "the command is on the page")
    ok(body:find("spec docs marker", 1, true) ~= nil, "so is its desc")
    ok(body:find("nargs=?", 1, true) ~= nil, "and the shape of the call")
    ok(
      body:find("lua/specplugin/init.lua", 1, true) ~= nil,
      "the source is relative to the repo root"
    )
    ok(
      body:find("SpecUsercmdA", 1, true) == nil,
      "a command created outside the root is filtered out"
    )

    eq(usercmd.docs.check({ dir = out, root = base }), true, "check() agrees right after a write")

    usercmd.create("SpecDocsCmd2", function() end, { desc = "x", src = file .. ":1" })
    eq(
      usercmd.docs.check({ dir = out, root = base }),
      false,
      "check() reports drift once something new is registered"
    )

    usercmd.delete("SpecDocsCmd")
    usercmd.delete("SpecDocsCmd2")
  end

  usercmd.delete("SpecUsercmdA")
  usercmd.delete("SpecUsercmdB")
end
