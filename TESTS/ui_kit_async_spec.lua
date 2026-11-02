-- Test code: when something here comes back nil, this file must crash and
-- name it rather than silently skip -- see TESTS/ui_kit_spec.lua's header.
---@diagnostic disable: need-check-nil
-- TESTS/ui_kit_async_spec.lua -- lib.nvim.ui.kit.async: coroutines over the callback components
-- (confirm, ask, input, form, select) without blocking Neovim. Port of ui.nvim's spec of the same
-- name; the typed-keys spec of a child Neovim with a UI lives in ui.nvim only.

return function(H)
  H.confirm_focus_first() -- the safe button is the default now; these specs drive Yes
  local restores = {}
  --- Every stub is put back, also when the body fails: a later spec of this shared run must not
  --- find a stubbed component.
  local function stub(tbl, key, fn)
    restores[#restores + 1] = { tbl, key, tbl[key] }
    tbl[key] = fn
  end
  local ok_body, err_body = pcall(function()
    local kit = require("lib.nvim.ui.kit")
    local async = kit.async
    local confirm = require("lib.nvim.ui.kit.confirm")

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

    -- outside a coroutine: an error that names run
    local called, err = pcall(async.confirm, { question = "x" })
    eq(called, false, "outside a coroutine it raises")
    ok(tostring(err):find("kit.async.run", 1, true), "and names kit.async.run: " .. tostring(err))

    -- confirm: suspends, resumes with the answer
    local got
    async.run(function()
      got = { async.confirm({ question = "Delete?" }) }
    end)
    ok(confirm.is_open(), "the dialog is open while the coroutine waits")
    eq(got, nil, "and the coroutine has not got past it")
    confirm.confirm()
    eq(got, { true }, "Yes -> true")

    async.run(function()
      got = { async.confirm({ question = "Delete?" }) }
    end)
    confirm.cancel()
    eq(got, { false }, "cancel -> false")

    async.run(function()
      got = { async.confirm({ question = "Which?", choices = { "Build", "Skip" } }) }
    end)
    confirm.move(1)
    confirm.confirm()
    eq(got, { "Skip" }, "choices -> the label")

    async.run(function()
      got = { async.confirm({ question = "Which?", choices = { "Build", "Skip" } }) }
    end)
    confirm.cancel()
    eq(got, {}, "choices cancel -> nil (nothing after the call)")
    got = nil

    -- ask: waits its turn, answers
    async.run(function()
      got = { async.ask({ question = "Really?" }) }
    end)
    ok(confirm.is_open(), "ask shows at once when nothing is open")
    confirm.confirm()
    eq(got, { true }, "ask -> true")

    -- a dialog that answers while it is being opened is returned without suspending
    local sync_result
    async.run(function()
      sync_result = {
        async.await(function(deliver)
          deliver("now", 2)
        end),
      }
    end)
    eq(sync_result, { "now", 2 }, "an answer given inside start is returned at once, all values")

    -- only the first delivery counts
    local second
    async.run(function()
      second = {
        async.await(function(deliver)
          vim.schedule(function()
            deliver("first")
            deliver("second")
          end)
        end),
      }
    end)
    ok(
      vim.wait(500, function()
        return second ~= nil
      end, 5),
      "the delayed delivery arrives"
    )
    eq(second, { "first" }, "a second delivery is ignored")

    -- select: the item and its index, nil on dismiss
    local stub_select = require("lib.nvim.ui.kit.select")
    stub(stub_select, "open", function(o)
      o.on_select(o.items[2], 2)
    end)
    local picked
    async.run(function()
      picked = { async.select({ items = { "a", "b" } }) }
    end)
    eq(picked, { "b", 2 }, "select -> item, index")
    stub(stub_select, "open", function(o)
      o.on_cancel()
    end)
    async.run(function()
      picked = { async.select({ items = { "a", "b" } }) }
    end)
    eq(picked, {}, "select dismissed -> nil")

    -- input / form: value, or nil and true when cancelled; the caller's own callbacks still run
    local input_mod = require("lib.nvim.ui.kit.input")
    local user_called
    stub(input_mod, "open", function(o)
      o.on_submit("typed")
      return {}
    end)
    async.run(function()
      got = {
        async.input({
          prompt = "p",
          on_submit = function(v)
            user_called = v
          end,
        }),
      }
    end)
    eq(got, { "typed", false }, "input -> value, false")
    eq(user_called, "typed", "the caller's own on_submit ran too")
    stub(input_mod, "open", function(o)
      o.on_cancel()
      return {}
    end)
    async.run(function()
      got = { async.input({ prompt = "p" }) }
    end)
    eq(got[1], nil, "input cancelled -> nil")
    eq(got[2], true, "and cancelled = true")

    -- a component that cannot open returns nothing and calls neither callback: counts as cancelled
    stub(input_mod, "open", function()
      return nil
    end)
    got = nil
    async.run(function()
      got = { async.input({ prompt = "p" }) }
    end)
    ok(got ~= nil, "an input that cannot open does not leave the coroutine waiting")
    eq(got[1], nil, "-> nil")
    eq(got[2], true, "and cancelled")

    -- leaving through the caller's own "back" resumes the coroutine too (and the caller's callback runs)
    local back_called = false
    stub(require("lib.nvim.ui.kit.form"), "open", function(o)
      vim.schedule(function()
        o.on_back()
      end)
      return {}
    end)
    got = nil
    async.run(function()
      got = {
        async.form({
          fields = {},
          on_back = function()
            back_called = true
          end,
        }),
      }
    end)
    vim.wait(200, function()
      return got ~= nil
    end, 5)
    ok(got ~= nil, "a form left through on_back does not leave the coroutine waiting")
    eq(got, { nil, true }, "-> nil, cancelled")
    ok(back_called, "and the caller's on_back ran")

    -- form goes through the same path
    stub(require("lib.nvim.ui.kit.form"), "open", function(o)
      o.on_submit({ a = 1 })
      return {}
    end)
    async.run(function()
      got = { async.form({ fields = {} }) }
    end)
    eq(got, { { a = 1 }, false }, "form -> values, false")

    -- the caller's own callback raising does not cost the coroutine its answer
    stub(input_mod, "open", function(o)
      vim.schedule(function()
        pcall(o.on_submit, "kept")
      end)
      return {}
    end)
    got = nil
    async.run(function()
      got = {
        async.input({
          on_submit = function()
            error("user callback failed")
          end,
        }),
      }
    end)
    ok(
      vim.wait(500, function()
        return got ~= nil
      end, 5),
      "the coroutine still gets its answer"
    )
    eq(got, { "kept", false }, "although the caller's on_submit raised")

    -- an error right after the answer, inside start, does not eat the answer either
    stub(input_mod, "open", function(o)
      o.on_submit("early")
      error("raised after answering")
    end)
    local late_notice
    stub(vim, "notify", function(msg)
      late_notice = msg
    end)
    got = nil
    async.run(function()
      got = { async.input({}) }
    end)
    eq(got, { "early", false }, "the answer wins over a later error")
    vim.wait(200, function()
      return late_notice ~= nil
    end, 5)
    ok(
      late_notice and late_notice:find("raised after answering", 1, true),
      "and the error is reported"
    )

    -- an error in the coroutine is reported with its traceback, not swallowed
    local notified
    stub(vim, "notify", function(msg)
      notified = msg
    end)
    async.run(function()
      error("boom in the coroutine")
    end)
    vim.wait(200, function()
      return notified ~= nil
    end, 5)
    ok(notified and notified:find("boom in the coroutine", 1, true), "the error is reported")
    ok(notified:find("ui.kit.async", 1, true), "and says where it comes from")

    -- an error raised after a suspension is reported too, and does not reach the dialog's callback
    local notified2
    stub(vim, "notify", function(msg)
      notified2 = msg
    end)
    async.run(function()
      async.confirm({ question = "then fail" })
      error("after the dialog")
    end)
    local resumed_ok = pcall(confirm.confirm)
    vim.wait(200, function()
      return notified2 ~= nil
    end, 5)
    eq(resumed_ok, true, "the answer's callback does not raise into the dialog")
    ok(notified2 and notified2:find("after the dialog", 1, true), "the late error is reported")

    -- a coroutine that run did not start must not be suspended
    local foreign_ok, foreign_err
    local co = coroutine.create(function()
      foreign_ok, foreign_err = pcall(async.confirm, { question = "x" })
    end)
    coroutine.resume(co)
    eq(foreign_ok, false, "another scheduler's coroutine is refused")
    ok(tostring(foreign_err):find("kit.async.run", 1, true), "and told where to go")
    ok(not confirm.is_open(), "without a dialog having been opened")

    -- ask: a question dropped because it is no longer wanted answers nil
    got = nil
    async.run(function()
      got = {
        async.ask({
          question = "no longer wanted",
          abandoned = function()
            return true
          end,
        }),
      }
    end)
    ok(got ~= nil, "an abandoned ask does not leave the coroutine waiting")
    eq(got[1], nil, "-> nil")

    -- ask: waits behind an open dialog, then shows and answers
    confirm.open({ question = "blocker", on_answer = function() end })
    got = nil
    async.run(function()
      got = { async.ask({ question = "behind the blocker" }) }
    end)
    eq(got, nil, "the question waits while a dialog is open")
    confirm.close()
    ok(
      vim.wait(500, function()
        return confirm.is_open()
      end, 5),
      "and opens once it is gone"
    )
    confirm.confirm()
    eq(got, { true }, "ask behind a dialog -> true")

    confirm.close()
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
