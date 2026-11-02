-- Test code: when something here comes back nil, this file must crash and
-- name it rather than silently skip -- see TESTS/ui_kit_spec.lua's header.
---@diagnostic disable: need-check-nil
-- TESTS/ui_kit_sheet_spec.lua -- lib.nvim.ui.kit's copy of `kit.sheet`, the
-- one-float form (every field at once, inline validation, Submit/Cancel).
-- The kit code lives in lib.nvim; full behavioural coverage also lives in ui.nvim's
-- TESTS/ui_kit_sheet_spec.lua and TESTS/ui_kit_sheet_ui_spec.lua (the latter
-- in a real, UI-attached Neovim, which a shared headless run like this one
-- cannot be). This file pins what the copy must still do: be reachable as
-- `kit.sheet` and `kit.popup({ type = "sheet" })`, show one row per field, walk
-- the fields by key, block a submit that fails validation (naming the field in
-- red under it and jumping there), and hand on the keyed values.

return function(H)
  local eq, ok = H.eq, H.ok
  local kit = require("lib.nvim.ui.kit")
  local api = vim.api

  vim.o.showmode = false

  local function keys(k)
    api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), "x", false)
  end

  --- What the user typed into row `i`: the buffer plus the `TextChanged` a
  --- real keystroke would have fired.
  local function type_into(surf, i, text)
    api.nvim_buf_set_lines(surf.bufnr, i - 1, i, false, { text })
    api.nvim_exec_autocmds("TextChanged", { buffer = surf.bufnr })
  end

  local function shown_errors(surf)
    local ns = api.nvim_get_namespaces().lib_kit_sheet
    local out = {}
    for _, m in ipairs(api.nvim_buf_get_extmarks(surf.bufnr, ns, 0, -1, { details = true })) do
      for _, vl in ipairs(m[4].virt_lines or {}) do
        out[#out + 1] = vl[1][1]
      end
    end
    return out
  end

  local function close_floats()
    for _, w in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_get_config(w).relative ~= "" then
        pcall(api.nvim_win_close, w, true)
      end
    end
  end

  local result, cancelled
  local function open(fields)
    result, cancelled = nil, false
    return kit.sheet({
      fields = fields,
      on_submit = function(v)
        result = v
      end,
      on_cancel = function()
        cancelled = true
      end,
    })
  end

  local FIELDS = {
    {
      name = "number",
      label = "Number",
      required = true,
      validate = function(v)
        return v:match("^%d+$") ~= nil, "digits only"
      end,
    },
    { name = "area", label = "Area", kind = "select", choices = { "one", "two" } },
    { name = "title", label = "Title" },
  }

  -- Reachable both ways, one row per field then the button row.
  local surf = open(FIELDS)
  ok(surf ~= nil and surf:is_valid(), "kit.sheet opens a float")
  local lines = api.nvim_buf_get_lines(surf.bufnr, 0, -1, false)
  eq(#lines, 5, "three field rows, a blank line, the buttons")
  eq(lines[2], "one", "a select shows its first choice")
  ok(lines[5]:find("[ Submit ]  [ Cancel ]", 1, true) ~= nil, "the button row")
  eq(surf:state().focus, "number")
  for _, name in ipairs({ "autoindent", "smartindent", "cindent" }) do
    eq(vim.bo[surf.bufnr][name], false, name .. " is off in a sheet")
  end
  close_floats()
  local via_popup = kit.popup({ type = "sheet", fields = FIELDS, on_submit = function() end })
  ok(via_popup ~= nil and via_popup:is_valid(), "kit.popup({ type = 'sheet' })")
  close_floats()

  -- Keys: <Tab> walks, a select cycles, <Esc> cancels.
  surf = open(FIELDS)
  keys("<Tab>")
  eq(surf:state().focus, "area")
  keys("l")
  eq(surf:state().values.area, "two", "l cycles the select")
  keys("<Tab><Tab><Tab>")
  eq(surf:state().focus, "cancel", "past the last field are the two buttons")
  keys("<Esc>")
  ok(cancelled, "<Esc> cancels")
  ok(not surf:is_valid())

  -- Validation: blocked, red message under the field, focus jumps there.
  surf = open(FIELDS)
  keys("<Tab><Tab>")
  eq(surf:state().focus, "title")
  surf:submit()
  eq(result, nil, "a blank required field blocks submit")
  eq(surf:state().focus, "number", "and the focus jumps to it")
  eq(shown_errors(surf)[1], "✗ required")
  type_into(surf, 1, "12x")
  surf:submit()
  eq(shown_errors(surf)[1], "✗ digits only", "validate()'s message")
  type_into(surf, 1, "977")
  eq(#shown_errors(surf), 0, "gone as soon as the value is right")
  type_into(surf, 3, "a title")
  keys("<Tab><Tab><Tab><CR>") -- number -> area -> title -> Submit, pressed
  ok(result ~= nil, "Submit with every field fine hands the values on")
  eq(result.number, "977")
  eq(result.area, "one")
  eq(result.title, "a title")
  ok(not surf:is_valid(), "and closes")

  -- A refused click on [ Submit ] must not stop Insert mode on its way: the click
  -- used to move the focus onto the button first (a stopinsert that lands once the
  -- mapping returns), so the startinsert of the refused submit, which puts the focus
  -- back on the bad field, was ignored and the field stood in Normal mode.
  surf = open(FIELDS)
  eq(surf:state().focus, "number")
  local stops = 0
  local real_cmd = vim.cmd
  vim.cmd = setmetatable({}, {
    __call = function(_, c, ...)
      if c == "stopinsert" then
        stops = stops + 1
      end
      return real_cmd(c, ...)
    end,
    __index = real_cmd,
  })
  local real_mousepos = vim.fn.getmousepos
  local button_line = api.nvim_buf_get_lines(surf.bufnr, 4, 5, false)[1]
  local from = assert(button_line:find("[ Submit ]", 1, true))
  vim.fn.getmousepos = function()
    return { winid = surf.winid, line = 5, column = from + 2 }
  end
  local clicked, click_err = pcall(vim.fn.maparg("<LeftMouse>", "n", false, true).callback)
  vim.cmd = real_cmd
  vim.fn.getmousepos = real_mousepos
  assert(clicked, click_err)
  eq(surf:state().focus, "number", "the blank required field has the focus again")
  eq(result, nil, "the submit was refused")
  eq(stops, 0, "nothing stopped Insert mode on the way")
  close_floats()
end
