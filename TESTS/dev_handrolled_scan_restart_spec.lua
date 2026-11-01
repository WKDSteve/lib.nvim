-- TESTS/dev_handrolled_scan_restart_spec.lua — handrolled_scan: indented
-- debounce timers (restart-before-create inside a factory closure, the shape of
-- lib.nvim's own ui/kit clones), timeouts that must stay quiet, and the
-- `include_self` option.

return function(H)
  local eq = H.eq
  local scan = require("lib.nvim.dev.handrolled_scan")

  local root = vim.fn.tempname()
  local function write(rel, lines)
    local path = root .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(lines, path)
  end

  -- ui/kit/live_input.lua shape: indented `local timer`, stop helper, restart.
  local debounce = {
    "local M = {}",
    "function M.open(opts)",
    "  local timer",
    "  local function stop_timer()",
    "    if timer then",
    "      timer:stop()",
    "      timer:close()",
    "      timer = nil",
    "    end",
    "  end",
    "  local function schedule_change()",
    "    stop_timer()",
    "    timer = vim.uv.new_timer()",
    "    timer:start(80, 0, function() stop_timer() end)",
    "  end",
    "  return schedule_change",
    "end",
    "return M",
  }
  write("kit.nvim/lua/kit/live.lua", debounce)
  -- Inline variant: the previous timer is stopped by name, not by a helper.
  write("kit.nvim/lua/kit/inline.lua", {
    "local function build()",
    "  local timer",
    "  local function arm(delay)",
    "    if timer then timer:stop() timer:close() end",
    "    timer = vim.uv.new_timer()",
    "    timer:start(delay, 0, function() end)",
    "  end",
    "  return arm",
    "end",
  })
  -- language.nvim util/job shape: an indented timeout, stopped only on finish.
  write("kit.nvim/lua/kit/timeout.lua", {
    "local function run(opts)",
    "  local timer",
    "  local function finish()",
    "    if timer then",
    "      timer:stop()",
    "      timer:close()",
    "      timer = nil",
    "    end",
    "  end",
    "  if opts.timeout_ms then",
    "    timer = vim.uv.new_timer()",
    "    timer:start(opts.timeout_ms, 0, function() finish() end)",
    "  end",
    "  return finish",
    "end",
  })

  -- An unrelated stop helper before a timeout is not a restart.
  write("kit.nvim/lua/kit/spinner.lua", {
    "local function run(opts)",
    "  local timer",
    "  local function stop_spinner() end",
    "  local function arm()",
    "    stop_spinner()",
    "    timer = vim.uv.new_timer()",
    "    timer:start(opts.timeout_ms, 0, function() timer:close() end)",
    "  end",
    "  return arm",
    "end",
  })

  -- lib.nvim-like tree: patterns/ emits, ui/kit debounces, hooks/ is reference.
  write("lib.nvim/lua/lib/lua/patterns/bus/init.lua", {
    "local listeners = {}",
    "local M = {}",
    "function M.emit(e) for _, l in ipairs(listeners) do l(e) end end",
    "return M",
  })
  write("lib.nvim/lua/lib/nvim/hooks/init.lua", {
    "local listeners = {}",
    "local M = {}",
    "function M.emit(e) for _, l in ipairs(listeners) do l(e) end end",
    "return M",
  })
  write("lib.nvim/lua/lib/nvim/ui/kit/y.lua", debounce)

  local function keyed(findings)
    local by = {}
    for _, f in ipairs(findings) do
      by[f.repo .. ":" .. f.file] = f.kind
    end
    return by
  end

  local by = keyed(scan.scan(root))
  eq(by["kit.nvim:lua/kit/live.lua"], "debounce", "indented timer with a stop helper is a debounce")
  eq(by["kit.nvim:lua/kit/inline.lua"], "debounce", "indented timer stopped inline is a debounce")
  eq(by["kit.nvim:lua/kit/timeout.lua"], nil, "an indented timeout stopped only in finish is quiet")
  eq(by["kit.nvim:lua/kit/spinner.lua"], nil, "an unrelated stop helper is not a restart")
  for key in pairs(by) do
    eq(key:find("^lib.nvim:") == nil, true, "lib.nvim is skipped without include_self")
  end

  local self_by = keyed(scan.scan(root, { include_self = true }))
  eq(self_by["lib.nvim:lua/lib/nvim/ui/kit/y.lua"], "debounce", "include_self scans ui/kit")
  eq(self_by["lib.nvim:lua/lib/lua/patterns/bus/init.lua"], nil, "patterns/ stays out")
  eq(self_by["lib.nvim:lua/lib/nvim/hooks/init.lua"], nil, "hooks/ stays out")
  eq(self_by["kit.nvim:lua/kit/live.lua"], "debounce", "other repos are still scanned")

  vim.fn.delete(root, "rf")
end
