---@module 'lib.strategies.telemetry_wrap'
--- Self-contained bridge instrumenting the `require("lib")` aggregate via
--- runtime-analysis.telemetry — the one piece the generic wrap/wrap_loaded
--- machinery there cannot do on its own, because the aggregate's key set is
--- metatable-hidden and only `lib.strategies.control` knows how to
--- enumerate and invalidate it.
---
---   require("lib.strategies.telemetry_wrap").setup({ profile_args = false })
---   -- ... later ...
---   require("lib.strategies.telemetry_wrap").teardown()
---
--- `setup()` owns the whole lifecycle — creating the instance, the
--- materialize-then-wrap dance, and starting it — so a caller needs neither
--- `runtime-analysis.telemetry`'s own API nor `lib.strategies.control`'s to
--- instrument lib.nvim's aggregate; this module is the one place that knows
--- both. Soft dependency on runtime-analysis.nvim throughout
--- (`pcall(require, "runtime-analysis.telemetry")`): `setup()` returns `nil`
--- rather than erroring when it is not installed.
---
--- WHY THE MATERIALIZE STEP
--- The aggregate is empty to `pairs()` until a key is touched (see
--- `lib.strategies.control`'s own doc-comment) -- `rawset` shadows `__index`
--- so the instance's own `wrap()` (a plain `pairs()` walk) actually sees the
--- fields, and so the resolved-key cache cannot hand out the pre-wrap value
--- for a key this module just wrapped.
---
--- Idempotent: a second `setup()` call before `teardown()` returns the
--- existing instance rather than creating a second live "lib.nvim"
--- namespace (two instances writing the same cache file, `runtime-analysis.
--- telemetry.new()`'s own documented "already has a live instance" case).

local M = {}

---`require("lib.strategies.telemetry_wrap")` itself.
---@class Lib.Strategies.TelemetryWrap
---@field setup fun(opts?: { namespace?: string, profile_args?: boolean, timing?: boolean, errors?: boolean, persist?: boolean, dir?: string, wrap_opts?: RA.Telemetry.WrapOpts }): RA.Telemetry.Instance|nil
---@field teardown fun(): nil

---@type RA.Telemetry.Instance|nil
local instance = nil
---@type string[]
local lib_keys = {}

---@internal
---Forces every enumerable key onto `lib` via `rawset`, then wraps the
---aggregate and each resolved submodule table with telemetry.
---@param inst RA.Telemetry.Instance
---@param lib table
---@param control table
---@param wrap_opts? RA.Telemetry.WrapOpts
local function instrument_keys(inst, lib, control, wrap_opts)
  for _, key in ipairs(control.keys(lib)) do
    local ok_value, value = pcall(function()
      return lib[key]
    end)
    if ok_value and type(value) == "function" then
      rawset(lib, key, value)
      lib_keys[#lib_keys + 1] = key
    end
  end
  inst.wrap(lib, nil, wrap_opts)
  for _, key in ipairs(control.keys(lib)) do
    local ok_value, value = pcall(function()
      return lib[key]
    end)
    if ok_value and type(value) == "table" then
      inst.wrap(value, key, wrap_opts)
    end
  end
end

---Create a telemetry instance for `require("lib")`'s aggregate, wrap it, and
---start it. Returns `nil` (rather than erroring) when runtime-analysis.nvim
---is not installed — the caller's own soft-dependency point.
---@param opts? { namespace?: string, profile_args?: boolean, timing?: boolean, errors?: boolean, persist?: boolean, dir?: string, wrap_opts?: RA.Telemetry.WrapOpts }
---@return RA.Telemetry.Instance|nil
function M.setup(opts)
  if instance then
    return instance
  end
  opts = opts or {}

  local ok_telemetry, telemetry = pcall(require, "runtime-analysis.telemetry")
  if not ok_telemetry then
    return nil
  end
  local ok_lib, lib = pcall(require, "lib")
  if not ok_lib then
    return nil
  end
  local control = require("lib.strategies.control")

  instance = telemetry.new({
    namespace = opts.namespace or "lib.nvim",
    persist = opts.persist,
    dir = opts.dir,
  })
  instrument_keys(instance, lib, control, opts.wrap_opts)
  instance.start({
    profile_args = opts.profile_args or nil,
    time = opts.timing or nil,
    errors = opts.errors ~= false or nil, -- counted unless opted out, like `telemetry.auto()`
  })

  return instance
end

---Undo `setup()`: stop + unwrap the instance, and remove the `rawset`
---materialization so the aggregate returns to being empty-until-touched.
---A no-op if `setup()` was never called (or already torn down).
function M.teardown()
  if not instance then
    return
  end
  instance.stop()
  instance.unwrap()

  if #lib_keys > 0 then
    local ok_lib, lib = pcall(require, "lib")
    if ok_lib then
      for _, key in ipairs(lib_keys) do
        rawset(lib, key, nil)
      end
      require("lib.strategies.control").reset_cache()
    end
    lib_keys = {}
  end
  instance = nil
end

---@type Lib.Strategies.TelemetryWrap
return M
