-- Test code: when something here comes back nil, this file must crash and
-- name it rather than silently skip -- see TESTS/ui_kit_spec.lua's header.
---@diagnostic disable: need-check-nil
-- TESTS/ui_kit_menu_zindex_spec.lua -- lib.nvim.ui.kit.menu opens above the float it is opened
-- from: a menu on the theme's popup level (50) below a snacks picker (52-55) took the focus but
-- could not be seen. Without a float the theme's `zindex.menu` applies; the caller's `zindex` wins.

return function(H)
  local eq, ok = H.eq, H.ok
  local api = vim.api
  local menu = require("lib.nvim.ui.kit.menu")

  local items = { { name = "Rename", cmd = function() end } }

  local function close_floats()
    menu.close()
    for _, w in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_is_valid(w) and api.nvim_win_get_config(w).relative ~= "" then
        pcall(api.nvim_win_close, w, true)
      end
    end
  end

  ---@param zindex integer
  ---@param enter boolean
  ---@param col? integer
  ---@return integer
  local function float(zindex, enter, col)
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, { "float line" })
    return api.nvim_open_win(buf, enter, {
      relative = "editor",
      row = 2,
      col = col or 2,
      width = 20,
      height = 3,
      zindex = zindex,
    })
  end

  ---@param opts table
  ---@return integer
  local function menu_zindex(opts)
    local surf = menu.open(vim.tbl_extend("force", { items = items }, opts))
    ok(surf and surf.winid and api.nvim_win_is_valid(surf.winid), "menu opens")
    local z = api.nvim_win_get_config(surf.winid).zindex
    menu.close()
    return z
  end

  close_floats()
  local theme = require("lib.nvim.ui.kit.theme").resolve("menu")

  -- no float around: the theme's menu level, not the popup level
  eq(
    menu_zindex({}),
    theme.zindex.menu,
    "without a float the menu opens on the theme's zindex.menu"
  )

  -- opened from a float above that level: the menu goes above it
  local host = float(100, true)
  local z = menu_zindex({})
  ok(z > 100, ("opened from a float at 100 the menu opens above it (got %s)"):format(z))

  -- the caller's zindex still wins
  eq(menu_zindex({ zindex = 42 }), 42, "an explicit zindex is kept")

  -- a float below the menu level does not pull the menu down
  close_floats()
  float(55, true)
  eq(menu_zindex({}), theme.zindex.menu, "a float at 55 leaves the menu on its own level")

  -- anchored to another float with `win`, the focus elsewhere
  close_floats()
  local other = float(130, false, 30)
  ok(api.nvim_get_current_win() ~= other, "the focus is not in the anchor float")
  z = menu_zindex({ win = other, row = 0, col = 0 })
  ok(z > 130, ("anchored with win to a float at 130 the menu opens above it (got %s)"):format(z))

  close_floats()
  ok(host ~= nil, "host float was created")
end
