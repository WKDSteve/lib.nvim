-- TESTS/dev_handrolled_scan_spec.lua — lib.nvim.dev.handrolled_scan: hand-rolled
-- debounce / throttle / emitter detection across sibling repos. Positives are the
-- shapes of the real pre-refactor code (mdview live_push, markdown refs, gitsuite
-- lazy); negatives are the shapes that must stay quiet.

return function(H)
  local eq, ok = H.eq, H.ok
  local scan = require("lib.nvim.dev.handrolled_scan")

  local root = vim.fn.tempname()
  local function write(rel, lines)
    local path = root .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(lines, path)
  end

  -- mdview live_push: module-level handle, throttle clock, trailing timer.
  write("alpha.nvim/lua/alpha/push.lua", {
    "local last_sent_at = 0",
    "local pending_timer = nil",
    "local function push(t)",
    "  if t - last_sent_at >= 150 then last_sent_at = t return end",
    "  if pending_timer then pending_timer:stop() end",
    "  pending_timer = (vim.uv or vim.loop).new_timer()",
    "  pending_timer:start(150, 0, function() end)",
    "end",
    "local function elapsed(now) return now - last_sent_at end",
    "local t0 = vim.uv.hrtime()",
    "return { push = push }",
  })
  -- markdown refs: the handle is a field of a per-buffer state table.
  write("beta.nvim/lua/beta/refs.lua", {
    "local function schedule(st, delay)",
    "  if st.timer then st.timer:stop() end",
    "  local timer = vim.uv.new_timer()",
    "  st.timer = timer",
    "  timer:start(delay, 0, function() end)",
    "end",
    "return schedule",
  })
  -- An emitter: listeners table plus emit().
  write("gamma.nvim/lua/gamma/bus.lua", {
    "local listeners = {}",
    "local M = {}",
    "function M.emit(event) for _, l in ipairs(listeners) do l(event) end end",
    "return M",
  })
  -- Negatives: a one-shot timer, a periodic heartbeat, a listeners table without emit.
  write("delta.nvim/lua/delta/quiet.lua", {
    "local function once()",
    "  local t = vim.uv.new_timer()",
    "  t:start(10, 0, function() t:stop() t:close() end)",
    "end",
  })
  write("delta.nvim/lua/delta/beat.lua", {
    "local heartbeat",
    "local function beat()",
    "  heartbeat = vim.uv.new_timer()",
    "  heartbeat:start(2000, 2000, function() end)",
    "  heartbeat:stop()",
    "end",
    "local listeners = {}",
    "return { once = once, beat = beat, listeners = listeners }",
  })
  -- Excused by an inline marker, and by the exceptions map.
  write("epsilon.nvim/lua/epsilon/marked.lua", {
    "-- handrolled-ok: needs a trailing-only restart that debounce does not offer",
    "local pending",
    "local function f() pending:stop() pending = vim.uv.new_timer() pending:start(1, 0, function() end) end",
  })
  write("zeta.nvim/lua/zeta/listed.lua", {
    "local pending",
    "local function f() pending:stop() pending = vim.uv.new_timer() pending:start(1, 0, function() end) end",
  })
  -- Not scanned: tests, lib.nvim itself, non-plugin directories.
  write("alpha.nvim/TESTS/x_spec.lua", {
    "local p",
    "local function f() p:stop() p = vim.uv.new_timer() p:start(1, 0, function() end) end",
  })
  write("lib.nvim/lua/lib/nvim/debounce.lua", {
    "local p",
    "local function f() p:stop() p = vim.uv.new_timer() p:start(1, 0, function() end) end",
  })
  write("notaplugin/readme.txt", { "p:stop()" })

  local findings =
    scan.scan(root, { exceptions = { ["zeta.nvim/lua/zeta/listed.lua"] = "listed" } })

  local by = {}
  for _, f in ipairs(findings) do
    by[f.repo .. ":" .. f.kind] = f
  end

  ok(by["alpha.nvim:debounce"], "module-level handle restarted one-shot is a debounce")
  eq(by["alpha.nvim:debounce"].name, "pending_timer", "keyed on the stopped handle")
  eq(by["alpha.nvim:debounce"].line, 6, "anchored at the new_timer line")
  eq(by["alpha.nvim:debounce"].hint, "lib.nvim.debounce", "points at the shared module")
  ok(by["alpha.nvim:throttle"], "a clock reading minus last_* is a throttle")
  eq(by["alpha.nvim:throttle"].hint, "lib.nvim.patterns.throttle", "throttle hint")
  ok(by["beta.nvim:debounce"], "a field handle (st.timer) counts as long-lived")
  eq(by["beta.nvim:debounce"].name, "st.timer", "field handle name")
  ok(by["gamma.nvim:emitter"], "listeners table plus emit() is an emitter")
  eq(by["gamma.nvim:emitter"].line, 1, "anchored at the listeners table")

  eq(by["delta.nvim:debounce"], nil, "one-shot local timers and periodic heartbeats are quiet")
  eq(by["delta.nvim:emitter"], nil, "a listeners table without an emit function is quiet")
  eq(by["epsilon.nvim:debounce"], nil, "the handrolled-ok marker silences a file")
  eq(by["zeta.nvim:debounce"], nil, "an exceptions entry silences a file")

  local repos = {}
  for _, f in ipairs(findings) do
    repos[f.repo] = true
  end
  eq(repos["lib.nvim"], nil, "lib.nvim itself is never a finding")
  eq(repos["notaplugin"], nil, "directories without lua/ are skipped")
  for _, f in ipairs(findings) do
    ok(not f.file:find("TESTS", 1, true), "TESTS/ is not scanned")
  end

  -- Whole-repo exception by repo name.
  local silenced = scan.scan(root, { exceptions = { ["alpha.nvim"] = "whole repo" } })
  for _, f in ipairs(silenced) do
    ok(f.repo ~= "alpha.nvim", "a repo-level exception skips the repo")
  end

  -- Report is warnings only.
  local lines = scan.lines(root)
  vim.fn.delete(root, "rf")
  local text = table.concat(lines, "\n")
  ok(text:find("WARN", 1, true) ~= nil, "findings are printed as WARN")
  ok(text:find("ERROR", 1, true) == nil, "nothing is an error")
  ok(text:find("| alpha.nvim |", 1, true) ~= nil, "summary table lists the repo")
  eq(#scan.lines(vim.fn.tempname()) >= 3, true, "an empty root still renders a table")
end
