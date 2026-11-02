-- Test code: when something here comes back nil, this file must crash and
-- name it rather than silently skip -- see TESTS/ui_kit_spec.lua's header.
---@diagnostic disable: need-check-nil
-- TESTS/ui_kit_ask_modal_spec.lua -- lib.nvim.ui.kit.confirm.ask waits for ANY modal kit dialog, is woken by its close instead of polling, takes a `choices` list, and ends the wait with one timer. Port of ui.nvim's spec of the same name.

return function(H)
  H.confirm_focus_first() -- the safe button is the default now; these specs drive Yes
  local kit = require("lib.nvim.ui.kit")
  local confirm = require("lib.nvim.ui.kit.confirm")
  local modal = require("lib.nvim.ui.kit.modal")
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
  local function wait_for(fn, msg)
    ok(vim.wait(800, fn, 5), msg)
  end
  local function idle(ms)
    vim.wait(ms, function()
      return false
    end, 5)
  end
  local function close_all()
    confirm.close()
    for _, w in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_is_valid(w) and api.nvim_win_get_config(w).relative ~= "" then
        pcall(api.nvim_win_close, w, true)
      end
    end
  end

  -- the registry follows the float
  eq(modal.busy(), false, "nothing open at the start")
  local input =
    kit.input({ prompt = "name", on_submit = function() end, on_cancel = function() end })
  ok(input, "an input opened")
  eq(modal.busy(), true, "an open input is a modal dialog")
  input:close()
  eq(modal.busy(), false, "and no longer once its float is closed")

  -- ask waits for an open INPUT (before: only a confirm counted, the question covered the input)
  local blocker =
    kit.input({ prompt = "typing", on_submit = function() end, on_cancel = function() end })
  local answer
  kit.ask({
    question = "ask while typing?",
    on_answer = function(yes)
      answer = yes
    end,
  })
  idle(60)
  eq(confirm.is_open(), false, "ask does not open on top of an open input")
  eq(answer, nil, "and has not answered")
  blocker:close()
  wait_for(function()
    return confirm.is_open()
  end, "the question opens once the input is gone")
  confirm.confirm()
  eq(answer, true, "and is answered")

  -- ask waits for an open SELECT
  local picked
  local sel = kit.select({
    items = { "a", "b" },
    on_select = function(item)
      picked = item
    end,
    on_cancel = function() end,
  })
  ok(sel ~= nil or modal.busy(), "a select opened")
  eq(modal.busy(), true, "an open select is a modal dialog")
  answer = nil
  kit.ask({
    question = "ask while choosing?",
    on_answer = function(yes)
      answer = yes
    end,
  })
  idle(60)
  eq(confirm.is_open(), false, "ask does not open on top of an open select")
  close_all()
  wait_for(function()
    return confirm.is_open()
  end, "the question opens once the select is gone")
  confirm.cancel()
  eq(answer, false, "and a cancel is a no")
  eq(picked, nil, "the select was not answered by the question")

  -- a list of choices: the label comes back, a cancel is nil
  local got = "none"
  kit.ask({
    question = "which?",
    choices = { "Build", "Skip" },
    on_answer = function(c)
      got = c
    end,
  })
  ok(confirm.is_open(), "an ask with choices shows at once when nothing is open")
  confirm.move(1)
  confirm.confirm()
  eq(got, "Skip", "the focused label is answered")
  kit.ask({
    question = "which?",
    choices = { "Build", "Skip" },
    on_answer = function(c)
      got = c
    end,
  })
  confirm.cancel()
  eq(got, nil, "a cancel answers nil for a choices list")

  -- starved: a choices ask is answered nil, a plain one false
  confirm.open({ question = "never answered", on_answer = function() end })
  local starved_choice = "none"
  local starved_yes
  kit.ask({
    question = "starved choices",
    choices = { "a", "b" },
    max_wait_ms = 40,
    on_answer = function(c)
      starved_choice = c
    end,
  })
  kit.ask({
    question = "starved yes/no",
    max_wait_ms = 40,
    on_answer = function(y)
      starved_yes = y
    end,
  })
  wait_for(function()
    return starved_choice ~= "none" and starved_yes ~= nil
  end, "starved questions are answered")
  eq(starved_choice, nil, "a starved choices ask answers nil")
  eq(starved_yes, false, "a starved yes/no ask answers false")
  close_all()

  -- nothing polls: while it waits an ask arms its wait limit and one slow re-check, none quicker
  local orig_defer, calls, quick = vim.defer_fn, 0, 0
  ---@diagnostic disable-next-line: duplicate-set-field
  vim.defer_fn = function(fn, ms)
    calls = calls + 1
    if ms < confirm.ASK_RECHECK_MS then
      quick = quick + 1
    end
    return orig_defer(fn, ms)
  end
  confirm.open({ question = "blocker", on_answer = function() end })
  local waiting_answer
  kit.ask({
    question = "waits quietly",
    on_answer = function(y)
      waiting_answer = y
    end,
  })
  idle(120)
  vim.defer_fn = orig_defer
  eq(calls, 2, "a wait limit and a slow re-check for the whole wait")
  eq(quick, 0, "no polling")
  confirm.close()
  wait_for(function()
    return confirm.is_open()
  end, "and it still opens when the blocker goes")
  confirm.confirm()
  eq(waiting_answer, true, "answered")

  -- an externally closed dialog whose answer opens another: a waiting question must not open
  -- between the close and that answer (it would be replaced and answered "no" by it)
  do
    local follow_up
    local x_surf = kit.confirm({
      question = "X",
      on_answer = function()
        follow_up = kit.confirm({ question = "Z", on_answer = function() end })
      end,
    })
    local asked_answer
    kit.ask({
      question = "Q",
      on_answer = function(yes)
        asked_answer = yes
      end,
    })
    api.nvim_win_close(x_surf.winid, true)
    wait_for(function()
      return follow_up ~= nil
    end, "the answer of the closed dialog ran")
    idle(60)
    eq(asked_answer, nil, "the waiting question was not answered by the follow-up dialog")
    confirm.confirm() -- answer Z (the follow-up)
    wait_for(function()
      return confirm.is_open()
    end, "the waiting question opens once the follow-up is gone")
    confirm.confirm()
    eq(asked_answer, true, "and gets its own answer")
  end

  -- on_free: a withdrawn listener is not called, also when it is already scheduled
  do
    local d = kit.input({ prompt = "busy", on_submit = function() end, on_cancel = function() end })
    local called = false
    local cancel = modal.on_free(function()
      called = true
    end)
    d:close() -- schedules the wake
    cancel()
    idle(60)
    eq(called, false, "a withdrawn on_free is not called, even once scheduled")
    eq(modal.busy(), false, "and the registry is free")
  end

  -- hold(): the registry stays busy until released, then wakes the subscribers
  do
    local release = modal.hold()
    eq(modal.busy(), true, "held: busy")
    local woke = false
    modal.on_free(function()
      woke = true
    end)
    idle(40)
    eq(woke, false, "a subscriber is not woken while a hold is on")
    release()
    release() -- a second release does nothing
    wait_for(function()
      return woke
    end, "released: the subscriber is woken")
    eq(modal.busy(), false, "and the registry is free")
  end

  -- abandoned while waiting: dropped, the timer does not answer for it later
  local dropped_called = false
  local b2 =
    kit.input({ prompt = "typing", on_submit = function() end, on_cancel = function() end })
  local gone = false
  kit.ask({
    question = "dropped",
    max_wait_ms = 80,
    abandoned = function()
      return gone
    end,
    on_answer = function()
      dropped_called = true
    end,
  })
  gone = true
  b2:close()
  idle(200)
  eq(
    dropped_called,
    false,
    "an abandoned question is dropped unasked and never answered by the timer"
  )
  eq(confirm.is_open(), false, "and nothing is shown")
  close_all()

  -- a question its owner withdrew while the blocker stays open is not answered by the timeout either
  do
    confirm.open({ question = "stays", on_answer = function() end })
    local withdrawn, called = false, false
    kit.ask({
      question = "withdrawn",
      max_wait_ms = 60,
      abandoned = function()
        return withdrawn
      end,
      on_answer = function()
        called = true
      end,
    })
    withdrawn = true
    idle(200)
    eq(called, false, "a withdrawn question is not answered when its wait runs out")
    close_all()
  end

  -- a dialog that goes without the event that wakes the subscribers does not strand the question
  do
    local saved = confirm.ASK_RECHECK_MS
    confirm.ASK_RECHECK_MS = 30
    local quiet =
      kit.input({ prompt = "quiet", on_submit = function() end, on_cancel = function() end })
    local quiet_answer
    kit.ask({
      question = "after a quiet close",
      on_answer = function(yes)
        quiet_answer = yes
      end,
    })
    local saved_ei = vim.o.eventignore
    vim.o.eventignore = "WinClosed"
    api.nvim_win_close(quiet.winid, true)
    vim.o.eventignore = saved_ei
    wait_for(function()
      return confirm.is_open()
    end, "the question opens although no close event woke it")
    confirm.confirm()
    eq(quiet_answer, true, "and gets its answer")
    confirm.ASK_RECHECK_MS = saved
    close_all()
  end

  -- ask with choices passes the position of the button as well: two buttons of one text differ
  do
    local label, index
    kit.ask({
      question = "which?",
      choices = { "Keep", "Keep" },
      on_answer = function(l, i)
        label, index = l, i
      end,
    })
    idle(60)
    confirm.pick(2)
    eq({ label, index }, { "Keep", 2 }, "ask answers the label and its position")
    close_all()
  end

  -- opening fails after the question waited: it is answered as cancelled, not left hanging
  do
    local typing =
      kit.input({ prompt = "typing", on_submit = function() end, on_cancel = function() end })
    local boom_answer = "none"
    kit.ask({
      question = "boom",
      on_answer = function(yes)
        boom_answer = yes
      end,
    })
    local buttons = require("lib.nvim.ui.kit.buttons")
    local real_layout, real_notify = buttons.layout_rows, vim.notify
    buttons.layout_rows = function()
      error("boom")
    end
    vim.notify = function() end
    typing:close()
    idle(150)
    buttons.layout_rows, vim.notify = real_layout, real_notify
    eq(boom_answer, false, "a question that could not be shown is answered as cancelled")
    close_all()
  end
end
