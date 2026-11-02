-- Test code: when something here comes back nil, this file must crash and
-- name it rather than silently skip -- see TESTS/ui_kit_spec.lua's header.
---@diagnostic disable: need-check-nil
-- TESTS/ui_kit_oneline_spec.lua -- lib.nvim.ui.kit's copy of ui.nvim's
-- TESTS/ui_kit_oneline_spec.lua (the kit exists twice, see ui.nvim's
-- docs/modules.md): a prompt's line and a button's label are ONE line of text.
--
-- `nvim_buf_set_lines` refuses a string with a newline in it, and a prompt's
-- `default` or a button's label reached it unchanged: the call raised, and the
-- scratch buffer `make_scratch` had just made stayed behind. They are flattened to
-- one line now (as `kit.sheet` always did for its own text); what `kit.confirm`
-- hands back stays the caller's own string.

return function(H)
  H.confirm_focus_first() -- the safe button is the default now; these specs drive Yes
  local eq, ok = H.eq, H.ok
  local kit = require("lib.nvim.ui.kit")
  local api = vim.api

  vim.o.showmode = false

  local function keys(k)
    api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), "x", false)
  end

  local function close_floats()
    for _ = 1, 10 do
      local closed = false
      for _, w in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_is_valid(w) and api.nvim_win_get_config(w).relative ~= "" then
          pcall(api.nvim_win_close, w, true)
          closed = true
        end
      end
      if not closed then
        return
      end
    end
  end

  local function lines_of(bufnr)
    return api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  local done, err = pcall(function()
    -- kit.input's default, and nothing left behind.
    for name, default in pairs({
      ["a newline"] = "a\nb",
      ["a CRLF"] = "a\r\nb",
      ["several newlines"] = "a\n\n\nb",
    }) do
      local before = #api.nvim_list_bufs()
      local surf = kit.input({ default = default })
      ok(surf ~= nil, "the prompt opens instead of raising for " .. name)
      eq(table.concat(lines_of(surf.bufnr), "|"), "a b", "flattened for " .. name)
      surf:close()
      eq(#api.nvim_list_bufs(), before, "no buffer is left behind for " .. name)
    end

    local with_buttons =
      kit.input({ default = "x\ny", buttons = { { id = "submit", label = "OK" } } })
    eq(lines_of(with_buttons.bufnr)[1], "x y", "flattened above a button row too")
    eq(#lines_of(with_buttons.bufnr), 2)
    eq(table.concat(lines_of(kit.input({ default = 5 }).bufnr), "|"), "5", "a number is text")
    close_floats()

    -- ... and a kit.form field's.
    local got
    local form = kit.form({
      fields = { { name = "note", default = "n1\nn2" } },
      on_submit = function(v)
        got = v
      end,
    })
    eq(lines_of(form.bufnr)[1], "n1 n2", "a form field's default is flattened")
    keys("<CR>")
    eq(got.note, "n1 n2")
    close_floats()

    -- A button label: in a prompt's row ...
    local submitted
    local surf = kit.input({
      buttons = { { id = "skip", label = "Sk\nip" }, { id = "submit", label = "O\r\nK" } },
      on_submit = function(v)
        submitted = v
      end,
    })
    ok(surf ~= nil, "a prompt with a newline in a button label opens")
    ok(lines_of(surf.bufnr)[2]:find("[ Sk ip ]  [ O K ]", 1, true) ~= nil, "drawn on one line")
    keys("<CR>")
    eq(submitted, "", "and its buttons still work")
    close_floats()

    -- ... in kit.confirm, which hands back the choice as it was given ...
    local before = #api.nvim_list_bufs()
    local answered
    local confirm = require("lib.nvim.ui.kit.confirm")
    local dialog = confirm.open({
      question = "Sure?",
      choices = { "a\nb", "c" },
      on_answer = function(v)
        answered = v
      end,
    })
    ok(dialog ~= nil, "the dialog opens instead of raising")
    local row = lines_of(dialog.bufnr)
    ok(row[#row]:find("[ a b ]  [ c ]", 1, true) ~= nil, "drawn on one line")
    keys("<CR>")
    eq(answered, "a\nb", "the answer is the caller's own string")
    eq(#api.nvim_list_bufs(), before, "no buffer is left behind")

    -- ... and in a sheet's button row.
    local sheet = kit.sheet({
      submit_label = "Go\nnow",
      cancel_label = "No",
      fields = { { name = "a" } },
      on_submit = function() end,
    })
    ok(sheet ~= nil, "a sheet with a newline in a button label opens")
    local srow = lines_of(sheet.bufnr)
    ok(srow[#srow]:find("[ Go now ]  [ No ]", 1, true) ~= nil, "drawn on one line")
  end)

  close_floats()
  assert(done, err)
end
