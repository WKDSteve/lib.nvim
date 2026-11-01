---@module 'lib.nvim.registry'
--- A generic registry: who is responsible for X, self-registration, deterministic order, `reset()` for tests.
---
--- The pattern turns up everywhere a plugin has "one entry per language / verb / backend / renderer": a name
--- (or any key) maps to a value, entries register themselves (a backend module calls `register` when it is
--- required), lookups are answered in **registration order** (never `pairs()` order, so a scan or a generated
--- doc is the same on every run), and a test can start from an empty one.
---
--- Extracted from `docmap.nvim`'s `lang_registry` and `usercmd.composer.registry`. Domain rules stay
--- with the owner (which backend claims a file name, a scan-scoped filter ...): this holds the entries.
---
--- ```lua
--- local registry = require("lib.nvim.registry")
---
--- local langs = registry.new({
---   name = "lang",
---   validate = function(key, backend)
---     return type(backend.is_source) == "function", "a backend needs is_source()"
---   end,
---   -- run once, before the first read: the one place that names the backend modules
---   loader = function()
---     require("my.lang.lua")
---     require("my.lang.python")
---   end,
--- })
---
--- langs:register("lua", { is_source = function(f) return f:match("%.lua$") ~= nil end })
--- langs:get("lua")
--- langs:find(function(key, backend) return backend.is_source("a.lua") end)  --> "lua", backend
--- langs:keys()      --> { "lua", "python" } (registration order)
--- langs:reset()     -- tests: empty again; the loader runs again before the next read
--- ```

local ordered_map = require("lib.lua.ordered_map")

local M = {}

---@class Lib.Registry.Opts
---@field name? string                                       # Used in messages (default "registry").
---@field validate? fun(key: any, value: any): boolean?, string?  # Refuse a registration: return false/nil (+ reason).
---@field loader? fun()                                      # Runs once before the first read (and again after `reset`).
---@field on_duplicate? "replace"|"keep"|"error"             # Same key twice (default "replace", keeping its position).

---@class Lib.Registry
---@field private _name string
---@field private _map Lib.Lua.OrderedMap  # key -> value in registration order
---@field private _validate? function
---@field private _loader? function
---@field private _loaded boolean
---@field private _seeded? table<any, true>     # Keys a failed loader run left behind.
---@field private _tolerated? table<any, true>  # While the loader re-runs: those keys, each may be registered once more.
---@field private _recording? table<any, true>  # While the loader runs: the keys it registers.
---@field private _on_duplicate string
local Registry = {}
Registry.__index = Registry

---Run the loader once. Marked loaded BEFORE it runs: a loader module that registers itself by calling
---back into this registry (the usual shape) must not recurse into the loader again.
---@private
function Registry:_ensure()
  if self._loaded then
    return
  end
  self._loaded = true
  if self._loader then
    -- the run after a failed one registers the keys the failed run left behind again: once each, that is
    -- no duplicate (any other collision still is one)
    self._tolerated = self._seeded
    self._recording = {}
    local ok, err = pcall(self._loader)
    local recorded = self._recording
    self._tolerated, self._recording = nil, nil
    if not ok then
      -- not "loaded": the next read runs it again instead of serving a half-filled registry in silence
      self._loaded = false
      self._seeded = vim.tbl_extend("force", self._seeded or {}, recorded)
      error(err, 0)
    end
    self._seeded = nil
  end
end

---Register `value` under `key`. Returns the registry (chainable).
---
---A key registered twice follows `on_duplicate`: `"replace"` (default) swaps the value and keeps the
---position, `"keep"` leaves the first one, `"error"` raises.
---@param key any   # Not nil.
---@param value any # Not nil.
---@return Lib.Registry
function Registry:register(key, value)
  if key == nil or value == nil then
    error(("lib.nvim.registry (%s): key and value must not be nil"):format(self._name), 2)
  end
  if self._validate then
    local ok, valid, why = pcall(self._validate, key, value)
    if not ok then
      error(
        ("lib.nvim.registry (%s): validate raised for %s: %s"):format(
          self._name,
          tostring(key),
          tostring(valid)
        ),
        2
      )
    end
    if not valid then
      error(
        ("lib.nvim.registry (%s): refused %s%s"):format(
          self._name,
          tostring(key),
          why and (": " .. tostring(why)) or ""
        ),
        2
      )
    end
  end
  if self._map:has(key) then
    if self._on_duplicate == "error" and self._tolerated and self._tolerated[key] then
      self._tolerated[key] = nil -- left by the failed run: replaced once, a second claim is a real duplicate
    elseif self._on_duplicate == "error" then
      error(
        ("lib.nvim.registry (%s): %s is already registered"):format(self._name, tostring(key)),
        2
      )
    elseif self._on_duplicate == "keep" then
      return self
    end
  end
  self._map:put(key, value)
  if self._recording then
    self._recording[key] = true
  end
  return self
end

---Remove one entry. Returns whether there was one.
---@param key any
---@return boolean
function Registry:unregister(key)
  self:_ensure()
  return self._map:delete(key)
end

---@param key any
---@return any|nil
function Registry:get(key)
  self:_ensure()
  return self._map:get(key)
end

---@param key any
---@return boolean
function Registry:has(key)
  self:_ensure()
  return self._map:has(key)
end

---@return integer
function Registry:count()
  self:_ensure()
  return self._map:count()
end

---The keys, in registration order (a fresh list).
---@return any[]
function Registry:keys()
  self:_ensure()
  return self._map:keys()
end

---The values, in registration order (a fresh list). With `pred`, only those it accepts.
---@param pred? fun(key: any, value: any): boolean?
---@return any[]
function Registry:all(pred)
  self:_ensure()
  local out = {}
  self._map:each(function(key, value)
    if pred == nil or pred(key, value) then
      out[#out + 1] = value
    end
  end)
  return out
end

---`{ key, value }` pairs in registration order (a fresh list).
---@return { [1]: any, [2]: any }[]
function Registry:entries()
  self:_ensure()
  local out = {}
  self._map:each(function(key, value)
    out[#out + 1] = { key, value }
  end)
  return out
end

---The first entry (in registration order) `pred` accepts: who is responsible.
---@param pred fun(key: any, value: any): boolean?
---@return any|nil key
---@return any|nil value
function Registry:find(pred)
  self:_ensure()
  local found_key, found_value
  self._map:each(function(key, value)
    if pred(key, value) then
      found_key, found_value = key, value
      return true
    end
  end)
  return found_key, found_value
end

---Drop every entry. The loader (if any) runs again before the next read, so a test starts empty and a
---later read finds the known entries again.
---@return Lib.Registry
function Registry:reset()
  self._map = ordered_map.new()
  self._loaded = false
  self._seeded = nil
  return self
end

---A new, empty registry.
---@param opts? Lib.Registry.Opts
---@return Lib.Registry
function M.new(opts)
  opts = opts or {}
  local dup = opts.on_duplicate or "replace"
  if dup ~= "replace" and dup ~= "keep" and dup ~= "error" then
    error('lib.nvim.registry.new: on_duplicate must be "replace", "keep" or "error"', 2)
  end
  return setmetatable({
    _name = opts.name or "registry",
    _map = ordered_map.new(),
    _validate = opts.validate,
    _loader = opts.loader,
    _loaded = false,
    _on_duplicate = dup,
  }, Registry)
end

return M
