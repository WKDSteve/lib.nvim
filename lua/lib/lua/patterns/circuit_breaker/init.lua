---@module 'lib.lua.patterns.circuit_breaker'
--- Circuit breaker: after `threshold` consecutive failures stop calling the protected function for
--- `reset_ms`, then let one probe call through (half-open). A successful probe closes the circuit, a
--- failed one opens it again.
---
--- Status: idea pool — no consumer in the author's plugins yet; kept as a reference until one appears.
---
--- ```lua
--- local breaker = require("lib.lua.patterns.circuit_breaker").new({ threshold = 3, reset_ms = 30000 })
--- local ok, value_or_err = breaker:call(fetch, url)
--- -- circuit open: ok == false, value_or_err == "circuit open"
--- ```
---
--- The clock is injectable (`opts.now`, milliseconds) so tests do not sleep. The default uses
--- `vim.uv.hrtime()` when available and `os.time()` otherwise.

require("lib.lua.patterns.circuit_breaker.@types")

local M = {}

local function default_now()
  local editor = rawget(_G, "vim")
  local uv = editor and (editor.uv or editor.loop)
  if uv and uv.hrtime then
    return uv.hrtime() / 1e6
  end
  return os.time() * 1000
end

---@class Lib.Patterns.CircuitBreaker
local B = {}
B.__index = B

---@param opts Lib.Patterns.CircuitBreaker.Opts|nil
---@return Lib.Patterns.CircuitBreaker
function M.new(opts)
  opts = opts or {}
  for _, key in ipairs({ "now", "on_change" }) do
    if opts[key] ~= nil and type(opts[key]) ~= "function" then
      error(("circuit_breaker.new: opts.%s must be a function"):format(key), 2)
    end
  end
  local function number(key, default, min)
    local v = opts[key]
    if v == nil then
      return default
    end
    if type(v) ~= "number" or v ~= v or v < min then
      error(("circuit_breaker.new: opts.%s must be a number >= %s"):format(key, min), 3)
    end
    return v
  end
  return setmetatable({
    threshold = number("threshold", 5, 1),
    reset_ms = number("reset_ms", 30000, 0),
    now = opts.now or default_now,
    on_change = opts.on_change,
    failures = 0,
    opened_at = nil,
    probing = false,
    current = "closed",
  }, B)
end

---@param self Lib.Patterns.CircuitBreaker
local function set_state(self, s)
  if self.current ~= s then
    local old = self.current
    self.current = s
    if self.on_change then
      pcall(self.on_change, s, old)
    end
  end
end

---`"closed"`, `"open"` or `"half_open"`. An open circuit whose pause is over reports `"half_open"`.
---@return string
function B:state()
  if self.current == "open" and self.now() - self.opened_at >= self.reset_ms then
    set_state(self, "half_open")
  end
  return self.current
end

---Call `fn(...)` through the breaker.
---@param fn function
---@param ... any
---@return boolean ok # false if the circuit was open or `fn` raised
---@return any value_or_err
function B:call(fn, ...)
  local st = self:state()
  if st == "open" or (st == "half_open" and self.probing) then
    return false, "circuit open"
  end
  if st == "half_open" then
    self.probing = true
  end
  local ok, res = pcall(fn, ...)
  self.probing = false
  if ok then
    self.failures = 0
    self.opened_at = nil
    set_state(self, "closed")
    return true, res
  end
  self.failures = self.failures + 1
  if st == "half_open" or self.failures >= self.threshold then
    self.opened_at = self.now()
    set_state(self, "open")
  end
  return false, res
end

---Force the circuit closed and forget the failure count.
function B:reset()
  self.failures = 0
  self.opened_at = nil
  self.probing = false
  set_state(self, "closed")
end

return M
