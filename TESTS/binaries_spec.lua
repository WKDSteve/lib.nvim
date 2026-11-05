-- TESTS/binaries_spec.lua — lib.nvim.binaries

return function(H)
  local eq, ok = H.eq, H.ok
  local binaries = require("lib.nvim.binaries")
  local saved = vim.g.lib_binaries

  vim.g.lib_binaries = nil
  eq(binaries.mode(), "auto", "the default is auto")
  eq(binaries.guard("x"), true, "auto lets a download through")

  vim.g.lib_binaries = "manual"
  local allowed, why = binaries.guard("x")
  eq(allowed, false, "manual stops an unasked download")
  ok(why and why:find("on request only", 1, true), "and says how it goes")

  vim.g.lib_binaries = "typo"
  eq(binaries.mode(), "manual", "an invalid value is manual, never auto")

  -- fetch: raises the explicit flag, so a fetcher that asks guard() gets through in manual
  local calls, guard_inside = 0, nil
  binaries.register("spec.plugin", {
    fetch = function()
      calls = calls + 1
      guard_inside = binaries.guard("spec.plugin")
      return true
    end,
    status = function()
      return "ok"
    end,
  })
  binaries.register("spec.failing", {
    fetch = function()
      return false, "no network"
    end,
  })
  binaries.register("spec.throwing", {
    fetch = function()
      error("boom")
    end,
  })
  ok(vim.tbl_contains(binaries.registered(), "spec.plugin"), "a plugin registers")
  eq(binaries.status()["spec.plugin"], "ok", "status asks the plugin")

  vim.g.lib_binaries = "manual"
  local res = binaries.fetch("spec.plugin")
  eq(res["spec.plugin"].ok, true, "fetch works in manual")
  eq(guard_inside, true, "...and the download passes the guard meanwhile")
  eq(binaries.guard("x"), false, "afterwards the flag is down again")

  res = binaries.fetch("spec.failing")
  eq(res["spec.failing"].err, "no network", "a failed download reports why")
  res = binaries.fetch("spec.throwing")
  eq(res["spec.throwing"].ok, false, "a throwing fetcher is a failure, not an error")
  eq(binaries.guard("x"), false, "...and does not leave the flag up")
  res = binaries.fetch("spec.unknown")
  ok(res["spec.unknown"].err:find("no binaries registered", 1, true), "an unknown plugin is named")

  vim.g.lib_binaries = "never"
  calls = 0
  res = binaries.fetch("spec.plugin")
  eq(res["spec.plugin"].ok, false, "never refuses fetch too")
  eq(calls, 0, "...without calling the plugin")

  vim.g.lib_binaries = saved
end
