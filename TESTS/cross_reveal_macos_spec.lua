-- TESTS/cross_reveal_macos_spec.lua -- cross.reveal_in_fm on a real macOS: `open -R` had never run.
-- Holds down what a run can: that the branch builds this command, its exit code and its error text.
-- Whether Finder visibly selects the file stays a check by hand. A runner where `open` cannot work is a
-- reported skip with its reason, never a green case.

return function(H)
  local eq = H.eq

  if vim.fn.has("mac") ~= 1 then
    H.skipped("reveal_in_fm open -R", "only runs on macOS")
    return
  end

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/reveal me.txt"
  vim.fn.writefile({ "x" }, path)

  local run = require("lib.nvim.cross.run")
  local real_detached = run.run_detached
  local argv
  run.run_detached = function(cmd)
    argv = cmd
    return true
  end
  local ran, err = pcall(require("lib.nvim.cross.reveal_in_fm"), path)
  run.run_detached = real_detached
  if not ran then
    vim.fn.delete(dir, "rf")
    error(err, 0)
  end

  eq(argv and argv[1], "open", "macOS: the opener is open")
  eq(argv and argv[2], "-R", "with -R, which selects the file")

  local res = vim.system(argv, { text = true }):wait(20000)
  vim.fn.delete(dir, "rf")
  local stderr = vim.trim(res.stderr or "")
  print(("reveal_in_fm open -R: exit %d, stderr: %q"):format(res.code, stderr))
  if res.code ~= 0 then
    H.skipped("reveal_in_fm open -R", ("exit %d on this runner: %s"):format(res.code, stderr))
  end
end
