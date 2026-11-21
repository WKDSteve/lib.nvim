---@module 'lib.nvim.core'
--- Executable-on-PATH lookups (memoized) plus lib.nvim.core's own aggregated
--- helpers, e.g. simple_echo.

local lazy = require("lib.lua.lazy")

local M = {}

---The memoized, $PATH-indexed lookups of `lib.nvim.cross.executable`. Loaded on
---first use: `lib.nvim.core` is required early and must stay cheap to load.
---@return table
local function executable()
  return (require("lib.nvim.cross.executable"))
end

---Whether `bin` is on PATH (or, for a path, is executable). Memoized per name.
---
---Answered by `lib.nvim.cross.executable.exists`: on Windows a name that is
---NOT installed costs a walk of every $PATH entry times every $PATHEXT
---extension (~80 ms each on a 78-entry PATH, measured 2026-11-21), and a tool
---with eight alternative names (hover.nvim's browser lookup) paid that eight
---times, ~640 ms. `cross.executable` switches to an index of $PATH once the
---native lookups cost as much as building it, so every further name is a table
---lookup.
---@param bin string
---@return boolean
function M.has_exec(bin)
  return executable().exists(bin)
end

---Return the first candidate binary found on PATH, or nil if none are.
---Results of `has_exec` are memoized per binary name.
---@param candidates string[]
---@return string|nil
function M.first_available(candidates)
  -- Several names at once (a tool and its alternatives): most of them are usually
  -- missing, and on Windows one missing name already costs more than indexing $PATH
  -- (~80 ms against ~25 ms), so index first.
  if #candidates > 2 then
    local index = require("lib.nvim.cross.executable.index")
    if index.supported() and not index.ready() then
      index.build()
    end
  end
  for _, bin in ipairs(candidates) do
    if M.has_exec(bin) then
      return bin
    end
  end
  return nil
end

---Drop `bin`'s memoized `has_exec` result, so the next call re-probes PATH.
---For the one legitimate case where "not found" can go stale within a
---session: something installed `bin` after `has_exec` first cached it —
---`lib.nvim.deps.view`'s inline install flips a tool's status line from
---`[missing]` to `[ok]` this way once its install finishes. Not needed for
---the opposite direction (PATH losing a binary mid-session is not a case
---any known caller re-checks).
---@param bin string
function M.forget_exec(bin)
  -- also makes `bin` skip an index built before it was installed
  executable().clear(bin)
end

M.simple_echo = lazy.require("lib.nvim.core.simple_echo")

---@type Lib.Nvim.Core
return M
