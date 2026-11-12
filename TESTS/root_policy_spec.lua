-- TESTS/root_policy_spec.lua — lib.nvim.fs.root_policy

return function(H)
  local eq, ok = H.eq, H.ok
  local root_policy = require("lib.nvim.fs.root_policy")
  local normkey = require("lib.nvim.fs.normkey")

  local base = normkey(vim.fn.tempname())
  local a, b, loose = base .. "/a", base .. "/b", base .. "/loose"
  for _, d in ipairs({ a .. "/src", b .. "/src", loose }) do
    vim.fn.mkdir(d, "p")
  end
  local fa, fb, fl = a .. "/src/x.lua", b .. "/src/y.lua", loose .. "/z.txt"
  for _, f in ipairs({ fa, fb, fl }) do
    vim.fn.writefile({ "x" }, f)
  end

  local original_cwd = vim.fn.getcwd()
  local function finder(file)
    if file:find("/a/", 1, true) then
      return a
    elseif file:find("/b/", 1, true) then
      return b
    end
    return nil -- loose files have no root
  end

  local changes = {}
  local function new(extra)
    changes = {}
    return root_policy.new(vim.tbl_extend("force", {
      find_root = finder,
      chdir = false, -- answer and track only; cwd tests below turn it on
      on_change = function(s)
        changes[#changes + 1] = s.mode .. ":" .. tostring(s.pinned)
      end,
    }, extra or {}))
  end

  -- follow: no policy
  local p = new()
  eq(p.mode(), "follow", "starts in follow")
  eq(p.decide(fa), nil, "follow: decide is nil")
  eq(p.decide(""), nil, "an empty path is nil")

  -- project: pins on the first file, holds while inside, re-pins outside
  ok(p.set_mode("project", nil))
  eq(p.mode(), "project", "project mode")
  local d = p.decide(fa)
  eq(d and d.root, a, "project: the finder's root")
  ok(d and d.chdir and d.reveal, "project: chdir and reveal")
  eq(p.pinned(), a, "project: pinned")
  d = p.decide(a .. "/src/other.lua")
  eq(d and d.root, a, "project: still inside, same root")
  d = p.decide(fb)
  eq(d and d.root, b, "project: a file in another project re-pins")
  eq(p.pinned(), b, "project: pinned moved")

  -- sticky: a file without a root keeps the pin; non-sticky pins its folder
  d = p.decide(fl)
  eq(d and d.root, b, "sticky: root kept for a loose file")
  eq(d and d.reveal, false, "sticky: no reveal outside by default")
  local ns = new({ sticky = false })
  ns.set_mode("project")
  ns.decide(fb)
  d = ns.decide(fl)
  eq(d and d.root, loose, "non-sticky: the loose file's folder becomes the root")

  -- reveal_outside
  local ro = new({ reveal_outside = "reveal" })
  ro.set_mode("project")
  ro.decide(fb)
  eq(ro.decide(fl).reveal, true, "reveal_outside = reveal")

  -- diff-based change callback: fires per real change, not per decide
  local q = new()
  q.set_mode("project")
  local n0 = #changes
  q.decide(fa)
  q.decide(fa)
  q.decide(a .. "/src/again.lua")
  eq(#changes - n0, 1, "on_change: one call for one re-pin, none for the repeats")
  q.decide(fb)
  eq(#changes - n0, 2, "on_change: a second call for the next re-pin")
  q.set_mode("project")
  eq(#changes - n0, 3, "on_change: the re-seed to the same dir adds none beyond the new pin")

  -- nearest asks for its own kind
  local kinds = {}
  local nr = new({
    find_root = function(f, kind)
      kinds[#kinds + 1] = kind
      return finder(f)
    end,
  })
  nr.set_mode("nearest")
  nr.decide(fb)
  eq(kinds[#kinds], "nearest", "nearest: the finder is asked for the nearest kind")

  -- lock: pinned, files outside do not move it; unlock returns to the previous mode
  local l = new()
  l.set_mode("project")
  ok(l.set_mode("lock", a))
  eq(l.mode(), "lock", "lock mode")
  eq(l.pinned(), a, "lock: pinned to the given dir")
  d = l.decide(fb)
  eq(d and d.root, a, "lock: a file outside keeps the root")
  eq(d and d.reveal, false, "lock: ... and is not revealed by default")
  eq(l.decide(fa).reveal, true, "lock: a file inside is revealed")
  ok(l.unlock())
  eq(l.mode(), "project", "unlock: back to the previous mode")
  local nok, nerr = l.unlock()
  eq(nok, false, "unlock when not locked")
  eq(nerr, "not locked", "unlock: the reason")
  l.release()

  -- manual and tree_leads
  local m = new()
  m.set_mode("project")
  m.decide(fa)
  m.set_mode("manual")
  d = m.decide(fb)
  ok(d and not d.chdir and not d.reveal, "manual: nothing automatic")
  eq(d.root, a, "manual: keeps the pin")
  local t = new({
    seed = function()
      return a
    end,
  })
  t.set_mode("tree_leads")
  eq(t.pinned(), a, "tree_leads: seeded from the caller")
  d = t.decide(fa)
  ok(d and d.reveal and not d.chdir, "tree_leads: reveal inside, never chdir")
  eq(t.decide(fb).reveal, false, "tree_leads: no reveal outside")
  ok(t.repin(b))
  eq(t.pinned(), b, "repin moves the pin")

  -- cycle
  local c = new()
  c.cycle({ "follow", "project", "lock" })
  eq(c.mode(), "project", "cycle: follow -> project")
  c.set_mode("follow")
  c.set_mode("manual")
  c.cycle({ "follow", "project" })
  eq(c.mode(), "follow", "cycle: a mode not in the list starts at the first")

  -- bad input
  local bad_ok, bad_err = c.set_mode("nonsense")
  eq(bad_ok, false, "set_mode: unknown mode refused")
  ok(tostring(bad_err):find("unknown"), "set_mode: the reason")
  eq((pcall(root_policy.new, { mode = "nonsense" })), false, "new: unknown start mode asserts")

  -- real chdir + enforcement
  local real = root_policy.new({ find_root = finder })
  ok(real.set_mode("project", nil))
  real.decide(fa)
  real.set_mode("project") -- seeds from the buffer/cwd, then moves the cwd
  ok(real.set_mode("lock", b))
  eq(normkey(vim.fn.getcwd()), b, "lock: the cwd moved to the pin")
  vim.cmd.cd(vim.fn.fnameescape(a))
  vim.wait(200, function()
    return normkey(vim.fn.getcwd()) == b
  end, 10)
  eq(normkey(vim.fn.getcwd()), b, "lock: a foreign :cd is undone")
  ok(real.enforced(), "enforced: a lock's guard is up")
  eq(real.scope(), "global", "scope: global by default")

  -- the scope can change under a held lock: the pin is re-applied there, the guard is held again
  ok(real.set_scope("tab"), "set_scope: a lock moves to the tab scope")
  eq(real.scope(), "tab", "set_scope: the scope is now tab")
  eq(real.pinned(), b, "set_scope: the pin is unchanged")
  ok(real.enforced(), "set_scope: the guard is held again")
  eq(normkey(vim.fn.getcwd(-1, 0)), b, "set_scope: the tab's cwd is the pin")
  local sok, serr = real.set_scope("nonsense")
  eq(sok, false, "set_scope: an unknown scope is refused")
  ok(tostring(serr):find("unknown scope"), "set_scope: the reason")
  eq(real.scope(), "tab", "set_scope: ...and the scope stays")
  ok(real.set_scope("tab"), "set_scope: the same scope is a no-op")
  real.release()
  ok(not real.enforced(), "enforced: no guard after release")
  vim.cmd.cd(vim.fn.fnameescape(original_cwd))
  vim.cmd.tcd(vim.fn.fnameescape(original_cwd))

  vim.fn.delete(base, "rf")
end
