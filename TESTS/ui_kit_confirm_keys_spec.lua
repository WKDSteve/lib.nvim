-- Test code: when something here comes back nil, this file must crash and
-- name it rather than silently skip -- see TESTS/ui_kit_spec.lua's header.
---@diagnostic disable: need-check-nil
-- TESTS/ui_kit_confirm_keys_spec.lua -- lib.nvim.ui.kit.confirm options: default focus, & hotkeys,
-- <C-c>, focus loss, kind, legend. Port of ui.nvim's spec of the same name.

return function(H)
  local restores = {}
  --- Every stub is put back, also when the body fails (shared run of lib.nvim).
  local function stub(tbl, key, fn)
    restores[#restores + 1] = { tbl, key, tbl[key] }
    tbl[key] = fn
  end
  local ok_body, err_body = pcall(function()
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

    confirm.close()

    --- Open a dialog; returns its answers (a list: `nil` becomes the string "nil") and its surface.
    local function open(opts)
      local calls = {}
      if opts.default == nil and not opts.safe_default then
        opts.default = 1 -- these tests drive the first button; `safe_default` keeps the real default
      end
      opts.on_answer = function(v)
        calls[#calls + 1] = v == nil and "nil" or v
      end
      local surf = kit.confirm(opts)
      ok(surf, "the dialog opened")
      return calls, surf
    end

    --- Type `keys` into the focused dialog the way a person would.
    local function type_keys(keys)
      api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end

    local function wait_for(fn, msg)
      ok(vim.wait(800, fn, 5), msg)
    end

    local warnings = {}
    stub(vim, "notify", function(msg)
      warnings[#warnings + 1] = msg
    end)

    -- ---------------------------------------------------------------- default
    local calls = open({ question = "Delete?", default = 2 })
    eq(confirm.current_focus(), 2, "default = 2 starts on the second button")
    type_keys("<CR>")
    eq(calls, { false }, "<CR> on the default 'No' answers false")

    open({ question = "Which?", choices = { "a", "b", "c" }, default = "c" })
    eq(confirm.current_focus(), 3, "default by label")
    confirm.cancel()
    open({ question = "Which?", choices = { "a", "b" }, default = 9 })
    eq(
      confirm.current_focus(),
      1,
      "a default that names no button falls back to the first (no No/Cancel label)"
    )
    confirm.cancel()

    -- without a default the safe button is focused: No, a no/cancel label, else the first button
    calls = open({ question = "Delete?", safe_default = true })
    eq(confirm.current_focus(), 2, "Yes/No without default starts on No")
    type_keys("<CR>")
    eq(calls, { false }, "a stray <CR> answers No")
    open({ question = "Which?", choices = { "Delete", "Cancel", "Later" }, safe_default = true })
    eq(confirm.current_focus(), 2, "a Cancel label is the safe button")
    confirm.cancel()
    open({ question = "Which?", choices = "&Remove\n&Keep", safe_default = true })
    eq(confirm.current_focus(), 1, "no no/cancel label: the first button")
    confirm.cancel()
    open({ question = "Which?", choices = { "a", "b" }, default = 1 })
    eq(confirm.current_focus(), 1, "an explicit default 1 still starts on the first button")
    confirm.cancel()

    -- ---------------------------------------------------------------- hotkeys
    calls = open({ question = "Sure?" })
    type_keys("n")
    eq(calls, { false }, "n answers No on the Yes/No default")
    calls = open({ question = "Sure?" })
    type_keys("y")
    eq(calls, { true }, "y answers Yes")
    calls = open({ question = "Sure?" })
    type_keys("Y")
    eq(calls, { true }, "and so does the capital")

    calls = open({ question = "Which?", choices = { "first", "second", "third" } })
    type_keys("3")
    eq(calls, { "third" }, "a digit picks the button")

    -- a vim.fn.confirm string: the letters are hotkeys and are not shown
    local surf
    calls, surf = open({ question = "Remove?", choices = "&Delete\n&Cancel\nRe&name" })
    local line = api.nvim_buf_get_lines(surf.bufnr, 0, -1, false)
    ok(table.concat(line, "\n"):find("%[ Delete %]"), "the & is not drawn")
    ok(table.concat(line, "\n"):find("%[ Rename %]"), "also in the middle of a label")
    local accents = {}
    for _, m in ipairs(api.nvim_buf_get_extmarks(surf.bufnr, -1, 0, -1, { details = true })) do
      if m[4].hl_group == "KitAccent" then
        accents[#accents + 1] =
          api.nvim_buf_get_text(surf.bufnr, m[2], m[3], m[2], m[4].end_col, {})[1]
      end
    end
    table.sort(accents)
    eq(accents, { "C", "D", "n" }, "the hotkey letters are drawn with the accent")
    type_keys("n")
    eq(calls, { "Rename" }, "the & letter picks the button, and answers the label without &")
    calls = open({ question = "Remove?", choices = "&Delete\n&Cancel" })
    type_keys("C") -- capital works too
    eq(calls, { "Cancel" }, "the capital of an & letter")

    -- a list is taken as it is: a & in it is text
    surf = select(2, open({ question = "Q?", choices = { "R&D", "Other" } }))
    ok(
      table.concat(api.nvim_buf_get_lines(surf.bufnr, 0, -1, false), "\n"):find("R&D", 1, true),
      "a & in a list stays"
    )
    confirm.cancel()

    -- keys that move or cancel are never a hotkey, and a taken key goes to the first button
    warnings = {}
    calls = open({ question = "Q?", choices = "&Help\n&Save\n&Send" })
    ok(#warnings == 1, "what was refused is reported once")
    ok(warnings[1]:find("Help", 1, true) and warnings[1]:find("Send", 1, true), "naming both")
    type_keys("l") -- still moves focus
    eq(confirm.current_focus(), 2, "h/l keep moving focus")
    type_keys("s")
    eq(calls, { "Save" }, "the taken key went to the first button that asked")

    -- ---------------------------------------------------------------- <C-c>
    calls = open({ question = "Q?" })
    type_keys("<C-c>")
    eq(calls, { false }, "<C-c> cancels")
    calls = open({ question = "Q?", choices = { "a", "b" } })
    type_keys("<C-c>")
    eq(calls, { "nil" }, "<C-c> on a choices list answers nil")

    -- ---------------------------------------------------------------- focus lost
    local main = api.nvim_list_wins()[1]
    calls = open({ question = "Q?" })
    api.nvim_set_current_win(main)
    wait_for(function()
      return #calls > 0
    end, "moving focus away cancels")
    eq(calls, { false }, "as a cancel, once")
    eq(confirm.is_open(), false, "and the dialog is gone")

    calls = open({ question = "Q?", keep_on_focus_lost = true })
    api.nvim_set_current_win(main)
    vim.wait(80, function()
      return false
    end, 5)
    eq(confirm.is_open(), true, "keep_on_focus_lost keeps it open")
    eq(calls, {}, "unanswered")
    confirm.close()

    -- a question nobody asked for is not answered "no" by a window change
    local asked = {}
    kit.ask({
      question = "Asked?",
      on_answer = function(v)
        asked[#asked + 1] = v
      end,
    })
    ok(confirm.is_open(), "the ask is showing")
    api.nvim_set_current_win(main)
    vim.wait(80, function()
      return false
    end, 5)
    eq(confirm.is_open(), true, "kit.ask keeps its dialog when focus moves")
    eq(asked, {}, "and has not answered")
    confirm.close()
    wait_for(function()
      return #asked > 0
    end, "close() answers it")

    -- ---------------------------------------------------------------- kind, legend
    surf = select(2, open({ question = "Delete everything?", kind = "danger", title = "Danger" }))
    ok(
      vim.wo[surf.winid].winhighlight:find("FloatBorder:KitError_", 1, true),
      "danger colours the border"
    )
    ok(vim.wo[surf.winid].winhighlight:find("FloatTitle:KitError_", 1, true), "and the title")
    confirm.cancel()
    surf = select(2, open({ question = "Careful", kind = "warn" }))
    ok(vim.wo[surf.winid].winhighlight:find("FloatBorder:KitWarn_", 1, true), "warn")
    confirm.cancel()

    surf = select(2, open({ question = "With a legend?", legend = true }))
    local bar = vim.wo[surf.winid].winbar
    ok(bar:find("select", 1, true) and bar:find("cancel", 1, true), "the legend lists the keys")
    ok(bar:find("y/n", 1, true), "including y/n for the Yes/No default")
    local rows = #api.nvim_buf_get_lines(surf.bufnr, 0, -1, false)
    ok(api.nvim_win_get_height(surf.winid) >= rows + 1, "the winbar row is on top of the content")
    confirm.cancel()
    surf = select(2, open({ question = "No legend", choices = { "a", "b" }, legend = true }))
    ok(not vim.wo[surf.winid].winbar:find("y/n", 1, true), "no y/n in the legend of a choices list")
    confirm.cancel()
    surf = select(2, open({ question = "Plain" }))
    eq(vim.wo[surf.winid].winbar, "", "no legend unless asked for")
    eq(vim.wo[surf.winid].winhighlight:find("FloatBorder:KitError", 1, true), nil, "no kind colour")
    confirm.cancel()

    -- ---------------------------------------------------------------- review fixes
    -- ask with a vim.fn.confirm string: custom choices, the label comes back
    local got = "none"
    kit.ask({
      question = "Remove?",
      choices = "&Delete\n&Cancel",
      on_answer = function(v)
        got = v
      end,
    })
    ok(confirm.is_open(), "ask with a choices string shows its dialog")
    -- keys typed ahead for the editor must not answer a question that popped up on its own
    type_keys("d")
    eq(got, "none", "a hotkey right after an ask opens is ignored")
    ok(confirm.is_open(), "and the question is still there")
    vim.wait(confirm.ASK_HOTKEY_GRACE_MS + 100)
    type_keys("d")
    eq(got, "Delete", "ask with a choices string answers the label, not false")

    -- a button labelled with a digit owns that digit, whatever its position (a 1-5 scale after "Skip"/"Stop")
    local scale = "none"
    kit.confirm({
      question = "Value?",
      choices = { "Skip", "Stop", "1", "2", "3", "4", "5" },
      on_answer = function(v)
        scale = v
      end,
    })
    type_keys("5")
    eq(scale, "5", "the key 5 picks the button 5, not the fifth button")
    scale = "none"
    kit.confirm({
      question = "Value?",
      choices = { "Skip", "Stop", "1", "2", "3", "4", "5" },
      on_answer = function(v)
        scale = v
      end,
    })
    type_keys("2")
    eq(scale, "2", "and 2 the button 2, not Stop")

    -- kit.prompt with a choices string uses the button dialog too, not a Yes/No list
    local prompted = "none"
    kit.prompt({
      question = "Remove?",
      choices = "&Delete\n&Keep",
      on_answer = function(v)
        prompted = v
      end,
    })
    ok(confirm.is_open(), "a choices string in kit.prompt shows the button dialog")
    confirm.pick(2)
    eq(prompted, "Keep", "and answers the label")
    got = "none"
    kit.ask({
      question = "Remove?",
      choices = "&Delete\n&Cancel",
      on_answer = function(v)
        got = v
      end,
    })
    confirm.cancel()
    eq(got, nil, "and nil when dismissed")

    -- the accents survive moving the focus (the repaint clears only the focus highlight)
    local function accent_count(buf)
      local n = 0
      for _, m in ipairs(api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        if m[4].hl_group == "KitAccent" then
          n = n + 1
        end
      end
      return n
    end
    surf = select(2, open({ question = "Q?", choices = "&Delete\n&Cancel" }))
    eq(accent_count(surf.bufnr), 2, "two accents on a fresh dialog")
    confirm.move(1)
    confirm.move(1)
    eq(accent_count(surf.bufnr), 2, "and still two after the focus moved")
    confirm.cancel()

    -- focus that leaves and comes back in the same turn leaves the dialog alone
    surf = select(2, open({ question = "Q?" }))
    api.nvim_set_current_win(main)
    api.nvim_set_current_win(surf.winid)
    vim.wait(80, function()
      return false
    end, 5)
    eq(confirm.is_open(), true, "a focus blip does not close the dialog")
    confirm.cancel()
    -- ... and its autocmd group is gone with it (asking for a deleted group raises)
    eq(
      pcall(api.nvim_get_autocmds, { group = "lib_kit_confirm_focus_" .. surf.winid }),
      false,
      "no hook left"
    )

    -- && is a literal ampersand and an empty piece is no button
    calls, surf = open({ question = "Q?", choices = "Fish && Chips\n&Cancel\n" })
    local text = table.concat(api.nvim_buf_get_lines(surf.bufnr, 0, -1, false), "\n")
    ok(text:find("[ Fish & Chips ]", 1, true), "&& is drawn as one &")
    ok(not text:find("[  ]", 1, true), "a trailing newline makes no empty button")
    eq(#confirm.button_ranges(), 2, "two buttons")
    type_keys("c")
    eq(calls, { "Cancel" }, "the & that is not doubled is the hotkey")

    -- a hotkey that is not ASCII, either case
    calls = open({ question = "Q?", choices = "&Да\n&Нет" })
    type_keys("д")
    eq(calls, { "Да" }, "a Cyrillic hotkey")
    calls = open({ question = "Q?", choices = "&Да\n&Нет" })
    type_keys("Н")
    eq(calls, { "Нет" }, "and its capital")

    -- kind replaces the theme's entries instead of adding a second one
    surf = select(2, open({ question = "Q?", kind = "danger" }))
    local wh = vim.wo[surf.winid].winhighlight
    eq(select(2, wh:gsub("FloatBorder:", "")), 1, "one FloatBorder entry: " .. wh)
    eq(select(2, wh:gsub("FloatTitle:", "")), 1, "one FloatTitle entry: " .. wh)
    confirm.cancel()
    warnings = {}
    open({ question = "Q?", kind = "loud" })
    ok(warnings[1] and warnings[1]:find("unknown kind", 1, true), "an unknown kind is reported")
    confirm.cancel()

    -- a legend row is part of the height budget
    local saved_lines = vim.o.lines
    vim.o.lines = 12
    local fits_ok, fits_err = pcall(function()
      local tall = {}
      for i = 1, 30 do
        tall[i] = "line " .. i
      end
      surf = select(2, open({ question = table.concat(tall, "\n"), legend = true }))
      local rows_used = #api.nvim_buf_get_lines(surf.bufnr, 0, -1, false) + 1
      ok(
        rows_used <= math.max(1, vim.o.lines - 4),
        "content plus the winbar fits the window: " .. rows_used
      )
      confirm.cancel()
    end)
    vim.o.lines = saved_lines
    assert(fits_ok, fits_err)

    -- the position comes with the label: two buttons of the same text can be told apart
    local picked_label, picked_index
    kit.confirm({
      question = "Same text",
      choices = { "Keep", "Keep" },
      default = 1,
      on_answer = function(label, index)
        picked_label, picked_index = label, index
      end,
    })
    confirm.move(1)
    confirm.confirm()
    eq({ picked_label, picked_index }, { "Keep", 2 }, "on_answer gets the label and its index")

    -- kit.prompt (layout buttons) forwards the options
    kit.prompt({
      layout = "buttons",
      question = "Q?",
      choices = { "a", "b", "c" },
      default = 3,
      kind = "warn",
      on_answer = function() end,
    })
    eq(confirm.current_focus(), 3, "default reaches the dialog through kit.prompt")
    confirm.cancel()
  end)
  for i = #restores, 1, -1 do
    local r = restores[i]
    r[1][r[2]] = r[3]
  end
  require("lib.nvim.ui.kit.confirm").close()
  if not ok_body then
    error(err_body, 0)
  end
end
