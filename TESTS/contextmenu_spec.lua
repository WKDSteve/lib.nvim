-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read, a uv handle -- this file must crash and name it. The nil
-- guards LuaLS asks for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
-- TESTS/contextmenu_spec.lua — lib.nvim.contextmenu: entry/group/submenu
-- (pure data builders), renderer selection, and bind_buffer's
-- soft-dependency degradation.
--
-- nvzone/menu is not installed in the test environment, so every path here
-- resolves to the kit renderer — which is the point: what these assert is
-- exactly what has to keep holding once nvzone/menu is dropped.

return function(H)
  local eq = H.eq
  local ok = H.ok
  local contextmenu = require("lib.nvim.contextmenu")

  -- ---------- entry ----------

  do
    eq(contextmenu.entry(false, "X", function() end), nil, "entry: nil when unavailable")
    eq(contextmenu.entry(nil, "X", function() end), nil, "entry: nil for falsy nil")

    local fn = function() end
    local e = contextmenu.entry(true, "  Do X", fn, "<leader>x")
    ok(type(e) == "table", "entry: table when available")
    eq(e.name, "  Do X", "entry: name")
    eq(e.rtxt, "<leader>x", "entry: rtxt")
    eq(e.cmd, fn, "entry: cmd is the passed function")

    local e_no_rtxt = contextmenu.entry(true, "Y", fn)
    eq(e_no_rtxt.rtxt, nil, "entry: rtxt omitted stays nil")
  end

  -- ---------- group ----------

  do
    local out = {}
    local added = contextmenu.group(out, nil, nil)
    eq(added, false, "group: false when every item is nil")
    eq(#out, 0, "group: nothing appended for an all-nil group")

    local a = { name = "A" }
    local b = { name = "B" }
    -- `b` sits after a nil gap — this is exactly the case a table-literal
    -- implementation (`ipairs`/`#`) would silently drop.
    added = contextmenu.group(out, a, nil, b)
    eq(added, true, "group: true when at least one item survives")
    eq(#out, 2, "group: nils dropped, non-nils appended (including past a nil gap)")
    eq(out[1], a, "group: first item in order")
    eq(out[2], b, "group: second item in order, survives despite the preceding nil")

    -- A second group on a non-empty `out` gets a separator prefix.
    local c = { name = "C" }
    contextmenu.group(out, c)
    eq(#out, 4, "group: separator + new item appended")
    eq(out[3].name, "separator", "group: separator inserted before a second group")
    eq(out[4], c, "group: new group's item appended after the separator")

    -- An empty/all-nil group after existing content adds nothing, not even
    -- a dangling separator.
    contextmenu.group(out)
    eq(#out, 4, "group: an empty group adds no separator")
  end

  -- ---------- submenu ----------

  do
    eq(contextmenu.submenu("Label", {}), nil, "submenu: nil for empty items")
    -- The non-table argument is the case.
    ---@diagnostic disable-next-line: param-type-mismatch
    eq(contextmenu.submenu("Label", "not-a-table"), nil, "submenu: nil for non-table items")

    local items = { { name = "A" } }
    local sub = contextmenu.submenu("  MyPlugin", items)
    ok(type(sub) == "table", "submenu: table when items non-empty")
    eq(sub.name, "  MyPlugin", "submenu: name is the label")
    eq(sub.items, items, "submenu: items passed through")
  end

  -- ---------- renderer selection ----------

  do
    eq(contextmenu.renderer(), "auto", "renderer: defaults to auto")

    contextmenu.setup({ renderer = "kit" })
    eq(contextmenu.renderer(), "kit", "renderer: setup narrows it")

    contextmenu.setup({})
    eq(contextmenu.renderer(), "kit", "renderer: setup without the key leaves it alone")

    -- The invalid value is the case under test.
    ---@diagnostic disable-next-line: assign-type-mismatch
    contextmenu.setup({ renderer = "nonsense" })
    eq(contextmenu.renderer(), "kit", "renderer: an unknown value is rejected, not applied")
  end

  -- ---------- native_popup: off by default, opt-out not opt-in ----------

  do
    local saved_mousemodel = vim.o.mousemodel

    vim.o.mousemodel = "popup_setpos"
    contextmenu.setup({ native_popup = true })
    eq(vim.o.mousemodel, "popup_setpos", "native_popup: true leaves 'mousemodel' untouched")

    vim.o.mousemodel = "popup_setpos"
    contextmenu.setup({})
    eq(
      vim.o.mousemodel,
      "extend",
      "native_popup: omitted disables Neovim's own PopUp menu by default"
    )

    vim.o.mousemodel = "popup_setpos"
    contextmenu.setup({ native_popup = false })
    eq(
      vim.o.mousemodel,
      "extend",
      "native_popup: false disables it too, same as omitting the option"
    )

    vim.o.mousemodel = saved_mousemodel
  end

  -- ---------- set_enabled: the renderer/trigger opt-out ----------

  do
    local chooser = require("lib.nvim.ui.kit.chooser")
    contextmenu.setup({ renderer = "kit", native_popup = true })
    eq(contextmenu.is_enabled(), true, "is_enabled: on by default")

    local items = { contextmenu.entry(true, "Do X", function() end) }
    contextmenu.set_enabled(false)
    eq(contextmenu.is_enabled(), false, "set_enabled(false) is reported")
    eq(contextmenu.open(items, { mouse = false }), nil, "open: renders nothing while disabled")
    eq(chooser.is_open(), false, "open: no surface while disabled")
    ok(
      contextmenu.entry(true, "Still", function() end) ~= nil,
      "builders keep working while disabled"
    )

    contextmenu.set_enabled(true)
    local surf = contextmenu.open(items, { mouse = false })
    ok(surf ~= nil, "open: renders again once re-enabled")
    chooser.close()
    vim.o.mousemodel = "popup_setpos"
  end

  -- ---------- open: draws with the kit renderer ----------

  do
    local chooser = require("lib.nvim.ui.kit.chooser")
    contextmenu.setup({ renderer = "kit" })

    local ran
    local out = {}
    contextmenu.group(
      out,
      contextmenu.entry(true, "Do X", function()
        ran = "x"
      end, "<leader>x"),
      contextmenu.entry(true, "Do Y", function()
        ran = "y"
      end)
    )
    contextmenu.group(
      out,
      contextmenu.submenu("Git", {
        contextmenu.entry(true, "Stage", function()
          ran = "stage"
        end),
      })
    )
    eq(#out, 4, "open fixture: two entries, a separator, a submenu")

    --- Wait for the row swap a pick sets off. The menu acknowledges a pick by
    --- lighting the row first (`flash_on_select`), so the new level is not on
    --- screen the instant `submit()` returns -- which is the whole point of
    --- it. Waits for the effect rather than sleeping a fixed span.
    ---@param pattern string  # Lua pattern the new level's first row matches
    local function wait_for_level(pattern)
      local swapped = vim.wait(1000, function()
        local first = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
        return first ~= nil and first:match(pattern) ~= nil
      end, 10)
      ok(swapped, "open: the level swap lands after the pick is acknowledged")
    end

    -- Every spec shares one Neovim, so callbacks other specs left on the
    -- scheduler are still pending here. Run them out first: one of them moves
    -- the focus, and a menu that opens before that lands is dismissed by its
    -- own `close_on_focus_lost` the moment the loop next turns -- which it
    -- does now that a pick is acknowledged before it is acted on.
    vim.wait(50)

    -- `mouse = false`: `relative = "mouse"` needs a real pointer position,
    -- which a headless run has no way to provide.
    contextmenu.open(out, { mouse = false })
    ok(chooser.is_open(), "open: kit renderer opens a chooser")

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    eq(#lines, 4, "open: one row per item, separator included")
    -- One pad column at each edge, so nothing sits flush against the border.
    -- The trailing run is the fly-out marker's column, blank on a leaf: it is
    -- measured across the whole level, so every row reserves it once one item
    -- has children.
    ok(
      lines[1]:match("^ Do X%s+<leader>x%s+$") ~= nil,
      "open: rtxt right-aligned in its own column"
    )
    -- Not a `^─+$` pattern: Lua patterns are byte-based, so `+` would repeat
    -- only the last byte of the multi-byte rule character. The rule carries
    -- the same leading pad column and stops short of the right edge.
    ok((lines[3]:gsub("^ ", ""):gsub("─", "")) == "", "open: separator drawn as a divider rule")
    -- The marker sits between the label and the hint column rather than at the
    -- far right; the trailing run here is this row's empty hint column.
    ok(lines[4]:match("^ Git%s+→%s+$") ~= nil, "open: a submenu entry is marked as one")

    -- Navigation steps over the separator rather than landing on it.
    eq(chooser.current_index(), 1, "open: cursor starts on the first entry")
    chooser.move(1)
    eq(chooser.current_index(), 2, "open: move lands on the second entry")
    chooser.move(1)
    eq(chooser.current_index(), 4, "open: move skips the separator")

    -- <CR> on a separator is inert (it can't be reached by moving, but a
    -- mouse click can put the cursor there).
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    chooser.submit()
    ok(chooser.is_open(), "open: submitting a separator leaves the menu open")
    eq(ran, nil, "open: submitting a separator runs nothing")

    -- Drill into the submenu, then run its leaf. The window and buffer must
    -- be the SAME ones: closing and reopening between levels repaints
    -- whatever is underneath, which reads as the menu flashing, and it
    -- re-anchors a `relative = "mouse"` menu to wherever the pointer drifted.
    local top_win, top_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    local top_pos = vim.fn.win_screenpos(top_win)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    chooser.submit()
    -- Held back for the length of the flash: the parent's rows are still the
    -- ones on screen, and the row that was picked is the one lit.
    eq(
      vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:match("^ Do X") ~= nil,
      true,
      "open: the level swap waits while the picked row is lit"
    )
    wait_for_level("^ ◂ Back")
    eq(vim.api.nvim_get_current_win(), top_win, "open: drilling down reuses the same window")
    eq(vim.api.nvim_get_current_buf(), top_buf, "open: drilling down reuses the same buffer")
    eq(
      table.concat(vim.fn.win_screenpos(top_win), ","),
      table.concat(top_pos, ","),
      "open: drilling down leaves the window where it was"
    )
    -- The child level names itself on the frame; the top level has no title,
    -- and walking back has to actually remove the child's rather than leave
    -- it standing (an omitted title is "unchanged" to nvim_win_set_config).
    local function frame_title()
      local cfg = vim.api.nvim_win_get_config(top_win)
      return cfg.title and cfg.title[1] and cfg.title[1][1] or nil
    end
    eq(frame_title(), "Git", "open: a nested level puts its label on the frame")
    local sub_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    -- A nested level leads with the back entry and a divider, so the menu is
    -- leavable with the mouse and not only with <BS>.
    ok(sub_lines[1]:match("^ ◂ Back") ~= nil, "open: a nested level opens with a back entry")
    ok(
      (sub_lines[2]:gsub("^ ", ""):gsub("─", "")) == "",
      "open: back entry is separated from the children"
    )
    -- Three columns of indent, not one: the back entry carries an icon, so
    -- the whole level reserves the icon column -- including "Stage", which
    -- has none of its own. That is the alignment guarantee.
    ok(sub_lines[3]:match("^   Stage") ~= nil, "open: picking a submenu drills into its children")

    -- Back out with the entry itself, then drill in again.
    eq(chooser.current_index(), 1, "open: the cursor starts on the back entry")
    chooser.submit()
    wait_for_level("^ Do X")
    ok(
      vim.api.nvim_buf_get_lines(0, 0, -1, false)[1]:match("^ Do X") ~= nil,
      "open: the back entry returns to the parent level"
    )
    eq(ran, nil, "open: going back runs no action")
    eq(frame_title(), nil, "open: going back clears the child level's title")
    -- The parent must not have grown a back entry of its own on the way back.
    eq(#vim.api.nvim_buf_get_lines(0, 0, -1, false), 4, "open: the top level stays back-entry free")

    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    chooser.submit()
    wait_for_level("^ ◂ Back")
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    chooser.submit()
    vim.wait(1000, function()
      return ran ~= nil
    end, 10)
    eq(ran, "stage", "open: the nested leaf's action runs")
    ok(not chooser.is_open(), "open: the menu closes after a leaf action")
  end

  -- ---------- bind_buffer: soft dependency, no nvzone/menu required ----------

  do
    local chooser = require("lib.nvim.ui.kit.chooser")
    vim.cmd("enew")
    local buf = vim.api.nvim_get_current_buf()

    local get_items_called = false
    contextmenu.bind_buffer(buf, function()
      get_items_called = true
      return {}
    end, { desc = "test menu" })

    -- Triggering the keymap must not error even though "menu" (nvzone/menu)
    -- is not installed in the test environment — the kit renderer takes over.
    local mapped = vim.fn.maparg("<RightMouse>", "n", false, true)
    ok(
      type(mapped) == "table" and mapped.buffer == 1,
      "bind_buffer: registers a buffer-local mapping"
    )
    eq(mapped.desc, "test menu", "bind_buffer: keymap desc passed through")

    local call_ok = pcall(mapped.callback)
    ok(call_ok, "bind_buffer: triggering without nvzone/menu installed doesn't error")
    -- Items are now collected before any renderer is reached — the provider
    -- decides whether there is a menu at all, and an empty list opens none.
    eq(get_items_called, true, "bind_buffer: get_items is called regardless of nvzone/menu")
    ok(not chooser.is_open(), "bind_buffer: an empty item list opens nothing")

    vim.cmd("bwipeout! " .. buf)
  end

  -- ---------- open: win/anchor/row/col forwarded, surface returned ----------
  --
  -- Positioning a menu beside a plugin's own window (rather than at the
  -- mouse) needs `win`/`row`/`col` to reach nvim_open_win, and needs a
  -- handle back so the caller can clear a temporary highlight when the menu
  -- closes -- `open()` used to both drop these opts on the floor for the kit
  -- path and discard its return value entirely.

  do
    local chooser = require("lib.nvim.ui.kit.chooser")
    contextmenu.setup({ renderer = "kit" })

    vim.cmd("enew")
    local anchor_buf = vim.api.nvim_get_current_buf()
    local anchor_win = vim.api.nvim_get_current_win()

    local out = {}
    contextmenu.group(out, contextmenu.entry(true, "Do X", function() end))

    local surf = contextmenu.open(out, { win = anchor_win, row = 0, col = -10, anchor = "NE" })
    ok(surf ~= nil, "open: returns the kit surface when win/row/col are given")
    ok(chooser.is_open(), "open: still actually opens the menu")

    if surf then
      local cfg = vim.api.nvim_win_get_config(surf.winid)
      eq(cfg.relative, "win", 'open: win implies relative = "win" when unset')
      eq(cfg.win, anchor_win, "open: the anchor window is forwarded")
      eq(cfg.col, -10, "open: explicit col is forwarded")
      eq(cfg.anchor, "NE", "open: explicit anchor overrides the auto-flip default")

      local closed = false
      surf:on_close(function()
        closed = true
      end)
      chooser.close()
      ok(closed, "open: the returned surface's on_close fires when the menu closes")
    end

    vim.cmd("bwipeout! " .. anchor_buf)
  end

  -- ---------- open: hover follows the mouse without a click ----------
  --
  -- <MouseMove> is a real, mappable key (like <LeftMouse>), gated behind
  -- 'mousemoveevent' -- not an autocmd event. Skipped outright on a Neovim
  -- where setting that option itself errors (older than this plugin's own
  -- 0.10 floor): hover is a silent no-op there, nothing to assert.

  if pcall(function()
    vim.o.mousemoveevent = vim.o.mousemoveevent
  end) then
    local chooser = require("lib.nvim.ui.kit.chooser")
    contextmenu.setup({ renderer = "kit" })

    local saved_mme = vim.o.mousemoveevent
    local out = {}
    contextmenu.group(
      out,
      contextmenu.entry(true, "Do X", function() end),
      contextmenu.entry(true, "Do Y", function() end)
    )
    local surf = contextmenu.open(out, { mouse = false })
    ok(surf ~= nil, "hover fixture: menu opens")
    ok(vim.o.mousemoveevent, "hover: turns 'mousemoveevent' on while open (default true)")

    -- Simulate the pointer sitting over the second row: stub getmousepos()
    -- (a headless run has no real pointer) and trigger the buffer-local
    -- <MouseMove> mapping directly, the same way the bind_buffer test above
    -- triggers <RightMouse>.
    eq(chooser.current_index(), 1, "hover fixture: cursor starts on the first entry")
    local orig_getmousepos = vim.fn.getmousepos
    vim.fn.getmousepos = function()
      return { winid = (surf and surf.winid) or 0, line = 2, column = 1 }
    end
    local mapped = vim.fn.maparg("<MouseMove>", "n", false, true)
    ok(type(mapped) == "table" and mapped.buffer == 1, "hover: <MouseMove> is bound (default true)")
    if type(mapped) == "table" and mapped.callback then
      mapped.callback()
    end
    eq(chooser.current_index(), 2, "hover: moving over row 2 moves the selection there")

    -- The row is also painted explicitly (KitHover), not left to
    -- CursorLine/window-highlight alone -- query every namespace's
    -- extmarks on the buffer for one carrying that group on row 2 (0-based 1).
    -- kit.menu supplies hover_start_col/hover_end_col (frame_row), so the
    -- paint is a hl_group span bounded to the field, not hl_eol to the
    -- window edge -- confirm it stops well short of the row's own length.
    if surf then
      local mark
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(surf.bufnr, -1, 0, -1, { details = true })) do
        local row, col, details = m[2], m[3], m[4]
        if
          row == 1
          and details
          and (details.hl_group == "KitHover" or details.line_hl_group == "KitHover")
        then
          mark = { col = col, details = details }
        end
      end
      ok(mark ~= nil, "hover: row 2 carries an explicit KitHover extmark")
      if mark then
        local line = vim.api.nvim_buf_get_lines(surf.bufnr, 1, 2, false)[1] or ""
        ok(
          mark.details.end_col ~= nil and mark.details.end_col < #line,
          "hover: paint stops before the row's full width (not hl_eol), got "
            .. vim.inspect(mark.details)
        )
      end
    end

    vim.fn.getmousepos = orig_getmousepos

    chooser.close()
    eq(
      vim.o.mousemoveevent,
      saved_mme,
      "hover: 'mousemoveevent' restored to its prior value on close"
    )
  end

  -- ---------- chooser: <ScrollWheelDown>/<Up> never overscroll past content ----------
  --
  -- Neovim's default <ScrollWheelDown> is a plain by-line window scroll
  -- (<C-e>), which has no floor stopping `topline` once the last line has
  -- reached the window's bottom row -- unlike cursor-driven motions (`G`,
  -- `j` at the last line), which do stop there. Confirmed live: 25 lines in
  -- an 8-row window, 30x <C-e>, topline lands on 25 -- the window then shows
  -- line 25 at the TOP with seven blank rows below it, forever. The
  -- chooser must not have that failure mode: <ScrollWheelDown> is remapped
  -- to M.move(1), which already clamps correctly.

  do
    local chooser = require("lib.nvim.ui.kit.chooser")
    local items = {}
    for i = 1, 25 do
      items[i] = "item " .. i
    end
    local surf = chooser.open({
      items = items,
      height = 8,
      relative = "editor",
      on_select = function() end,
    })
    ok(surf ~= nil, "wheel-scroll fixture: chooser opens")

    if surf then
      local mapped = vim.fn.maparg("<ScrollWheelDown>", "n", false, true)
      ok(
        type(mapped) == "table" and type(mapped.callback) == "function",
        "wheel-scroll: <ScrollWheelDown> is bound to a callback, not native scroll"
      )
      -- Exactly 24 steps: item 1 (where a fresh chooser starts) to item 25,
      -- with nothing left over to wrap. M.move wraps around by design (the
      -- picker drives it the same way arrow keys cycle results) -- a 25th
      -- step is covered separately below, deliberately past this point.
      if type(mapped) == "table" and mapped.callback then
        for _ = 1, 24 do
          mapped.callback()
        end
      end
      eq(chooser.current_index(), 25, "wheel-scroll: selection follows, same as keyboard nav")
      local last_visible = vim.fn.line("w$", surf.winid)
      eq(
        last_visible,
        25,
        "wheel-scroll: 24x <ScrollWheelDown> lands on the last item with no blank rows below it"
      )

      -- One more: wraps back to item 1. The window must follow that jump
      -- too, not get stuck showing the tail end with the selection now
      -- invisible above the top.
      if type(mapped) == "table" and mapped.callback then
        mapped.callback()
      end
      eq(chooser.current_index(), 1, "wheel-scroll: one more step wraps back to the first item")
      eq(
        vim.fn.line("w0", surf.winid),
        1,
        "wheel-scroll: wrapping back scrolls the window back to the top too"
      )
    end

    chooser.close()
  end

  -- Leave the module as the rest of the suite (and any host) expects it.
  -- `native_popup = true`: setup() now disables the native PopUp menu by
  -- default, which the rest of the shared test session did not ask for.
  contextmenu.setup({ renderer = "auto", native_popup = true })
  vim.o.mousemodel = "popup_setpos"
end
