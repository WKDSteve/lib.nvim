-- Test code: when something here comes back nil, this file must crash and
-- name it rather than silently skip -- see TESTS/ui_kit_spec.lua's header.
---@diagnostic disable: need-check-nil
-- TESTS/ui_kit_ask_spec.lua -- lib.nvim.ui.kit.confirm.ask: the yes/no question that waits its
-- turn (kit.confirm is single-instance and drops an open dialog UNANSWERED), answers "no" when it
-- gets no answer, and falls back to vim.ui.select when the float cannot open.

return function(H)
  H.confirm_focus_first() -- the safe button is the default now; these specs drive Yes
  local eq, ok = H.eq, H.ok
  local kit = require("lib.nvim.ui.kit")
  local confirm = require("lib.nvim.ui.kit.confirm")
  local api = vim.api

  vim.o.showmode = false

  local function close_all()
    confirm.close()
    for _, w in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_is_valid(w) and api.nvim_win_get_config(w).relative ~= "" then
        pcall(api.nvim_win_close, w, true)
      end
    end
  end

  -- Another spec of a shared run may have left a modal float open: ask would rightly wait for it.
  close_all()
  -- ... or an answer still on its way (a dialog closed from outside answers on the next loop turn).
  vim.wait(300, function()
    return not require("lib.nvim.ui.kit.modal").busy()
  end, 5)

  -- ---------------------------------------------------------------- idle: shows at once
  local a
  kit.ask({
    question = "first?",
    on_answer = function(yes)
      a = yes
    end,
  })
  ok(confirm.is_open(), "ask with no dialog open shows its own at once")
  confirm.confirm() -- Yes
  eq(a, true, "ask: Yes -> true")

  kit.ask({
    question = "again?",
    on_answer = function(yes)
      a = yes
    end,
  })
  confirm.cancel()
  eq(a, false, "ask: cancel -> false")

  -- ---------------------------------------------------------------- waits for an open dialog
  local first, second
  confirm.open({
    question = "open one",
    on_answer = function(yes)
      first = yes
    end,
  })
  kit.ask({
    question = "waiting",
    on_answer = function(yes)
      second = yes
    end,
  })
  eq(second, nil, "ask does not answer while another dialog is open")
  eq(first, nil, "ask does not close the open dialog unanswered")
  confirm.confirm() -- answer the first: Yes
  eq(first, true, "the open dialog still gets its own answer")
  ok(
    vim.wait(500, function()
      return confirm.is_open()
    end, 5),
    "the waiting question opens once the first is answered"
  )
  confirm.confirm()
  eq(second, true, "the waiting question gets its own answer")

  -- ---------------------------------------------------------------- gives up: answered "no"
  local timed_out
  confirm.open({ question = "never answered", on_answer = function() end })
  kit.ask({
    question = "starved",
    max_wait_ms = 40,
    on_answer = function(yes)
      timed_out = yes
    end,
  })
  ok(
    vim.wait(1000, function()
      return timed_out ~= nil
    end, 5),
    "a question starved past max_wait_ms is answered"
  )
  eq(timed_out, false, "a starved question is answered as declined")
  close_all()

  -- ---------------------------------------------------------------- abandoned: never asked
  local ab_called = false
  confirm.open({ question = "blocker", on_answer = function() end })
  kit.ask({
    question = "dropped",
    abandoned = function()
      return true
    end,
    on_answer = function()
      ab_called = true
    end,
  })
  vim.wait(80, function()
    return false
  end, 5)
  close_all()
  vim.wait(80, function()
    return false
  end, 5)
  eq(ab_called, false, "an abandoned question is dropped unasked")

  -- ---------------------------------------------------------------- float fails: vim.ui.select
  local orig_open, orig_select = confirm.open, vim.ui.select
  local picked_prompt
  confirm.open = function(o)
    o.on_answer(false) -- what the real open does when the float cannot be created
    return nil
  end
  vim.ui.select = function(items, o, cb)
    picked_prompt = o.prompt
    eq(table.concat(items, "|"), "Yes|No", "the fallback offers Yes/No")
    cb("Yes")
  end
  local fb
  kit.ask({
    question = "fallback?",
    on_answer = function(yes)
      fb = yes
    end,
  })
  confirm.open, vim.ui.select = orig_open, orig_select
  eq(picked_prompt, "fallback?", "the fallback carries the question")
  eq(fb, true, "the fallback's Yes is the answer, not the failed float's synchronous no")

  -- a dialog that opens and answers at once (a stub, another implementation) is a real answer
  confirm.open = function(o)
    o.on_answer(false)
    return {}
  end
  vim.ui.select = function()
    error("the fallback must not run when the dialog opened")
  end
  local instant
  kit.ask({
    question = "instant?",
    on_answer = function(yes)
      instant = yes
    end,
  })
  confirm.open, vim.ui.select = orig_open, orig_select
  eq(instant, false, "a synchronous answer of an opened dialog is delivered")

  -- on_answer fires once only
  local count = 0
  kit.ask({
    question = "once",
    on_answer = function()
      count = count + 1
    end,
  })
  confirm.confirm()
  confirm.cancel()
  eq(count, 1, "on_answer fires exactly once")
  close_all()

  -- Waiting questions are shown in the order they were asked: the blocker's close wakes both,
  -- and the younger one must not overtake the older.
  do
    local shown = {}
    confirm.open({ question = "blocker", on_answer = function() end })
    local real_open = confirm.open
    confirm.open = function(o)
      shown[#shown + 1] = o.question
      return real_open(o)
    end
    kit.ask({ question = "A", on_answer = function() end })
    kit.ask({ question = "B", on_answer = function() end })
    confirm.close() -- the blocker goes: both wake
    ok(
      vim.wait(500, function()
        return #shown >= 1
      end, 5),
      "a waiting question is shown once the blocker is gone"
    )
    eq(shown[1], "A", "the older question is shown first")
    eq(#shown, 1, "the younger one does not open on top of it")
    confirm.confirm() -- answer A
    ok(
      vim.wait(500, function()
        return vim.tbl_contains(shown, "B")
      end, 5),
      "and the younger one follows"
    )
    confirm.open = real_open
    close_all()
  end

  -- A question that raises must not block the ones behind it for ever.
  do
    local seen
    local ok_call = pcall(kit.ask, {
      question = "throws",
      abandoned = function()
        error("boom")
      end,
      on_answer = function() end,
    })
    eq(ok_call, false, "the error surfaces")
    kit.ask({
      question = "after the error",
      on_answer = function(yes)
        seen = yes
      end,
    })
    ok(confirm.is_open(), "the next question is shown at once, the failed one left the queue")
    confirm.confirm()
    eq(seen, true, "and it is answered")
    close_all()
  end
end
