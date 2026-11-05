---@module 'lib.nvim.binaries'
-- =========================================================
-- Whether a plugin may download a binary (a server, a release asset) on its own.
--
-- One setting for all own plugins instead of one per plugin: `vim.g.lib_binaries`.
--   "auto"    (default) a plugin downloads what it needs on first use
--   "manual"  nothing is downloaded unasked; `fetch()` (a user command, a CLI) downloads on request
--   "never"   nothing is downloaded, `fetch()` refuses too
--
-- A plugin that downloads asks `guard(name)` right before the download and registers a fetcher with
-- `register(name, { fetch = ... })` so that `fetch(name)` can run it on request. A value that is not one of
-- the three counts as "manual": a typo must not switch downloads on.
-- =========================================================

local M = {}

---@type string[]
M.MODES = { "auto", "manual", "never" }

---@type table<string, Lib.Binaries.Spec>
local registry = {}

-- >0 while `fetch()` runs: the user asked for it, so "manual" lets the download through
local explicit = 0

---The setting, normalised.
---@return "auto"|"manual"|"never"
function M.mode()
  local value = vim.g.lib_binaries
  if value == nil then
    return "auto"
  end
  if vim.tbl_contains(M.MODES, value) then
    return value
  end
  return "manual"
end

---May `name` download a binary now? Ask right before the download.
---@param name string Plugin name, for the message
---@return boolean allowed
---@return string|nil why Set when not allowed
function M.guard(name)
  local mode = M.mode()
  if mode == "auto" or (mode == "manual" and explicit > 0) then
    return true, nil
  end
  if mode == "never" then
    return false, ('%s: downloading binaries is off (vim.g.lib_binaries = "never")'):format(name)
  end
  return false,
    ('%s: downloading binaries is on request only (vim.g.lib_binaries = "manual"); fetch them by hand'):format(
      name
    )
end

---Register how a plugin downloads its binaries (call at load time, cheap).
---@param name string
---@param spec Lib.Binaries.Spec
function M.register(name, spec)
  registry[name] = spec
end

---@return string[] names Sorted
function M.registered()
  local names = vim.tbl_keys(registry)
  table.sort(names)
  return names
end

---One line per registered plugin: what is there.
---@return table<string, string>
function M.status()
  local out = {}
  for name, spec in pairs(registry) do
    local ok, text = pcall(function()
      return spec.status and spec.status() or "registered"
    end)
    out[name] = ok and text or ("status failed: " .. tostring(text))
  end
  return out
end

---@param name string
---@return Lib.Binaries.Result
local function fetch_one(name)
  local spec = registry[name]
  if not spec then
    return { ok = false, err = "no binaries registered for " .. name }
  end
  local called, ok, err = pcall(spec.fetch)
  if not called then
    return { ok = false, err = tostring(ok) }
  end
  if not ok then
    return { ok = false, err = err or "download failed" }
  end
  return { ok = true }
end

---Download the binaries of one plugin, or of all registered ones, on request.
---@param name? string
---@return table<string, Lib.Binaries.Result> results
function M.fetch(name)
  local results = {}
  local names = name and { name } or M.registered()
  if M.mode() == "never" then
    for _, n in ipairs(names) do
      results[n] = { ok = false, err = select(2, M.guard(n)) }
    end
    return results
  end
  explicit = explicit + 1
  for _, n in ipairs(names) do
    results[n] = fetch_one(n)
  end
  explicit = explicit - 1
  return results
end

return M
