-- Test code: when something here comes back nil, this file must crash and
-- name it rather than silently skip -- see TESTS/ui_kit_spec.lua's header.
---@diagnostic disable: need-check-nil
-- TESTS/ui_kit_confirm_layout_spec.lua -- lib.nvim.ui.kit.confirm keeps its buttons inside the window: wrapped question, buttons in several rows, cut labels. Port of ui.nvim's spec of the same name.

return function(H)
  H.confirm_focus_first() -- the safe button is the default now; these specs drive Yes
  local kit = require("lib.nvim.ui.kit")
  local confirm = require("lib.nvim.ui.kit.confirm")
  local api = vim.api

  local function eq(actual, expected, msg)
    H.ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function ok(cond, msg)
    H.ok(cond, msg)
  end

  local saved_cols, saved_lines = vim.o.columns, vim.o.lines
  local function open(opts)
    local seen = {}
    opts.on_answer = function(v)
      seen[#seen + 1] = v == nil and "nil" or v
    end
    local surf = kit.confirm(opts)
    ok(surf, "the dialog opened")
    return surf, seen
  end

  --- Every line fits the window, and every button's range lies inside its line.
  local function assert_inside(surf, label)
    local win_w = api.nvim_win_get_width(surf.winid)
    local lines = api.nvim_buf_get_lines(surf.bufnr, 0, -1, false)
    for i, l in ipairs(lines) do
      ok(
        vim.fn.strdisplaywidth(l) <= win_w,
        ("%s: line %d is %d wide, window %d"):format(label, i, vim.fn.strdisplaywidth(l), win_w)
      )
    end
    local ranges = confirm.button_ranges()
    for i, r in ipairs(ranges) do
      local line = lines[r.row + 1]
      ok(line, ("%s: button %d lies on a line of the buffer"):format(label, i))
      ok(r.end_col <= #line, ("%s: button %d ends inside its line"):format(label, i))
      ok(
        line:sub(r.start_col + 1, r.start_col + 1) == "[",
        ("%s: button %d starts at its box"):format(label, i)
      )
    end
    return win_w, lines, ranges
  end

  local function restore()
    confirm.close()
    vim.o.columns, vim.o.lines = saved_cols, saved_lines
  end

  vim.o.columns, vim.o.lines = 80, 30

  -- a long question: wrapped, the buttons are in the window
  local surf = open({ question = string.rep("long-word ", 20) .. "end" })
  local win_w, lines = assert_inside(surf, "long question")
  ok(win_w <= 76, "the window is no wider than the float ceiling")
  ok(#lines > 3, "the question was wrapped into several lines")
  restore()

  -- a single word wider than the window is broken between characters
  surf = open({ question = string.rep("x", 200) })
  lines = select(2, assert_inside(surf, "one long word"))
  ok(#lines > 3, "the word was broken")
  restore()

  -- many wide buttons: packed into several rows, focus walks over all of them, the answer is the label
  local choices = {
    "Update all references",
    "Inspect first",
    "Leave as-is",
    "Cancel the operation",
    "Something else",
  }
  local seen
  surf, seen = open({ question = "Pick", choices = choices })
  local _, _, ranges = assert_inside(surf, "five buttons")
  local rows = {}
  for _, r in ipairs(ranges) do
    rows[r.row] = true
  end
  ok(vim.tbl_count(rows) > 1, "the buttons were packed into more than one row")
  for _ = 1, 3 do
    confirm.move(1)
  end
  eq(confirm.current_focus(), 4, "focus walks over the packed buttons")
  confirm.confirm()
  eq(seen, { "Cancel the operation" }, "the answer is the focused button's label")

  -- a label wider than the window is cut, the answer is not
  local long_label = string.rep("w", 120)
  surf, seen = open({ question = "Pick", choices = { long_label, "Other" } })
  assert_inside(surf, "long label")
  confirm.confirm()
  eq(seen, { long_label }, "the full label is answered")

  -- a narrow editor
  vim.o.columns = 30
  surf = open({
    question = "Delete the file with a rather long name?",
    choices = { "Delete", "Keep", "Cancel" },
  })
  assert_inside(surf, "narrow editor")
  restore()
  vim.o.columns, vim.o.lines = 80, 30

  -- a question taller than the editor leaves the buttons visible
  vim.o.lines = 12
  local tall = {}
  for i = 1, 40 do
    tall[i] = "line " .. i
  end
  surf = open({ question = table.concat(tall, "\n") })
  local win_h = api.nvim_win_get_height(surf.winid)
  local buf_lines = api.nvim_buf_get_lines(surf.bufnr, 0, -1, false)
  ok(
    #buf_lines <= win_h,
    ("every line is visible: %d lines, window %d high"):format(#buf_lines, win_h)
  )
  ok(buf_lines[#buf_lines]:find("%[ Yes %]"), "the buttons are the last line")
  restore()

  -- the buttons alone fill a tiny editor: the question gives way, the buttons are what is shown
  vim.o.columns, vim.o.lines = 30, 8
  surf = open({
    question = "Pick one of these",
    choices = {
      "Update all references",
      "Inspect first",
      "Leave as-is",
      "Cancel the operation",
      "Something else",
    },
  })
  local tiny = api.nvim_buf_get_lines(surf.bufnr, 0, -1, false)
  ok(not table.concat(tiny, "\n"):find("Pick one"), "the question made room for the buttons")
  ok(tiny[1]:find("%["), "the first line is a button row")
  restore()
  vim.o.columns, vim.o.lines = 80, 30

  -- one huge unbroken line (minified JSON, base64): cut before it is wrapped, not quadratic in its length
  local started = vim.uv.hrtime()
  surf = open({ question = "Send " .. string.rep("x", 60000) .. "?" })
  local took = (vim.uv.hrtime() - started) / 1e9
  ok(took < 1, ("a 60k-character question opens in %.2f s"):format(took))
  assert_inside(surf, "huge question")
  ok(
    table.concat(api.nvim_buf_get_lines(surf.bufnr, 0, -1, false), "\n"):find("…", 1, true),
    "and says it was cut"
  )
  restore()
  vim.o.columns, vim.o.lines = 80, 30

  -- a short question is unchanged: one row, nothing cut
  surf = open({ question = "Delete?" })
  local _, short_lines, short_ranges = assert_inside(surf, "short question")
  eq(#short_lines, 3, "question, blank, buttons")
  eq(#short_ranges, 2, "two buttons")
  eq(short_ranges[1].row, short_ranges[2].row, "on one row")
  restore()
end
