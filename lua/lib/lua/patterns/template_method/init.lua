---@module 'lib.lua.patterns.template_method'
--- Template method: a fixed skeleton whose steps the implementer fills in.
---
--- Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.
---
--- `define(spec)` declares the steps (`required` ones must be supplied, others have a `default`) and the
--- skeleton `run(steps, ...)` that calls them in order. `implement(impl)` checks the steps up front and
--- returns the runnable function.
---
--- ```lua
--- local template_method = require("lib.lua.patterns.template_method")
--- local import = template_method.define({
---   steps = {
---     read = { required = true },
---     parse = { required = true },
---     validate = { default = function(data) return data end },
---   },
---   run = function(step, source)
---     return step.validate(step.parse(step.read(source)))
---   end,
--- })
--- local import_json = import.implement({ read = read_file, parse = vim.json.decode })
--- import_json("a.json")
--- ```
---
--- For classes with overridable methods see `lib.lua.class` (`extend`); this variant needs no class.

require("lib.lua.patterns.template_method.@types")

local M = {}

---@param spec { steps: table<string, { required: boolean|nil, default: function|nil }>, run: fun(steps: table<string, function>, ...): any }
---@return { implement: fun(impl: table<string, function>): function }
function M.define(spec)
  if type(spec) ~= "table" or type(spec.steps) ~= "table" or type(spec.run) ~= "function" then
    error("template_method.define: spec.steps and spec.run are required", 2)
  end
  return {
    implement = function(impl)
      impl = impl or {}
      local steps = {}
      for name, def in pairs(spec.steps) do
        local fn = impl[name] or def.default
        if fn == nil then
          if def.required then
            error(("template_method: required step %q is missing"):format(name), 2)
          end
        elseif type(fn) ~= "function" then
          error(("template_method: step %q must be a function"):format(name), 2)
        end
        steps[name] = fn
      end
      for name in pairs(impl) do
        if not spec.steps[name] then
          error(("template_method: unknown step %q"):format(tostring(name)), 2)
        end
      end
      return function(...)
        return spec.run(steps, ...)
      end
    end,
  }
end

return M
