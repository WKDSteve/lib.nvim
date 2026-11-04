-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read -- this file must crash and name it. The nil guards LuaLS asks
-- for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
---@diagnostic disable: missing-fields
-- TESTS/usrcmds_help_spec.lua -- every flag, key=value pair and positional argument of the `:Lib`
-- verb has a line in the composer's option float.
--
-- `:Lib` is assembled from three places: `lib.nvim_usrcmds.usrcmds` (helptags, cwd-here,
-- ps-profile), `lib.nvim.notify.popup.routes()` (`:Lib notify ...`) and `lib.nvim.deps.routes()`
-- (`:Lib deps ...`, with the `DEPS_PLUGIN` type). A new option or argument without a text shows up
-- as a bare row in the cheatsheet, so this fails until it is described.

return function(H)
  local eq, ok = H.eq, H.ok

  local composer = require("lib.nvim.bindings.usercmd.composer")

  -- Every optional route on, so the verb carries everything it can.
  require("lib.nvim_usrcmds.usrcmds").lib_verb({ powershell_profile = true, deps = true })
  local handle = composer.registry().Lib
  ok(handle ~= nil, ":Lib is registered through the composer")

  local function names(list)
    local out = {}
    for _, m in ipairs(list) do
      out[#out + 1] = ("%s %s %s"):format(m.kind, m.route, m.name)
    end
    return table.concat(out, ", ")
  end

  local missing = composer.help.undocumented("Lib", { args = true })
  eq(#missing, 0, ":Lib entries without a help text: " .. names(missing))

  -- The texts follow the house style: one line, no trailing period, at most 80 characters.
  local texts = {}
  for _, route in ipairs(handle:spec().routes) do
    for _, arg in ipairs(route.args or {}) do
      if arg.desc then
        texts[#texts + 1] = arg.desc
      end
    end
  end
  local def = require("lib.nvim.bindings.usercmd.composer.argtypes").get("DEPS_PLUGIN")
  ok(def ~= nil, "DEPS_PLUGIN is a registered argument type")
  ok(def.desc ~= nil and def.desc ~= "", "DEPS_PLUGIN has a help text")
  texts[#texts + 1] = def.desc

  ok(#texts >= 4, "the argument texts were found (notify history/clear, deps show, the type)")
  local malformed = {}
  for _, text in ipairs(texts) do
    if text:find("\n", 1, true) or text:sub(-1) == "." or #text > 80 then
      malformed[#malformed + 1] = text
    end
  end
  eq(#malformed, 0, "one line, no trailing period, <= 80 chars: " .. table.concat(malformed, " | "))

  pcall(vim.api.nvim_del_user_command, "Lib")
end
