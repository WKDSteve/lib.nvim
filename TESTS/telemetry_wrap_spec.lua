-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read, a uv handle -- this file must crash and name it. The nil
-- guards LuaLS asks for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
-- TESTS/telemetry_wrap_spec.lua — lib.strategies.telemetry_wrap
--
-- The one piece of the old lib.nvim.telemetry test suite that could not move
-- with the rest of it to runtime-analysis.nvim: this specifically exercises
-- `require("lib")`'s own metatable-hidden aggregate, which only exists here.
-- Covers the round-trip this module exists for: `setup()` enumerating the
-- aggregate despite the metatable (`control.keys()`) and installing real
-- dispatchers over real lib.nvim functions, a real call being counted, and
-- `teardown()` restoring the aggregate byte-for-byte -- the same
-- identity-restore property every other telemetry test asserts, just against
-- `require("lib")` specifically instead of a plain table.

return function(H)
  local telemetry_wrap = require("lib.strategies.telemetry_wrap")
  local control = require("lib.strategies.control")
  local lib = require("lib")

  local original_trim = lib.trim

  -- a throwing function inside a wrapped submodule table (removed again below)
  rawset(lib.dict, "spec_boom", function()
    error("boom", 0)
  end)

  -- the wrapper is runtime-analysis.nvim's telemetry (an optional dependency, checked out by the CI): without it
  -- setup() returns nil on purpose, and there is nothing to check here
  if not pcall(require, "runtime-analysis.telemetry") then
    rawset(lib.dict, "spec_boom", nil)
    print(
      "n/a  runtime-analysis.nvim is not on the runtimepath: the telemetry wrapper is not checked here"
    )
    return
  end
  local inst = telemetry_wrap.setup({ namespace = "spec.telemetry_wrap", persist = false })
  H.ok(inst ~= nil, "setup() returns the instance it created")

  local keys = control.keys(lib)
  local has_trim = false
  for _, k in ipairs(keys) do
    if k == "trim" then
      has_trim = true
    end
  end
  H.ok(has_trim, "special-handler keys included, not just MODULE_MAP")

  H.ok(
    lib.trim ~= original_trim,
    'setup() wraps AND starts -- the dispatcher is already installed over the real require("lib") aggregate'
  )
  H.eq(lib.trim("  x  "), "x", "the wrapper is transparent -- a real call still behaves correctly")

  -- errors are counted by default, like `telemetry.auto()`
  H.ok(not pcall(lib.dict.spec_boom), "the wrapper rethrows the error")
  local boom_entry
  for _, e in ipairs(inst.report().entries) do
    if e.key == "dict.spec_boom" then
      boom_entry = e
    end
  end
  H.ok(boom_entry ~= nil, "the throwing function was counted")
  H.eq(boom_entry and boom_entry.errors, 1, "setup() counts thrown errors by default")

  local found = nil
  for _, e in ipairs(inst.report().entries) do
    if e.key == "trim" then
      found = e
    end
  end
  H.ok(found ~= nil, 'the real call through require("lib") was counted')
  H.eq(found.calls, 1, "exactly once")

  H.eq(
    telemetry_wrap.setup({ namespace = "spec.telemetry_wrap", persist = false }),
    inst,
    "a second setup() before teardown() returns the SAME instance, not a second live one"
  )

  telemetry_wrap.teardown()
  rawset(lib.dict, "spec_boom", nil)
  H.eq(lib.trim, original_trim, "teardown() restores the original object exactly")
  H.eq(rawget(lib, "trim"), nil, "...and removes the rawset materialization")
  H.eq(
    lib.trim,
    original_trim,
    "...and the metatable still resolves it to the same function afterward"
  )

  local ok_noop = pcall(telemetry_wrap.teardown)
  H.eq(ok_noop, true, "a second teardown() with nothing set up is a no-op, not an error")
end
