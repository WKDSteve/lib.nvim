-- Test code: when something here comes back nil, this file must crash and
-- name it rather than silently skip -- see TESTS/ui_kit_spec.lua's header.
---@diagnostic disable: need-check-nil
-- TESTS/ui_kit_sidebar_spec.lua -- `lib.nvim.ui.kit.sidebar`: a themed split on the left, the right or the
-- bottom (fixed size, winfixwidth/winfixheight, winhighlight from the kit theme, a winbar title), found again
-- through its buffer variable, exclusive slots that restore what they displaced exactly once (UI-54), the
-- handles in `sidebar_state` and `close_all` as the one cleanup. Runs in a tabpage of its own.

return function(H)
  local eq, ok = H.eq, H.ok
  local api = vim.api
  local kit = require("lib.nvim.ui.kit")
  local sidebar = require("lib.nvim.ui.kit.sidebar")
  local theme = require("lib.nvim.ui.kit.theme")

  eq(kit.sidebar, sidebar, "kit.sidebar is the module")

  vim.cmd("tabnew")
  local tab = api.nvim_get_current_tabpage()
  local main = api.nvim_get_current_win()

  --- Let the double-deferred restore run (two scheduled ticks and a margin).
  local function settle()
    vim.wait(50, function()
      return false
    end)
  end

  local function text(buf)
    return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "|")
  end

  local function wo(win, name)
    return api.nvim_get_option_value(name, { win = win })
  end

  local function shows(buf)
    local n = 0
    for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
      if api.nvim_win_get_buf(win) == buf then
        n = n + 1
      end
    end
    return n
  end

  local function reset()
    sidebar.close_all()
    settle()
    api.nvim_set_current_win(main)
    eq(#sidebar.list(), 0, "reset: no sidebar left")
  end

  -- ---------------------------------------------------------------- left: a split, fixed width, theme
  api.nvim_set_option_value("winhighlight", "Search:ErrorMsg", { win = main })
  local tree = sidebar.open({
    name = "tree",
    lines = { "a", "b" },
    size = 24,
    title = "Files 100%",
    theme = { hl = { normal = "Comment" } },
  })
  ok(tree ~= nil, "open returns a handle")
  local win = tree.winid
  eq(api.nvim_win_get_config(win).relative, "", "a split, not a float")
  eq(api.nvim_get_current_win(), win, "entered by default")
  eq(api.nvim_win_get_width(win), 24, "the requested width")
  eq(api.nvim_win_get_position(win)[2], 0, "left: at column 0")
  eq(wo(win, "winfixwidth"), true, "winfixwidth")
  eq(wo(win, "winfixbuf"), true, "winfixbuf")
  eq(wo(win, "number"), false, "no line numbers")
  eq(wo(win, "cursorline"), true, "cursorline")
  eq(wo(win, "winbar"), " Files 100%%", "the title in the winbar, % escaped")
  local winhl = wo(win, "winhighlight")
  local names = theme.window_groups(theme.resolve({ hl = { normal = "Comment" } }))
  ok(
    winhl:find("Normal:" .. names.normal, 1, true),
    "Normal maps to the theme's normal group: " .. winhl
  )
  ok(winhl:find("NormalNC:" .. names.normal, 1, true), "NormalNC too: " .. winhl)
  ok(winhl:find("WinSeparator:" .. names.border, 1, true), "WinSeparator maps to border: " .. winhl)
  ok(winhl:find("CursorLine:KitSelection", 1, true), "CursorLine maps to KitSelection: " .. winhl)
  ok(
    not winhl:find("Search:", 1, true),
    "the source window's own mappings are not copied: " .. winhl
  )
  eq(
    api.nvim_get_hl(0, { name = names.normal, link = true }).link,
    "Comment",
    "theme override applied"
  )
  eq(vim.b[tree.bufnr].ui_kit_sidebar, "tree", "the buffer variable names the sidebar")
  eq(sidebar.find("tree"), win, "find() by buffer variable")
  eq(sidebar.get("tree"), tree, "get() returns the handle")
  eq(vim.bo[tree.bufnr].modifiable, false, "not modifiable by default")
  tree:set_lines({ "x" })
  eq(text(tree.bufnr), "x", "set_lines (inherited from surface)")
  eq(vim.bo[tree.bufnr].modifiable, false, "set_lines keeps it read-only")
  tree:set_title(nil)
  eq(wo(win, "winbar"), "", "set_title(nil) clears the winbar")
  api.nvim_set_option_value("winhighlight", "", { win = main })

  -- Same name: the existing sidebar comes back, with new lines.
  local again = sidebar.open({ name = "tree", lines = { "y" } })
  eq(again, tree, "open with a known name reuses the handle")
  eq(#sidebar.list(), 1, "no second sidebar")
  eq(text(tree.bufnr), "y", "and replaces the lines")
  reset()

  -- ---------------------------------------------------------------- right and bottom
  local right = sidebar.open({ name = "right", position = "right", size = 20, enter = false })
  eq(api.nvim_get_current_win(), main, "enter = false keeps the cursor")
  eq(
    api.nvim_win_get_position(right.winid)[2] + api.nvim_win_get_width(right.winid),
    vim.o.columns,
    "right: flush with the right edge"
  )
  local bottom = sidebar.open({ name = "bottom", position = "bottom", size = 6 })
  eq(api.nvim_win_get_height(bottom.winid), 6, "bottom: the requested height")
  eq(wo(bottom.winid, "winfixheight"), true, "bottom: winfixheight")
  eq(api.nvim_win_get_width(bottom.winid), vim.o.columns, "bottom: full width")
  ok(right:is_visible() and bottom:is_visible(), "different positions coexist")
  reset()

  local half = sidebar.open({ position = "left", size = 0.5 })
  eq(
    api.nvim_win_get_width(half.winid),
    math.floor(vim.o.columns * 0.5 + 0.5),
    "a fraction is a share"
  )
  ok(half.name:find("^sidebar_%d+$") ~= nil, "an unnamed sidebar gets a name: " .. half.name)
  reset()

  ok(not pcall(sidebar.open, { position = "top" }), "an unknown position raises")

  -- ---------------------------------------------------------------- UI-54: displace and restore once
  local a_closed, b_closed = 0, 0
  local a = sidebar.open({
    name = "a",
    lines = { "A" },
    size = 22,
    on_close = function()
      a_closed = a_closed + 1
    end,
  })
  local b = sidebar.open({
    name = "b",
    on_close = function()
      b_closed = b_closed + 1
    end,
  })
  ok(b:is_visible(), "b is shown")
  ok(not a:is_visible(), "a is displaced by b at the same position")
  ok(not a:is_closed(), "a displaced is hidden, not closed")
  ok(api.nvim_buf_is_valid(a.bufnr), "a's buffer survives")
  eq(sidebar.find("a"), nil, "find() does not report a hidden sidebar")
  eq(a_closed, 0, "hiding a runs no close callback")

  local b_buf = b.bufnr
  b:close()
  eq(b_closed, 1, "b's close callback ran")
  ok(not api.nvim_buf_is_valid(b_buf), "b's buffer is gone")
  ok(not a:is_visible(), "a comes back deferred, not inside b's close")
  settle()
  ok(a:is_visible(), "a is restored after b closed")
  eq(shows(a.bufnr), 1, "a is shown in exactly one window")
  eq(api.nvim_win_get_width(a.winid), 22, "a keeps its size")
  eq(text(a.bufnr), "A", "and its content")
  eq(sidebar.find("a"), a.winid, "find() sees a again")
  b:close()
  eq(b_closed, 1, "closing twice runs the callbacks once")

  -- Once: hiding a after the restore brings nothing back.
  ok(a:hide(), "a hides")
  settle()
  ok(not a:is_visible(), "nothing restores a a second time")
  ok(a:show(), "show() brings a back")
  ok(a:is_visible(), "a visible again")

  -- The window closed by other means (:q) is a close too, and restores.
  local c = sidebar.open({ name = "c" })
  ok(not a:is_visible(), "c displaces a")
  api.nvim_win_close(c.winid, true)
  ok(c:is_closed(), ":q on the window closes the sidebar")
  settle()
  ok(a:is_visible(), "and a comes back")

  -- hide() of the newer one restores the older one too.
  local d = sidebar.open({ name = "d" })
  ok(d:hide(), "d hides")
  settle()
  ok(a:is_visible(), "hiding d restores a")
  ok(not d:is_closed(), "d is only hidden")
  -- The record was used up: d shown into a free slot and hidden again restores nothing.
  ok(a:hide(), "a hides")
  ok(d:show(), "d shows into the free slot")
  ok(d:hide(), "d hides again")
  settle()
  ok(not a:is_visible(), "a was restored once, not on every hide of d")
  reset()

  -- A chain: a <- b <- c, b closed while hidden; closing c restores a.
  a = sidebar.open({ name = "a" })
  b = sidebar.open({ name = "b" })
  c = sidebar.open({ name = "c" })
  ok(not a:is_visible() and not b:is_visible() and c:is_visible(), "only c is shown")
  b:close()
  settle()
  ok(c:is_visible() and not a:is_visible(), "closing hidden b changes nothing on screen")
  c:close()
  settle()
  ok(a:is_visible(), "closing c restores a (what b had displaced)")
  reset()

  -- exclusive = false shares the slot.
  a = sidebar.open({ name = "a" })
  b = sidebar.open({ name = "b", exclusive = false })
  ok(a:is_visible() and b:is_visible(), "a non-exclusive sidebar displaces nothing")
  reset()

  -- A slot taken again before the deferred restore runs keeps its occupant.
  a = sidebar.open({ name = "a" })
  b = sidebar.open({ name = "b" })
  b:close()
  c = sidebar.open({ name = "c" })
  settle()
  ok(c:is_visible() and not a:is_visible(), "c keeps the slot")
  c:close()
  settle()
  ok(a:is_visible(), "a waits behind c and comes back after it")
  reset()

  -- ---------------------------------------------------------------- toggle, focus
  local t = sidebar.toggle({ name = "t", lines = { "t" } })
  ok(t:is_visible(), "toggle opens")
  eq(sidebar.toggle({ name = "t" }), t, "toggle returns the same handle")
  ok(not t:is_visible() and not t:is_closed(), "toggle hides")
  sidebar.toggle({ name = "t" })
  ok(t:is_visible(), "toggle shows again")
  t:hide()
  api.nvim_set_current_win(main)
  t:focus()
  eq(api.nvim_get_current_win(), t.winid, "focus() shows a hidden sidebar and enters it")
  reset()
  ok(not pcall(sidebar.toggle, {}), "toggle without a name raises")
  eq(#sidebar.list(), 0, "and opens nothing")

  -- ---------------------------------------------------------------- folds of the code window
  -- A split copies the window's fold settings; a tree's indented lines must stay open.
  vim.wo[main].foldmethod = "indent"
  vim.wo[main].foldlevel = 0
  vim.wo[main].foldenable = true
  local f = sidebar.open({ name = "f", lines = { "dir", "  a", "  b" }, bo = { shiftwidth = 2 } })
  eq(wo(f.winid, "foldenable"), false, "folds off in the sidebar")
  eq(
    api.nvim_win_call(f.winid, function()
      return vim.fn.foldclosed(2)
    end),
    -1,
    "the indented lines are not folded"
  )
  vim.wo[main].foldmethod = "manual"
  vim.wo[main].foldenable = false
  reset()

  -- ---------------------------------------------------------------- UI-54 edge cases
  -- A sidebar the user brought back and hid again is not restored by a stale record.
  a = sidebar.open({ name = "a" })
  b = sidebar.open({ name = "b" })
  ok(a:show(), "a shown by hand")
  ok(not b:is_visible(), "a displaces b")
  ok(a:hide(), "a hidden by hand")
  settle()
  ok(b:is_visible(), "hiding a brings b back")
  b:close()
  settle()
  ok(not a:is_visible(), "closing b does not bring back the a the user hid")
  reset()

  -- Showing the middle of a chain a <- b <- c keeps a: c, then a come back in turn.
  a = sidebar.open({ name = "a" })
  b = sidebar.open({ name = "b" })
  c = sidebar.open({ name = "c" })
  ok(b:show(), "b shown by hand")
  ok(b:is_visible() and not c:is_visible() and not a:is_visible(), "b displaces c")
  b:close()
  settle()
  ok(c:is_visible() and not a:is_visible(), "closing b brings c back")
  c:close()
  settle()
  ok(a:is_visible(), "closing c brings a back (not lost)")
  reset()

  -- A restore that finds an occupant with its own record waits at the end of that chain.
  a = sidebar.open({ name = "a" })
  b = sidebar.open({ name = "b" })
  b:close()
  d = sidebar.open({ name = "d" })
  local e = sidebar.open({ name = "e" })
  settle()
  ok(e:is_visible() and not d:is_visible() and not a:is_visible(), "e holds the slot")
  e:close()
  settle()
  ok(d:is_visible() and not a:is_visible(), "d comes back first")
  d:close()
  settle()
  ok(a:is_visible(), "then a (it waited behind d)")
  reset()

  -- An exclusive sidebar displaces every sidebar at its position; they come back together.
  a = sidebar.open({ name = "a" })
  b = sidebar.open({ name = "b", exclusive = false })
  c = sidebar.open({ name = "c" })
  ok(c:is_visible() and not a:is_visible() and not b:is_visible(), "c displaces a and b")
  c:close()
  settle()
  settle()
  ok(a:is_visible() and b:is_visible(), "a and b share the slot again")
  reset()

  -- :only / <C-w>o in the code window closes the sidebar and restores nothing: the user asked for
  -- one window.
  a = sidebar.open({ name = "a" })
  e = sidebar.open({ name = "e" })
  ok(not a:is_visible(), "e displaces a")
  api.nvim_set_current_win(main)
  vim.cmd("only")
  ok(e:is_closed(), ":only closes the sidebar")
  settle()
  ok(not a:is_visible(), ":only does not bring the displaced sidebar back")
  ok(a:show(), "a can be shown again by hand")
  reset()

  -- ---------------------------------------------------------------- tabpages
  -- The displacing sidebar closed from another tabpage: the displaced one comes back there.
  a = sidebar.open({ name = "a" })
  b = sidebar.open({ name = "b" })
  vim.cmd("tabnew")
  local tab2 = api.nvim_get_current_tabpage()
  b:close()
  settle()
  ok(a:is_visible(), "a restored in its own tabpage")
  eq(api.nvim_win_get_tabpage(a.winid), tab, "a is back in the first tabpage")
  eq(api.nvim_get_current_tabpage(), tab2, "without switching tabpages")
  api.nvim_set_current_tabpage(tab)
  reset()

  -- toggle and open by name work on the current tabpage, never jump to another one.
  t = sidebar.open({ name = "t", enter = false })
  api.nvim_set_current_tabpage(tab2)
  sidebar.toggle({ name = "t" })
  ok(t:is_visible(), "toggle shows t ...")
  eq(api.nvim_win_get_tabpage(t.winid), tab2, "... in the current tabpage")
  eq(api.nvim_get_current_tabpage(), tab2, "and stays there")
  eq(#api.nvim_tabpage_list_wins(tab), 1, "t left the first tabpage")
  sidebar.toggle({ name = "t" })
  ok(not t:is_visible(), "the second toggle hides it")
  api.nvim_set_current_tabpage(tab)
  sidebar.toggle({ name = "t" })
  api.nvim_set_current_tabpage(tab2)
  eq(sidebar.open({ name = "t", enter = false }), t, "open by name from the other tabpage")
  eq(api.nvim_get_current_tabpage(), tab2, "does not jump to the first tabpage")
  eq(api.nvim_win_get_tabpage(t.winid), tab2, "it moves t here")
  reset()
  api.nvim_set_current_tabpage(tab2)
  vim.cmd("tabclose")
  api.nvim_set_current_win(main)

  -- ---------------------------------------------------------------- UI-52: close_all
  local closed = 0
  local function count()
    closed = closed + 1
  end
  a = sidebar.open({ name = "a", on_close = count })
  b = sidebar.open({ name = "b", on_close = count })
  local bot = sidebar.open({ name = "bot", position = "bottom", on_close = count })
  local bufs = { a.bufnr, b.bufnr, bot.bufnr }
  sidebar.close_all()
  settle()
  eq(closed, 3, "close_all closes visible and hidden sidebars")
  eq(#sidebar.list(), 0, "the state is empty")
  for _, buf in ipairs(bufs) do
    ok(not api.nvim_buf_is_valid(buf), "buffer wiped: " .. buf)
  end
  ok(not a:is_visible(), "close_all restores nothing")
  eq(#api.nvim_tabpage_list_wins(tab), 1, "only the main window is left")

  -- The sidebar as the tabpage's last window: close still wipes it, without an error.
  local last = sidebar.open({ name = "last" })
  api.nvim_win_close(main, true)
  ok(not last:hide(), "the last window cannot hide")
  local last_buf = last.bufnr
  last:close()
  settle()
  ok(last:is_closed(), "the last window's sidebar closes")
  ok(not api.nvim_buf_is_valid(last_buf), "and its buffer is gone")

  -- In the last tabpage the window stays and shows the user's buffer again: without the
  -- sidebar's winfixwidth (later splits would copy it). A child Neovim: this run has more
  -- tabpages than one.
  local script = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({
    "vim.opt.rtp:append(" .. vim.inspect(vim.fn.getcwd()) .. ")",
    "vim.cmd('edit ' .. vim.fn.fnameescape(vim.fn.tempname() .. '.txt'))",
    "local main = vim.api.nvim_get_current_win()",
    "local l = require('lib.nvim.ui.kit.sidebar').open({ name = 'l' })",
    "local win = l.winid",
    "vim.api.nvim_win_close(main, true)",
    "l:close()",
    "io.stdout:write(tostring(vim.api.nvim_win_is_valid(win)), ' ',",
    "  tostring(vim.wo[win].winfixwidth), ' ', vim.wo[win].winbar, '|\\n')",
    "vim.cmd('qa!')",
  }, script)
  local child = vim
    .system({ vim.v.progpath, "--headless", "-n", "-i", "NONE", "-u", "NONE", "-l", script })
    :wait()
  eq(child.code, 0, "child ran: " .. tostring(child.stderr))
  eq(vim.trim(child.stdout), "true false |", "the window stays, without the sidebar's options")

  if api.nvim_tabpage_is_valid(tab) then
    vim.cmd("tabclose")
  end
end
