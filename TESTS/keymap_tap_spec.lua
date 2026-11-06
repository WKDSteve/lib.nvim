-- TESTS/keymap_tap_spec.lua — lib.nvim.bindings.keymap.tap / .lhs, and conflicts({ scope = "full" })
---@diagnostic disable: need-check-nil

return function(H)
  local eq, ok = H.eq, H.ok

  local tap = require("lib.nvim.bindings.keymap.tap")
  local lhs = require("lib.nvim.bindings.keymap.lhs")
  local keymap = require("lib.nvim.bindings.keymap")
  local registry = require("lib.nvim.bindings.keymap.registry")

  local api = vim.api
  -- What the API looked like before this spec touched anything: the last line of
  -- defence, because the runner shares one Neovim between all specs.
  local pristine = {
    nvim_set_keymap = api.nvim_set_keymap,
    nvim_buf_set_keymap = api.nvim_buf_set_keymap,
    nvim_del_keymap = api.nvim_del_keymap,
    nvim_buf_del_keymap = api.nvim_buf_del_keymap,
  }
  ok(not tap.is_installed(), "the tap is not installed when the spec starts")

  ---Run `fn` with the tap installed and an empty recording; always put the API
  ---back and drop the recording, whatever `fn` does.
  ---@param fn fun()
  local function with_tap(fn)
    tap.clear()
    tap.install()
    local passed, err = pcall(fn)
    tap.uninstall()
    tap.clear()
    for name, f in pairs(pristine) do
      api[name] = f
    end
    if not passed then
      error(err, 0)
    end
  end

  ---@param mode string|string[]
  ---@param key string
  ---@param buf? integer
  local function unbind(mode, key, buf)
    pcall(vim.keymap.del, mode, key, { buffer = buf })
  end

  local function noop() end

  ---Drop the direct records this spec made, not those of every plugin in the shared editor. The
  ---plain `keymap(mode, lhs, rhs, opts, "lib one")` calls here have no plugin: their records are
  ---filed under "(unknown)" ("lib one" is only the description).
  local function forget_ours()
    keymap.forget("(unknown)")
  end

  -- ------------------------------------------------------------- lhs.lua

  eq(lhs.normalize("<M-h>"), lhs.normalize("<A-h>"), "<M-h> and <A-h> are one key")
  eq(lhs.normalize("<C-K>"), lhs.normalize("<C-k>"), "<C-K> and <C-k> are one key")
  ok(lhs.normalize("<M-h>") ~= lhs.normalize("<M-j>"), "different keys stay different")
  eq(lhs.normalize(42), "42", "a non-string lhs does not raise")
  eq(table.concat(lhs.modes(""), ""), "nxso", [[mode "" stands for n, x, s, o]])
  eq(table.concat(lhs.modes("v"), ""), "xs", [[mode "v" stands for x, s]])
  eq(table.concat(lhs.modes("!"), ""), "ic", [[mode "!" stands for i, c]])
  eq(table.concat(lhs.modes({ "n", "v" }), ""), "nxs", "a list is expanded without duplicates")
  eq(lhs.scope(nil), "*", "global scope")
  eq(lhs.scope(7), "7", "buffer scope")

  -- --------------------------------------------- one call, one event (guard)
  --
  -- `vim.keymap.set` ends in `nvim_set_keymap`; a tap that wrapped both levels
  -- counted every binding twice (505 of 520 keys were false alarms).

  with_tap(function()
    vim.keymap.set("n", "<M-F9>", noop, { desc = "one" })
    local log = tap.log()
    eq(#log, 1, "one vim.keymap.set is exactly one event")
    eq(log[1].op, "set", "it is a set")
    eq(log[1].mode, "n", "with its mode")
    eq(log[1].rhs_kind, "function", "a callback is recorded as a function")
    eq(log[1].desc, "one", "and its description")
    ok(
      log[1].source:find("keymap_tap_spec.lua:%d+$") ~= nil,
      "the source is this spec, not vim/keymap.lua: " .. tostring(log[1].source)
    )
    eq(log[1].via, "raw", "a plain vim.keymap.set is raw")
    unbind("n", "<M-F9>")

    tap.clear()
    vim.keymap.set({ "n", "x" }, "<M-F9>", noop)
    eq(#tap.log(), 2, "a list of two modes is two events")
    vim.keymap.del({ "n", "x" }, "<M-F9>")
    eq(#tap.log(), 4, "and the delete of two modes is two more")

    tap.clear()
    vim.keymap.set("", "<M-F9>", ":echo<CR>")
    eq(#tap.log(), 4, [[mode "" is n, x, s, o]])
    vim.keymap.del("", "<M-F9>")
  end)

  -- Neovim stamps a Lua mapping with the script that set it. The tap's wrapper
  -- must not become that script.
  with_tap(function()
    vim.keymap.set("n", "<M-F3>", noop, { desc = "provenance" })
    api.nvim_set_keymap("n", "<M-F2>", ":echo<CR>", { desc = "provenance, api" })
    for _, key in ipairs({ "<M-F3>", "<M-F2>" }) do
      local found
      for _, e in ipairs(require("lib.nvim.bindings.keymap.runtime").snapshot()) do
        if e.key == key then
          found = e
        end
      end
      ok(found ~= nil, key .. " is live")
      ok(
        found.source ~= nil and found.source:find("keymap_tap_spec.lua", 1, true) ~= nil,
        key .. " is attributed to the spec, not to the tap: " .. tostring(found.source)
      )
    end
    unbind("n", "<M-F3>")
    unbind("n", "<M-F2>")
  end)

  -- Neovim's own keymap code is a file where the runtime sits on disk and a
  -- bare `vim/keymap` chunk where it is compiled into the binary. Either way it
  -- is not the caller.
  with_tap(function()
    for _, chunkname in ipairs({ "@vim/keymap.lua", "vim/keymap", "=vim/keymap" }) do
      local inner = assert(
        load(
          "return function() vim.api.nvim_set_keymap('n', '<M-F4>', ':echo<CR>', {}) end",
          chunkname
        )
      )()
      tap.clear()
      inner()
      local ev = tap.log()[1]
      ok(
        ev ~= nil and ev.source:find("keymap_tap_spec.lua:%d+$") ~= nil,
        chunkname .. " is skipped as Neovim's own: " .. tostring(ev and ev.source)
      )
      unbind("n", "<M-F4>")
    end
  end)

  -- ----------------------------------------------------------- collisions
  --
  -- Positive case first: each check below is proven to fire on a known
  -- collision before its negative twin is believed.

  with_tap(function()
    vim.keymap.set("n", "<M-h>", noop, { desc = "first" })
    vim.keymap.set("n", "<M-h>", function() end, { desc = "second" })
    local c = tap.collisions()
    eq(#c, 1, "two raw vim.keymap.set on one key and mode are one collision")
    eq(c[1].mode, "n", "in mode n")
    eq(c[1].lhs, "<M-h>", "on <M-h>")
    eq(#c[1].claimants, 2, "with two claimants")
    eq(c[1].claimants[1].desc, "first", "the earlier binding first")
    eq(c[1].claimants[2].desc, "second", "the winner last")
    eq(c[1].claimants[1].via, "raw", "each says how it was set")
    ok(c[1].claimants[1].source ~= c[1].claimants[2].source, "and from where")
    eq(c[1].benign, nil, "a real collision is not benign")
    unbind("n", "<M-h>")
  end)

  with_tap(function()
    vim.keymap.set("n", "<M-h>", noop, { desc = "via keymap.set" })
    api.nvim_set_keymap("n", "<M-h>", ":echo 1<CR>", { desc = "via the api" })
    eq(#tap.collisions(), 1, "vim.keymap.set and nvim_set_keymap on one key are one collision")
    unbind("n", "<M-h>")
  end)

  with_tap(function()
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_keymap(buf, "n", "<M-h>", ":echo 1<CR>", {})
    api.nvim_buf_set_keymap(buf, "n", "<M-h>", ":echo 2<CR>", {})
    eq(#tap.collisions(), 1, "nvim_buf_set_keymap twice in one buffer collides")
    api.nvim_buf_delete(buf, { force = true })
  end)

  with_tap(function()
    vim.keymap.set("n", "<M-h>", noop, { desc = "alt" })
    vim.keymap.set("n", "<A-h>", noop, { desc = "alt, spelled differently" })
    local c = tap.collisions()
    eq(#c, 1, "<M-h> and <A-h> are the same key")
    eq(c[1].lhs, "<M-h>", "reported under the canonical spelling")
    eq(c[1].claimants[2].lhs, "<A-h>", "while each claimant keeps its own")
    unbind("n", "<M-h>")
  end)

  with_tap(function()
    vim.keymap.set("n", "<C-K>", noop)
    vim.keymap.set("n", "<C-k>", noop, { desc = "x" })
    eq(#tap.collisions(), 1, "<C-K> and <C-k> are the same key")
    unbind("n", "<C-k>")
  end)

  with_tap(function()
    vim.keymap.set("n", "<M-h>", noop)
    vim.keymap.set("x", "<M-h>", noop)
    vim.keymap.set("i", "<M-h>", noop)
    eq(#tap.collisions(), 0, "the same key in another mode is not a collision")
    unbind({ "n", "x", "i" }, "<M-h>")
  end)

  with_tap(function()
    vim.keymap.set("n", "<M-h>", noop, { desc = "old" })
    vim.keymap.del("n", "<M-h>")
    vim.keymap.set("n", "<M-h>", function() end, { desc = "new" })
    eq(#tap.collisions(), 0, "a delete in between is a re-bind")
    vim.keymap.set("n", "<M-h>", function() end, { desc = "newer" })
    eq(#tap.collisions(), 1, "but binding again after that collides with the re-bind")
    unbind("n", "<M-h>")

    tap.clear()
    api.nvim_set_keymap("n", "<M-h>", ":echo 1<CR>", {})
    api.nvim_del_keymap("n", "<M-h>")
    api.nvim_set_keymap("n", "<M-h>", ":echo 2<CR>", {})
    eq(#tap.collisions(), 0, "nvim_del_keymap in between counts as well")
    unbind("n", "<M-h>")
  end)

  with_tap(function()
    local a = api.nvim_create_buf(false, true)
    local b = api.nvim_create_buf(false, true)
    vim.keymap.set("n", "<M-h>", noop, { desc = "global" })
    vim.keymap.set("n", "<M-h>", noop, { buffer = a, desc = "local a" })
    vim.keymap.set("n", "<M-h>", function() end, { buffer = b, desc = "local b" })
    eq(#tap.collisions(), 0, "buffer-local and global, or two buffers, do not meet")
    vim.keymap.set("n", "<M-h>", function() end, { buffer = a, desc = "local a again" })
    eq(#tap.collisions(), 1, "two bindings in one buffer do")
    unbind("n", "<M-h>")
    api.nvim_buf_delete(a, { force = true })
    api.nvim_buf_delete(b, { force = true })
  end)

  with_tap(function()
    local buf = api.nvim_create_buf(false, true)
    api.nvim_set_current_buf(buf)
    vim.keymap.set("n", "<M-h>", noop, { buffer = true, desc = "true" })
    vim.keymap.set("n", "<M-h>", function() end, { buffer = 0, desc = "zero" })
    eq(#tap.collisions(), 1, "buffer = true and buffer = 0 both mean the current buffer")
    eq(tap.collisions()[1].claimants[1].buffer, buf, "recorded as the real buffer number")
    api.nvim_buf_delete(buf, { force = true })
  end)

  -- The same call site binding the same thing again is a re-bind (a FileType
  -- autocmd firing twice, a :source), whatever new closure it creates.
  with_tap(function()
    local function bind(desc)
      vim.keymap.set("n", "<M-h>", function() end, { desc = desc })
    end
    bind("same")
    bind("same")
    eq(#tap.collisions(), 0, "the same site, description and function definition is a re-bind")
    bind("other")
    eq(#tap.collisions(), 1, "another description from the same helper is a collision")
    unbind("n", "<M-h>")
  end)

  -- ----------------------------------------------------------- lazy stubs

  do
    local dir = vim.fn.tempname() .. "/lazy/core/handler"
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/keys.lua"
    local f = assert(io.open(path, "w"))
    f:write(
      "return function(mode, key, desc)\n  vim.keymap.set(mode, key, function() end, { desc = desc })\nend\n"
    )
    f:close()
    local lazy_set = assert(loadfile(path))()

    -- lazy.nvim binds a placeholder, deletes it before it loads the plugin, binds the real
    -- mapping, and the plugin then binds its own: the run that follows the deletion is benign.
    with_tap(function()
      lazy_set("n", "<M-h>", "Find files")
      unbind("n", "<M-h>")
      lazy_set("n", "<M-h>", "Find files")
      vim.keymap.set("n", "<M-h>", function() end, { desc = "Find files" })
      local c = tap.collisions()
      eq(#c, 1, "lazy's real mapping followed by the plugin's own still shows up in the raw list")
      eq(c[1].benign, "lazy-stub", "but flagged as benign")
      eq(c[1].claimants[1].via, "lazy", "lazy's mapping is recognised by its source file")
      unbind("n", "<M-h>")
    end)

    -- A placeholder that is overwritten without lazy having deleted it is dead: the plugin it
    -- stands for is never lazy-loaded through that key. Alike descriptions do not make it benign.
    with_tap(function()
      lazy_set("n", "<M-j>", "Find files")
      vim.keymap.set("n", "<M-j>", function() end, { desc = "Find files" })
      local c = tap.collisions()
      eq(#c, 1, "a placeholder overwritten by another plugin collides")
      eq(c[1].benign, nil, "and is not benign, even with the same description")
      unbind("n", "<M-j>")
    end)

    with_tap(function()
      lazy_set("n", "<M-h>", "[plug.nvim] Find files")
      unbind("n", "<M-h>")
      lazy_set("n", "<M-h>", "[plug.nvim] Find files")
      vim.keymap.set("n", "<M-h>", function() end, { desc = "plug: [plug.nvim] Find files" })
      local c = tap.collisions()
      eq(#c, 1, "a lazy placeholder and a register()-style mapping with a plugin prefix")
      eq(c[1].benign, "lazy-stub", "are the same description")
      unbind("n", "<M-h>")
    end)

    with_tap(function()
      lazy_set("n", "<M-h>", "Find files")
      vim.keymap.set("n", "<M-h>", function() end, { desc = "Something else entirely" })
      local c = tap.collisions()
      eq(#c, 1, "a lazy mapping and an unrelated one collide")
      eq(c[1].benign, nil, "and that is not benign: the descriptions differ")
      unbind("n", "<M-h>")
    end)

    vim.fn.delete(vim.fn.fnamemodify(dir, ":h:h:h"), "rf")
  end

  -- ---------------------------------------------------- errors pass through

  do
    local function fail(f, ...)
      local passed, err = pcall(f, ...)
      eq(passed, false, "the call must fail")
      -- Neovim 0.11 puts the position of the Lua caller in front of an API error; the wrapper that
      -- passes the error on is that caller, so the stamp comes and goes. The message is what counts.
      return (tostring(err):gsub("^vim/keymap%.lua:%d+: ", ""))
    end

    local plain_set = fail(vim.keymap.set, "zz", "<M-h>", "x")
    local plain_api = fail(api.nvim_set_keymap, "zz", "<M-h>", "x", {})
    local plain_del = fail(vim.keymap.del, "n", "<M-F8>")

    with_tap(function()
      eq(
        fail(vim.keymap.set, "zz", "<M-h>", "x"),
        plain_set,
        "vim.keymap.set raises the same message"
      )
      eq(
        fail(api.nvim_set_keymap, "zz", "<M-h>", "x", {}),
        plain_api,
        "nvim_set_keymap raises the same message"
      )
      eq(
        fail(vim.keymap.del, "n", "<M-F8>"),
        plain_del,
        "deleting a missing mapping raises the same message"
      )
      eq(#tap.log(), 0, "a call that failed leaves no event")
      vim.keymap.set("n", "<M-h>", noop)
      vim.keymap.set("n", "<M-h>", function() end, { desc = "b" })
      eq(#tap.collisions(), 1, "the tap still works after the failures")
      unbind("n", "<M-h>")
    end)
  end

  -- -------------------------------------------------- install / uninstall

  do
    -- Whatever fails in here, the API is put back below: the specs after this one share the editor.
    local block_ok, block_err = pcall(function()
      tap.clear()
      eq(tap.install(), true, "the first install installs")
      eq(tap.install(), false, "the second one does nothing")
      ok(tap.is_installed(), "installed")
      ok(api.nvim_set_keymap ~= pristine.nvim_set_keymap, "and the API is wrapped")
      local restored, left = tap.uninstall()
      eq(restored, true, "uninstall restores")
      eq(#left, 0, "everything")
      ok(not tap.is_installed(), "no longer installed")
      for name, f in pairs(pristine) do
        ok(api[name] == f, name .. " is the original function again")
      end
      vim.keymap.set("n", "<M-F9>", noop)
      eq(#tap.log(), 0, "nothing is recorded after uninstall")
      unbind("n", "<M-F9>")

      -- A foreign wrapper on top is not torn out; the tap steps aside.
      tap.install()
      local ours = api.nvim_set_keymap
      local calls = 0
      api.nvim_set_keymap = function(...)
        calls = calls + 1
        return ours(...)
      end
      local foreign = api.nvim_set_keymap
      local restored2, left2 = tap.uninstall()
      eq(restored2, false, "uninstall reports what it could not restore")
      eq(left2[1], "nvim_set_keymap", "naming it")
      ok(api.nvim_set_keymap == foreign, "and leaves the other wrapper in place")
      vim.keymap.set("n", "<M-F9>", noop)
      ok(calls > 0, "which keeps working")
      eq(#tap.log(), 0, "while the stopped tap records nothing")
      unbind("n", "<M-F9>")
      for name, f in pairs(pristine) do
        api[name] = f
      end
      tap.clear()
    end)
    tap.uninstall()
    tap.clear()
    for name, f in pairs(pristine) do
      api[name] = f
    end
    pcall(vim.keymap.del, "n", "<M-F9>")
    if not block_ok then
      error(block_err, 0)
    end
  end

  -- Installing again over the foreign wrapper that blocked the last uninstall: the layer
  -- that stays in the chain below must stay quiet, or one binding is recorded per layer.
  do
    tap.clear()
    tap.install()
    local ours = api.nvim_set_keymap
    api.nvim_set_keymap = function(...)
      return ours(...)
    end
    tap.uninstall()
    tap.install()
    tap.clear()
    vim.keymap.set("n", "<M-F9>", noop)
    eq(#tap.log(), 1, "one binding is one event after a reinstall over a foreign wrapper")
    unbind("n", "<M-F9>")
    tap.uninstall()
    for name, f in pairs(pristine) do
      api[name] = f
    end
    tap.clear()
  end

  -- The recording stops at `max_events` and says so (a long session binds buffer-local maps on
  -- every attach, and 18000 events cost about 9 MB).
  do
    local limit = tap.max_events
    tap.max_events = 3
    with_tap(function()
      for i = 1, 5 do
        vim.keymap.set("n", "<M-F" .. (5 + i) .. ">", noop)
      end
      eq(#tap.log(), 3, "the recording stops at max_events")
      ok(tap.truncated(), "and says so")
      local _, info = registry.conflicts({ scope = "full" })
      local told = false
      for _, note in ipairs(info.notes) do
        told = told or note:find("stopped recording", 1, true) ~= nil
      end
      ok(told, "conflicts() warns that a clean answer proves nothing")
      for i = 1, 5 do
        unbind("n", "<M-F" .. (5 + i) .. ">")
      end
    end)
    tap.max_events = limit
    ok(not tap.truncated(), "clear() lets the recording grow again")
  end

  -- ------------------------------------------------------------------ via

  with_tap(function()
    keymap.set("n", "<M-h>", noop, { record = false }, "lib one")
    keymap("n", "<M-h>", function() end, { record = false }, "lib two")
    local c = tap.collisions()
    eq(#c, 1, "two lib.nvim keymap.set calls on one key collide")
    eq(c[1].claimants[1].via, "lib", "recognised as coming through lib.nvim")
    ok(
      c[1].claimants[1].source:find("keymap_tap_spec.lua", 1, true) ~= nil,
      "with the caller as source, not lib.nvim's wrapper"
    )
    unbind("n", "<M-h>")
  end)

  -- A hook that something put around `vim.keymap.set` (a telemetry wrapper) sits inside lib.nvim's
  -- own frames: lib.nvim's `set` calls the wrapper, which calls Neovim's. It must not pass for the
  -- caller; the caller is the first frame after the last of lib.nvim's.
  do
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/telemetry_hook.lua"
    local f = assert(io.open(path, "w"))
    -- Not `return orig(...)`: a tail call drops the wrapper's frame from the stack, and the frame is
    -- the whole point of this case.
    f:write(
      "local orig = vim.keymap.set\nreturn function(...)\n  local res = orig(...)\n  return res\nend\n"
    )
    f:close()
    local original = vim.keymap.set
    vim.keymap.set = assert(loadfile(path))()
    local passed, err = pcall(function()
      with_tap(function()
        keymap("n", "<M-h>", noop, { record = false }, "lib one")
        local e = tap.log()[1]
        eq(e.via, "lib", "still recognised as coming through lib.nvim")
        ok(
          e.source:find("keymap_tap_spec.lua", 1, true) ~= nil,
          "the caller, not the telemetry hook: " .. tostring(e.source)
        )
        unbind("n", "<M-h>")
      end)
    end)
    vim.keymap.set = original
    vim.fn.delete(dir, "rf")
    if not passed then
      error(err, 0)
    end
  end

  -- Instrumentation that wraps lib.nvim's own API and calls it on (so it sits *outside* lib's frames,
  -- where no rule can tell it from a real caller) is named as the source unless `tap.skip` lists it.
  do
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/outer_hook.lua"
    local f = assert(io.open(path, "w"))
    f:write(
      "local target = ...\nreturn function(...)\n  local res = target(...)\n  return res\nend\n"
    )
    f:close()
    local hooked = assert(loadfile(path))(keymap.set)
    local passed, err = pcall(function()
      with_tap(function()
        hooked("n", "<M-h>", noop, { record = false }, "lib one")
        local e = tap.log()[1]
        ok(
          e.source:find("outer_hook.lua", 1, true) ~= nil,
          "without a skip pattern the wrapper is the caller: " .. tostring(e.source)
        )

        tap.clear()
        tap.skip = { "/outer_hook%.lua$" }
        hooked("n", "<M-h>", function() end, { record = false }, "lib two")
        e = tap.log()[1]
        ok(
          e.source:find("keymap_tap_spec.lua", 1, true) ~= nil,
          "with its pattern in tap.skip the real caller is: " .. tostring(e.source)
        )
        unbind("n", "<M-h>")
      end)
    end)
    tap.skip = {}
    vim.fn.delete(dir, "rf")
    if not passed then
      error(err, 0)
    end
  end

  -- ---------------------------------------------- pure over a given list

  do
    local function ev(op, desc, key, fp)
      return {
        op = op,
        mode = "n",
        lhs = key,
        key = key,
        desc = desc,
        rhs_kind = "none",
        source = "x:1",
        via = "raw",
        fp = fp or (op .. (desc or "")),
      }
    end
    eq(#tap.collisions({}), 0, "an empty recording has no collisions")
    eq(
      #tap.collisions({ ev("set", "a", "q"), ev("set", "b", "q"), ev("set", "c", "q") }),
      1,
      "three bindings are one collision with three claimants"
    )
    local with_delete = { ev("set", "a", "q"), ev("set", "b", "q") }
    with_delete[#with_delete + 1] = ev("del", nil, "q")
    with_delete[#with_delete + 1] = ev("set", "c", "q")
    eq(#tap.collisions(with_delete), 1, "a delete ends a run, it does not erase it")
    eq(
      #tap.collisions({ ev("set", "a", "q"), ev("del", nil, "q"), ev("set", "b", "q") }),
      0,
      "set, delete, set is nothing"
    )
  end

  -- ------------------------------------- conflicts({ scope = "full" })

  do
    forget_ours()
    -- Default scope: the tap's recording is not consulted at all.
    with_tap(function()
      vim.keymap.set("n", "<M-F12>", noop, { desc = "raw 1" })
      vim.keymap.set("n", "<M-F12>", function() end, { desc = "raw 2" })
      local registered_only, info = registry.conflicts()
      local found = false
      for _, c in ipairs(registered_only) do
        found = found or c.lhs == "<M-F12>"
      end
      ok(not found, "scope registered does not see raw bindings")
      eq(info.scope, "registered", "and says which scope it answered")

      local full, finfo = registry.conflicts({ scope = "full" })
      local hit
      for _, c in ipairs(full) do
        if c.lhs == "<M-F12>" and c.mode == "n" then
          hit = c
        end
      end
      ok(hit ~= nil, "scope full reports the raw collision")
      eq(finfo.tap_installed, true, "knowing the tap was there")
      eq(#finfo.notes, 0, "so there is nothing to caveat")
      ok(hit.claimants[1].source ~= nil, "each claimant says where it came from")
      unbind("n", "<M-F12>")
    end)

    -- Without the tap the answer must say it cannot see overwritten mappings.
    tap.clear()
    vim.keymap.set("n", "<M-F12>", noop, { desc = "raw 1" })
    vim.keymap.set("n", "<M-F12>", function() end, { desc = "raw 2" })
    local full, finfo = registry.conflicts({ scope = "full" })
    eq(finfo.tap_installed, false, "without the tap, the answer says so")
    ok(#finfo.notes >= 1 and finfo.notes[1]:find("not installed", 1, true) ~= nil, "in a note")
    for _, c in ipairs(full) do
      ok(not (c.lhs == "<M-F12>" and c.mode == "n"), "and the overwritten raw mapping is not found")
    end
    unbind("n", "<M-F12>")

    -- A lib.nvim collision is listed once, not once per source of knowledge.
    with_tap(function()
      keymap("n", "<M-F12>", noop, {}, "lib one")
      keymap("n", "<M-F12>", function() end, {}, "lib two")
      local both = registry.conflicts({ scope = "full" })
      local n = 0
      for _, c in ipairs(both) do
        if c.lhs == "<M-F12>" and c.mode == "n" then
          n = n + 1
        end
      end
      eq(n, 1, "a collision known to registry and tap is one row")
      unbind("n", "<M-F12>")
    end)
    forget_ours()

    ---@param key string
    ---@param rows Lib.Keymap.Conflict[]
    ---@return Lib.Keymap.Conflict[]
    local function rows_of(key, rows)
      local found = {}
      for _, c in ipairs(rows) do
        if c.lhs == key then
          found[#found + 1] = c
        end
      end
      return found
    end

    -- Mode shorthands: the registry keeps `""` (n/x/s/o) and `"v"` (x/s) as bound, the tap records
    -- real modes. `""` used to crash the merge, `"v"` was listed once per real mode on top of the
    -- registry's own row.
    with_tap(function()
      keymap("", "<M-l>", noop, {}, "lib one")
      keymap("", "<M-l>", function() end, {}, "lib two")
      local called, rows = pcall(function()
        return (registry.conflicts({ scope = "full" }))
      end)
      ok(called, "the full check survives a collision in the empty mode: " .. tostring(rows))
      if called then
        eq(#rows_of("<M-l>", rows), 1, "a collision in mode '' is one row, not one per real mode")
      end
      unbind("", "<M-l>")

      keymap("v", "<M-j>", noop, {}, "lib one")
      keymap("v", "<M-j>", function() end, {}, "lib two")
      eq(#rows_of("<M-j>", (registry.conflicts({ scope = "full" }))), 1, "and so is one in mode v")
      unbind("v", "<M-j>")
    end)
    forget_ours()

    -- Two lib.nvim bindings and then a raw one that overwrites both: the registry knows the key
    -- already, but only the tap has the winner, so its row (three claimants) must not be dropped.
    with_tap(function()
      keymap("n", "<M-F12>", noop, {}, "lib one")
      keymap("n", "<M-F12>", function() end, {}, "lib two")
      vim.keymap.set("n", "<M-F12>", function() end, { desc = "raw winner" })
      local rows = rows_of("<M-F12>", (registry.conflicts({ scope = "full" })))
      eq(#rows, 1, "one row for the key")
      eq(#rows[1].claimants, 3, "and it has the raw mapping that overwrote both")
      unbind("n", "<M-F12>")

      -- The same over a registry row in mode '': the raw binding in n is a real mode of that row,
      -- not the row itself, and must not be dropped with it.
      keymap("", "<M-F11>", noop, {}, "lib one")
      keymap("", "<M-F11>", function() end, {}, "lib two")
      vim.keymap.set("n", "<M-F11>", function() end, { desc = "raw winner" })
      local winner = false
      for _, c in ipairs(rows_of("<M-F11>", (registry.conflicts({ scope = "full" })))) do
        winner = winner or (c.mode == "n" and #c.claimants == 3)
      end
      ok(winner, "a raw binding over a collision in mode '' is reported with its winner")
      unbind("", "<M-F11>")

      -- Overwritten raw in *every* mode of the '' row: that row wins nowhere any more and must
      -- not stand next to the tap rows with a stale winner.
      keymap("", "<M-F10>", noop, {}, "lib one")
      keymap("", "<M-F10>", function() end, {}, "lib two")
      vim.keymap.set("", "<M-F10>", function() end, { desc = "raw everywhere" })
      local stale, modes = false, 0
      for _, c in ipairs(rows_of("<M-F10>", (registry.conflicts({ scope = "full" })))) do
        stale = stale or c.mode == ""
        modes = modes + ((#c.claimants == 3) and 1 or 0)
      end
      ok(not stale, "the registry row overwritten in all its modes is gone")
      eq(modes, 4, "one row with the raw winner per real mode")
      unbind("", "<M-F10>")
    end)
    forget_ours()

    -- Benign collisions are counted, and shown on request.
    with_tap(function()
      local dir = vim.fn.tempname() .. "/lazy/core/handler"
      vim.fn.mkdir(dir, "p")
      local f = assert(io.open(dir .. "/keys.lua", "w"))
      f:write(
        "return function(mode, key, desc)\n  vim.keymap.set(mode, key, function() end, { desc = desc })\nend\n"
      )
      f:close()
      local lazy_set = assert(loadfile(dir .. "/keys.lua"))()
      lazy_set("n", "<M-F12>", "Find files")
      unbind("n", "<M-F12>")
      lazy_set("n", "<M-F12>", "Find files")
      vim.keymap.set("n", "<M-F12>", function() end, { desc = "Find files" })
      local hidden, hinfo = registry.conflicts({ scope = "full" })
      for _, c in ipairs(hidden) do
        ok(not (c.lhs == "<M-F12>" and c.mode == "n"), "the lazy placeholder is left out")
      end
      eq(hinfo.benign_hidden, 1, "but counted")
      local shown = registry.conflicts({ scope = "full", benign = true })
      local seen = false
      for _, c in ipairs(shown) do
        seen = seen or (c.lhs == "<M-F12>" and c.benign == "lazy-stub")
      end
      ok(seen, "and listed with opts.benign")
      unbind("n", "<M-F12>")
      vim.fn.delete(vim.fn.fnamemodify(dir, ":h:h:h"), "rf")
    end)
  end

  -- ------------------------------------------------- the report lines

  with_tap(function()
    vim.keymap.set("n", "<M-h>", noop, { desc = "raw 1" })
    vim.keymap.set("n", "<M-h>", function() end, { desc = "raw 2" })
    local text = table.concat(keymap.conflict_lines({ scope = "full" }), "\n")
    ok(text:find("<M-h>", 1, true) ~= nil, "the full report names the key")
    ok(text:find("[raw]", 1, true) ~= nil, "and how each binding was made")
    ok(text:find("keymap_tap_spec.lua", 1, true) ~= nil, "and where")
    unbind("n", "<M-h>")
  end)

  do
    local text = table.concat(keymap.conflict_lines({ scope = "full" }), "\n")
    ok(text:find("not installed", 1, true) ~= nil, "the full report without a tap says so")
  end

  -- ------------------------------------------------ reload and stripped chunk

  local modname = "lib.nvim.bindings.keymap.tap"
  local handover = "__lib_nvim_keymap_tap"

  ---Put this spec's own copy of the module back, whatever a case did to the loaded one.
  ---@param old table
  local function restore_module(old)
    package.loaded[modname] = old
    rawset(_G, handover, old)
    tap.uninstall()
    tap.clear()
    tap.skip = {}
    tap.max_events = 50000
    for fname, f in pairs(pristine) do
      api[fname] = f
    end
    pcall(vim.keymap.del, "n", "<M-F9>")
    pcall(vim.keymap.del, "n", "<M-F8>")
  end

  -- A reload (package.loaded cleared, the module required again) used to leave the old copy's
  -- wrappers next to the new one's: every call recorded twice, and an uninstall of the new copy
  -- that restored nothing. The new copy takes over the recording and the settings and silences the old.
  do
    local old = package.loaded[modname]
    local passed, err = pcall(function()
      tap.clear()
      tap.install()
      tap.skip = { "/marker_skip%.lua$" }
      tap.max_events = 1234
      vim.keymap.set("n", "<M-F9>", noop, { desc = "before the reload" })

      package.loaded[modname] = nil
      local fresh = require(modname)
      ok(fresh ~= tap, "a reload gives a new module table")
      ok(fresh.is_installed(), "which carries on recording")
      ok(not tap.is_installed(), "while the old copy is stopped")
      eq(fresh.max_events, 1234, "keeps the settings")
      eq(fresh.skip[1], "/marker_skip%.lua$", "including the skip patterns")
      eq(#fresh.log(), 1, "and what was recorded")

      vim.keymap.set("n", "<M-F8>", noop, { desc = "after the reload" })
      eq(#fresh.log(), 2, "one binding is one event, not one per copy")

      local restored = fresh.uninstall()
      ok(restored, "the new copy's uninstall restores the API")
      for fname, f in pairs(pristine) do
        ok(api[fname] == f, fname .. " is the original function again")
      end
    end)
    restore_module(old)
    if not passed then
      error(err, 0)
    end
  end

  -- A recording that stopped at max_events still says so after a reload: the copy that takes it
  -- over must not present a cut-off log as complete.
  do
    local old = package.loaded[modname]
    local passed, err = pcall(function()
      tap.clear()
      tap.max_events = 1
      tap.install()
      vim.keymap.set("n", "<M-F9>", noop, { desc = "kept" })
      vim.keymap.set("n", "<M-F8>", noop, { desc = "past the limit" })
      ok(tap.truncated(), "the old copy stopped at the limit")

      package.loaded[modname] = nil
      local fresh = require(modname)
      ok(fresh.truncated(), "the new copy reports the recording as cut off")
      fresh.uninstall()
    end)
    restore_module(old)
    if not passed then
      error(err, 0)
    end
  end

  -- On a Lua without line info Neovim's own keymap.lua is a chunk named `?` (a Windows build has
  -- that for real). Its frame must not pass for the caller. Two ways to know it, tried separately:
  -- by the name `?` -- nothing written by a person is called that -- and by being the function
  -- that was `vim.keymap.set` when the module loaded, whatever its chunk is called. The wrapper
  -- below sits over `vim.keymap.set` before the module reloads, as a hook installed early does.
  ---@param chunknames string[]  # Wrappers over vim.keymap.set, innermost first.
  ---@param label string
  local function stripped_case(chunknames, label)
    local old = package.loaded[modname]
    local real_set = vim.keymap.set
    local chain = real_set
    for _, chunkname in ipairs(chunknames) do
      chain = assert(
        load(
          "local orig = ...\nreturn function(...)\n  local res = orig(...)\n  return res\nend",
          chunkname
        )
      )(chain)
    end
    vim.keymap.set = chain
    local passed, err = pcall(function()
      package.loaded[modname] = nil
      local fresh = require(modname)
      fresh.install()
      vim.keymap.set("n", "<M-F9>", noop)
      local e = fresh.log()[1]
      ok(
        e ~= nil and e.source:find("keymap_tap_spec.lua", 1, true) ~= nil,
        label .. " is looked past: " .. tostring(e and e.source)
      )
      fresh.uninstall()
    end)
    vim.keymap.set = real_set
    restore_module(old)
    if not passed then
      error(err, 0)
    end
  end

  stripped_case({ "=?" }, "a frame of a chunk named `?`")
  stripped_case(
    { "=keymap_set_without_a_name_rule" },
    "the function that was vim.keymap.set at load"
  )
  -- Only the name can know this one: the outer wrapper is what `vim.keymap.set` was at load, so the
  -- `?` chunk below it is nobody's but its name.
  stripped_case({ "=?", "=outer_hook_named_by_hand" }, "a `?` frame under a named wrapper")

  eq(tap.is_installed(), false, "the spec leaves the tap uninstalled")
  for name, f in pairs(pristine) do
    ok(api[name] == f, name .. " is original at the end of the spec")
  end
end
