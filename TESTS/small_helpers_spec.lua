-- TESTS/small_helpers_spec.lua — lib.nvim.fs.norm, lib.nvim.bindings.usercmd.prefix,
-- lib.nvim.cross.shell_quote.single: the helpers the fleet report found copied into many plugins.

return function(H)
  local eq, ok = H.eq, H.ok

  -- fs.norm ------------------------------------------------------------------
  local norm = require("lib.nvim.fs.norm")
  eq(norm("c:\\Users\\me\\"), "C:/Users/me", "norm: backslashes, drive letter, trailing slash")
  eq(norm("C:/"), "C:/", "norm: a drive root keeps its slash")
  eq(norm("/"), "/", "norm: the POSIX root keeps its slash")
  eq(norm(""), "", "norm: empty stays empty")
  eq(norm("a/b/"), "a/b", "norm: relative path loses the trailing slash")
  eq(norm("//srv/share/"), "//srv/share", "norm: a UNC prefix is kept")
  eq(require("lib.nvim.fs.fast").norm("c:/a/"), "C:/a", "fast.norm spells a path the same way")

  -- usercmd.prefix -----------------------------------------------------------
  local prefix = require("lib.nvim.bindings.usercmd.prefix")
  eq(
    vim.inspect(prefix({ "open", "on", "off" }, "o")),
    vim.inspect({ "open", "on", "off" }),
    "prefix: all match"
  )
  eq(vim.inspect(prefix({ "open", "on", "off" }, "of")), vim.inspect({ "off" }), "prefix: filters")
  eq(
    vim.inspect(prefix({ "Open", "open" }, "o")),
    vim.inspect({ "open" }),
    "prefix: case is significant"
  )
  eq(vim.inspect(prefix({ "a" }, "ab")), vim.inspect({}), "prefix: lead longer than the candidate")
  local list = { "x" }
  ok(prefix(list, "") == list, "prefix: an empty lead returns the list itself")
  local at = require("lib.nvim.bindings.usercmd.composer.argtypes").prefix
  eq(
    vim.inspect(at({ "ab", "b" }, "a")),
    vim.inspect({ "ab" }),
    "argtypes.prefix filters the same way"
  )

  -- cross.shell_quote.single -------------------------------------------------
  local single = require("lib.nvim.cross.shell_quote").single
  eq(single("abc"), "'abc'", "single: a plain word is still quoted")
  eq(single("it's"), "'it'\\''s'", "single: an inner quote is closed, escaped and reopened")
  eq(single(""), "''", "single: the empty word")
  eq(single("a b;$(x)"), "'a b;$(x)'", "single: shell syntax stays inside the quotes")
end
