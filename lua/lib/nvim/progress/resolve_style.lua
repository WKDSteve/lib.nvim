---@module 'lib.nvim.progress.resolve_style'
---Resolve a `Lib.Progress.Style` request to a concrete, loadable implementation.
---Mirrors the ripgrep/vimgrep auto-detection used elsewhere in these plugins:
---prefer the richer UI when available, otherwise fall back to something that
---always works without extra dependencies.

require("lib.nvim.progress.@types")

---Style name -> module that implements it. "float"/"kit" are opt-in only: both are more intrusive
---(an interactive window) and must be requested explicitly, never picked automatically.
---@type table<string, string>
local STYLES = {
  statusline = "lib.nvim.progress.styles.statusline",
  echo = "lib.nvim.progress.styles.echo",
  fidget = "lib.nvim.progress.styles.fidget",
  notify = "lib.nvim.progress.styles.notify",
  float = "lib.nvim.progress.styles.float",
  kit = "lib.nvim.progress.styles.kit",
}

local FALLBACK = "lib.nvim.progress.styles.notify"

---@internal
---@param want Lib.Progress.Style|nil
---@return Lib.Progress.StyleImpl
local function resolve_style(want)
  -- "auto" (default) or unrecognized: prefer fidget, else notify
  local module = STYLES[want or "auto"] or STYLES.fidget
  -- fidget is a soft dependency: without it the always-available notify style takes over
  if module == STYLES.fidget and not pcall(require, "fidget") then
    module = FALLBACK
  end
  return (require(module))
end

return resolve_style
