-- TESTS/selection_spec.lua — lib.nvim.selection: lines, same-line chars,
-- and multi-line chars capture/reselect.
--
-- A Visual selection only exists while Vim is actually IN Visual mode
-- (`mode() == "v"`), so these specs enter it with `:normal! v` and no
-- trailing <Esc> (Vim's `:normal` leaves the editor exactly in whatever mode
-- the simulated keys left it in) rather than the usual "set marks, then Esc"
-- trick other specs use for `'<`/`'>`-based assertions.
--
-- `reselect_*` queue their keys via `nvim_feedkeys(..., "ni", false)`
-- (no remap, deferred, in front of the typeahead), so an empty flush --
-- `nvim_feedkeys("", "x", false)` -- is needed to run them synchronously
-- before the next assertion, same idiom cascade.nvim's specs use for its
-- operatorfunc dot-repeat trampoline.

return function(H)
  local eq = H.eq
  local selection = require("lib.nvim.selection")

  local function flush()
    vim.api.nvim_feedkeys("", "x", false)
  end

  local function esc()
    vim.cmd("normal! \27")
  end

  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()

  -- ---------- lines ----------

  do
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("normal! V")
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    -- lines() doesn't require Visual mode to still be active; either point works.
    local srow, erow = selection.lines()
    eq(srow, 1, "lines: srow 0-based")
    eq(erow, 2, "lines: erow 0-based")
    esc()

    -- Direction-agnostic: dragging upward still returns (srow, erow) sorted.
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.cmd("normal! V")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local a, b = selection.lines()
    eq(a, 0, "lines: sorted regardless of drag direction (srow)")
    eq(b, 2, "lines: sorted regardless of drag direction (erow)")
    esc()

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! V")
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    selection.reselect_lines(0, 3)
    flush()
    eq(vim.fn.mode(), "V", "reselect_lines: leaves linewise Visual active")
    local nsrow, nerow = selection.lines()
    eq(nsrow, 0, "reselect_lines: srow restored")
    eq(nerow, 3, "reselect_lines: erow restored")
    esc()

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("normal! V")
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    local ret = selection.keep_lines(function(s, e)
      return s + e
    end)
    flush()
    eq(ret, 3, "keep_lines: returns fn's result")
    local ksrow, kerow = selection.lines()
    eq(ksrow, 1, "keep_lines: reselects the same srow")
    eq(kerow, 2, "keep_lines: reselects the same erow")
    esc()
  end

  -- ---------- chars (same-line) ----------

  do
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })

    eq(selection.chars(), nil, "chars: nil outside Visual mode")

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! v")
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    local row, scol, ecol = selection.chars()
    eq(row, 0, "chars: row 0-based")
    eq(scol, 0, "chars: scol 0-based")
    eq(ecol, 4, "chars: ecol inclusive")
    esc()

    -- Direction-agnostic: dragging leftward still returns sorted columns.
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    vim.cmd("normal! v")
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    local drow, dscol, decol = selection.chars()
    eq(drow, 0, "chars: row (reverse drag)")
    eq(dscol, 2, "chars: sorted scol (reverse drag)")
    eq(decol, 6, "chars: sorted ecol (reverse drag)")
    esc()

    -- Multi-line charwise: chars() is same-line only, so this is nil (the
    -- gap chars_multiline exists to cover).
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "line one", "line two" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! v")
    vim.api.nvim_win_set_cursor(0, { 2, 3 })
    eq(selection.chars(), nil, "chars: nil for a multi-line charwise selection")
    esc()

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! v")
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    selection.reselect_chars(0, 1, 3)
    flush()
    eq(vim.fn.mode(), "v", "reselect_chars: leaves charwise Visual active")
    local rrow, rscol, recol = selection.chars()
    eq(rrow, 0, "reselect_chars: row restored")
    eq(rscol, 1, "reselect_chars: scol restored")
    eq(recol, 3, "reselect_chars: ecol restored")
    esc()

    -- UTF-8: a byte column always names where a character *starts* (a cursor
    -- can never sit mid-codepoint), so selecting through "ä" (2 bytes, at
    -- byte offset 1) round-trips as ecol = 1, not its second byte.
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "aäb" })
    selection.reselect_chars(0, 0, 1) -- "a" + "ä"
    flush()
    local urow, uscol, uecol = selection.chars()
    eq(urow, 0, "reselect_chars utf8: row")
    eq(uscol, 0, "reselect_chars utf8: scol")
    eq(uecol, 1, "reselect_chars utf8: ecol names ä's start byte, round-trips exactly")
    esc()

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! v")
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    local kret, kapplicable = selection.keep_chars(function(r, s, e)
      return r + s + e
    end)
    flush()
    eq(kapplicable, true, "keep_chars: applicable for a same-line charwise selection")
    eq(kret, 4, "keep_chars: returns fn's result")
    local kkrow, kkscol, kkecol = selection.chars()
    eq(kkrow, 0, "keep_chars: row reselected")
    eq(kkscol, 0, "keep_chars: scol reselected")
    eq(kkecol, 4, "keep_chars: ecol reselected")
    esc()

    -- Not applicable outside Visual mode: fn is never called.
    local called = false
    local nret, napplicable = selection.keep_chars(function()
      called = true
      return nil
    end)
    eq(napplicable, false, "keep_chars: not applicable outside Visual mode")
    eq(called, false, "keep_chars: fn not called when not applicable")
    eq(nret, nil, "keep_chars: nil ret when not applicable")
  end

  -- ---------- chars_multiline ----------

  do
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "hello world" })
    eq(selection.chars_multiline(), nil, "chars_multiline: nil outside Visual mode")

    -- Same-line charwise: not multi-line, so nil (the gap chars() covers).
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! v")
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    eq(selection.chars_multiline(), nil, "chars_multiline: nil for a same-line charwise selection")
    esc()

    -- Linewise Visual: also nil, chars_multiline is charwise-only.
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! V")
    eq(selection.chars_multiline(), nil, "chars_multiline: nil for linewise Visual")
    esc()

    vim.api.nvim_buf_set_lines(
      buf,
      0,
      -1,
      false,
      { "### 2. iwas", "prose line", "### 3. sad", "tail" }
    )
    vim.api.nvim_win_set_cursor(0, { 1, 4 }) -- on "2."
    vim.cmd("normal! v")
    vim.api.nvim_win_set_cursor(0, { 3, 9 }) -- on "sad"'s 'd'
    local srow, scol, erow, ecol = selection.chars_multiline()
    eq(srow, 0, "chars_multiline: srow 0-based")
    eq(scol, 4, "chars_multiline: scol 0-based")
    eq(erow, 2, "chars_multiline: erow 0-based")
    eq(ecol, 9, "chars_multiline: ecol inclusive")
    esc()

    -- Direction-agnostic: dragging upward still returns the earlier point
    -- as (srow, scol) and the later point as (erow, ecol).
    vim.api.nvim_win_set_cursor(0, { 3, 9 })
    vim.cmd("normal! v")
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    local rsrow, rscol, rerow, recol = selection.chars_multiline()
    eq(rsrow, 0, "chars_multiline: srow (reverse drag)")
    eq(rscol, 4, "chars_multiline: scol (reverse drag)")
    eq(rerow, 2, "chars_multiline: erow (reverse drag)")
    eq(recol, 9, "chars_multiline: ecol (reverse drag)")
    esc()
  end

  -- ---------- reselect_chars_multiline / keep_chars_multiline ----------

  do
    vim.api.nvim_buf_set_lines(
      buf,
      0,
      -1,
      false,
      { "### 2. iwas", "prose line", "### 3. sad", "tail" }
    )
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    vim.cmd("normal! v")
    vim.api.nvim_win_set_cursor(0, { 3, 9 })
    selection.reselect_chars_multiline(0, 4, 2, 9)
    flush()
    eq(vim.fn.mode(), "v", "reselect_chars_multiline: leaves charwise Visual active")
    local srow, scol, erow, ecol = selection.chars_multiline()
    eq(srow, 0, "reselect_chars_multiline: srow restored")
    eq(scol, 4, "reselect_chars_multiline: scol restored")
    eq(erow, 2, "reselect_chars_multiline: erow restored")
    eq(ecol, 9, "reselect_chars_multiline: ecol restored")
    esc()

    -- UTF-8 on both the first and last line: byte offsets name the start of
    -- "ä" (line 1) and "ö" (line 3), and round-trip exactly, same reasoning
    -- as the same-line case above.
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "aäb", "middle", "cödd" })
    selection.reselect_chars_multiline(0, 1, 2, 1) -- "äb" ... "ödd"
    flush()
    local urow, uscol, uerow, uecol = selection.chars_multiline()
    eq(urow, 0, "reselect_chars_multiline utf8: srow")
    eq(uscol, 1, "reselect_chars_multiline utf8: scol names ä's start byte")
    eq(uerow, 2, "reselect_chars_multiline utf8: erow")
    eq(uecol, 1, "reselect_chars_multiline utf8: ecol names ö's start byte")
    esc()

    vim.api.nvim_buf_set_lines(
      buf,
      0,
      -1,
      false,
      { "### 2. iwas", "prose line", "### 3. sad", "tail" }
    )
    vim.api.nvim_win_set_cursor(0, { 1, 4 })
    vim.cmd("normal! v")
    vim.api.nvim_win_set_cursor(0, { 3, 9 })
    local captured
    local kret, kapplicable = selection.keep_chars_multiline(function(s, sc, e, ec)
      captured = { s, sc, e, ec }
      return "ok"
    end)
    flush()
    eq(kapplicable, true, "keep_chars_multiline: applicable for a multi-line charwise selection")
    eq(kret, "ok", "keep_chars_multiline: returns fn's result")
    eq(captured[1], 0, "keep_chars_multiline: fn saw srow")
    eq(captured[2], 4, "keep_chars_multiline: fn saw scol")
    eq(captured[3], 2, "keep_chars_multiline: fn saw erow")
    eq(captured[4], 9, "keep_chars_multiline: fn saw ecol")
    local srow2, scol2, erow2, ecol2 = selection.chars_multiline()
    eq(srow2, 0, "keep_chars_multiline: srow reselected")
    eq(scol2, 4, "keep_chars_multiline: scol reselected")
    eq(erow2, 2, "keep_chars_multiline: erow reselected")
    eq(ecol2, 9, "keep_chars_multiline: ecol reselected")
    esc()

    -- Not applicable for a same-line selection: fn is never called, falls
    -- through for the caller to handle its own way (mirrors keep_chars).
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! v")
    vim.api.nvim_win_set_cursor(0, { 1, 3 })
    local called = false
    local nret, napplicable = selection.keep_chars_multiline(function()
      called = true
      return nil
    end)
    eq(napplicable, false, "keep_chars_multiline: not applicable for a same-line selection")
    eq(called, false, "keep_chars_multiline: fn not called when not applicable")
    eq(nret, nil, "keep_chars_multiline: nil ret when not applicable")
    esc()
  end

  -- ---------- ordering: the reselect runs before the keys queued after it ----------
  -- In a macro, a `:normal` or a paste the keys after the mapping are already
  -- in the typeahead; the reselect must run in front of them (regression: it
  -- was appended behind them, so `d` below hit the old selection and the
  -- reselect then left Visual mode active on the wrong rows).

  do
    vim.keymap.set("x", "<Plug>(lib-selection-keep)", function()
      selection.keep_lines(function() end)
    end, { buffer = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.api.nvim_feedkeys(vim.keycode("Vj<Plug>(lib-selection-keep)d"), "mtx", false)
    eq(vim.fn.mode(), "n", "ordering: the queued d ran last and left Normal mode")
    eq(
      table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "|"),
      "three|four",
      "ordering: d deleted the reselected rows"
    )
    vim.keymap.del("x", "<Plug>(lib-selection-keep)", { buffer = buf })
    esc()
  end

  vim.cmd("bwipeout! " .. buf)
end
