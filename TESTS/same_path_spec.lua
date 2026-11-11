-- TESTS/same_path_spec.lua — lib.nvim.fs.same_path and lib.nvim.cross.platform.case_blind

return function(H)
  local eq = H.eq
  local same_path = require("lib.nvim.fs.same_path")
  local case_blind = require("lib.nvim.cross.platform.case_blind")

  -- surface
  eq(type(same_path), "function", "same_path: module is a function")
  eq(type(case_blind()), "boolean", "case_blind: returns a boolean")
  eq(require("lib").same_path, same_path, "same_path: reachable as lib.same_path")
  eq(require("lib").case_blind, case_blind, "case_blind: reachable as lib.case_blind")
  eq(require("lib.nvim.cross").case_blind, case_blind, "case_blind: reachable as cross.case_blind")

  -- case_blind follows the platform
  local expected = require("lib.nvim.cross.platform.is_windows")()
    or require("lib.nvim.cross.platform.is_macos")()
  eq(case_blind(), expected, "case_blind: windows or macos")

  -- spelling differences that never depend on case
  eq(same_path("/a/b", "/a/b"), true, "identical")
  eq(same_path("/a/b", "/a//b/"), true, "duplicate and trailing separators")
  eq(same_path("/a/b", "/a/c"), false, "different leaf")
  eq(same_path("/a/b", "/a/b/c"), false, "parent is not child")
  eq(same_path("/", "/"), true, "root")
  eq(same_path("a", 1), false, "non-string is false")

  -- case: explicit opts decide, the default follows case_blind()
  eq(same_path("/A/b", "/a/B", { ignore_case = true }), true, "ignore_case = true folds")
  eq(same_path("/A/b", "/a/B", { ignore_case = false }), false, "ignore_case = false is exact")
  eq(same_path("/A/b", "/a/B"), case_blind(), "default follows case_blind()")
  eq(same_path("/Ärger", "/ärger", { ignore_case = true }), true, "non-ASCII letters fold")

  -- realpath is off by default (no syscalls), on when asked
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  eq(same_path(dir, dir .. "/", { realpath = true }), true, "realpath: trailing slash")
  eq(same_path(dir, vim.fs.normalize(dir), { realpath = true }), true, "realpath: normalized spelling")
  vim.fn.delete(dir, "d")
end
