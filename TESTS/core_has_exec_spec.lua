-- TESTS/core_has_exec_spec.lua — lib.nvim.core.has_exec/first_available go through
-- lib.nvim.cross.executable (memo + $PATH index) instead of one vim.fn.executable() per name.
--
-- Why: on Windows a missing name costs a walk of every $PATH entry times every $PATHEXT
-- extension (~80 ms each, 78 PATH entries, measured 2026-11-21). lib.nvim.deps asks
-- first_available() for a tool and its alternatives -- hover.nvim's browser lookup asked for
-- eight names and froze the first page shot ~640 ms. Both modules are replaced by stand-ins
-- here, so the spec is the same on every platform.

return function(H)
  local eq = H.eq

  local real_exec = package.loaded["lib.nvim.cross.executable"]
  local real_index = package.loaded["lib.nvim.cross.executable.index"]
  local real_fn_executable = vim.fn.executable

  local asked, cleared, builds = {}, {}, 0
  local present = { ["found-tool"] = true }
  local ready = false

  package.loaded["lib.nvim.cross.executable"] = {
    exists = function(name)
      asked[#asked + 1] = name
      return present[name] == true
    end,
    clear = function(name)
      cleared[#cleared + 1] = name
    end,
  }
  package.loaded["lib.nvim.cross.executable.index"] = {
    supported = function()
      return true
    end,
    ready = function()
      return ready
    end,
    build = function()
      builds = builds + 1
      ready = true
    end,
  }
  local native = 0
  vim.fn.executable = function()
    native = native + 1
    return 0
  end

  local ok, err = pcall(function()
    local core = require("lib.nvim.core")

    eq(core.has_exec("found-tool"), true, "has_exec answers through cross.executable")
    eq(core.has_exec("missing-tool"), false, "a missing name too")
    H.ok(vim.deep_equal(asked, { "found-tool", "missing-tool" }), "both asked of cross.executable")
    eq(native, 0, "no vim.fn.executable() of its own")

    asked = {}
    eq(
      core.first_available({ "a", "b", "found-tool", "c" }),
      "found-tool",
      "first_available still answers the first found name"
    )
    eq(builds, 1, "several candidates: the $PATH index is built first")
    H.ok(vim.deep_equal(asked, { "a", "b", "found-tool" }), "and stops at the first hit")

    builds, asked = 0, {}
    core.first_available({ "x", "y", "z" })
    eq(builds, 0, "an index already built is not built again")

    ready, builds = false, 0
    core.first_available({ "found-tool" })
    eq(builds, 0, "one or two names: no index for them alone")

    core.forget_exec("missing-tool")
    H.ok(
      vim.deep_equal(cleared, { "missing-tool" }),
      "forget_exec drops the name in cross.executable"
    )
  end)

  package.loaded["lib.nvim.cross.executable"] = real_exec
  package.loaded["lib.nvim.cross.executable.index"] = real_index
  vim.fn.executable = real_fn_executable
  if not ok then
    error(err, 0)
  end
end
