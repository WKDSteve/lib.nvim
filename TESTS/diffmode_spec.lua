-- TESTS/diffmode_spec.lua — lib.nvim.diffmode (N-way native diffmode)

return function(H)
  local eq, ok = H.eq, H.ok
  local dm = require("lib.nvim.diffmode")

  local function buf(lines)
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    return b
  end
  local function diff_on(w)
    return vim.api.nvim_get_option_value("diff", { win = w, scope = "local" })
  end

  local start_win = vim.api.nvim_get_current_win()
  local start_tab = vim.api.nvim_get_current_tabpage()

  -- input checks
  local r, err = dm.open_n_way({ buf({ "a" }) }, "vsplit")
  eq(r, nil, "one buffer is not a diff")
  ok(err:find("two"), "...says so")
  r, err = dm.open_n_way({ buf({ "a" }), 99999 }, "vsplit")
  eq(r, nil, "an invalid buffer is refused")
  ok(err:find("not valid"), "...names the problem")
  r = dm.open_n_way({ buf({ "a" }), buf({ "b" }) }, "diagonal")
  eq(r, nil, "an unknown view is refused")
  r = dm.open_n_way({ buf({ "a" }), buf({ "b" }) }, "vsplit", { origin_win = 99999 })
  eq(r, nil, "an invalid origin window is refused")
  eq(#vim.api.nvim_tabpage_list_wins(0), 1, "nothing was opened by the refusals")

  -- three-way, origin window shown first
  local a, b, c = buf({ "one", "two" }), buf({ "one", "2" }), buf({ "1", "two" })
  vim.api.nvim_win_set_buf(start_win, a)
  local res = assert(dm.open_n_way({ a, b, c }, "vsplit", { origin_win = start_win }))
  eq(#res.windows, 3, "three windows in the diff")
  eq(#res.opened, 2, "two were opened here")
  eq(res.windows[1], start_win, "the origin window is first")
  ok(not vim.tbl_contains(res.opened, start_win), "the origin window is never in opened")
  eq(vim.api.nvim_win_get_buf(res.windows[2]), b, "second window shows the second buffer")
  eq(vim.api.nvim_win_get_buf(res.windows[3]), c, "third window shows the third buffer")
  for _, w in ipairs(res.windows) do
    ok(diff_on(w), "diff is on in every window")
  end
  eq(vim.go.diff, false, "the global 'diff' value is not touched")
  local cols = {}
  for _, w in ipairs(res.windows) do
    cols[#cols + 1] = vim.api.nvim_win_get_position(w)[2]
  end
  ok(cols[1] < cols[2] and cols[2] < cols[3], "side by side, left to right")
  eq(vim.api.nvim_get_current_win(), start_win, "focus returns to the origin window")

  -- a window opened later does not inherit diffmode
  vim.cmd("new")
  local fresh = vim.api.nvim_get_current_win()
  eq(diff_on(fresh), false, "a window opened afterwards is not in diffmode")
  vim.api.nvim_win_close(fresh, true)

  dm.close(res)
  ok(vim.api.nvim_win_is_valid(start_win), "close keeps the origin window")
  eq(diff_on(start_win), false, "...and turns its diff off")
  eq(#vim.api.nvim_tabpage_list_wins(0), 1, "the opened windows are gone")

  -- stacked, no origin: every buffer gets a window of its own
  local d, e = buf({ "x" }), buf({ "y" })
  res = assert(dm.open_n_way({ d, e }, "split"))
  eq(#res.opened, 2, "without an origin window all are opened here")
  local rows = {}
  for _, w in ipairs(res.windows) do
    rows[#rows + 1] = vim.api.nvim_win_get_position(w)[1]
  end
  ok(rows[1] < rows[2], "stacked, top to bottom")
  dm.close(res)

  -- tab
  res = assert(dm.open_n_way({ a, b, c, d }, "tab"))
  eq(#res.windows, 4, "four-way diff")
  ok(vim.api.nvim_get_current_tabpage() ~= start_tab, "the tab view opens a new tab")
  eq(#vim.api.nvim_tabpage_list_wins(0), 4, "all four windows live in it")
  for _, w in ipairs(res.windows) do
    ok(diff_on(w), "diff on in the tab view")
  end
  dm.close(res)
  vim.api.nvim_set_current_tabpage(start_tab)
  vim.cmd("silent! tabonly")

  -- what :diffthis sets besides 'diff', and :diffoff puts back
  local origin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(origin, a)
  local wo = { scope = "local" }
  wo.win = origin
  vim.api.nvim_set_option_value("foldmethod", "indent", wo)
  vim.api.nvim_set_option_value("wrap", true, wo)
  vim.api.nvim_set_option_value("scrollbind", false, wo)
  res = assert(dm.open_n_way({ a, b }, "vsplit", { origin_win = origin }))
  for _, w in ipairs(res.windows) do
    local o = vim.wo[w]
    ok(o.scrollbind, "diff windows scroll together")
    ok(o.cursorbind, "diff windows move the cursor together")
    eq(o.foldmethod, "diff", "unchanged text folds away")
    ok(o.foldenable, "folding is on")
    eq(o.wrap, false, "no wrap, so the lines stay aligned")
  end
  dm.set(origin, true) -- a second set must not take the diff values as the ones to restore
  dm.close(res)
  eq(vim.wo[origin].diff, false, "the origin window is out of diffmode")
  eq(vim.wo[origin].scrollbind, false, "its scrollbind is back")
  eq(vim.wo[origin].cursorbind, false, "its cursorbind is back")
  eq(vim.wo[origin].foldmethod, "indent", "its foldmethod is back")
  eq(vim.wo[origin].wrap, true, "its wrap is back")
  -- the global values stay untouched, so the next window starts plain
  vim.cmd("vsplit")
  local plain = vim.api.nvim_get_current_win()
  eq(vim.wo[plain].scrollbind, false, "a new window does not inherit scrollbind")
  vim.api.nvim_win_close(plain, true)

  dm.close(nil) -- nothing to do, no error
  for _, x in ipairs({ a, b, c, d, e }) do
    pcall(vim.api.nvim_buf_delete, x, { force = true })
  end
end
