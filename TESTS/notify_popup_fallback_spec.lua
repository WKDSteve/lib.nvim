-- TESTS/notify_popup_fallback_spec.lua — lib.nvim.notify.popup without ui.nvim
--
-- Without ui.nvim, `popup.deliver` used to hand every message to `vim.notify`
-- (an echo). A multi-line echo from a callback (an async git answer) stops the
-- editor at a hit-enter prompt; synchronously inside a command it does not.
-- Now a multi-line message gets lib.nvim's own toast (`lib.nvim.ui.kit.toast`,
-- the one ui.nvim re-exports as `ui.kit.toast`), a one-line message stays an
-- echo.
--
-- Part 1 runs in this process. Part 2 starts an embedded child with an
-- attached UI (testing.nvim's `testing.rpc`) and asks the editor itself
-- whether it stands in a hit-enter prompt; n/a without testing.nvim.

return function(H)
  local eq, ok = H.eq, H.ok
  local popup = require("lib.nvim.notify.popup")
  local toast = require("lib.nvim.ui.kit.toast")

  ---Run `fn` as if ui.nvim were not installed: `require("ui.kit.toast")` and
  ---`require("ui.notify")` fail, `vim.notify` is recorded instead of echoed.
  ---@return { msg: string, level: integer }[] echoed
  local function without_ui_nvim(fn)
    local saved_loaded, saved_preload = {}, {}
    for _, name in ipairs({ "ui.kit.toast", "ui.notify" }) do
      saved_loaded[name] = package.loaded[name]
      saved_preload[name] = package.preload[name]
      package.loaded[name] = nil
      package.preload[name] = function()
        error("ui.nvim is not installed (spec)", 0)
      end
    end
    local echoed = {}
    local original = vim.notify
    vim.notify = function(msg, level)
      echoed[#echoed + 1] = { msg = msg, level = level }
    end
    local fine, err = pcall(fn)
    vim.notify = original
    for name in pairs(saved_preload) do
      package.loaded[name] = saved_loaded[name]
      package.preload[name] = saved_preload[name]
    end
    if not fine then
      error(err, 0)
    end
    return echoed
  end

  ---Text of every live toast window (title and body), one string per toast:
  ---a message's first line can become the title (`derive_title`).
  ---@return string[]
  local function toast_texts()
    local out = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      local cfg = vim.api.nvim_win_get_config(win)
      if cfg.relative ~= "" then
        local title = ""
        if type(cfg.title) == "string" then
          title = cfg.title
        elseif type(cfg.title) == "table" then
          for _, chunk in ipairs(cfg.title) do
            title = title .. (type(chunk) == "table" and chunk[1] or tostring(chunk))
          end
        end
        local buf = vim.api.nvim_win_get_buf(win)
        out[#out + 1] = title
          .. "\n"
          .. table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
      end
    end
    return out
  end

  -- ------------------------------------------------------------ in process

  do -- a delayed four-line message: lib's toast, no echo, the whole text
    toast.clear()
    popup.clear()
    local done = false
    local echoed = without_ui_nvim(function()
      vim.defer_fn(function()
        popup.deliver("first\nsecond\nthird\nfourth", vim.log.levels.WARN, { source = "spec" })
        done = true
      end, 20)
      vim.wait(2000, function()
        return done
      end, 5)
    end)
    eq(#echoed, 0, "fallback: a multi-line message from a callback is not echoed")
    eq(toast.active(), 1, "fallback: it is shown as lib.nvim's own toast")
    local text = toast_texts()[1] or ""
    for _, word in ipairs({ "first", "second", "third", "fourth" }) do
      ok(text:find(word, 1, true), "fallback: the toast shows every line (" .. word .. ")")
    end
    eq(popup.history()[1].message, "first\nsecond\nthird\nfourth", "fallback: history keeps it")
    toast.clear()
  end

  do -- a one-line message stays an echo
    popup.clear()
    local echoed = without_ui_nvim(function()
      popup.deliver("just one line", vim.log.levels.WARN, { source = "spec" })
    end)
    eq(#echoed, 1, "fallback: a one-line message is still echoed")
    eq(toast.active(), 0, "fallback: and gets no toast")
  end

  do -- a trailing newline does not make a message multi-line
    local echoed = without_ui_nvim(function()
      popup.deliver("one line\n", vim.log.levels.WARN)
    end)
    eq(#echoed, 1, "fallback: a trailing newline still counts as one line")
    toast.clear()
    popup.clear()
  end

  ---Run `fn` with the toast's clock (`vim.defer_fn`) replaced by a fake one,
  ---then let all of the fake time pass: every timer `fn` started fires now.
  ---No real waiting.
  ---@return integer started timers started inside `fn`
  local function with_fake_clock(fn)
    local timers = {}
    local real_defer = vim.defer_fn
    vim.defer_fn = function(cb, ms)
      timers[#timers + 1] = { cb = cb, ms = ms }
    end
    local fine, err = pcall(fn)
    vim.defer_fn = real_defer
    if not fine then
      error(err, 0)
    end
    for _, t in ipairs(timers) do
      t.cb()
    end
    return #timers
  end

  do -- the multi-line fallback toast has no time limit: it stays until closed
    toast.clear()
    popup.clear()
    local started
    without_ui_nvim(function()
      started = with_fake_clock(function()
        popup.deliver("plan:\nstep one\nstep two", vim.log.levels.INFO, { source = "spec" })
      end)
    end)
    eq(started, 0, "no time limit: the fallback toast starts no close timer")
    eq(toast.active(), 1, "no time limit: after all the fake time it is still on screen")

    popup.dismiss()
    eq(toast.active(), 0, "dismiss: closes the toast")
    eq(#popup.history(), 1, "dismiss: the history stays")
    popup.clear()
  end

  do -- an explicit per-call timeout still wins over the sticky default
    without_ui_nvim(function()
      with_fake_clock(function()
        popup.deliver("a\nb", vim.log.levels.INFO, { timeout = 500 })
      end)
    end)
    eq(toast.active(), 0, "explicit timeout: the caller's own limit still closes it")
    toast.clear()
    popup.clear()
  end

  do -- `:Lib notify dismiss` is one of the routes
    local found = false
    for _, route in ipairs(popup.routes()) do
      if route.path[1] == "notify" and route.path[2] == "dismiss" then
        found = true
        route.run({ args = {} })
      end
    end
    ok(found, "routes: notify dismiss exists")
  end

  do -- the test switch: fallback_toast = false hands the whole text to vim.notify
    toast.clear()
    popup.clear()
    popup.setup({ fallback_toast = false })
    local fine, err = pcall(function()
      local echoed = without_ui_nvim(function()
        popup.deliver("first\nsecond\nthird", vim.log.levels.WARN, { source = "spec" })
      end)
      eq(#echoed, 1, "switch off: the multi-line message goes to vim.notify")
      eq(echoed[1] and echoed[1].msg, "first\nsecond\nthird", "switch off: with its whole text")
      eq(toast.active(), 0, "switch off: and no toast")
    end)
    popup.setup({ fallback_toast = true })
    if not fine then
      error(err, 0)
    end
    local echoed = without_ui_nvim(function()
      popup.deliver("x\ny", vim.log.levels.WARN)
    end)
    eq(#echoed, 0, "switch back on: the toast is the fallback again")
    toast.clear()
    popup.clear()
  end

  -- ------------------------------------------------------------ embedded editor

  local spec_dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
  local root = vim.fs.normalize(vim.fn.fnamemodify(spec_dir .. "..", ":p")):gsub("/$", "")
  local ok_rpc, rpc = pcall(require, "testing.rpc")
  if not ok_rpc then
    local repos = vim.env.REPOS_DIR and vim.env.REPOS_DIR ~= "" and vim.env.REPOS_DIR or ""
    for _, dir in ipairs({
      vim.env.TESTING_NVIM_DIR or "",
      repos ~= "" and (repos .. "/testing.nvim") or "",
      root .. "/.deps/testing.nvim",
      vim.fs.dirname(root) .. "/testing.nvim",
    }) do
      if dir ~= "" and vim.fn.isdirectory(dir .. "/lua/testing") == 1 then
        vim.opt.rtp:append(dir)
        ok_rpc, rpc = pcall(require, "testing.rpc")
        if ok_rpc then
          break
        end
      end
    end
  end
  if not ok_rpc then
    print(
      "n/a  testing.nvim is not available (testing.rpc): the hit-enter check needs an attached UI"
    )
    return
  end

  -- this checkout first (its lib.nvim wins), then testing.nvim, which the child's boot needs
  local rpc_file = vim.api.nvim_get_runtime_file("lua/testing/rpc/init.lua", false)[1]
  local testing_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(rpc_file))))
  local child, err = rpc.spawn({
    root = root,
    rtp_prepend = { root, testing_root },
    size = { rows = 12, cols = 80 },
  })
  if not child then
    error("could not start the embedded editor: " .. tostring(err), 0)
  end
  local fine, why = pcall(function()
    child.screen() -- attaches the UI: without one the editor never shows a hit-enter prompt
    eq(
      child.lua_get("pcall(require, 'ui.kit.toast')"),
      false,
      "child: ui.nvim is not on the runtimepath"
    )

    ---Deliver `code` from a timer (a callback, not a command) and report the prompt afterwards.
    local function delayed(code)
      child.lua(("vim.defer_fn(function() %s end, 30)"):format(code))
      vim.wait(400)
      local mode = child.prompt()
      if mode then
        child.input("<CR>")
        vim.wait(50)
      end
      return mode and (rpc.PROMPTS[mode] or mode) or nil
    end

    -- positive control: the detector sees the prompt a plain multi-line echo causes
    eq(
      delayed([[vim.notify("one\ntwo\nthree\nfour", vim.log.levels.WARN)]]),
      "hit-enter",
      "child: a delayed four-line vim.notify shows a hit-enter prompt (the detector works)"
    )
    eq(
      delayed(
        [[require("lib.nvim.notify.popup").deliver("one\ntwo\nthree\nfour", vim.log.levels.WARN)]]
      ),
      nil,
      "child: a delayed four-line popup.deliver without ui.nvim shows no hit-enter prompt"
    )
    eq(
      child.lua_get("require('lib.nvim.ui.kit.toast').active()"),
      1,
      "child: the message is on screen as a toast"
    )
    eq(
      delayed([[require("lib.nvim.notify.popup").deliver("one line", vim.log.levels.WARN)]]),
      nil,
      "child: a delayed one-line message shows no prompt either"
    )
  end)
  child.kill()
  if not fine then
    error(why, 0)
  end
end
