-- TESTS/progress_fanout_spec.lua — lib.nvim.progress with several styles at once: every style
-- gets the same calls in order, state is threaded back per style, a style that raises is
-- disabled for the handle without touching the others (and its window is cleaned up on the next
-- tick), a handle that ends before `delay_ms` renders nothing. Written against the hand-rolled
-- fan-out loops first, so the move onto `composite` is a behaviour-preserving change.

return function(H)
  local eq, ok = H.eq, H.ok
  local progress = require("lib.nvim.progress")

  local trace

  ---A style that records every call; `fail_on` names the calls (and optionally the spec text) it raises on.
  local function fake(name, fail_on)
    fail_on = fail_on or {}
    return {
      start = function(spec)
        trace[#trace + 1] = name .. ".start:" .. tostring(spec.text)
        if fail_on.start then
          error(name .. " start boom", 0)
        end
        return { name = name, n = 0 }
      end,
      update = function(state, spec)
        trace[#trace + 1] = ("%s.update:%s:%s"):format(
          name,
          tostring(spec.text),
          tostring(state and state.n)
        )
        if fail_on.update and spec.text == fail_on.update then
          error(name .. " update boom", 0)
        end
        state.n = state.n + 1
        return state
      end,
      finish = function(state, spec)
        trace[#trace + 1] = ("%s.finish:%s:%s"):format(
          name,
          tostring(spec.text),
          tostring(state and state.n)
        )
        if fail_on.finish then
          error(name .. " finish boom", 0)
        end
      end,
      cancel = function(state, spec)
        trace[#trace + 1] = ("%s.cancel:%s:%s"):format(
          name,
          tostring(spec.text),
          tostring(state and state.n)
        )
        if fail_on.cancel then
          error(name .. " cancel boom", 0)
        end
      end,
    }
  end

  -- The three real style names resolve to modules, so the fakes are installed over those.
  local MODULES = {
    a = "lib.nvim.progress.styles.echo",
    b = "lib.nvim.progress.styles.statusline",
    c = "lib.nvim.progress.styles.notify",
  }
  local saved = {}
  for _, module in pairs(MODULES) do
    saved[module] = package.loaded[module]
  end
  local function install(styles)
    for key, module in pairs(MODULES) do
      package.loaded[module] = styles[key]
    end
  end

  local messages
  local function run(styles, opts, body)
    trace, messages = {}, {}
    install(styles)
    local patched = H.with_patched(vim, "notify", function(msg)
      messages[#messages + 1] = tostring(msg)
    end, function()
      local handle = progress.create(
        vim.tbl_extend(
          "force",
          { delay_ms = 0, style = { "echo", "statusline", "notify" } },
          opts or {}
        )
      )
      body(handle)
      vim.wait(50)
    end)
    return patched
  end

  local function joined()
    return table.concat(trace, " | ")
  end

  -- ---------------------------------------------------------------- the happy path
  run({ a = fake("A"), b = fake("B") }, { style = { "echo", "statusline" } }, function(h)
    h:update({ text = "one", current = 1, total = 3 })
    h:update({ text = "two" })
    h:finish("done")
    h:update({ text = "late" })
    h:finish("again")
  end)
  eq(
    joined(),
    "A.start:nil | B.start:nil | A.update:one:0 | B.update:one:0 | A.update:two:1 | B.update:two:1 | A.finish:done:2 | B.finish:done:2",
    "start, updates (state threaded per style), one finish; later calls are no-ops"
  )

  -- ---------------------------------------------------------------- a failing update disables one style
  run(
    { a = fake("A", { update = "boom" }), b = fake("B") },
    { style = { "echo", "statusline" } },
    function(h)
      h:update({ text = "ok" })
      h:update({ text = "boom" })
      h:update({ text = "after" })
      h:finish("end")
    end
  )
  local t = joined()
  ok(t:find("A.update:boom:1", 1, true), "A raised on its second update")
  ok(not t:find("A.update:after", 1, true), "A is skipped afterwards")
  ok(t:find("B.update:after:2", 1, true), "B keeps rendering")
  ok(not t:find("A.finish", 1, true), "a failed style is not finished")
  ok(t:find("B.finish:end:3", 1, true))
  ok(
    t:find("A.cancel:boom:1", 1, true),
    "its window is cleaned up on the next tick, with the state it had before"
  )
  eq(#messages, 1, "one error notification")
  ok(messages[1]:find("style #1 failed to update, disabling it for this handle", 1, true))

  -- ---------------------------------------------------------------- a failing start
  run(
    { a = fake("A", { start = true }), b = fake("B") },
    { style = { "echo", "statusline" } },
    function(h)
      h:update({ text = "x" })
      h:finish("y")
    end
  )
  t = joined()
  ok(
    not t:find("A.update", 1, true) and not t:find("A.finish", 1, true),
    "a style that failed to start is never called again"
  )
  ok(t:find("B.finish:y:1", 1, true))
  ok(messages[1]:find("style #1 failed to start, disabling it for this handle", 1, true))

  -- ---------------------------------------------------------------- finish / cancel failures
  run(
    { a = fake("A", { finish = true }), b = fake("B") },
    { style = { "echo", "statusline" } },
    function(h)
      h:update({ text = "x" })
      h:finish("y")
    end
  )
  t = joined()
  ok(t:find("B.finish:y:1", 1, true), "a raising finish does not stop the other style")
  ok(t:find("A.cancel:y:1", 1, true), "and the failed one is cancelled on the next tick")
  ok(messages[1]:find("style #1 failed to finish", 1, true))

  run(
    { a = fake("A"), b = fake("B", { cancel = true }) },
    { style = { "echo", "statusline" } },
    function(h)
      h:update({ text = "x" })
      h:cancel("stop")
      h:cancel("again")
      h:update({ text = "late" })
    end
  )
  t = joined()
  ok(t:find("A.cancel:stop:1", 1, true) and t:find("B.cancel:stop:1", 1, true))
  ok(messages[1]:find("style #2 failed to cancel", 1, true))
  eq(select(2, t:gsub("A%.cancel", "")), 1, "cancel runs once")

  -- ---------------------------------------------------------------- request_cancel and on_cancel
  local order = {}
  run({ a = fake("A"), b = fake("B") }, { style = { "echo", "statusline" } }, function(h)
    h:on_cancel(function()
      order[#order + 1] = "first"
    end)
    h:on_cancel(function()
      error("callback boom", 0)
    end)
    h:on_cancel(function()
      order[#order + 1] = "third"
    end)
    h:update({ text = "x" })
    h:request_cancel()
    h:request_cancel()
    ok(h.cancelled, "request_cancel sets cancelled")
  end)
  eq(
    table.concat(order, ","),
    "first,third",
    "on_cancel callbacks all run, a raising one is reported"
  )
  ok(
    joined():find("A.cancel:x:1", 1, true) and joined():find("B.cancel:x:1", 1, true),
    "then the styles are cancelled"
  )
  ok(messages[1]:find("on_cancel callback failed: callback boom", 1, true))

  -- ---------------------------------------------------------------- delay: a fast operation stays silent
  run(
    { a = fake("A"), b = fake("B") },
    { style = { "echo", "statusline" }, delay_ms = 80 },
    function(h)
      h:update({ text = "quick" })
      h:finish("done")
    end
  )
  eq(joined(), "", "finish before delay_ms renders nothing")

  run(
    { a = fake("A"), b = fake("B") },
    { style = { "echo", "statusline" }, delay_ms = 20 },
    function(h)
      h:update({ text = "slow" })
      vim.wait(120, function()
        return #trace > 0
      end)
      h:update({ text = "next" })
      h:finish("fin")
    end
  )
  t = joined()
  ok(t:find("A.start:slow", 1, true), "after delay_ms the styles start with the fields set so far")
  ok(t:find("B.finish:fin:1", 1, true))

  for module, impl in pairs(saved) do
    package.loaded[module] = impl
  end
  for _, module in pairs(MODULES) do
    if saved[module] == nil then
      package.loaded[module] = nil
    end
  end
end
