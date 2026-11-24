-- TESTS/fs_fast_spec.lua — lib.nvim.fs.helper (which program, from which mode) and lib.nvim.fs.fast:
-- the options of a listing in every tier this machine has (Lua always, fd/rg when installed, the
-- helper when a program is there), the same files from every tier, a folder's size, a watch that
-- reports the folder of a change, and a helper that ends handing its listing on without a path twice.
--
-- The program: $LIB_FS_HELPER_TEST, else filetree.nvim's helper build next to this repository
-- (../filetree.nvim/helper/target/release/). Without one the helper cases are skipped (the lib CI
-- builds no Rust); filetree.nvim's own CI runs them through its native_helper_spec.

return function(H)
  local eq, ok = H.eq, H.ok
  local uv = vim.uv or vim.loop

  local helper = require("lib.nvim.fs.helper")
  local fast = require("lib.nvim.fs.fast")

  -- ── which program, from which mode ─────────────────────────────────────────
  helper.configure(false)
  local exe, why = helper.find()
  eq(exe, nil, "mode false: no program")
  ok(why and why:find("off", 1, true) ~= nil, "mode false: says it is off")
  eq(helper.request("walk", ".", function() end), nil, "mode false: a request is not taken")

  do
    local lines = {}
    local function say(kind)
      return function(msg)
        lines[#lines + 1] = kind .. " " .. msg
      end
    end
    helper.health(say("ok"), say("info"), say("warn"))
    ok(lines[1] and lines[1]:find("^info file helper: ") ~= nil, "health: default label")
    lines = {}
    helper.health(say("ok"), say("info"), say("warn"), "native")
    ok(lines[1] and lines[1]:find("^info native: ") ~= nil, "health: a caller's own label")
  end

  helper.configure(nil)
  helper.set_mode_provider(function()
    return "/no/such/filetree-helper"
  end)
  local _, why_path = helper.find()
  ok(
    why_path and why_path:find("no program", 1, true) ~= nil,
    "a provider's path that is not there: none"
  )
  helper.set_mode_provider(function()
    return nil
  end)
  vim.g.lib_fs_helper = false
  eq(helper.mode(), false, "a provider without an answer: vim.g.lib_fs_helper decides")
  vim.g.lib_fs_helper = nil
  eq(helper.mode(), "auto", "nothing set: auto")
  helper.set_mode_provider(nil)
  ok(
    helper.default_path():find(helper.install_dir(), 1, true) == 1
      and helper.install_dir():find("filetree%-helper$") ~= nil,
    "auto looks below stdpath('data')/filetree-helper"
  )
  local saved_role = vim.env.NVIM_MACHINE_ROLE
  vim.env.NVIM_MACHINE_ROLE = "Workstation"
  helper.configure(nil)
  local _, why_ws = helper.find()
  ok(why_ws and why_ws:find("workstation", 1, true) ~= nil, "auto on the workstation: never")
  vim.env.NVIM_MACHINE_ROLE = saved_role
  helper.configure(false)

  -- ── a fixture ──────────────────────────────────────────────────────────────
  local tmp =
    fast.norm(tostring(uv.fs_realpath(vim.fn.tempname():match("^(.*)[/\\]")) or vim.fn.tempname()))
  local root = ("%s/lib_fast_%d"):format(tmp, uv.hrtime() % 1e9)
  local function mkfile(rel, text)
    local path = root .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({ text or "x" }, path, "b")
  end
  for _, rel in ipairs({
    "a.txt",
    "b.log",
    "sub/c.txt",
    "sub/deep/d.txt",
    "sub/deep/e.log",
    ".hidden/f.txt",
    ".top",
    "node_modules/pkg/g.js",
    "build/h.o",
    ".git/HEAD",
  }) do
    mkfile(rel)
  end

  local function rel(paths)
    local out = {}
    for _, p in ipairs(paths) do
      out[#out + 1] = fast.norm(p):sub(#root + 2)
    end
    table.sort(out)
    return table.concat(out, ",")
  end

  ---@return string listed, boolean|nil ok
  local function listed(opts)
    local got, done
    fast.list_all(root, opts, function(paths, success)
      got, done = paths, success
    end)
    vim.wait(10000, function()
      return done ~= nil
    end, 5)
    return rel(got or {}), done
  end

  -- ── the Lua walk ───────────────────────────────────────────────────────────
  local all =
    ".hidden/f.txt,.top,a.txt,b.log,build/h.o,node_modules/pkg/g.js,sub/c.txt,sub/deep/d.txt,sub/deep/e.log"
  local got, done = listed({ tier = "lua", ignore = "none" })
  eq(got, all, "lua, ignore none: everything but .git")
  eq(done, true, "lua: says it is done")
  eq(
    (listed({ tier = "lua" })),
    ".hidden/f.txt,.top,a.txt,b.log,sub/c.txt,sub/deep/d.txt,sub/deep/e.log",
    "lua, gitignore: the folders of the ignore list instead"
  )
  eq(
    (listed({ tier = "lua", ignore = "names", names = { "sub" } })),
    ".hidden/f.txt,.top,a.txt,b.log,build/h.o,node_modules/pkg/g.js",
    "lua, names: only the given folders"
  )
  eq(
    (listed({ tier = "lua", ignore = "none", hidden = false })),
    "a.txt,b.log,build/h.o,node_modules/pkg/g.js,sub/c.txt,sub/deep/d.txt,sub/deep/e.log",
    "lua, hidden false: no dot entries"
  )
  eq(
    (listed({ tier = "lua", ignore = "none", exclude = { "*.log", "node_modules" } })),
    ".hidden/f.txt,.top,a.txt,build/h.o,sub/c.txt,sub/deep/d.txt",
    "lua, exclude: globs on the name at any depth"
  )
  eq(
    (listed({ tier = "lua", ignore = "none", max_depth = 2 })),
    ".hidden/f.txt,.top,a.txt,b.log,build/h.o,sub/c.txt",
    "lua, max_depth 2: as fd counts it"
  )
  eq(
    (
      listed({
        tier = "lua",
        skip = function(name)
          return name == "sub"
        end,
      })
    ),
    ".hidden/f.txt,.top,a.txt,b.log,build/h.o,node_modules/pkg/g.js",
    "lua, skip: replaces the names for gitignore"
  )

  -- a link to a folder: not followed, unless asked; a loop is entered once
  local outside = root .. "_outside"
  vim.fn.mkdir(outside, "p")
  vim.fn.writefile({ "t" }, outside .. "/t.txt", "b")
  local linked = pcall(uv.fs_symlink, outside, root .. "/link", { dir = true, junction = true })
    and uv.fs_lstat(root .. "/link") ~= nil
  if linked then
    pcall(uv.fs_symlink, root, outside .. "/back", { dir = true, junction = true })
    local plain = listed({ tier = "lua", ignore = "none" })
    eq(plain, all, "lua: a link to a folder is not followed")
    local followed = listed({ tier = "lua", ignore = "none", follow = true })
    ok(followed:find("link/t.txt", 1, true) ~= nil, "lua, follow: walks into the linked folder")
    ok(
      select(2, followed:gsub("a%.txt", "")) == 1,
      "lua, follow: a loop back to the root is entered once"
    )
    os.remove(outside .. "/back")
    vim.fn.delete(outside .. "/back", "d")
    os.remove(root .. "/link")
    vim.fn.delete(root .. "/link", "d")
  else
    H.skipped("links", "no symlink or junction allowed here")
  end

  -- ── the tools give what the walk gives ─────────────────────────────────────
  for _, tier in ipairs({ "fd", "rg" }) do
    local tool = tier == "fd"
        and (vim.fn.executable("fd") == 1 and "fd" or vim.fn.executable("fdfind") == 1 and "fdfind")
      or (vim.fn.executable("rg") == 1 and "rg")
    if tool then
      for _, case in ipairs({
        { ignore = "none" },
        { ignore = "none", hidden = false },
        { ignore = "none", exclude = { "*.log", "node_modules" } },
        { ignore = "none", max_depth = 2 },
        { ignore = "names", names = { "sub", "build" } },
      }) do
        local by_lua = listed(vim.tbl_extend("force", case, { tier = "lua" }))
        local by_tool, tool_done = listed(vim.tbl_extend("force", case, { tier = tier }))
        eq(
          by_tool,
          by_lua,
          ("%s lists what the walk lists: %s"):format(
            tier,
            vim.inspect(case, { newline = " ", indent = "" })
          )
        )
        eq(tool_done, true, tier .. " says it is done")
      end
    else
      H.skipped(tier, "not installed")
    end
  end
  local cmd = fast.command(
    "fd",
    "fd",
    root,
    { hidden = false, ignore = "names", names = { "x" }, max_depth = 3 }
  )
  local line = table.concat(cmd, " ")
  ok(
    not line:find("--hidden", 1, true)
      and line:find("--no-ignore", 1, true)
      and line:find("--exclude x", 1, true)
      and line:find("--max-depth 3", 1, true),
    "fd command: the options become fd's switches"
  )

  -- a cancelled listing calls nothing more
  do
    local calls = 0
    local cancel = fast.list(root, { tier = "lua", ignore = "none" }, function()
      calls = calls + 1
    end, function()
      calls = calls + 1
    end)
    cancel()
    vim.wait(200, function()
      return false
    end)
    eq(calls, 0, "a cancelled listing calls nothing")
  end

  -- ── size ───────────────────────────────────────────────────────────────────
  do
    local bytes, files, tier
    fast.size(root, function(b, f, t)
      bytes, files, tier = b, f, t
    end, { tier = "lua" })
    vim.wait(5000, function()
      return tier ~= nil
    end, 5)
    eq(files, 10, "size: every file, .git and ignored ones too")
    eq(tier, "lua", "size: the Lua walk without a helper")
    ok(type(bytes) == "number" and bytes >= 10, "size: the bytes add up")
    local none
    fast.size(root .. "/nothing_here", function(b)
      none = b == nil and "nil" or b
    end, { tier = "lua" })
    vim.wait(2000, function()
      return none ~= nil
    end, 5)
    eq(none, "nil", "size of a folder that is not there: nil")
  end

  -- ── watch (libuv) ──────────────────────────────────────────────────────────
  do
    local seen = {}
    local w = fast.watch(root, { tier = "libuv", debounce_ms = 50 }, function(dirs)
      for _, d in ipairs(dirs) do
        seen[d] = true
      end
    end)
    eq(w.tier(), "libuv", "watch: libuv without a helper")
    ok(w.handles() >= 1, "watch: holds a handle")
    -- a backend may need a moment before it delivers (FSEvents): write until it is seen
    local target = root .. "/sub/deep"
    local n = 0
    vim.wait(8000, function()
      n = n + 1
      if n % 20 == 1 then
        vim.fn.writefile({ tostring(n) }, target .. "/new.txt", "b")
      end
      return seen[target] == true
    end, 25)
    ok(seen[target], "watch: the folder of a change deep down is reported")
    if uv.os_uname().sysname == "Linux" then
      ok(w.handles() >= 3, "watch on Linux: one handle per folder")
    end
    w.stop()
    w.stop()
    os.remove(target .. "/new.txt")
  end

  -- ── the helper, when a program is there ────────────────────────────────────
  local program = vim.env.LIB_FS_HELPER_TEST
  if not program or program == "" then
    program = vim.fn.fnamemodify(vim.fn.getcwd(), ":h")
      .. "/filetree.nvim/helper/target/release/"
      .. helper.binary_name()
  end
  if not uv.fs_stat(program) then
    H.skipped("the helper tier", "no program (" .. program .. ")")
  else
    helper.configure(program)
    eq((fast.tier()), "helper", "with a program: the helper lists")
    for _, case in ipairs({
      { ignore = "none" },
      { ignore = "none", hidden = false },
      { ignore = "none", exclude = { "*.log", "node_modules" } },
      { ignore = "none", max_depth = 2 },
      { ignore = "names", names = { "sub", "build" } },
    }) do
      local by_lua = listed(vim.tbl_extend("force", case, { tier = "lua" }))
      local by_helper, helper_done = listed(vim.tbl_extend("force", case, { tier = "helper" }))
      eq(
        by_helper,
        by_lua,
        "the helper lists what the walk lists: "
          .. vim.inspect(case, { newline = " ", indent = "" })
      )
      eq(helper_done, true, "... and is done (the answers came back through lib.nvim.fs.helper)")
    end
    local _, bad = listed({ tier = "helper", exclude = { "a[" } })
    eq(bad, false, "a glob the helper cannot parse: done false")

    local bytes, tier
    fast.size(root, function(b, _, t)
      bytes, tier = b, t
    end)
    vim.wait(5000, function()
      return tier ~= nil
    end, 5)
    eq(tier, "helper", "size through the helper")
    local lua_bytes
    fast.size(root, function(b)
      lua_bytes = b
    end, { tier = "lua" })
    vim.wait(5000, function()
      return lua_bytes ~= nil
    end, 5)
    eq(bytes, lua_bytes, "... the same bytes as the walk")

    -- a helper that ends during a listing: the next tier finishes it, nothing twice
    for i = 1, 30 do
      for j = 1, 100 do
        mkfile(("many/d%02d/f%03d.txt"):format(i, j))
      end
    end
    local paths, finished = {}, nil
    fast.list(root, { ignore = "none" }, function(batch)
      vim.list_extend(paths, batch)
      helper.stop()
    end, function(success)
      finished = success
    end)
    vim.wait(15000, function()
      return finished ~= nil
    end, 5)
    local count, unique = #paths, {}
    for _, p in ipairs(paths) do
      unique[p] = true
    end
    eq(vim.tbl_count(unique), count, "a helper that ends: no path twice")
    eq(count, 3009, "... and every file is there")
    helper.configure(false)
  end

  vim.fn.delete(root, "rf")
  vim.fn.delete(outside, "rf")
end
