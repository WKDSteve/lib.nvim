-- TESTS/clipboard_image_spec.lua -- lib.nvim.clipboard_image: the clipboard image as a PNG file.

return function(H)
  local ok = H.ok
  local ci = require("lib.nvim.clipboard_image")

  local function eq(a, b, msg)
    if not vim.deep_equal(a, b) then
      error(("FAIL %s: expected %s, got %s"):format(msg or "", vim.inspect(b), vim.inspect(a)), 2)
    end
  end

  local PNG = "\137PNG\r\n\26\n" .. "rest-of-image"
  local tmp = vim.fn.tempname() .. "_clip.png"
  local function cleanup()
    pcall(vim.uv.fs_unlink, tmp)
  end

  -- ---- Linux: wl-paste preferred, xclip as the fallback ---------------------
  local seen
  local function fake(res)
    return function(cmd)
      seen = cmd
      return res
    end
  end
  local done, err = ci.save(tmp, {
    platform = "linux",
    has = function(exe)
      return exe == "wl-paste" or exe == "xclip"
    end,
    system = fake({ code = 0, stdout = PNG }),
  })
  ok(done, "linux/wl-paste saves: " .. tostring(err))
  eq(seen[1], "wl-paste", "wl-paste is preferred over xclip")
  eq(vim.fn.readblob(tmp):sub(1, 4), "\137PNG", "the bytes are written verbatim")
  cleanup()

  done = ci.save(tmp, {
    platform = "linux",
    has = function(exe)
      return exe == "xclip"
    end,
    system = fake({ code = 0, stdout = PNG }),
  })
  ok(done, "linux/xclip saves")
  eq(seen[1], "xclip", "xclip is used when wl-paste is missing")
  cleanup()

  -- ---- no image: nothing is written -----------------------------------------
  done, err = ci.save(tmp, {
    platform = "linux",
    has = function()
      return true
    end,
    system = fake({ code = 1, stdout = "" }),
  })
  ok(not done and err:find("no image", 1, true), "an empty clipboard says so")
  ok(vim.uv.fs_stat(tmp) == nil, "and writes nothing")

  done, err = ci.save(tmp, {
    platform = "linux",
    has = function()
      return true
    end,
    system = fake({ code = 0, stdout = "just some copied text" }),
  })
  ok(not done and err:find("no PNG", 1, true), "text on the clipboard is not stored as an image")
  ok(vim.uv.fs_stat(tmp) == nil, "and nothing is written for it either")

  -- ---- missing tools are a message, not an error ----------------------------
  done, err = ci.save(tmp, {
    platform = "linux",
    has = function()
      return false
    end,
  })
  ok(not done and err:find("wl-paste", 1, true), "no tool: the message names wl-paste/xclip")
  done, err = ci.save(tmp, {
    platform = "macos",
    has = function()
      return false
    end,
  })
  ok(not done and err:find("pngpaste", 1, true), "macOS without pngpaste says so")
  local tool, why = ci.tool({
    platform = "linux",
    has = function()
      return false
    end,
  })
  ok(tool == nil and why ~= nil, "tool() reports the reason for :checkhealth")
  eq(ci.tool({ platform = "windows" }), "powershell.exe", "tool() on Windows")

  -- ---- Windows / macOS: the tool writes the file itself ---------------------
  done, err = ci.save(tmp, {
    platform = "windows",
    system = function(cmd)
      ok(
        cmd[1] == "powershell.exe" and vim.tbl_contains(cmd, "-STA"),
        "windows runs powershell.exe -STA"
      )
      ok(
        cmd[#cmd]:find("'" .. tmp:gsub("'", "''") .. "'", 1, true),
        "the path is a quoted PowerShell string"
      )
      vim.fn.writefile({ "x" }, tmp, "b")
      return { code = 0 }
    end,
  })
  ok(done, "windows: a written file is success: " .. tostring(err))
  cleanup()

  done, err = ci.save(tmp, {
    platform = "windows",
    system = function()
      return { code = 3 }
    end,
  })
  ok(not done and err:find("no image", 1, true), "windows exit 3 means no image")

  done, err = ci.save(tmp, {
    platform = "windows",
    system = function()
      return { code = 0 }
    end,
  })
  ok(not done and err:find("no image", 1, true), "windows: success without a file is no image")

  done, err = ci.save(tmp, {
    platform = "macos",
    has = function()
      return true
    end,
    system = function()
      return { code = 2, stderr = "boom\n" }
    end,
  })
  ok(not done and err:find("boom", 1, true), "a failing tool reports its stderr")

  -- a quote in the path cannot break out of the PowerShell string
  local quoted
  ci.save("C:/it's/a.png", {
    platform = "windows",
    system = function(cmd)
      quoted = cmd[#cmd]
      return { code = 3 }
    end,
  })
  ok(quoted:find("'C:/it''s/a.png'", 1, true), "a single quote in the path is doubled")

  eq(
    select(2, ci.save("", {})),
    "clipboard_image.save needs a target path",
    "an empty path is refused"
  )

  -- ---- save_async: never waits, answers on a later tick ---------------------
  ---Run `save_async` and wait (in the spec, not in the module) for its answer.
  local function async(path, opts)
    local got
    ci.save_async(path, opts, function(a, b)
      got = { a, b }
    end)
    local sync = got ~= nil
    vim.wait(2000, function()
      return got ~= nil
    end, 5)
    return got, sync
  end

  -- A stand-in for vim.system whose wait() throws: the call must go through the exit callback.
  local real_system = vim.system
  local spawned
  local ran_ok, ran_err = pcall(function()
    vim.system = function(cmd, o, on_exit)
      spawned = { cmd = cmd, o = o, on_exit = on_exit }
      return {
        wait = function()
          error("save_async waited for the tool")
        end,
      }
    end
    local got
    ci.save_async(tmp, {
      platform = "linux",
      has = function(exe)
        return exe == "wl-paste"
      end,
    }, function(a, b)
      got = { a, b }
    end)
    ok(spawned and spawned.cmd[1] == "wl-paste", "save_async starts the tool")
    ok(type(spawned.on_exit) == "function", "with an exit callback")
    eq(spawned.o.text, false, "the PNG bytes are read as bytes")
    ok(got == nil, "and returns before the tool has answered")
    -- libuv calls the exit callback in a fast event: the answer must still reach the main loop.
    local timer = assert(vim.uv.new_timer())
    timer:start(0, 0, function()
      timer:close()
      spawned.on_exit({ code = 0, stdout = PNG })
    end)
    vim.wait(2000, function()
      return got ~= nil
    end, 5)
    ok(got and got[1], "the clipboard image is saved: " .. tostring(got and got[2]))
    eq(vim.fn.readblob(tmp):sub(1, 4), "\137PNG", "the bytes are written by the callback")
    cleanup()

    -- the tool cannot be started (not on PATH): a message, on a later tick
    vim.system = function()
      error("ENOENT: no such file or directory")
    end
    local res, sync = async(tmp, { platform = "windows" })
    ok(not sync, "a failed start answers on a later tick")
    ok(
      res and not res[1] and res[2]:find("cannot run powershell.exe", 1, true),
      "and names the tool"
    )
  end)
  vim.system = real_system
  cleanup()
  ok(ran_ok, tostring(ran_err))

  local res, sync = async("", {})
  ok(not sync, "a missing path answers on a later tick")
  eq(res, { false, "clipboard_image.save needs a target path" }, "and is refused")

  res, sync = async(tmp, {
    platform = "linux",
    has = function()
      return false
    end,
  })
  ok(not sync and not res[1] and res[2]:find("wl-paste", 1, true), "no tool: the same message")

  res = async(tmp, {
    platform = "windows",
    system = function()
      return { code = 3 }
    end,
  })
  eq(res, { false, "no image in the clipboard" }, "the answer is the one save gives (exit 3)")

  res = async(tmp, {
    platform = "linux",
    has = function()
      return true
    end,
    system = fake({ code = 0, stdout = "just some copied text" }),
  })
  ok(not res[1] and res[2]:find("no PNG", 1, true), "text is not stored as an image")
  ok(vim.uv.fs_stat(tmp) == nil, "and nothing is written")

  res = async(tmp, {
    platform = "linux",
    has = function()
      return true
    end,
    system = function()
      error("boom")
    end,
  })
  ok(not res[1] and res[2]:find("cannot run wl-paste", 1, true), "a throwing runner is a message")

  local threw = pcall(ci.save_async, tmp, {})
  ok(not threw, "save_async without a callback is a programming error")
end
