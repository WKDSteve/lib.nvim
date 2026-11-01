---@module 'lib.lua.patterns.adapter'
--- Adapter: give a foreign object the interface the caller expects.
---
--- Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.
---
--- `adapter.new(interface, adaptee, map)` returns a table with exactly the methods listed in `interface`.
--- Each entry of `map` is either the name of an adaptee method (forwarded as is) or a function
--- `(adaptee, ...)` for anything that needs translation. A method that is neither mapped nor present
--- under the same name on the adaptee raises at construction, not at the first call.
---
--- ```lua
--- local adapter = require("lib.lua.patterns.adapter")
--- local explorer = adapter.new({ "refresh", "current_path" }, nvim_tree_api, {
---   refresh = function(api) api.tree.reload() end,
---   current_path = "get_node_path",
--- })
--- explorer.refresh()
--- ```

require("lib.lua.patterns.adapter.@types")

local M = {}

---@param interface string[]
---@param adaptee table
---@param map table<string, string|function>|nil
---@return table
function M.new(interface, adaptee, map)
  map = map or {}
  local out = {}
  for _, name in ipairs(interface) do
    local target = map[name] or name
    if type(target) == "function" then
      out[name] = function(...)
        return target(adaptee, ...)
      end
    else
      if type(adaptee[target]) ~= "function" then
        error(
          ("adapter.new: cannot provide %q (adaptee has no function %q)"):format(name, target),
          2
        )
      end
      out[name] = function(...)
        return adaptee[target](...)
      end
    end
  end
  return out
end

return M
