-- Test code: when something here comes back nil, this file must crash and
-- name it rather than silently skip -- see TESTS/ui_kit_spec.lua's header.
---@diagnostic disable: need-check-nil
-- TESTS/ui_dialog_spec.lua -- lib.nvim.ui.dialog: one wrapper over ui.kit / the lib copy / native.
-- Every backend, every function, and the contract: the callback runs once and never before the
-- call has returned.

return function(H)
  local eq, ok = H.eq, H.ok
  local api = vim.api

  local function same(actual, expected, msg)
    ok(
      vim.deep_equal(actual, expected),
      ("%s: expected %s, got %s"):format(msg, vim.inspect(expected), vim.inspect(actual))
    )
  end
  local function wait_for(fn, msg)
    ok(vim.wait(800, fn, 5), msg)
  end
  local function idle(ms)
    vim.wait(ms, function()
      return false
    end, 5)
  end

  local restores = {}
  --- Put `value` in `tbl[key]` for the rest of the spec; everything is restored at the end.
  local function stub(tbl, key, value)
    restores[#restores + 1] = { tbl, key, tbl[key] }
    tbl[key] = value
  end

  --- `require("ui.kit")` raises (ui.nvim not installed).
  local function without_ui_kit()
    stub(package.loaded, "ui.kit", nil)
    stub(package.preload, "ui.kit", function()
      error("module 'ui.kit' not found")
    end)
  end

  --- A kit that records what it was asked and answers when the test says so.
  local function fake_kit()
    local kit = { confirm_calls = {}, ask_calls = {}, input_calls = {} }
    kit.confirm = function(o)
      kit.confirm_calls[#kit.confirm_calls + 1] = o
      return {}
    end
    kit.ask = function(o)
      kit.ask_calls[#kit.ask_calls + 1] = o
    end
    kit.input = function(o)
      kit.input_calls[#kit.input_calls + 1] = o
      return {}
    end
    return kit
  end

  local ok_body, err_body = pcall(function()
    local dialog = require("lib.nvim.ui.dialog")
    stub(package.loaded, "ui.kit", nil)

    -- ------------------------------------------------------------ backend 1: ui.kit
    local ui_kit = fake_kit()
    stub(package.loaded, "ui.kit", ui_kit)
    eq(dialog.backend(), "ui.kit", "ui.kit is preferred when it loads")

    local got = {}
    local used = dialog.confirm({
      question = "Delete?",
      default = 2,
      kind = "danger",
      on_answer = function(v)
        got[#got + 1] = v
      end,
    })
    eq(used, "ui.kit", "confirm reports the backend")
    eq(#ui_kit.confirm_calls, 1, "the question went to ui.kit")
    eq(ui_kit.confirm_calls[1].question, "Delete?", "with its question")
    eq(ui_kit.confirm_calls[1].default, 2, "and the options of the kit")
    eq(ui_kit.confirm_calls[1].kind, "danger", "kind too")
    ui_kit.confirm_calls[1].on_answer(true)
    ui_kit.confirm_calls[1].on_answer(false)
    same(got, { true }, "answered once, a second answer from the kit is ignored")

    -- an answer given while the dialog is being opened waits for the next turn
    ui_kit.confirm = function(o)
      o.on_answer(true)
      return {}
    end
    got = {}
    dialog.confirm({
      question = "At once?",
      on_answer = function(v)
        got[#got + 1] = v
      end,
    })
    same(got, {}, "not called before confirm() returned")
    wait_for(function()
      return #got > 0
    end, "an answer given while opening arrives on the next turn")
    same(got, { true }, "exactly once")

    -- ask goes to kit.ask
    got = {}
    used = dialog.ask({
      question = "Later?",
      on_answer = function(v)
        got[#got + 1] = v
      end,
    })
    eq(used, "ui.kit", "ask uses the kit's queued question")
    eq(#ui_kit.ask_calls, 1, "kit.ask got it")
    ui_kit.ask_calls[1].on_answer(false)
    same(got, { false }, "and its answer")

    -- yesno: No first and focused, the label accepts, a dismissal declines, `unprompted` goes through ask
    local accepted_list = {}
    local function push_accepted(v)
      accepted_list[#accepted_list + 1] = v
    end
    local yn
    ui_kit.confirm = function(o)
      yn = o
      return {}
    end
    dialog.yesno("Delete it?", "delete & go", push_accepted)
    eq(yn.choices, "&No\n&Yes, delete && go", "No first, the label's ampersand escaped")
    eq(yn.default, 1, "No is focused")
    yn.on_answer("Yes, delete & go", 2)
    dialog.yesno("Delete it?", "delete & go", push_accepted)
    yn.on_answer(nil)
    same(accepted_list, { true, false }, "the label accepts, a dismissal declines")
    dialog.yesno("All ticked?", "finish", push_accepted, { unprompted = true })
    eq(
      #ui_kit.ask_calls > 0 and ui_kit.ask_calls[#ui_kit.ask_calls].choices,
      "&No\n&Yes, finish",
      "unprompted -> ask"
    )
    ui_kit.ask_calls[#ui_kit.ask_calls].on_answer("Yes, finish", 2)
    eq(accepted_list[3], true, "and it answers")

    -- input: callback style (vim.ui.input) and kit style
    got = {}
    used = dialog.input({ prompt = "Name", default = "x" }, function(v)
      got[#got + 1] = v == nil and "nil" or v
    end)
    eq(used, "ui.kit", "input goes to ui.kit")
    eq(ui_kit.input_calls[1].default, "x", "with its options")
    ui_kit.input_calls[1].on_submit("typed")
    ui_kit.input_calls[1].on_cancel()
    same(got, { "typed" }, "callback style: the value, once")
    got = {}
    dialog.input({ prompt = "Name" }, function(v)
      got[#got + 1] = v == nil and "nil" or v
    end)
    ui_kit.input_calls[2].on_cancel()
    same(got, { "nil" }, "callback style: nil when cancelled")
    local submitted, cancelled, backed
    dialog.input({
      prompt = "Kit style",
      on_submit = function(v)
        submitted = v
      end,
      on_cancel = function()
        cancelled = true
      end,
    })
    ui_kit.input_calls[3].on_submit("kit")
    eq(submitted, "kit", "kit style: on_submit")
    dialog.input({
      prompt = "Kit style",
      on_submit = function() end,
      on_cancel = function()
        cancelled = true
      end,
    })
    ui_kit.input_calls[4].on_cancel()
    eq(cancelled, true, "kit style: on_cancel")

    -- leaving through the caller's own "back" answers too, and the caller's on_back runs
    got, backed = {}, false
    dialog.input({
      prompt = "Step 2",
      on_back = function()
        backed = true
      end,
    }, function(v)
      got[#got + 1] = v == nil and "nil" or v
    end)
    ui_kit.input_calls[5].on_back()
    same(got, { "nil" }, "on_back: the callback gets nil")
    eq(backed, true, "and the caller's on_back ran")

    -- choose: the answer is the index, 0 when dismissed; the type colours the border
    ui_kit.confirm = fake_kit().confirm
    ui_kit.confirm_calls = {}
    local recording = ui_kit.confirm
    ui_kit.confirm = function(o)
      ui_kit.confirm_calls[#ui_kit.confirm_calls + 1] = o
      return recording(o)
    end
    got = {}
    used = dialog.choose("Save?", "&Save\n&Discard\n&Cancel", 2, function(i)
      got[#got + 1] = i
    end, "Warning")
    eq(used, "ui.kit", "choose rides on confirm")
    local c = ui_kit.confirm_calls[#ui_kit.confirm_calls]
    eq(c.default, 2, "the default button")
    eq(c.kind, "warn", "Warning -> warn")
    eq(c.choices, "&Save\n&Discard\n&Cancel", "the choices string goes to the kit as it is")
    c.on_answer("Discard")
    same(got, { 2 }, "the index of the label without the &")
    got = {}
    dialog.choose("Save?", { "a", "b" }, 0, function(i)
      got[#got + 1] = i
    end)
    ui_kit.confirm_calls[#ui_kit.confirm_calls].on_answer(nil)
    same(got, { 0 }, "dismissed -> 0")
    eq(ui_kit.confirm_calls[#ui_kit.confirm_calls].default, 1, "default 0 starts on the first")

    dialog.choose(
      "Save?",
      { "a", "b" },
      1,
      function() end,
      nil,
      { title = "Unsaved changes", kind = "danger" }
    )
    c = ui_kit.confirm_calls[#ui_kit.confirm_calls]
    eq(c.title, "Unsaved changes", "choose: opts.title is the window title")
    eq(c.kind, "danger", "choose: opts.kind is passed on")

    -- opts.kind wins over the kind the message type implies; without opts nothing changes
    dialog.choose("Save?", { "a", "b" }, 1, function() end, "Warning", { kind = "info" })
    eq(ui_kit.confirm_calls[#ui_kit.confirm_calls].kind, "info", "choose: opts.kind beats msg_type")
    dialog.choose("Save?", { "a", "b" }, 1, function() end, "Warning", {})
    c = ui_kit.confirm_calls[#ui_kit.confirm_calls]
    eq(c.kind, "warn", "choose: an opts without kind keeps the kind of msg_type")
    eq(c.title, nil, "choose: ...and has no title")
    dialog.choose("Save?", { "a", "b" }, 1, function() end, nil, { keep_on_focus_lost = true })
    c = ui_kit.confirm_calls[#ui_kit.confirm_calls]
    eq(c.keep_on_focus_lost, true, "choose: opts.keep_on_focus_lost is passed on")

    -- ------------------------------------------------------------ backend 2: the copy in lib.nvim
    without_ui_kit()
    eq(dialog.backend(), "lib.nvim.ui.kit", "without ui.nvim the copy of lib.nvim answers")
    local lib_kit = require("lib.nvim.ui.kit")
    local confirm = require("lib.nvim.ui.kit.confirm")
    confirm.close()
    idle(20)

    got = {}
    used = dialog.choose("Remove?", "&Delete\n&Cancel", 2, function(i)
      got[#got + 1] = i
    end)
    eq(used, "lib.nvim.ui.kit", "a real dialog of the lib copy")
    ok(confirm.is_open(), "which is open")
    same(got, {}, "unanswered so far")
    api.nvim_feedkeys(api.nvim_replace_termcodes("d", true, false, true), "x", false)
    same(got, { 1 }, "the hotkey picks the first button: index 1")
    ok(not confirm.is_open(), "and the dialog is gone")

    got = {}
    dialog.confirm({
      question = "Sure?",
      on_answer = function(v)
        got[#got + 1] = v
      end,
    })
    confirm.cancel()
    same(got, { false }, "dismissed -> false")

    got = {}
    dialog.choose("Which?", { "a", "b" }, 1, function(i)
      got[#got + 1] = i
    end)
    confirm.cancel()
    same(got, { 0 }, "choose dismissed -> 0")

    -- replaced by another dialog: the kit is single-instance, the replaced question is answered as
    -- dismissed on the next turn (a caller such as data.nvim's diff preview cleans up there), also
    -- when focus changes are no dismissal (keep_on_focus_lost)
    got = {}
    dialog.choose("Apply?", { "Discard", "Apply" }, 1, function(i)
      got[#got + 1] = "choose:" .. i
    end, nil, { keep_on_focus_lost = true })
    dialog.confirm({
      question = "Other?",
      on_answer = function(v)
        got[#got + 1] = "confirm:" .. tostring(v)
      end,
    })
    same(got, {}, "a replaced choose is not answered inside the call that replaces it")
    wait_for(function()
      return #got > 0
    end, "a replaced choose is answered")
    same(got, { "choose:0" }, "replaced choose -> 0, once")
    lib_kit.confirm({
      question = "Third?",
      on_answer = function(v)
        got[#got + 1] = "third:" .. tostring(v)
      end,
    })
    wait_for(function()
      return #got > 1
    end, "a replaced confirm is answered")
    idle(20)
    same(got, { "choose:0", "confirm:false" }, "replaced yes/no confirm -> false, once")
    got = {}
    dialog.confirm({
      question = "Pick",
      choices = { "a", "b" },
      on_answer = function(v, i)
        got[#got + 1] = { v, i }
      end,
    })
    wait_for(function()
      return #got > 0
    end, "the replacement is answered in turn")
    confirm.close()
    idle(20)
    eq(#got, 2, "the third dialog and the choice dialog answer once each")
    eq(got[2][1], nil, "replaced choice confirm -> nil")

    -- the lib copy's input
    got = {}
    local s_input = lib_kit.input
    stub(lib_kit, "input", function(o)
      vim.schedule(function()
        o.on_submit("from the lib copy")
      end)
      return {}
    end)
    dialog.input({ prompt = "x" }, function(v)
      got[#got + 1] = v
    end)
    wait_for(function()
      return #got > 0
    end, "the lib copy's input answers")
    same(got, { "from the lib copy" }, "its value")
    lib_kit.input = s_input

    -- ------------------------------------------------------------ backend 3: native
    stub(package.loaded, "lib.nvim.ui.kit", {}) -- loads, but is no kit
    eq(dialog.backend(), "native", "no kit loads -> native")
    local asked = {}
    stub(vim.ui, "select", function(items, opts, on_choice)
      asked[#asked + 1] = { items = items, prompt = opts.prompt }
      on_choice(items[#items], #items)
    end)

    got = {}
    used = dialog.confirm({
      question = "Native yes/no?",
      on_answer = function(v)
        got[#got + 1] = v
      end,
    })
    eq(used, "native", "native backend")
    same(asked[1].items, { "No", "Yes" }, "No first: a stray <CR> is the safe answer")
    eq(asked[1].prompt, "Native yes/no?", "the question is the prompt")
    same(got, {}, "native select answered at once, still not before confirm() returned")
    wait_for(function()
      return #got > 0
    end, "and it arrives")
    same(got, { true }, "picking the last item (Yes) -> true, once")

    -- the labels of a vim.fn.confirm string, cleaned the way the kit cleans them
    asked = {}
    got = {}
    dialog.choose("Pick", "Fish && Chips\n&Cancel\n", 1, function(i)
      got[#got + 1] = i
    end)
    same(asked[1].items, { "Fish & Chips", "Cancel" }, "&& literal, & dropped, empty piece skipped")
    wait_for(function()
      return #got > 0
    end, "native choose answers")
    same(got, { 2 }, "the index of the picked label")

    -- ask without a kit falls back to the same native question
    got = {}
    used = dialog.ask({
      question = "Native ask?",
      on_answer = function(v)
        got[#got + 1] = v
      end,
    })
    eq(used, "native", "ask has a native path too")
    wait_for(function()
      return #got > 0
    end, "native ask answers")

    -- native input, plain and secret
    local seen_input
    stub(vim.ui, "input", function(opts, on_confirm)
      seen_input = opts
      on_confirm("typed natively")
    end)
    got = {}
    used = dialog.input({ prompt = "Name", default = "d", completion = "file" }, function(v)
      got[#got + 1] = v
    end)
    eq(used, "native", "native input")
    eq(seen_input.prompt, "Name", "prompt")
    eq(seen_input.default, "d", "default")
    eq(seen_input.completion, "file", "completion")
    same(got, {}, "not before input() returned")
    wait_for(function()
      return #got > 0
    end, "native input answers")
    same(got, { "typed natively" }, "once")
    stub(vim.fn, "inputsecret", function()
      return "hunter2"
    end)
    got = {}
    dialog.input({ prompt = "Password", secret = true }, function(v)
      got[#got + 1] = v
    end)
    wait_for(function()
      return #got > 0
    end, "native secret input answers")
    same(got, { "hunter2" }, "a secret goes through inputsecret")

    local base_select, base_input = vim.ui.select, vim.ui.input
    -- a provider that calls back with the choice only is read by its text
    stub(vim.ui, "select", function(items, _, on_choice)
      on_choice(vim.tbl_contains(items, "Yes") and "Yes" or items[1])
    end)
    got = {}
    dialog.confirm({
      question = "No index?",
      on_answer = function(v)
        got[#got + 1] = v
      end,
    })
    wait_for(function()
      return #got > 0
    end, "an answer without a position arrives")
    same(got, { true }, "Yes is Yes, not false")
    got = {}
    dialog.confirm({
      question = "Which?",
      choices = { "a", "b" },
      on_answer = function(label, idx)
        got = { label, idx }
      end,
    })
    wait_for(function()
      return #got > 0
    end, "a choice without a position arrives")
    same(got, { "a", 1 }, "the position is found by the label")

    -- a NUL byte in a question is shown, not an E976 out of the provider
    local prompts = {}
    stub(vim.ui, "select", function(items, o, on_choice)
      prompts[#prompts + 1] = o.prompt
      on_choice(items[1], 1)
    end)
    local nul_ok = pcall(dialog.confirm, { question = "bad\0title?", on_answer = function() end })
    ok(nul_ok and not prompts[1]:find("\0", 1, true), "a NUL in the question is made safe")

    -- a long line is cut to the screen, a long list to a few lines; the last short line survives
    prompts = {}
    local many = {}
    for i = 1, 40 do
      many[i] = "name " .. i
    end
    dialog.confirm({
      question = string.rep("x", 500) .. "\n" .. table.concat(many, "\n"),
      on_answer = function() end,
    })
    local first_line, line_count = prompts[1]:match("^[^\n]*"), #vim.split(prompts[1], "\n")
    ok(vim.fn.strdisplaywidth(first_line) <= math.max(40, vim.o.columns - 12), "a long line is cut")
    ok(line_count <= 13, "and the number of lines is capped: " .. line_count)

    -- a provider that raises: the error is raised and the callback is not left waiting
    stub(vim.ui, "select", function()
      error("provider broke")
    end)
    got = {}
    local provider_raised, raised_err = pcall(dialog.confirm, {
      question = "Raise?",
      on_answer = function(v)
        got[#got + 1] = v
      end,
    })
    eq(provider_raised, false, "the provider's error surfaces")
    ok(tostring(raised_err):find("provider broke", 1, true), "with its message")

    -- the native input expands what the kit would expand, and leaving through on_back answers nil
    stub(vim.ui, "input", function(_, on_confirm)
      on_confirm("~/x")
    end)
    got = {}
    dialog.input({ prompt = "Path", expand_env = true }, function(v)
      got[#got + 1] = v
    end)
    wait_for(function()
      return #got > 0
    end, "native input with expand_env answers")
    ok(
      got[1] ~= "~/x" and got[1]:find("/x$"),
      "expand_env is honoured natively: " .. tostring(got[1])
    )
    vim.ui.select, vim.ui.input = base_select, base_input

    -- ------------------------------------------------------------ a float that cannot open
    stub(package.loaded, "lib.nvim.ui.kit", {
      confirm = function(o)
        o.on_answer(false) -- what the kit does when its float cannot be created
        return nil
      end,
      input = function()
        return nil
      end,
    })
    eq(dialog.backend(), "lib.nvim.ui.kit", "the kit loads...")
    asked = {}
    got = {}
    used = dialog.confirm({
      question = "No float?",
      on_answer = function(v)
        got[#got + 1] = v
      end,
    })
    eq(used, "native", "...but its float did not open: the question goes native")
    eq(#asked, 1, "asked once, natively")
    wait_for(function()
      return #got > 0
    end, "native answer arrives")
    same(got, { true }, "once (the kit's own 'no' was not delivered on top of it)")
    got = {}
    used = dialog.input({ prompt = "No float" }, function(v)
      got[#got + 1] = v
    end)
    eq(used, "native", "input falls back as well")
    wait_for(function()
      return #got > 0
    end, "native input answers")
    same(got, { "typed natively" }, "once")

    -- ------------------------------------------------------------ review: errors, needs, defaults
    -- a kit that raises is not a float that failed to open: raised again, not asked twice
    stub(package.loaded, "ui.kit", {
      confirm = function()
        error("bad option")
      end,
    })
    local native_calls = 0
    stub(vim.ui, "select", function(_, _, on_choice)
      native_calls = native_calls + 1
      on_choice("Yes", 1)
    end)
    local raised, err = pcall(dialog.confirm, { question = "x", on_answer = function() end })
    eq(raised, false, "a kit error is raised")
    ok(tostring(err):find("bad option", 1, true), "with its message")
    eq(native_calls, 0, "and no second, native question is asked")

    -- the kit is chosen per function: ui.kit without ask -> the lib copy's ask
    local no_ask = fake_kit()
    no_ask.ask = nil
    stub(package.loaded, "ui.kit", no_ask)
    stub(package.loaded, "lib.nvim.ui.kit", nil)
    local lib_ask_called = false
    local lib_copy = require("lib.nvim.ui.kit")
    stub(lib_copy, "ask", function(o)
      lib_ask_called = true
      o.on_answer(true)
    end)
    got = {}
    used = dialog.ask({
      question = "Per function?",
      on_answer = function(v)
        got[#got + 1] = v
      end,
    })
    eq(used, "lib.nvim.ui.kit", "ask falls to the next kit that has ask")
    ok(lib_ask_called, "and asked it")
    wait_for(function()
      return #got > 0
    end, "the answer arrives")

    -- ask: an abandoned question answers nil once, on every path
    local ab_kit = fake_kit()
    ab_kit.ask = function(o)
      ab_kit.dropped = o.abandoned()
    end
    stub(package.loaded, "ui.kit", ab_kit)
    got = {}
    dialog.ask({
      question = "Dropped?",
      abandoned = function()
        return true
      end,
      on_answer = function(v)
        got[#got + 1] = v == nil and "nil" or v
      end,
    })
    eq(ab_kit.dropped, true, "the kit asked abandoned()")
    wait_for(function()
      return #got > 0
    end, "an abandoned ask answers")
    same(got, { "nil" }, "nil, once")

    stub(package.loaded, "ui.kit", nil)
    stub(package.preload, "ui.kit", function()
      error("module 'ui.kit' not found")
    end)
    stub(package.loaded, "lib.nvim.ui.kit", {})
    asked = {}
    stub(vim.ui, "select", function(items, opts, on_choice)
      asked[#asked + 1] = { items = items, prompt = opts.prompt }
      on_choice(items[1], 1)
    end)
    got = {}
    dialog.ask({
      question = "Native, dropped",
      abandoned = function()
        return true
      end,
      on_answer = function(v)
        got[#got + 1] = v == nil and "nil" or v
      end,
    })
    wait_for(function()
      return #got > 0
    end, "native: an abandoned ask answers")
    same(got, { "nil" }, "nil, once")
    eq(#asked, 0, "and is never asked")

    -- native: the default button is listed first and mapped back
    asked = {}
    got = {}
    dialog.choose("Delete?", "&Yes\n&No", 2, function(i)
      got[#got + 1] = i
    end)
    same(asked[1].items, { "No", "Yes" }, "the default is listed first")
    wait_for(function()
      return #got > 0
    end, "native choose answers")
    same(got, { 2 }, "taking the first entry gives the index of 'No' in the caller's order")
    asked = {}
    got = {}
    dialog.confirm({
      question = "Delete?",
      default = 2,
      on_answer = function(v)
        got[#got + 1] = v
      end,
    })
    wait_for(function()
      return #got > 0
    end, "native confirm answers")
    same(asked[1].items, { "No", "Yes" }, "yes/no with default 2 lists No first")
    same(got, { false }, "and the first entry is No: false")

    -- nothing to choose from: a single OK, as vim.fn.confirm shows
    asked = {}
    got = {}
    dialog.choose("Done", nil, 0, function(i)
      got[#got + 1] = i
    end)
    same(asked[1].items, { "OK" }, "empty choices -> OK")
    wait_for(function()
      return #got > 0
    end, "answers")
    same(got, { 1 }, "OK is button 1, not 'dismissed'")

    -- native secret: an empty line is a cancel, the default goes to inputsecret
    local secret_args
    stub(vim.fn, "inputsecret", function(...)
      secret_args = { ... }
      return ""
    end)
    got = {}
    dialog.input({ prompt = "Token", secret = true, default = "old" }, function(v)
      got[#got + 1] = v == nil and "nil" or v
    end)
    wait_for(function()
      return #got > 0
    end, "native secret answers")
    same(got, { "nil" }, "an empty secret counts as cancelled natively")
    same(secret_args, { "Token", "old" }, "prompt and default reach inputsecret")

    -- two buttons with the same text: the index says which one, with the real lib copy
    stub(package.loaded, "lib.nvim.ui.kit", lib_copy)
    got = {}
    dialog.choose("Same text", { "Keep", "Keep" }, 1, function(i)
      got[#got + 1] = i
    end)
    require("lib.nvim.ui.kit.confirm").move(1)
    require("lib.nvim.ui.kit.confirm").confirm()
    same(got, { 2 }, "the second 'Keep' is index 2, not 1")

    -- the labels the native path shows are the ones the kit draws
    local tricky = "Fish && Chips\n&Cancel\nRe&name\n"
    dialog.choose("Same labels", tricky, 1, function() end)
    local drawn = table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    ok(drawn:find("[ Fish & Chips ]", 1, true), "kit draws 'Fish & Chips'")
    ok(drawn:find("[ Cancel ]", 1, true), "kit draws 'Cancel'")
    ok(drawn:find("[ Rename ]", 1, true), "kit draws 'Rename'")
    require("lib.nvim.ui.kit.confirm").close()
    stub(package.loaded, "lib.nvim.ui.kit", {})
    asked = {}
    dialog.choose("Same labels", tricky, 1, function() end)
    same(
      asked[1].items,
      { "Fish & Chips", "Cancel", "Rename" },
      "and the native path shows the same three"
    )

    -- a kit that is installed but broken is reported, not mistaken for an absent one
    package.loaded["ui.kit"] = nil
    stub(package.preload, "ui.kit", function()
      error("syntax error near 'end'")
    end)
    stub(package.loaded, "lib.nvim.ui.kit", lib_copy)
    eq(dialog.backend(), "lib.nvim.ui.kit", "the copy answers")
    ok(
      (dialog.load_errors()["ui.kit"] or ""):find("syntax error", 1, true),
      "and the load error of ui.kit is kept"
    )
    -- (the runtime remembers a failed load: forget it, as a fresh session would)
    package.loaded["ui.kit"] = nil
    stub(package.preload, "ui.kit", function()
      error("module 'ui.kit' not found")
    end)
    eq(dialog.load_errors()["ui.kit"], nil, "an absent kit leaves no error")

    -- health: the backend is named, a broken kit is warned about
    local lines = {}
    local function note(kind)
      return function(msg)
        lines[#lines + 1] = kind .. ": " .. msg
      end
    end
    stub(package.loaded, "lib.health", nil)
    stub(vim, "health", {
      start = note("start"),
      ok = note("ok"),
      warn = note("warn"),
      error = note("error"),
      info = note("info"),
    })
    local health = require("lib.health")
    stub(package.loaded, "ui.kit", fake_kit())
    health.check_dialog()
    ok(
      lines[#lines]:find("ok: ", 1, true) and lines[#lines]:find("ui.nvim", 1, true),
      "ui.kit: ok line"
    )
    lines = {}
    stub(package.loaded, "ui.kit", nil)
    health.check_dialog()
    ok(lines[#lines]:find("info: ", 1, true), "the lib copy: an info line")
    lines = {}
    stub(package.loaded, "lib.nvim.ui.kit", {})
    health.check_dialog()
    ok(lines[#lines]:find("warn: ", 1, true), "native: a warning")
    lines = {}
    package.loaded["ui.kit"] = nil
    stub(package.preload, "ui.kit", function()
      error("syntax error near 'end'")
    end)
    stub(package.loaded, "lib.nvim.ui.kit", lib_copy)
    health.check_dialog()
    local joined = table.concat(lines, "\n")
    ok(
      joined:find("failed to load", 1, true) and joined:find("syntax error", 1, true),
      "a broken kit is named"
    )
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
