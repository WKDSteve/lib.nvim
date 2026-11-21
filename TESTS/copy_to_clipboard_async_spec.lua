-- TESTS/copy_to_clipboard_async_spec.lua — copy_to_clipboard(text, on_done)
--
-- The external fallback (`powershell ... Set-Clipboard` on Windows) used to be
-- waited for on every copy: 150-800 ms of a frozen editor per `gY`. With a
-- callback it now runs in the background. Pinned here with a `vim.system`
-- stand-in whose `wait()` raises (any wait on the async path fails the case)
-- and whose exits the spec triggers itself, so it also checks the two
-- promises a synchronous writer gave for free: the clipboard ends with the
-- last text (writes run one at a time, a newer queued copy replaces an older
-- one), and a blocking copy or `:qa` waits for writes still in flight.
--
-- Never reaches a real clipboard tool: every start goes to the stand-in.

return function(H)
  local copy = require("lib.nvim.cross.copy_to_clipboard")
  local writer = require("lib.nvim.cross.copy_to_clipboard.writer")
  local lib = require("lib")
  local core = require("lib.nvim.core")

  ---@class Spec.Start
  ---@field argv string[]
  ---@field stdin string
  ---@field on_exit fun(obj: table)

  --- Run `fn` with every `{ target, key, value }` in `patches` in place.
  local function patched(patches, fn)
    local function step(i)
      local p = patches[i]
      if not p then
        return fn()
      end
      H.with_patched(p[1], p[2], p[3], function()
        step(i + 1)
      end)
    end
    step(1)
  end

  --- A provider-less `+` register, platform `os`, every tool "on PATH", and a
  --- `vim.system` stand-in. `wait` decides what a blocking `wait()` does
  --- (default: raise -- the async path must never wait).
  ---@param os "windows"|"linux"
  ---@param fn fun(starts: Spec.Start[])
  ---@param wait? fun(start: Spec.Start): table
  local function scene(os, fn, wait)
    local starts = {} ---@type Spec.Start[]
    local real_getreg = vim.fn.getreg
    local function fake_system(argv, opts, on_exit)
      local s = { argv = argv, stdin = opts and opts.stdin, on_exit = on_exit }
      starts[#starts + 1] = s
      return {
        wait = function()
          if wait then
            return wait(s)
          end
          error("the editor waited for " .. tostring(argv[1]))
        end,
        kill = function() end,
      }
    end
    patched({
      {
        vim.fn,
        "getreg",
        function(r, ...)
          if r == "+" then
            return ""
          end
          return real_getreg(r, ...)
        end,
      },
      {
        lib,
        "is_windows",
        function()
          return os == "windows"
        end,
      },
      {
        lib,
        "is_linux",
        function()
          return os == "linux"
        end,
      },
      {
        lib,
        "is_macos",
        function()
          return false
        end,
      },
      {
        lib,
        "is_wsl",
        function()
          return false
        end,
      },
      {
        core,
        "has_exec",
        function()
          return true
        end,
      },
      { vim.env, "WAYLAND_DISPLAY", "" },
      { vim.env, "DISPLAY", "" },
      { vim, "system", fake_system },
    }, function()
      fn(starts)
    end)
    -- Every case ends with nothing in flight, or it would leak into the next.
    H.eq(writer.busy(), false, "the case left no write running")
  end

  ---@param s Spec.Start
  ---@param code integer
  local function exit(s, code)
    s.on_exit({ code = code, stdout = "", stderr = "" })
  end

  local function drain()
    vim.wait(50, function()
      return false
    end, 5)
  end

  -- ------------------------------------------------ returns before the tool
  scene("windows", function(starts)
    local got = "unset" ---@type boolean|string
    local ret = copy("alpha", function(ok)
      got = ok
    end)
    H.eq(ret, nil, "with a callback the copy returns nil at once")
    H.eq(#starts, 1, "one tool started")
    H.eq(starts[1].argv[1], "powershell", "the Windows fallback is PowerShell")
    H.eq(starts[1].argv[#starts[1].argv], "$input | Set-Clipboard", "Set-Clipboard reads stdin")
    H.eq(starts[1].stdin, "alpha", "the text goes in on stdin")
    drain()
    H.eq(got, "unset", "no answer before the tool exits")
    exit(starts[1], 0)
    vim.wait(500, function()
      return got ~= "unset"
    end, 5)
    H.eq(got, true, "the answer comes from the exit callback")
  end)

  -- ---------------------------- quick copies: one at a time, the last wins
  scene("windows", function(starts)
    local answers = {}
    local function cb(name)
      return function(ok)
        answers[name] = ok
      end
    end
    copy("one", cb("one"))
    copy("two", cb("two"))
    copy("three", cb("three"))
    H.eq(#starts, 1, "a second write waits while the first runs")
    exit(starts[1], 0)
    vim.wait(500, function()
      return #starts == 2
    end, 5)
    H.eq(#starts, 2, "the queued write starts after the first, once")
    H.eq(starts[2].stdin, "three", "the newest queued text replaced the older one")
    H.eq(answers.one, true, "the first copy's answer")
    H.eq(answers.two, nil, "the replaced copy waits for the write that replaced it")
    exit(starts[2], 0)
    vim.wait(500, function()
      return answers.three ~= nil
    end, 5)
    H.eq(answers.two, true, "the replaced copy gets the replacing write's answer")
    H.eq(answers.three, true, "the last copy's answer")
    drain()
    H.eq(#starts, 2, "no third start: 'two' was never written on its own")
  end)

  -- ------------------------------ a failed tool hands over to the next one
  scene("linux", function(starts)
    local got = "unset" ---@type boolean|string
    copy("text", function(ok)
      got = ok
    end)
    H.eq(starts[1].argv[1], "wl-copy", "first Linux candidate")
    exit(starts[1], 1)
    vim.wait(500, function()
      return #starts == 2
    end, 5)
    H.eq(starts[2].argv[1], "xclip", "a failing tool hands over to the next")
    exit(starts[2], 1)
    vim.wait(500, function()
      return #starts == 3
    end, 5)
    exit(starts[3], 1)
    vim.wait(500, function()
      return got ~= "unset"
    end, 5)
    H.eq(got, false, "every tool failed: the answer is false")
  end)

  -- ----------------------- a program that cannot start counts as a failure
  do
    local got = "unset" ---@type boolean|string
    local tried = 0
    scene("linux", function()
      -- `scene` installed its own stand-in; replace it with a raising one.
      H.with_patched(vim, "system", function()
        tried = tried + 1
        error("ENOENT")
      end, function()
        copy("text", function(ok)
          got = ok
        end)
        vim.wait(500, function()
          return got ~= "unset"
        end, 5)
      end)
    end)
    H.eq(got, false, "no tool could start: false, not a hang")
    H.ok(tried >= 3, "every candidate was tried")
  end

  -- ---------------- a throwing callback neither hides others nor stalls
  scene("windows", function(starts)
    local notified, second = nil, "unset" ---@type string|nil, boolean|string
    H.with_patched(vim, "notify", function(msg)
      notified = msg
    end, function()
      copy("one", function()
        error("caller bug")
      end)
      copy("two", function(ok)
        second = ok
      end)
      exit(starts[1], 0)
      vim.wait(500, function()
        return #starts == 2
      end, 5)
      H.eq(#starts, 2, "the queue went on after a throwing callback")
      exit(starts[2], 0)
      vim.wait(500, function()
        return second ~= "unset" and notified ~= nil
      end, 5)
    end)
    H.eq(second, true, "the next copy still got its answer")
    H.ok(notified and notified:find("caller bug", 1, true), "the callback's error was reported")
  end)

  -- ------------- a blocking copy waits for the background write in flight
  do
    local order = {}
    scene("windows", function(starts)
      copy("bg", function(ok)
        order[#order + 1] = "bg-done:" .. tostring(ok)
      end)
      -- The background write exits a little later, on its own.
      local first = starts[1]
      vim.defer_fn(function()
        exit(first, 0)
      end, 30)
      local ok = copy("fg")
      order[#order + 1] = "fg:" .. tostring(ok)
      H.eq(#starts, 2, "the blocking copy started its own tool")
      H.eq(starts[2].stdin, "fg", "with its own text")
    end, function(s)
      order[#order + 1] = "fg-start:" .. s.stdin
      return { code = 0 }
    end)
    H.eq(
      table.concat(order, " "),
      "bg-done:true fg-start:fg fg:true",
      "the background write finished before the blocking one began"
    )
  end

  -- ------- a blocking copy from a callback waits for the write queued behind
  do
    local order = {}
    scene("windows", function(starts)
      copy("a", function()
        order[#order + 1] = "a-done"
        copy("c")
        order[#order + 1] = "c-returned"
      end)
      copy("b", function()
        order[#order + 1] = "b-done"
      end)
      exit(starts[1], 0)
      vim.defer_fn(function()
        exit(starts[2], 0)
      end, 30)
      vim.wait(1000, function()
        return #order >= 4
      end, 5)
    end, function(s)
      order[#order + 1] = "sync:" .. s.stdin
      return { code = 0 }
    end)
    H.eq(
      table.concat(order, " "),
      "a-done b-done sync:c c-returned",
      "the queued 'b' landed before the later blocking 'c'"
    )
  end

  -- ----------------------------- the register path answers on a later tick
  do
    local got = "unset" ---@type boolean|string
    local started = false
    H.with_patched(vim, "system", function()
      started = true
      error("no tool expected")
    end, function()
      local ret = copy("lib_spec_async_marker", function(ok)
        got = ok
      end)
      H.eq(ret, nil, "nil at once")
      H.eq(got, "unset", "never called synchronously")
      vim.wait(500, function()
        return got ~= "unset"
      end, 5)
    end)
    H.eq(got, true, "the fake provider took it")
    H.eq(vim.fn.getreg("+"), "lib_spec_async_marker", "and holds the text")
    H.eq(started, false, "no external tool when the register works")
  end

  -- --------------------------------------------- flush and :qa coverage
  H.eq(writer.flush(), true, "flush returns at once when nothing runs")
  H.ok(
    #vim.api.nvim_get_autocmds({ group = "lib_nvim_copy_to_clipboard", event = "VimLeavePre" }) == 1,
    "VimLeavePre flushes background writes"
  )

  -- ------------------------------------------------- a bad callback type
  local ok_bad, err = pcall(copy, "x", "not a function")
  H.eq(ok_bad, false, "a non-function on_done is refused")
  H.ok(tostring(err):find("on_done", 1, true), "naming the parameter")
end
