-- Test code: when something here comes back nil, this file must crash and
-- name it rather than silently skip -- see TESTS/ui_kit_spec.lua's header.
---@diagnostic disable: need-check-nil
-- TESTS/ui_kit_form_back_spec.lua — lib.nvim.ui.kit's copy of `kit.form`'s
-- opt-in back navigation, `kit.input`'s `on_back`/`buttons` and the shared
-- `ui.kit.buttons` row helper (what `kit.confirm` lays its buttons out with).
-- The kit code lives in lib.nvim; full behavioural coverage also lives in ui.nvim's
-- TESTS/ui_kit_spec.lua and TESTS/ui_kit_form_back_ui_spec.lua (the latter in
-- a real, UI-attached Neovim, which a shared headless run like this one
-- cannot be). This file pins what the copy must still do: stay off unless
-- asked for, go back and forth without losing an answer, keep `<Esc>` and
-- `required` as they were, and press a button by key and by click -- and that
-- `kit.confirm` still answers a click after its move onto the shared helper.

return function(H)
  local eq, ok = H.eq, H.ok
  local kit = require("lib.nvim.ui.kit")

  local function keys(k)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), "x", false)
  end

  ---@return string
  local function field_text()
    return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
  end

  ---@param text string
  local function type_into_field(text)
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { text })
  end

  ---@return string|nil
  local function title_now()
    local t = vim.api.nvim_win_get_config(0).title
    if type(t) == "table" then
      return t[1] and t[1][1] or nil
    end
    return t
  end

  ---@return string
  local function button_row_text()
    local line = vim.api.nvim_buf_get_lines(0, 1, 2, false)[1] or ""
    return (line:gsub("^%s+", ""):gsub("%s+$", ""))
  end

  --- Left-click (`row`, `col`) of the focused float, 1-based like
  --- `getmousepos()`, through the mapping `<LeftMouse>` is bound to.
  ---@param row integer
  ---@param col integer
  local function click_at(row, col)
    local real = vim.fn.getmousepos
    vim.fn.getmousepos = function()
      return { winid = vim.api.nvim_get_current_win(), line = row, column = col }
    end
    local map = vim.fn.maparg("<LeftMouse>", "n", false, true)
    local done, err = pcall(map.callback)
    vim.fn.getmousepos = real
    ok(done, tostring(err))
  end

  ---@param label string
  local function click_button(label)
    local line = vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]
    local from = line:find("[ " .. label .. " ]", 1, true)
    ok(from, "no such button: " .. label)
    click_at(2, from + 2)
  end

  --- Closing a form's field from outside is that field's <Esc>, which opens the
  --- next one: loop until the chain has run out.
  local function close_floats()
    for _ = 1, 20 do
      local closed = false
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_config(w).relative ~= "" then
          pcall(vim.api.nvim_win_close, w, true)
          closed = true
        end
      end
      if not closed then
        return
      end
    end
  end

  ---@param fields table[]
  ---@param extra? table
  ---@return table
  local function open_form(fields, extra)
    local result = {}
    kit.form(vim.tbl_extend("force", {
      fields = fields,
      on_submit = function(values)
        result.values = values
      end,
      on_cancel = function()
        result.cancelled = true
      end,
    }, extra or {}))
    return result
  end

  local THREE = {
    { name = "a", label = "A" },
    { name = "b", label = "B" },
    { name = "c", label = "C" },
  }

  -- Off unless asked for: one line, no indicator, no buttons, no field keys.
  do
    local r =
      open_form({ { name = "a", label = "A", default = "dA" }, { name = "b", label = "B" } })
    eq(title_now(), "A", "no step indicator without back")
    eq(vim.api.nvim_win_get_height(0), 1, "one line without back")
    eq(vim.api.nvim_buf_line_count(0), 1, "no button row without back")
    for _, k in ipairs({ "<BS>", "<S-Tab>", "<C-p>", "<Down>", "<Tab>", "<LeftMouse>" }) do
      for _, mode in ipairs({ "n", "i" }) do
        local map = vim.fn.maparg(k, mode, false, true)
        ok((map.buffer or 0) ~= 1, k .. " is not bound in the field without back")
      end
    end
    keys("<CR>")
    type_into_field("bee")
    keys("<CR>")
    eq(r.values.a, "dA", "an untouched default is still submitted")
    eq(r.values.b, "bee", "the second field still chains")
    close_floats()
  end

  -- Step indicator, button row, and back with the previous answer as text.
  do
    local r = open_form(THREE, { back = true })
    eq(title_now(), "A (1/3)", "step indicator")
    eq(vim.api.nvim_win_get_height(0), 2, "field plus button row")
    eq(button_row_text(), "[ Skip ]  [ Next ↵ ]", "first field: no Back")
    for _, k in ipairs({ "<S-Tab>", "<C-p>", "<BS>" }) do
      keys(k)
      eq(title_now(), "A (1/3)", k .. " does nothing on the first field")
    end
    type_into_field("one")
    keys("<CR>")
    eq(title_now(), "B (2/3)", "<CR> goes forward")
    eq(button_row_text(), "[ ← Back ]  [ Skip ]  [ Next ↵ ]", "later field: Back appears")
    type_into_field("two (draft)")
    keys("<S-Tab>")
    eq(title_now(), "A (1/3)", "<S-Tab> goes back")
    eq(field_text(), "one", "the previous answer is the editable text")
    type_into_field("ONE")
    keys("<CR>")
    eq(field_text(), "two (draft)", "a half-typed field comes back as typed")
    keys("<CR>")
    eq(button_row_text(), "[ ← Back ]  [ Skip ]  [ Done ↵ ]", "last field: Done")
    type_into_field("three")
    keys("<CR>")
    eq(r.values.a, "ONE", "a corrected answer replaces the old one")
    eq(r.values.b, "two (draft)", "going back and forth loses nothing")
    eq(r.values.c, "three", "the last field is collected")
    close_floats()
  end

  -- `on_back` gives the FIRST field a back as well: the form closes and hands the
  -- answers so far on, without a submit or a cancel.
  do
    local left
    local r = open_form(THREE, {
      back = true,
      on_back = function(values)
        left = values
      end,
    })
    eq(button_row_text(), "[ ← Back ]  [ Skip ]  [ Next ↵ ]", "first field: Back with on_back")
    type_into_field("one")
    keys("<CR>")
    type_into_field("two")
    keys("<S-Tab>")
    type_into_field("ONE")
    keys("<S-Tab>")
    ok(left ~= nil, "on_back fired from the first field")
    eq(left.a, "ONE", "the first field's text as it stood")
    eq(left.b, "two", "an answer walked back from is handed on too")
    eq(r.values, nil, "no submit")
    eq(r.cancelled, nil, "no cancel")
    close_floats()
  end

  -- <BS> only goes back on an empty field; <C-p> goes back too. The clock the
  -- held-key guard reads is stubbed, so "a moment later" is a number.
  do
    local real_hrtime, now_ms = vim.uv.hrtime, 0
    vim.uv.hrtime = function()
      return now_ms * 1e6
    end
    local done, err = pcall(function()
      open_form(THREE, { back = true })
      type_into_field("one")
      keys("<CR>")
      type_into_field("xy")
      vim.api.nvim_win_set_cursor(0, { 1, 1 })
      keys("<BS>")
      eq(title_now(), "B (2/3)", "<BS> on a field with text is not back")
      eq(vim.api.nvim_win_get_cursor(0)[2], 0, "it is still the native <BS>")
      type_into_field("")
      now_ms = now_ms + 1000 -- a deliberate press, not a held key repeating
      keys("<BS>")
      eq(title_now(), "A (1/3)", "<BS> on an empty field goes back")
      keys("<CR>")
      keys("<C-p>")
      eq(title_now(), "A (1/3)", "<C-p> goes back")
      close_floats()

      -- A held <BS> empties the field and stops there: the repeats are not
      -- presses, or it would delete every earlier answer on its way back.
      open_form(THREE, { back = true })
      type_into_field("1")
      keys("<CR>")
      type_into_field("2")
      keys("<CR>")
      type_into_field("z")
      keys("<BS>")
      type_into_field("")
      for _ = 1, 40 do
        now_ms = now_ms + 30
        keys("<BS>")
        eq(title_now(), "C (3/3)", "a repeat is not a press")
      end
      now_ms = now_ms + 400
      keys("<BS>")
      eq(title_now(), "B (2/3)", "a press after a pause goes back")
      eq(field_text(), "2", "to an answer that is still there")
      close_floats()
    end)
    vim.uv.hrtime = real_hrtime
    ok(done, tostring(err))
  end

  -- The button row stays right under a one-line field and in view: a paste
  -- that carries a newline is joined, a window scrolled sideways by a long
  -- answer gets the row shifted by the same amount (and is still clickable).
  do
    open_form(THREE, { back = true })
    local row = vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "some/path", "" })
    vim.cmd("doautocmd <nomodeline> TextChanged")
    eq(
      table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|"),
      "some/path|" .. row,
      "a pasted newline goes"
    )
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { "one", "two", "" })
    vim.cmd("doautocmd <nomodeline> TextChanged")
    eq(
      table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "|"),
      "one two|" .. row,
      "lines are joined"
    )
    type_into_field(string.rep("x", 80))
    vim.fn.winrestview({ leftcol = 30 })
    vim.cmd("doautocmd <nomodeline> CursorMovedI")
    eq(
      vim.api.nvim_buf_get_lines(0, 1, 2, false)[1],
      string.rep(" ", 30) .. row,
      "the row follows the scroll"
    )
    click_button("Next ↵")
    eq(title_now(), "B (2/3)", "and a click where it is drawn presses it")
    close_floats()
  end

  -- <Esc> keeps its meaning, a required field has no Skip and aborts.
  do
    local r = open_form({
      { name = "a", label = "A" },
      { name = "b", label = "B", required = true },
    }, { back = true })
    keys("<CR>")
    ok(not button_row_text():find("Skip", 1, true), "a required field cannot be skipped")
    keys("<S-Tab>")
    keys("<CR>")
    keys("<Esc>")
    ok(r.cancelled, "<Esc> on a required field aborts, back and forth included")
    ok(r.values == nil, "and nothing is submitted")
    close_floats()
  end

  -- Buttons by keyboard.
  do
    local r = open_form(THREE, { back = true })
    type_into_field("typed")
    keys("<Down>")
    ok(not vim.bo.modifiable, "the labels are read-only while the buttons have focus")
    keys("<CR>")
    eq(title_now(), "B (2/3)", "<CR> on Next submits the field")
    keys("<Down>")
    keys("hh") -- Next -> Skip -> Back
    keys("<CR>")
    eq(title_now(), "A (1/3)", "<CR> on Back goes back")
    eq(field_text(), "typed")
    keys("<Down>")
    keys("<Up>")
    ok(vim.bo.modifiable, "<Up> returns to the field")
    ok(r.cancelled == nil)
    close_floats()
  end

  -- Buttons by mouse.
  do
    open_form(THREE, { back = true })
    type_into_field("clicked")
    click_button("Next ↵")
    eq(title_now(), "B (2/3)", "a click presses Next")
    click_button("← Back")
    eq(title_now(), "A (1/3)", "a click presses Back")
    eq(field_text(), "clicked")
    click_button("Skip")
    eq(title_now(), "B (2/3)", "a click presses Skip")
    click_at(2, 1)
    eq(title_now(), "B (2/3)", "blank space on the row does nothing")
    close_floats()
  end

  -- The shared row helper, and kit.confirm on top of it.
  do
    local buttons = require("lib.nvim.ui.kit.buttons")
    local line, ranges = buttons.layout({ "A", "B" }, 20, 3)
    eq(vim.trim(line), "[ A ]  [ B ]", "centered row")
    eq(line:sub(ranges[2].start_col + 1, ranges[2].end_col), "[ B ]", "a range covers its box")
    eq(buttons.wrap(1, -1, 3), 3, "focus wraps")

    local confirm = require("lib.nvim.ui.kit.confirm")
    local answer = "unset"
    confirm.open({
      question = "Sure?",
      on_answer = function(a)
        answer = a
      end,
    })
    local buf = vim.api.nvim_get_current_buf()
    for row, text in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      local from = text:find("[ No ]", 1, true)
      if from then
        local real = vim.fn.getmousepos
        vim.fn.getmousepos = function()
          return { winid = vim.api.nvim_get_current_win(), line = row, column = from + 2 }
        end
        confirm.click()
        vim.fn.getmousepos = real
      end
    end
    eq(answer, false, "kit.confirm still answers the button that was clicked")
    confirm.close()
  end

  close_floats()
end
