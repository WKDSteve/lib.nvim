-- TESTS/ui_kit_sidebar_foreign_spec.lua -- `kit.sidebar.register_foreign`: a panel that is not a kit sidebar
-- (Neo-tree, filetree.nvim) takes part in slot exclusivity. A fake panel: a split on a scratch buffer.

return function(H)
  local eq, ok = H.eq, H.ok
  local api = vim.api
  local sidebar = require("lib.nvim.ui.kit.sidebar")

  vim.cmd("tabnew")
  local tab = api.nvim_get_current_tabpage()
  local main = api.nvim_get_current_win()

  local function settle()
    vim.wait(60, function()
      return false
    end)
  end

  ---A fake foreign panel on `side` ("left"|"right"|"bottom"): its window is a split of a scratch buffer.
  local function fake_panel(name, position, extra)
    local panel = { buf = api.nvim_create_buf(false, true), hides = 0, shows = 0 }
    function panel.open()
      local cmd = position == "bottom" and "botright split"
        or (position == "left" and "topleft vsplit" or "botright vsplit")
      vim.cmd(cmd)
      panel.win = api.nvim_get_current_win()
      api.nvim_win_set_buf(panel.win, panel.buf)
      api.nvim_set_current_win(main)
    end
    function panel.visible()
      return panel.win ~= nil and api.nvim_win_is_valid(panel.win)
    end
    function panel.close()
      if panel.visible() then
        api.nvim_win_close(panel.win, true)
      end
    end
    panel.handle = sidebar.register_foreign(vim.tbl_extend("force", {
      name = name,
      position = position,
      win = function()
        return panel.visible() and panel.win or nil
      end,
      hide = function()
        panel.hides = panel.hides + 1
        panel.close()
      end,
      show = function()
        panel.shows = panel.shows + 1
        panel.open()
      end,
    }, extra or {}))
    return panel
  end

  local function visible_wins_showing(buf)
    local n = 0
    for _, w in ipairs(api.nvim_tabpage_list_wins(tab)) do
      if api.nvim_win_get_buf(w) == buf then
        n = n + 1
      end
    end
    return n
  end

  -- registration
  ok(not pcall(sidebar.register_foreign, { position = "left" }), "a spec needs win, hide and show")
  ok(not pcall(sidebar.register_foreign, {
    position = "middle",
    win = function() end,
    hide = function() end,
    show = function() end,
  }), "a position must be left, right or bottom")

  -- a kit sidebar takes the slot of a visible foreign panel; closing it brings the panel back
  local tree = fake_panel("fake_tree", "left")
  tree.open()
  eq(visible_wins_showing(tree.buf), 1, "the foreign panel is on screen")
  ok(tree.handle:is_visible(), "...and the kit sees it")

  local kit_side = assert(sidebar.open({ name = "k_tests", position = "left", enter = false }))
  eq(tree.hides, 1, "the kit hid the foreign panel through its own hide callback")
  eq(visible_wins_showing(tree.buf), 0, "...it is off the screen")
  ok(kit_side:is_visible(), "the kit sidebar holds the slot")

  kit_side:close()
  settle()
  eq(tree.shows, 1, "closing the kit sidebar brings the foreign panel back through show")
  eq(visible_wins_showing(tree.buf), 1, "...it is on screen again")

  -- a foreign panel that appears on its own displaces a kit sidebar; hiding it restores the kit sidebar
  tree.close()
  tree.handle:hidden()
  settle()
  local k2 = assert(sidebar.open({ name = "k_two", position = "left", enter = false }))
  ok(k2:is_visible(), "a kit sidebar on the left")
  tree.open()
  tree.handle:shown()
  ok(not k2:is_visible(), "the panel appearing displaced the kit sidebar")
  ok(tree.handle:is_visible(), "...and stays")
  tree.close()
  tree.handle:hidden()
  settle()
  ok(k2:is_visible(), "the panel going away brought the kit sidebar back, once")
  tree.handle:hidden()
  settle()
  eq(#vim.tbl_filter(function(w)
    return api.nvim_win_get_buf(w) == k2.bufnr
  end, api.nvim_tabpage_list_wins(tab)), 1, "a second hidden() restores nothing more")

  -- a hide the kit caused is not reported back as hidden() (no restore loop)
  local before_hides = tree.hides
  tree.open()
  tree.handle:shown()
  ok(not k2:is_visible(), "displaced again")
  eq(tree.hides, before_hides, "shown() displaces the kit sidebar, it does not hide the panel")
  local k3 = assert(sidebar.open({ name = "k_three", position = "left", enter = false }))
  ok(k3:is_visible(), "a new kit sidebar takes the slot")
  eq(tree.hides, before_hides + 1, "...hiding the panel via the callback")
  settle()
  ok(not tree.handle:is_visible(), "the panel stays hidden while k3 holds the slot")
  ok(not k2:is_visible(), "...and k2 did not come back (hidden() ignored the kit's own hide)")
  k3:close()
  settle()
  ok(tree.handle:is_visible(), "closing k3 restores the panel")
  k2:close()
  k3:close()
  tree.close()
  tree.handle:hidden()

  -- non-exclusive foreign panel and other positions displace nothing
  local right = fake_panel("fake_right", "right")
  local k4 = assert(sidebar.open({ name = "k_four", position = "left", enter = false }))
  right.open()
  right.handle:shown()
  ok(k4:is_visible(), "a panel at another position displaces nothing")
  local shared = fake_panel("fake_shared", "left", { exclusive = false })
  shared.open()
  shared.handle:shown()
  ok(k4:is_visible(), "a non-exclusive panel shares the slot")
  shared.close()
  shared.handle:unregister()
  right.close()
  right.handle:unregister()
  k4:close()

  -- unregister forgets it
  tree.open()
  local hides_now = tree.hides
  tree.handle:unregister()
  ok(tree.handle:is_closed(), "unregistered")
  local k5 = assert(sidebar.open({ name = "k_five", position = "left", enter = false }))
  eq(tree.hides, hides_now, "an unregistered panel is not touched any more")
  ok(tree.visible(), "...and stays on screen")
  k5:close()
  tree.close()

  -- close_all forgets foreign handles without hiding them
  local keep = fake_panel("fake_keep", "bottom")
  keep.open()
  sidebar.close_all()
  ok(keep.visible(), "close_all does not close a panel that is not ours")
  ok(keep.handle:is_closed(), "...but forgets it")
  keep.close()

  if api.nvim_tabpage_is_valid(tab) then
    vim.cmd("tabclose")
  end
end
