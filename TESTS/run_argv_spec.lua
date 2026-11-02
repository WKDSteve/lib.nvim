-- TESTS/run_argv_spec.lua — lib.nvim.cross.run_argv

return function(H)
  local eq, ok = H.eq, H.ok

  local run_argv = require("lib.nvim.cross.run_argv")

  -- A child that really starts on every platform (no `sh` needed): this Neovim running a script that writes
  -- `out_text` to stdout and `err_text` to stderr and exits with `code`. `ENOENT` cannot satisfy a check on its text.
  local function exiting_child(code, out_text, err_text)
    local script = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({
      ("vim.uv.fs_write(1, %q)"):format(out_text),
      ("vim.uv.fs_write(2, %q)"):format(err_text),
      ("os.exit(%d)"):format(code),
    }, script)
    return { vim.v.progpath, "-n", "-i", "NONE", "-u", "NONE", "--headless", "-l", script }
  end

  -- ------------------------------------------------------------ run_blocking

  -- A real, trivially-successful command.
  local echo_ok, echo_err = run_argv.run_blocking({ "echo", "hello" })
  eq(echo_ok, true, "run_blocking: a successful command reports ok")
  eq(echo_err, nil, "run_blocking: a successful command has no error")

  -- A real command that exits non-zero.
  local fail_ok, fail_err = run_argv.run_blocking(exiting_child(3, "", "child-stderr-text"))
  eq(fail_ok, false, "run_blocking: a non-zero exit reports failure")
  ok(
    tostring(fail_err):find("child-stderr-text", 1, true) ~= nil,
    "run_blocking: a non-zero exit reports the child's stderr, so the child did run"
  )

  -- Regression: a command that can't be spawned at all (ENOENT) used to
  -- raise synchronously through vim.system() instead of returning
  -- (false, err) like every other failure path here.
  local enoent_ok, enoent_err = run_argv.run_blocking({ "this-binary-does-not-exist-anywhere" })
  eq(
    enoent_ok,
    false,
    "run_blocking: an unspawnable command reports failure, not an uncaught error"
  )
  ok(enoent_err ~= nil, "run_blocking: an unspawnable command reports an error message")

  -- ------------------------------------------------------- run_blocking_captured

  local cap_ok, cap_out = run_argv.run_blocking_captured({ "echo", "captured text" })
  eq(cap_ok, true, "run_blocking_captured: a successful command reports ok")
  ok(cap_out:find("captured text", 1, true) ~= nil, "run_blocking_captured: stdout is captured")

  local cap_fail_ok, cap_fail_out =
    run_argv.run_blocking_captured(exiting_child(1, "child-stdout-text", ""))
  eq(cap_fail_ok, false, "run_blocking_captured: a non-zero exit reports failure")
  ok(
    tostring(cap_fail_out):find("child-stdout-text", 1, true) ~= nil,
    "run_blocking_captured: ... with the stdout of the child that did run"
  )
  eq(
    type(cap_fail_out),
    "string",
    "run_blocking_captured: output is always a string, even on failure"
  )

  -- Same ENOENT regression as run_blocking: must not raise.
  local cap_enoent_ok, cap_enoent_out =
    run_argv.run_blocking_captured({ "this-binary-does-not-exist-anywhere" })
  eq(
    cap_enoent_ok,
    false,
    "run_blocking_captured: an unspawnable command reports failure, not an uncaught error"
  )
  eq(
    type(cap_enoent_out),
    "string",
    "run_blocking_captured: still returns a string on the ENOENT path"
  )

  -- ------------------------------------------------------- binary (byte-exact)

  -- A child Neovim writes a fixed byte string straight to fd 1 through libuv
  -- (no C-runtime newline translation): CRLF, a NUL, a lone CR, a high byte.
  local script = H.tmpfile(".lua")
  vim.fn.writefile({ 'vim.uv.fs_write(1, "a\\r\\nb\\0c\\r\\n\\r\\255")' }, script)
  local argv = { vim.v.progpath, "--headless", "-u", "NONE", "-l", script }
  local exact = "a\r\nb\0c\r\n\r\255"

  local bin_ok, bin_out = run_argv.run_blocking_captured(argv, nil, { binary = true })
  eq(bin_ok, true, "run_blocking_captured{binary}: the child ran")
  eq(bin_out, exact, "run_blocking_captured{binary}: stdout is delivered byte for byte")

  -- Default mode is text: `\r\n` becomes `\n` (vim.system's own documented
  -- behaviour). Unchanged by the new option -- callers that never pass it must
  -- see exactly what they saw before.
  local text_ok, text_out = run_argv.run_blocking_captured(argv)
  eq(text_ok, true, "run_blocking_captured: default mode still runs the child")
  eq(
    text_out,
    "a\nb\0c\n\r\255",
    "run_blocking_captured: default mode is text (\\r\\n -> \\n), as before"
  )

  local async_done, async_ok, async_out = false, nil, nil
  run_argv.run_async_captured(argv, function(ok_, out_)
    async_done, async_ok, async_out = true, ok_, out_
  end, nil, { binary = true })
  vim.wait(10000, function()
    return async_done
  end, 20)
  ok(async_done, "run_async_captured{binary}: on_done fires")
  eq(async_ok, true, "run_async_captured{binary}: the child ran")
  eq(async_out, exact, "run_async_captured{binary}: stdout is delivered byte for byte")

  local async_text_done, async_text_out = false, nil
  run_argv.run_async_captured(argv, function(_, out_)
    async_text_done, async_text_out = true, out_
  end)
  vim.wait(10000, function()
    return async_text_done
  end, 20)
  eq(async_text_out, "a\nb\0c\n\r\255", "run_async_captured: default mode is text, as before")
  vim.fn.delete(script)

  -- ------------------------------------------- env / cwd / timeout / result

  -- A child Neovim that reports its environment and working directory on
  -- stdout, writes to stderr and exits with a code of its own.
  local probe = H.tmpfile(".lua")
  vim.fn.writefile({
    'io.stdout:write((os.getenv("LIB_SPEC_VAR") or "unset") .. "|" .. vim.uv.cwd())',
    'io.stderr:write("to-stderr")',
    "os.exit(3)",
  }, probe)
  local probe_argv = { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", probe }
  local work = vim.fn.tempname() .. "-run-argv-cwd"
  vim.fn.mkdir(work, "p")
  local function same_dir(a, b)
    return vim.fs.normalize(vim.uv.fs_realpath(a) or a)
      == vim.fs.normalize(vim.uv.fs_realpath(b) or b)
  end

  local res = run_argv.run_blocking_result(probe_argv, nil, {
    env = { LIB_SPEC_VAR = "from-opts" },
    cwd = work,
  })
  eq(res.ok, false, "run_blocking_result: a non-zero exit is not ok")
  eq(res.code, 3, "run_blocking_result: ... with the child's exit code")
  eq(res.stderr, "to-stderr", "run_blocking_result: ... and its stderr")
  eq(res.timed_out, false, "run_blocking_result: ... which is not a timeout")
  local seen_var, seen_cwd = res.stdout:match("^(.-)|(.*)$")
  eq(seen_var, "from-opts", "run_blocking_result: opts.env reaches the child")
  ok(
    seen_cwd and same_dir(seen_cwd, work),
    "run_blocking_result: opts.cwd is the child's directory"
  )

  local plain = run_argv.run_blocking_result(probe_argv)
  eq(plain.stdout:match("^(.-)|"), "unset", "run_blocking_result: no env entry unless asked for")

  local good = run_argv.run_blocking_result({ vim.v.progpath, "--version" })
  eq(good.ok, true, "run_blocking_result: a successful command is ok")
  eq(good.code, 0, "run_blocking_result: ... exit code 0")
  ok(good.stdout:find("NVIM", 1, true) ~= nil, "run_blocking_result: ... stdout captured")
  eq(good.stderr, "", 'run_blocking_result: ... an empty stderr is ""')

  local missing = run_argv.run_blocking_result({ "this-binary-does-not-exist-anywhere" })
  eq(missing.ok, false, "run_blocking_result: an unspawnable command is not ok")
  eq(missing.code, -1, "run_blocking_result: ... code -1")
  eq(missing.stdout, "", "run_blocking_result: ... no stdout")
  ok(
    type(missing.stderr) == "string" and missing.stderr ~= "",
    "run_blocking_result: ... the reason in stderr"
  )

  local sleeper = H.tmpfile(".lua")
  vim.fn.writefile({ "vim.wait(60000, function() return false end, 50)" }, sleeper)
  local sleeper_argv =
    { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", sleeper }
  local slow = run_argv.run_blocking_result(sleeper_argv, nil, { timeout_ms = 300 })
  eq(slow.timed_out, true, "run_blocking_result: a process past timeout_ms is timed out")
  eq(slow.code, 124, "run_blocking_result: ... with the timeout(1) exit code")
  eq(slow.ok, false, "run_blocking_result: ... and not ok")

  -- A child that catches SIGTERM and exits normally reports no signal; the deadline still
  -- makes it a timeout (this is what a CI runner's nvim does when it is the sleeper).
  if vim.fn.has("win32") == 0 and vim.fn.executable("sh") == 1 then
    local trapped = run_argv.run_blocking_result(
      { "sh", "-c", "trap 'exit 0' TERM; while :; do sleep 0.05; done" },
      nil,
      { timeout_ms = 300 }
    )
    eq(trapped.code, 124, "run_blocking_result: a child that traps SIGTERM: the timeout code")
    eq(trapped.timed_out, true, "run_blocking_result: ... is still timed out")
    eq(trapped.signal, 15, "run_blocking_result: ... and reports the SIGTERM it was sent")
    local early = run_argv.run_blocking_result(
      { "sh", "-c", "exit 124" },
      nil,
      { timeout_ms = 20000 }
    )
    eq(early.timed_out, false, "run_blocking_result: an early exit 124 of its own is no timeout")
  end

  -- The deadline is our own timer, so a loop that was not iterated for a while before
  -- the call (libuv's cached time is then stale and a timer armed on it fires early)
  -- must not turn a timeout into "not timed out": busy-wait first, then run a child
  -- that handles SIGTERM and exits 0 (what Neovim does).
  do
    local posix = vim.fn.has("win32") == 0 and vim.fn.executable("sh") == 1
    local term_argv = posix and { "sh", "-c", "trap 'exit 0' TERM; while :; do sleep 0.05; done" }
      or sleeper_argv
    local function stall(ms)
      local t = vim.uv.hrtime()
      while (vim.uv.hrtime() - t) / 1e6 < ms do
      end
    end

    stall(230)
    local stalled = run_argv.run_blocking_result(term_argv, nil, { timeout_ms = 300 })
    eq(stalled.timed_out, true, "run_blocking_result: a stalled loop before the call: timed out")
    eq(stalled.code, 124, "run_blocking_result: ... code 124")
    ok(stalled.signal ~= 0, "run_blocking_result: ... with a non-zero signal")

    stall(230)
    local c_ok = run_argv.run_blocking_captured(term_argv, nil, { timeout_ms = 300 })
    eq(c_ok, false, "run_blocking_captured: a stalled loop before the call: a failure")
    stall(230)
    local c_ok2 =
      run_argv.run_blocking_captured(term_argv, nil, { timeout_ms = 300, max_output_bytes = 1000 })
    eq(c_ok2, false, "run_blocking_captured: ... also with an output cap")

    stall(230)
    local s_done, s_res
    run_argv.run_async_captured(term_argv, function(_, _, code_, _, sig_)
      s_done, s_res = true, { code = code_, signal = sig_ }
    end, nil, { timeout_ms = 300 })
    vim.wait(8000, function()
      return s_done
    end, 20)
    ok(s_done, "run_async_captured: a stalled loop before the call: on_done fires")
    eq((s_res or {}).code, 124, "run_async_captured: ... code 124")
    ok(((s_res or {}).signal or 0) ~= 0, "run_async_captured: ... with a non-zero signal")

    if posix then
      -- A child that ignores SIGTERM is killed (SIGKILL) after the grace period.
      local stubborn_argv = { "sh", "-c", "trap '' TERM; while :; do sleep 0.05; done" }
      local stubborn = run_argv.run_blocking_result(stubborn_argv, nil, { timeout_ms = 2000 })
      eq(stubborn.timed_out, true, "run_blocking_result: a child ignoring SIGTERM: timed out")
      eq(stubborn.code, 124, "run_blocking_result: ... code 124")
      eq(stubborn.signal, 9, "run_blocking_result: ... killed with SIGKILL")

      local b_done, b_res
      run_argv.run_async_captured(stubborn_argv, function(_, _, code_, _, sig_)
        b_done, b_res = true, { code = code_, signal = sig_ }
      end, nil, { timeout_ms = 2000 })
      vim.wait(12000, function()
        return b_done
      end, 20)
      ok(b_done, "run_async_captured: a child ignoring SIGTERM: on_done fires")
      eq((b_res or {}).code, 124, "run_async_captured: ... code 124")
      eq((b_res or {}).signal, 9, "run_async_captured: ... signal 9")
    end
  end

  -- the same options on the older runners
  local cap_ok_, cap_out_ = run_argv.run_blocking_captured(probe_argv, nil, {
    env = { LIB_SPEC_VAR = "captured" },
  })
  eq(cap_ok_, false, "run_blocking_captured: the child exits 3")
  eq(cap_out_:match("^(.-)|"), "captured", "run_blocking_captured: opts.env reaches the child")
  local cap_slow_ok = run_argv.run_blocking_captured(sleeper_argv, nil, { timeout_ms = 300 })
  eq(cap_slow_ok, false, "run_blocking_captured: opts.timeout_ms kills a slow process")

  local a_done, a_ok, a_out, a_code, a_err
  run_argv.run_async_captured(probe_argv, function(ok_, out_, code_, err_)
    a_done, a_ok, a_out, a_code, a_err = true, ok_, out_, code_, err_
  end, nil, { env = { LIB_SPEC_VAR = "async" }, cwd = work })
  vim.wait(10000, function()
    return a_done
  end, 20)
  ok(a_done, "run_async_captured: on_done fires")
  eq(a_ok, false, "run_async_captured: the child exits 3")
  eq(a_code, 3, "run_async_captured: ... and the code is reported")
  eq(a_err, "to-stderr", "run_async_captured: ... and the stderr")
  eq(a_out:match("^(.-)|"), "async", "run_async_captured: opts.env reaches the child")
  ok(same_dir(a_out:match("|(.*)$"), work), "run_async_captured: opts.cwd is the child's directory")

  local t_done, t_code
  run_argv.run_async_captured(sleeper_argv, function(_, _, code_)
    t_done, t_code = true, code_
  end, nil, { timeout_ms = 300 })
  vim.wait(10000, function()
    return t_done
  end, 20)
  ok(t_done, "run_async_captured: a timed-out process still reports")
  eq(t_code, 124, "run_async_captured: ... with exit code 124")

  -- A process that merely exits 124 by itself is not a timeout.
  local own_124 = run_argv.run_blocking_result({
    vim.v.progpath,
    "-n",
    "-i",
    "NONE",
    "--headless",
    "-u",
    "NONE",
    "-c",
    "cquit 124",
  })
  eq(own_124.code, 124, "run_blocking_result: an exit code of 124 is reported")
  eq(own_124.timed_out, false, "run_blocking_result: ... but with no timeout_ms it is no timeout")

  -- ... and not with a timeout_ms that was not reached either: only a kill for the
  -- deadline is a timeout.
  local own_124_budget = run_argv.run_blocking_result({
    vim.v.progpath,
    "-n",
    "-i",
    "NONE",
    "--headless",
    "-u",
    "NONE",
    "-c",
    "cquit 124",
  }, nil, { timeout_ms = 60000 })
  eq(own_124_budget.code, 124, "run_blocking_result: the child's own 124 is reported")
  eq(
    own_124_budget.timed_out,
    false,
    "run_blocking_result: ... and is no timeout although timeout_ms is set"
  )

  -- A tiny budget must give a result, not an error from indexing a nil wait().
  for _, ms in ipairs({ 0, 1 }) do
    local r_ok, r = pcall(run_argv.run_blocking_result, sleeper_argv, nil, { timeout_ms = ms })
    eq(r_ok, true, ("run_blocking_result: timeout_ms=%d does not throw"):format(ms))
    eq(r.ok, false, ("run_blocking_result: timeout_ms=%d is a failure"):format(ms))
    local c_ok, c_res =
      pcall(run_argv.run_blocking_captured, sleeper_argv, nil, { timeout_ms = ms })
    eq(c_ok, true, ("run_blocking_captured: timeout_ms=%d does not throw"):format(ms))
    eq(c_res, false, ("run_blocking_captured: timeout_ms=%d is a failure"):format(ms))
  end

  -- ------------------------------------------------------- max_output_bytes

  -- A child that prints ~3 MB. Under a cap it is stopped and the run says why.
  local big = H.tmpfile(".lua")
  vim.fn.writefile({
    "local chunk = string.rep('x', 65536)",
    "for _ = 1, 48 do io.stdout:write(chunk) end",
    "io.stdout:flush()",
  }, big)
  local big_argv = { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", big }

  local capped = run_argv.run_blocking_result(big_argv, nil, { max_output_bytes = 100000 })
  eq(capped.ok, false, "run_blocking_result: output past max_output_bytes is a failure")
  eq(capped.code, run_argv.OUTPUT_LIMIT_CODE, "run_blocking_result: ... with the output-limit code")
  ok(#capped.stdout <= 100000, "run_blocking_result: ... and stdout holds at most the cap")
  ok(#capped.stdout > 0, "run_blocking_result: ... and what fitted")
  ok(capped.stderr:find("exceeded", 1, true) ~= nil, "run_blocking_result: ... and stderr says why")
  eq(capped.timed_out, false, "run_blocking_result: ... which is not a timeout")

  -- A cap that falls inside a multi-byte character must not leave half of it.
  local wide = H.tmpfile(".lua")
  vim.fn.writefile({
    "io.stdout:write(string.rep('\226\130\172', 200))",
    "io.stdout:flush()",
  }, wide)
  local wide_argv = { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", wide }
  for _, cap in ipairs({ 100, 101, 102 }) do
    local cut = run_argv.run_blocking_result(wide_argv, nil, { max_output_bytes = cap })
    eq(cut.code, run_argv.OUTPUT_LIMIT_CODE, "utf8 cap " .. cap .. ": stopped at the cap")
    eq(#cut.stdout % 3, 0, "utf8 cap " .. cap .. ": ... on a character boundary")
  end

  -- stderr handed back is bounded as well.
  local noisy = H.tmpfile(".lua")
  vim.fn.writefile({
    "io.stderr:write(string.rep('e', 400000))",
    "os.exit(3)",
  }, noisy)
  local noisy_result = run_argv.run_blocking_result(
    { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", noisy },
    nil,
    {}
  )
  eq(noisy_result.code, 3, "stderr bound: the exit code is kept")
  ok(#noisy_result.stderr <= 64 * 1024 + 8, "stderr bound: ... and the text is cut")
  eq(noisy_result.stderr:sub(-3), "...", "stderr bound: ... and marked as cut")

  -- the cut never leaves half a multi-byte character: 65536 is not a multiple of 3
  local utf8_script = H.tmpfile(".lua")
  vim.fn.writefile({ "io.stderr:write(string.rep('\\230\\188\\162', 30000))" }, utf8_script)
  local wide_result = run_argv.run_blocking_result(
    { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", utf8_script },
    nil,
    {}
  )
  eq(#wide_result.stderr, 65535 + 3, "stderr bound: a cut 3-byte character is dropped whole")

  local under = run_argv.run_blocking_result(big_argv, nil, { max_output_bytes = 10 * 1024 * 1024 })
  eq(under.ok, true, "run_blocking_result: output under the cap is untouched")
  eq(#under.stdout, 48 * 65536, "run_blocking_result: ... byte for byte")

  local cap_ok2, cap_out2 =
    run_argv.run_blocking_captured(big_argv, nil, { max_output_bytes = 100000 })
  eq(cap_ok2, false, "run_blocking_captured: output past the cap is a failure")
  ok(#cap_out2 <= 100000, "run_blocking_captured: ... and cut at the cap")

  local o_done, o_ok, o_out, o_code, o_err
  run_argv.run_async_captured(big_argv, function(ok_, out_, code_, err_)
    o_done, o_ok, o_out, o_code, o_err = true, ok_, out_, code_, err_
  end, nil, { max_output_bytes = 100000 })
  vim.wait(20000, function()
    return o_done
  end, 20)
  ok(o_done, "run_async_captured: a runaway process still reports")
  eq(o_ok, false, "run_async_captured: ... as a failure")
  eq(o_code, run_argv.OUTPUT_LIMIT_CODE, "run_async_captured: ... with the output-limit code")
  ok(#o_out <= 100000, "run_async_captured: ... stdout cut at the cap")
  ok(o_err:find("exceeded", 1, true) ~= nil, "run_async_captured: ... and the reason in stderr")
  vim.fn.delete(big)

  -- CRLF handling is the same with and without a cap: text mode rewrites it.
  local crlf_argv = {
    vim.v.progpath,
    "-n",
    "-i",
    "NONE",
    "--headless",
    "-u",
    "NONE",
    "-c",
    -- written past the C runtime, which would turn "\n" into "\r\n" on Windows
    "lua vim.uv.fs_write(1, 'a\\r\\nb')",
    "-c",
    "qa!",
  }
  local crlf = run_argv.run_blocking_result(crlf_argv, nil, { max_output_bytes = 1000 })
  ok(
    crlf.stdout:find("\r", 1, true) == nil,
    "run_blocking_result: a capped run still rewrites CRLF in text mode"
  )

  -- ------------------------------------------------- async answer at the deadline

  -- A grandchild that keeps the output pipes open must not delay the answer
  -- past the deadline (POSIX: the sleeper outlives the killed shell).
  if vim.fn.has("win32") == 0 then
    local g_done, g_code
    local started = vim.uv.hrtime()
    run_argv.run_async_captured({ "sh", "-c", "sleep 30 & wait" }, function(_, _, code_)
      g_done, g_code = true, code_
    end, nil, { timeout_ms = 300 })
    vim.wait(8000, function()
      return g_done
    end, 20)
    ok(g_done, "run_async_captured: a timeout is answered although a descendant holds the pipes")
    ok(
      (vim.uv.hrtime() - started) / 1e6 < 6000,
      "run_async_captured: ... at the deadline (plus grace), not when the sleeper ends"
    )
    eq(g_code, 124, "run_async_captured: ... with exit code 124")
  end

  -- A process killed by a signal reports exit status 0 plus `signal`: success
  -- must not be read from the status alone. POSIX only.
  if vim.fn.has("win32") == 0 then
    local killed = run_argv.run_blocking_result({ "sh", "-c", "kill -9 $$" })
    eq(killed.ok, false, "run_blocking_result: a process killed by a signal is not ok")
    eq(killed.signal, 9, "run_blocking_result: ... the signal is reported")
    eq(killed.code, 137, "run_blocking_result: ... as 128 + signal, the shell's convention")
    eq(killed.timed_out, false, "run_blocking_result: ... which is not a timeout")

    local k_done, k_ok, k_code, k_signal
    run_argv.run_async_captured({ "sh", "-c", "kill -9 $$" }, function(ok_, _, code_, _, signal_)
      k_done, k_ok, k_code, k_signal = true, ok_, code_, signal_
    end)
    vim.wait(10000, function()
      return k_done
    end, 20)
    ok(k_done, "run_async_captured: a killed process reports")
    eq(k_signal, 9, "run_async_captured: the terminating signal is the 5th argument")
    -- `ok`/`code` keep reading the exit status alone, as they always did.
    eq(k_ok, true, "run_async_captured: ok is still the bare exit status (compatible)")
    eq(k_code, 0, "run_async_captured: ... and so is code")
  end

  -- ------------------------------------------- the whole process group is killed

  -- A timeout, `stop()` or an output cap must not leave the GRANDCHILDREN of the
  -- child alive (POSIX: the child runs in a process group of its own and the
  -- signal goes to the group; Windows has `taskkill /T`, a different code path
  -- that needs a Windows host to be exercised, so these specs are POSIX only).
  -- The grandchildren are `sleep 60` processes started by a shell: they hold the
  -- output pipes of the shell, as the `git-remote-http` behind a stalled
  -- `git fetch` does.
  if vim.fn.has("win32") == 0 and vim.fn.executable("sh") == 1 then
    local TIMEOUT = 1000 -- ms; the shell has written its pid file long before

    --- The pid a script wrote to `file`, or nil while it has not (completely).
    ---@param file string
    ---@return integer|nil
    local function read_pid(file)
      local f = io.open(file, "r")
      if not f then
        return nil
      end
      local text = f:read("*a")
      f:close()
      return tonumber(text:match("^(%d+)\n"))
    end

    --- Whether `pid` is a live process. A zombie (killed, but not yet reaped by
    --- whatever adopted it; PID 1 of a container often never does) is dead.
    ---@param pid integer
    ---@return boolean
    local function is_alive(pid)
      if vim.uv.kill(pid, 0) ~= 0 then
        return false -- ESRCH
      end
      local f = io.open(("/proc/%d/stat"):format(pid), "r")
      if f then
        -- (nil when the process is reaped between the open and the read)
        local stat = f:read("*a") or ""
        f:close()
        if stat:match("%) (%a)") == "Z" then
          return false
        end
      end
      return true
    end

    --- `sh -c` argv of a script that starts `grandchild` in the background, writes
    --- its pid to `file`, then runs `tail`.
    ---@param file string
    ---@param grandchild string  The background command, e.g. `sleep 60`
    ---@param tail string  What the shell does after the pid file exists
    ---@param head? string  Run before the grandchild is started (`trap ...`)
    ---@return string[]
    local function sh_script(file, grandchild, tail, head)
      local text = ("%s%s & echo $! > %s; %s"):format(
        head and (head .. "; ") or "",
        grandchild,
        vim.fn.shellescape(file),
        tail
      )
      return { "sh", "-c", text }
    end

    --- Poll until the pid file exists; the grandchild pid.
    ---@param file string
    ---@return integer
    local function grandchild_pid(file)
      vim.wait(10000, function()
        return read_pid(file) ~= nil
      end, 20)
      local pid = read_pid(file)
      ok(pid ~= nil, "the script started its background grandchild (pid file: " .. file .. ")")
      return pid
    end

    --- Assert that the grandchild is gone shortly after the run was reported; kill
    --- it in any case, so that a failing spec leaves no `sleep 60` behind.
    ---@param pid integer
    ---@param msg string
    local function expect_dead(pid, msg)
      local dead = vim.wait(8000, function()
        return not is_alive(pid)
      end, 20)
      if not dead then
        vim.uv.kill(pid, "sigkill")
      end
      ok(dead, msg .. " (pid " .. pid .. " is still alive)")
    end

    --- Run `argv` through `run_async_captured` and wait for `on_done`.
    ---@param argv string[]
    ---@param opts? table
    ---@param during? fun(handle: table)  Called right after the start
    ---@return table r  `done, ok, code, signal, stderr, elapsed` (ms from start to on_done)
    local function run_async(cmd, opts, during)
      local r = { done = false }
      local t0 = vim.uv.hrtime()
      local handle = run_argv.run_async_captured(cmd, function(ok_, out_, code_, err_, sig_)
        r.done, r.ok, r.out, r.code, r.stderr, r.signal = true, ok_, out_, code_, err_, sig_
        r.elapsed = (vim.uv.hrtime() - t0) / 1e6
      end, nil, opts)
      if during then
        during(handle)
      end
      vim.wait(20000, function()
        return r.done
      end, 20)
      ok(r.done, "run_async_captured: on_done fires")
      return r
    end

    --- A fresh path for a script to write a pid (or a marker) to.
    ---@return string
    local function tmp_pidfile()
      return H.tmpfile(".pid")
    end

    -- (a) timeout: the shell dies of the SIGTERM, the grandchild must too.
    do
      local file = tmp_pidfile()
      local r = run_async(sh_script(file, "sleep 60", "wait"), { timeout_ms = TIMEOUT })
      eq(r.code, 124, "async timeout: code 124")
      eq(r.signal, 15, "async timeout: ... the shell died of the SIGTERM")
      -- Not delayed by the grace period (1500 ms): the pipes close with the group.
      ok(
        r.elapsed < TIMEOUT + 1000,
        ("async timeout: answered at the deadline, not after the grace period (%d ms)"):format(
          r.elapsed
        )
      )
      expect_dead(grandchild_pid(file), "async timeout: the grandchild is killed")
      vim.fn.delete(file)

      file = tmp_pidfile()
      local result = run_argv.run_blocking_result(
        sh_script(file, "sleep 60", "wait"),
        nil,
        { timeout_ms = TIMEOUT }
      )
      eq(result.timed_out, true, "blocking_result timeout: timed out")
      eq(result.code, 124, "blocking_result timeout: code 124")
      expect_dead(grandchild_pid(file), "blocking_result timeout: the grandchild is killed")
      vim.fn.delete(file)

      file = tmp_pidfile()
      local c_ok = run_argv.run_blocking_captured(
        sh_script(file, "sleep 60", "wait"),
        nil,
        { timeout_ms = TIMEOUT }
      )
      eq(c_ok, false, "blocking_captured timeout: a failure")
      expect_dead(grandchild_pid(file), "blocking_captured timeout: the grandchild is killed")
      vim.fn.delete(file)
    end

    -- (b) stop() reaches the grandchild too.
    do
      local file = tmp_pidfile()
      local r = run_async(sh_script(file, "sleep 60", "wait"), nil, function(handle)
        grandchild_pid(file) -- the group exists
        handle.stop()
      end)
      eq(r.signal, 15, "async stop(): the shell died of the SIGTERM")
      expect_dead(grandchild_pid(file), "async stop(): the grandchild is killed")
      vim.fn.delete(file)
    end

    -- (c) the shell and the grandchild ignore SIGTERM: SIGKILL for the group after
    -- the grace period (the trap is inherited by the background command).
    do
      local file = tmp_pidfile()
      local term_argv = sh_script(file, "sleep 60", "wait", "trap '' TERM")
      local r = run_async(term_argv, { timeout_ms = TIMEOUT })
      eq(r.code, 124, "async, SIGTERM ignored: code 124")
      eq(r.signal, 9, "async, SIGTERM ignored: killed with SIGKILL")
      expect_dead(grandchild_pid(file), "async, SIGTERM ignored: the grandchild is killed")
      vim.fn.delete(file)

      file = tmp_pidfile()
      local result = run_argv.run_blocking_result(
        sh_script(file, "sleep 60", "wait", "trap '' TERM"),
        nil,
        { timeout_ms = TIMEOUT }
      )
      eq(result.code, 124, "blocking_result, SIGTERM ignored: code 124")
      eq(result.signal, 9, "blocking_result, SIGTERM ignored: killed with SIGKILL")
      expect_dead(grandchild_pid(file), "blocking_result, SIGTERM ignored: grandchild killed")
      vim.fn.delete(file)

      file = tmp_pidfile()
      local c_ok = run_argv.run_blocking_captured(
        sh_script(file, "sleep 60", "wait", "trap '' TERM"),
        nil,
        { timeout_ms = TIMEOUT }
      )
      eq(c_ok, false, "blocking_captured, SIGTERM ignored: a failure")
      expect_dead(grandchild_pid(file), "blocking_captured, SIGTERM ignored: grandchild killed")
      vim.fn.delete(file)
    end

    --- argv of a leader that exits on the SIGTERM (its trap leaves `marker` behind)
    --- while its grandchild ignores the SIGTERM and keeps running and holding the pipes.
    --- The grandchild writes its own pid file, and only once it ignores SIGTERM: a pid
    --- file written by the leader right after the fork (`$!`) can show up while the
    --- subshell still has the default disposition, so a `stop()` sent as soon as the
    --- file exists killed the grandchild, the pipes closed and the run ended with the
    --- leader's code 0 instead of at the deadline (seen on macOS CI). The `sleep 0.1`
    --- before the trap keeps that window open on every host, so a pid file that is
    --- written too early again fails (e2) every time instead of now and then.
    ---@param file string  The pid file of the grandchild
    ---@param marker string  Written by the leader's TERM trap
    ---@return string[]
    local function stubborn_grandchild(file, marker)
      local text = [[trap "echo t > %s; exit 0" TERM; ]]
        .. [[(sleep 0.1; trap '' TERM; exec sh -c 'echo $$ > "$0"; exec sleep 60' %s) & wait]]
      return {
        "sh",
        "-c",
        text:format(vim.fn.shellescape(marker), vim.fn.shellescape(file)),
      }
    end

    -- (c2) the shell exits on the SIGTERM (and is reaped) while its grandchild
    -- ignores it and keeps the pipes: the SIGKILL of the grace period must still
    -- reach the group of the dead leader. The marker of the shell's TERM trap proves
    -- the deadline sends SIGTERM first (SIGKILL cannot be trapped).
    do
      local file, marker = tmp_pidfile(), tmp_pidfile()
      local r = run_async(stubborn_grandchild(file, marker), { timeout_ms = TIMEOUT })
      eq(r.code, 124, "async, leader gone: code 124")
      ok(vim.fn.filereadable(marker) == 1, "async, leader gone: the deadline sent SIGTERM first")
      expect_dead(grandchild_pid(file), "async, leader gone: the grandchild is killed")
      vim.fn.delete(file)
      vim.fn.delete(marker)

      file, marker = tmp_pidfile(), tmp_pidfile()
      local result = run_argv.run_blocking_result(stubborn_grandchild(file, marker), nil, {
        timeout_ms = TIMEOUT,
      })
      eq(result.code, 124, "blocking_result, leader gone: code 124")
      ok(
        vim.fn.filereadable(marker) == 1,
        "blocking_result, leader gone: the deadline sent SIGTERM first"
      )
      expect_dead(grandchild_pid(file), "blocking_result, leader gone: the grandchild is killed")
      vim.fn.delete(file)
      vim.fn.delete(marker)
    end

    -- (d) output cap: the SIGKILL goes to the group. A blocking call that missed the
    -- group would sit in `wait()` until the grandchild ended by itself (60 s) and only
    -- then find it dead, so for these the time the call took is what is asserted.
    do
      local flood = "while :; do echo xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx; done"
      local file = tmp_pidfile()
      local r = run_async(sh_script(file, "sleep 60", flood), { max_output_bytes = 2000 })
      eq(r.code, run_argv.OUTPUT_LIMIT_CODE, "async output cap: the output-limit code")
      expect_dead(grandchild_pid(file), "async output cap: the grandchild is killed")
      vim.fn.delete(file)

      file = tmp_pidfile()
      local t0 = vim.uv.hrtime()
      local result = run_argv.run_blocking_result(
        sh_script(file, "sleep 60", flood),
        nil,
        { max_output_bytes = 2000 }
      )
      local took = (vim.uv.hrtime() - t0) / 1e6
      eq(
        result.code,
        run_argv.OUTPUT_LIMIT_CODE,
        "blocking_result output cap: the output-limit code"
      )
      ok(took < 20000, ("blocking_result output cap: returned at once (%d ms)"):format(took))
      expect_dead(grandchild_pid(file), "blocking_result output cap: the grandchild is killed")
      vim.fn.delete(file)

      file = tmp_pidfile()
      t0 = vim.uv.hrtime()
      local c_ok = run_argv.run_blocking_captured(
        sh_script(file, "sleep 60", flood),
        nil,
        { max_output_bytes = 2000 }
      )
      took = (vim.uv.hrtime() - t0) / 1e6
      eq(c_ok, false, "blocking_captured output cap: a failure")
      ok(took < 20000, ("blocking_captured output cap: returned at once (%d ms)"):format(took))
      expect_dead(grandchild_pid(file), "blocking_captured output cap: the grandchild is killed")
      vim.fn.delete(file)
    end

    --- Assert that `pid` is still running (no signal reached it) and kill it. A signal
    --- that did go out needs a moment to take effect, so the process is watched for
    --- 500 ms instead of looked at once.
    ---@param pid integer
    ---@param msg string
    local function expect_left_alone(pid, msg)
      local died = vim.wait(500, function()
        return not is_alive(pid)
      end, 20)
      vim.uv.kill(pid, "sigkill")
      ok(not died, msg .. " (pid " .. pid .. " was killed)")
      vim.wait(2000, function()
        return not is_alive(pid)
      end, 20)
    end

    -- (e) the pid-reuse guard: once the leader has been reaped, its group id may belong
    -- to a stranger, so the group is left alone -- except for the SIGKILL that follows
    -- the deadline's own SIGTERM while the leader was alive (c2). The descendants of
    -- such a leader survive on purpose; the run is still answered, by the async
    -- runner at the deadline plus the grace period (code 124, signal 9).
    do
      -- (e1) the leader exits on its own before the deadline
      local file = tmp_pidfile()
      local r = run_async(sh_script(file, "sleep 60", "exit 0"), { timeout_ms = 500 })
      eq(r.code, 124, "async, leader exited on its own: code 124")
      eq(r.signal, 9, "async, leader exited on its own: signal 9")
      ok(
        (r.stderr or ""):find("did not exit", 1, true) ~= nil,
        "async, leader exited on its own: answered by the grace timer"
      )
      expect_left_alone(
        grandchild_pid(file),
        "async, leader exited on its own: the group of a reaped leader is left alone"
      )
      vim.fn.delete(file)

      -- (e2) the leader exits on a stop() long before the deadline: stop() owes no
      -- follow-up, so the deadline finds a reaped leader and signals nothing
      file = tmp_pidfile()
      local marker = tmp_pidfile()
      r = run_async(stubborn_grandchild(file, marker), { timeout_ms = TIMEOUT }, function(handle)
        grandchild_pid(file)
        handle.stop()
      end)
      eq(r.code, 124, "async, stop() then deadline: code 124")
      ok(vim.fn.filereadable(marker) == 1, "async, stop() then deadline: stop() sent SIGTERM")
      expect_left_alone(
        grandchild_pid(file),
        "async, stop() then deadline: the group of a reaped leader is left alone"
      )
      vim.fn.delete(file)
      vim.fn.delete(marker)
    end

    -- (f) a descendant that leaves the group (`setsid`) is out of reach of the group
    -- kill. It keeps the pipes, so the run is answered by the grace timer (async) or when
    -- `wait()` gives up (blocking), and the escaped process is not signalled.
    if vim.fn.executable("setsid") == 1 then
      local escape = [[setsid sh -c 'echo $$ > "$PIDFILE"; exec sleep 60' & wait]]
      local file = tmp_pidfile()
      local r = run_async({ "sh", "-c", escape }, { timeout_ms = 300, env = { PIDFILE = file } })
      eq(r.code, 124, "async, descendant left the group: code 124")
      eq(r.signal, 9, "async, descendant left the group: signal 9")
      ok(
        (r.stderr or ""):find("did not exit", 1, true) ~= nil,
        "async, descendant left the group: answered by the grace timer"
      )
      expect_left_alone(
        grandchild_pid(file),
        "async, descendant left the group: the escaped process is not reached"
      )
      vim.fn.delete(file)

      file = tmp_pidfile()
      local result = run_argv.run_blocking_result({ "sh", "-c", escape }, nil, {
        timeout_ms = 300,
        env = { PIDFILE = file },
      })
      eq(result.timed_out, true, "blocking_result, descendant left the group: timed out")
      eq(result.code, 124, "blocking_result, descendant left the group: code 124")
      eq(result.signal, 9, "blocking_result, descendant left the group: signal 9")
      ok(
        (result.stderr or ""):find("still holds", 1, true) ~= nil,
        "blocking_result, descendant left the group: wait() gave up"
      )
      expect_left_alone(
        grandchild_pid(file),
        "blocking_result, descendant left the group: the escaped process is not reached"
      )
      vim.fn.delete(file)
    else
      io.stdout:write("run_argv_spec: SKIPPED — the setsid specs need a setsid(1) executable\n")
    end

    -- (g) a job that reports pid 0 or 1 is never signalled as a group: kill(0) is the
    -- process group of the editor itself, kill(-1) every process it may signal. Stand-ins
    -- for vim.system and uv.kill record what would be sent (uv.kill is replaced as well,
    -- so that a broken guard cannot harm anybody).
    do
      local real_system, real_kill = vim.system, vim.uv.kill
      for _, fake_pid in ipairs({ 0, 1 }) do
        ---@type string[]
        local group_signals, direct_signals = {}, {}
        vim.uv.kill = function(pid, signal)
          group_signals[#group_signals + 1] = ("%s:%s"):format(pid, signal)
          return 0
        end
        vim.system = function()
          return {
            pid = fake_pid,
            is_closing = function()
              return false
            end,
            kill = function(_, signal)
              direct_signals[#direct_signals + 1] = signal
            end,
          }
        end
        local stopped, err = pcall(function()
          run_argv.run_async_captured({ "never-started" }, function() end).stop()
        end)
        vim.system, vim.uv.kill = real_system, real_kill
        ok(stopped, ("pid %d guard: stop() does not raise (%s)"):format(fake_pid, tostring(err)))
        eq(
          table.concat(group_signals, ","),
          "",
          ("pid %d guard: no group signal is sent"):format(fake_pid)
        )
        eq(
          table.concat(direct_signals, ","),
          "sigterm",
          ("pid %d guard: the job itself is signalled"):format(fake_pid)
        )
      end
    end

    -- A run that nothing can kill keeps the terminal and its signals: no new
    -- process group for a plain blocking run, one for every run that can be killed.
    -- (needs a `ps` that can print the process group id)
    local function ps_has_pgid()
      if vim.fn.executable("ps") ~= 1 then
        return false
      end
      local probe_res = vim
        .system({ "ps", "-o", "pgid=", "-p", tostring(vim.uv.os_getpid()) }, { text = true })
        :wait()
      return probe_res.code == 0 and tonumber(vim.trim(probe_res.stdout or "")) ~= nil
    end
    if ps_has_pgid() then
      local pgid_argv = { "sh", "-c", "echo $$; ps -o pgid= -p $$" }

      --- The pid and the process group id a `pgid_argv` run printed.
      ---@param text string
      ---@return integer|nil pid
      ---@return integer|nil pgid
      local function pid_and_pgid(text)
        local pid_, pgid_ = text:match("^(%d+)%s+(%d+)")
        return tonumber(pid_), tonumber(pgid_)
      end

      local plain_pid, plain_pgid = pid_and_pgid(run_argv.run_blocking_result(pgid_argv).stdout)
      ok(plain_pid ~= nil, "pgid probe: the shell reported its pid")
      ok(plain_pgid ~= plain_pid, "a plain blocking run shares the process group of the editor")

      local timed = run_argv.run_blocking_result(pgid_argv, nil, { timeout_ms = 20000 })
      local t_pid, t_pgid = pid_and_pgid(timed.stdout)
      ok(t_pid ~= nil and t_pgid == t_pid, "a blocking run with a deadline leads its own group")

      -- a deadline or cap that is not armed (NaN, negative) kills nothing, so it detaches nothing
      for _, bad in ipairs({ -1, 0 / 0 }) do
        local unarmed =
          run_argv.run_blocking_result(pgid_argv, nil, { timeout_ms = bad, max_output_bytes = bad })
        local u_pid, u_pgid = pid_and_pgid(unarmed.stdout)
        ok(
          u_pid ~= nil and u_pgid ~= u_pid,
          ("an unusable limit (%s) detaches nothing"):format(tostring(bad))
        )
      end

      local a = run_async(pgid_argv)
      local a_pid, a_pgid = pid_and_pgid(a.out)
      ok(a_pid ~= nil and a_pgid == a_pid, "an async run leads its own process group")
    end
  else
    io.stdout:write(
      "run_argv_spec: SKIPPED — the process-group specs need a POSIX host with sh "
        .. "(Windows kills the tree with taskkill /T)\n"
    )
  end

  -- Windows: the callback of the `taskkill` that stops a timed out run may run after the job has exited and
  -- been closed (a loop that did not iterate for a while). Windows reuses pids within milliseconds, so a
  -- signal to the closed job would terminate whichever process holds its pid now: the next child died with
  -- exit code 1 right after its spawn (the "run_async_captured: a stalled loop" flake).
  if vim.fn.has("win32") == 1 then
    local real_system = vim.system
    local callbacks, kills = {}, {}
    local closing = false
    vim.system = function(cmd, _, on_exit)
      -- (started by its full path, %SystemRoot%/System32/taskkill.exe)
      if vim.fs.basename(cmd[1]):lower():gsub("%.exe$", "") == "taskkill" then
        callbacks[#callbacks + 1] = on_exit
        return {
          pid = 0,
          is_closing = function()
            return true
          end,
          kill = function() end,
        }
      end
      return {
        pid = 4242,
        is_closing = function()
          return closing
        end,
        kill = function(_, signal)
          kills[#kills + 1] = signal
        end,
      }
    end
    local started, serr = pcall(function()
      run_argv.run_async_captured({ "never-exits" }, function() end, nil, { timeout_ms = 50 })
      vim.wait(2000, function()
        return #callbacks > 0
      end, 10)
    end)
    vim.system = real_system
    ok(started, "taskkill callback: setup does not raise (" .. tostring(serr) .. ")")
    ok(#callbacks > 0, "taskkill callback: the deadline started a taskkill")
    closing = true -- the job exited and was closed before taskkill reported back
    if callbacks[1] then
      callbacks[1]({ code = 0, signal = 0 })
    end
    eq(#kills, 0, "taskkill callback: a closed job (reusable pid) is not signalled")
  end

  vim.fn.delete(probe)
  vim.fn.delete(sleeper)
  vim.fn.delete(work, "rf")
end
