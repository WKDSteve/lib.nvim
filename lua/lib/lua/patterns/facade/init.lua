---@module 'lib.lua.patterns.facade'
--- Facade: one small module API in front of several submodules, loaded lazily.
---
--- Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.
---
--- Each entry is either a module path (`"my.parser"`: the module itself), `"module:function"` (one
--- function out of a module) or a function. Nothing is required until the entry is first used.
---
--- ```lua
--- local facade = require("lib.lua.patterns.facade")
--- return facade.new({
---   parse = "my.parser:parse",        -- require("my.parser").parse
---   render = "my.render:render",
---   config = "my.config",             -- the module table
---   version = function() return "1.0" end,
--- })
--- ```
---
--- This is the same idea as the `lib` aggregator and `lib.lua.lazy`; use this when you want the entry
--- list to be explicit and checkable (`names()`).

require("lib.lua.patterns.facade.@types")

local M = {}

---@param spec table<string, string|function>
---@return table
function M.new(spec)
  if type(spec) ~= "table" then
    error("facade.new: spec must be a table", 2)
  end
  if spec.names ~= nil or spec.loaded ~= nil then
    error("facade.new: 'names' and 'loaded' are reserved entry names", 2)
  end
  for name, entry in pairs(spec) do
    if type(entry) ~= "function" then
      if type(entry) ~= "string" or entry == "" then
        error(
          ("facade.new: entry %q must be a function or a module path string"):format(tostring(name)),
          2
        )
      end
      local _, colons = entry:gsub(":", "")
      if colons > 1 then
        error(("facade.new: entry %q: use 'module' or 'module:function'"):format(tostring(name)), 2)
      end
    end
  end
  local cache = {}
  local api = {}

  local function resolve(name)
    local entry = spec[name]
    if type(entry) == "function" then
      return entry
    end
    local mod, fn = entry:match("^([^:]+):(.+)$")
    if mod then
      local target = require(mod)[fn]
      if target == nil then
        error(("facade: module %q has no %q"):format(mod, fn), 0)
      end
      return target
    end
    return require(entry)
  end

  ---Entry names, sorted.
  ---@return string[]
  function api.names()
    local out = {}
    for name in pairs(spec) do
      out[#out + 1] = name
    end
    table.sort(out)
    return out
  end

  ---Names that have been resolved so far, sorted.
  ---@return string[]
  function api.loaded()
    local out = {}
    for name in pairs(cache) do
      out[#out + 1] = name
    end
    table.sort(out)
    return out
  end

  return setmetatable(api, {
    __index = function(_, name)
      if spec[name] == nil then
        return nil
      end
      if cache[name] == nil then
        cache[name] = resolve(name)
      end
      return cache[name]
    end,
  })
end

return M
