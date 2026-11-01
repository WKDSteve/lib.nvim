-- TESTS/cache_spec.lua — lib.nvim.cache.disk, lib.nvim.cache.memory

return function(H)
  local eq, ok = H.eq, H.ok

  -- -------------------------------------------------------------- cache.disk
  local disk = require("lib.nvim.cache.disk")

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local opts = { dir = dir }

  eq(disk.load("missing", opts), nil, "cache.disk: load on missing namespace is nil")
  eq(
    select(2, disk.load("missing", opts)),
    nil,
    "cache.disk: a missing namespace is 'empty, but ok' -- no err"
  )
  eq(disk.stats("missing", opts).exists, false, "cache.disk: stats on missing namespace")

  -- A file that exists but cannot be read is not the same as no file: a
  -- directory squatting on the path makes io.open (Windows) or read (POSIX)
  -- fail on every platform, which is the shape of a real transient failure.
  vim.fn.mkdir(dir .. "/squatted.json", "p")
  local squatted, squatted_err = disk.load("squatted", opts)
  eq(squatted, nil, "cache.disk: an unreadable file loads as nil")
  ok(
    type(squatted_err) == "string" and squatted_err:match("^read failed") ~= nil,
    "cache.disk: and says so, distinguishable from a missing file: " .. tostring(squatted_err)
  )

  local saved, err = disk.save("widgets", { { id = 1 }, { id = 2 } }, opts)
  eq(saved, true, "cache.disk: save reports success: " .. tostring(err))

  local loaded = disk.load("widgets", opts)
  eq(#loaded, 2, "cache.disk: load roundtrips the saved data")
  eq(loaded[1].id, 1, "cache.disk: nested data survives the roundtrip")

  local st = disk.stats("widgets", opts)
  eq(st.exists, true, "cache.disk: stats.exists after save")
  ok(st.size_bytes > 0, "cache.disk: stats.size_bytes is positive")
  ok(st.age_seconds ~= nil and st.age_seconds >= 0, "cache.disk: stats.age_seconds present")

  -- TTL expiry: rewrite the file with an old `saved_at` to avoid a real sleep.
  local path = dir .. "/widgets.json"
  local f = assert(io.open(path, "r"), "cache.disk spec: widgets.json must exist")
  local entry = vim.json.decode(f:read("*a"))
  f:close()
  entry.saved_at = os.time() - 1000000
  local fw = assert(io.open(path, "w"), "cache.disk spec: widgets.json must be writable")
  fw:write(vim.json.encode(entry))
  fw:close()

  eq(
    disk.load("widgets", vim.tbl_extend("force", opts, { ttl_seconds = 60 })),
    nil,
    "cache.disk: expired entry (by ttl_seconds) loads as nil"
  )
  ok(disk.load("widgets", opts) ~= nil, "cache.disk: load without ttl_seconds ignores age")

  eq(disk.clear("widgets", opts), true, "cache.disk: clear reports success")
  eq(disk.load("widgets", opts), nil, "cache.disk: load after clear is nil")
  eq(
    disk.clear("widgets", opts),
    true,
    "cache.disk: clear on an already-absent namespace is still ok"
  )

  -- A decode failure on an existing, non-empty file is not the same as no
  -- file at all: a caller built on top of this (lib.nvim.store.project, and
  -- through it e.g. spotlight.nvim's persisted spotlights/exceptions) can
  -- have a load-modify-save cycle where a corrupt load collapses to an
  -- empty in-memory value, and the very next unrelated save then silently
  -- replaces the corrupt file with that near-empty value -- destroying
  -- whatever real data was in it. The original bytes must survive as a
  -- `.corrupt` backup once, not be silently discarded.
  disk.save("gadgets", { { id = 9 } }, opts)
  local gadgets_path = dir .. "/gadgets.json"
  local corrupt_backup_path = gadgets_path .. ".corrupt"
  vim.fn.delete(corrupt_backup_path)
  vim.fn.writefile({ "{not valid json" }, gadgets_path)

  local corrupt_data, corrupt_err = disk.load("gadgets", opts)
  eq(corrupt_data, nil, "cache.disk: corrupt file loads as nil, not an error")
  ok(
    type(corrupt_err) == "string" and corrupt_err:match("^invalid json") ~= nil,
    "cache.disk: a corrupt file reports why, naming the backup: " .. tostring(corrupt_err)
  )
  eq(
    vim.fn.filereadable(corrupt_backup_path),
    1,
    "cache.disk: corrupt file backed up to <namespace>.json.corrupt"
  )
  eq(
    table.concat(vim.fn.readfile(corrupt_backup_path), "\n"),
    "{not valid json",
    "cache.disk: backup preserves the original corrupt bytes"
  )

  -- A second load must not clobber an existing backup — mark it, then load
  -- again (the source file is still corrupt) and confirm the mark survives;
  -- an overwrite would replace it with the source file's own bytes again.
  vim.fn.writefile({ "{not valid json -- MARKED" }, corrupt_backup_path)
  disk.load("gadgets", opts)
  eq(
    table.concat(vim.fn.readfile(corrupt_backup_path), "\n"),
    "{not valid json -- MARKED",
    "cache.disk: an existing backup is not rewritten by a later load"
  )

  disk.clear("gadgets", opts)
  vim.fn.delete(corrupt_backup_path)

  -- An interrupted write (crash mid-write, or a disk that fills up before
  -- any bytes land) can leave a save's target file completely empty.
  -- `vim.json.decode("")` throws just like decoding garbage does, but there
  -- is nothing to back up -- the error must not claim a `.corrupt` backup
  -- exists when no bytes were ever written to one.
  disk.save("empty", { { id = 1 } }, opts)
  local empty_path = dir .. "/empty.json"
  local empty_backup_path = empty_path .. ".corrupt"
  vim.fn.delete(empty_backup_path)
  vim.fn.writefile({}, empty_path) -- truncate to 0 bytes
  local empty_data, empty_err = disk.load("empty", opts)
  eq(empty_data, nil, "cache.disk: an empty file loads as nil")
  ok(
    type(empty_err) == "string" and empty_err:match("^invalid json") ~= nil,
    "cache.disk: an empty file reports invalid json: " .. tostring(empty_err)
  )
  ok(
    not empty_err:match("kept at"),
    "cache.disk: an empty file's error does not claim a backup that was never written: "
      .. tostring(empty_err)
  )
  eq(
    vim.fn.filereadable(empty_backup_path),
    0,
    "cache.disk: no .corrupt backup is created for an empty file"
  )
  disk.clear("empty", opts)

  -- A namespace may contain slashes to group related entries — the form
  -- store.project's own documentation uses. Only the cache *root* used to be
  -- created, so every nested namespace failed to write with ENOENT, reporting
  -- it just through save()'s ignorable second return value.
  local nested_ok, nested_err = disk.save("plugin/section/entry", { n = 7 }, opts)
  eq(nested_ok, true, "cache.disk: nested namespace saves: " .. tostring(nested_err))
  local nested = disk.load("plugin/section/entry", opts)
  ok(nested ~= nil and nested.n == 7, "cache.disk: nested namespace roundtrips")
  eq(disk.stats("plugin/section/entry", opts).exists, true, "cache.disk: nested stats")
  eq(disk.clear("plugin/section/entry", opts), true, "cache.disk: nested clear")
  eq(disk.load("plugin/section/entry", opts), nil, "cache.disk: nested load after clear")

  -- A save goes through the atomic writer (temp file, flush, rename): a crash cannot leave the zero-filled file that
  -- truncating in place leaves on NTFS, and no temp file stays behind.
  do
    local real_atomic = require("lib.nvim.fs.write.atomic")
    local seen
    package.loaded["lib.nvim.fs.write.atomic"] = function(target, content, ...)
      seen = { path = target, content = content }
      return real_atomic(target, content, ...)
    end
    local atomic_ok = disk.save("atomic-ns", { n = 1 }, opts)
    package.loaded["lib.nvim.fs.write.atomic"] = real_atomic
    eq(atomic_ok, true, "cache.disk: the atomic save succeeds")
    ok(
      seen and seen.path:match("atomic%-ns%.json$") ~= nil,
      "cache.disk: save writes through lib.nvim.fs.write.atomic"
    )
    eq(#vim.fn.glob(dir .. "/atomic-ns.json.*", false, true), 0, "cache.disk: no temp file is left")
    local back = disk.load("atomic-ns", opts)
    ok(back ~= nil and back.n == 1, "cache.disk: the atomically written file loads")
    -- a target that cannot be replaced is a failed save, not a half-written file
    vim.fn.mkdir(dir .. "/blocked.json", "p")
    local blocked_ok = disk.save("blocked", { n = 1 }, opts)
    eq(blocked_ok, false, "cache.disk: a save that cannot replace the target reports failure")
  end

  -- ------------------------------------------------------------ cache.memory
  local memory = require("lib.nvim.cache.memory")

  local ns = memory.namespace("spec.widgets", { ttl = 0.02 })
  eq(ns.get("a"), nil, "cache.memory: get on empty namespace is nil")

  ns.set("a", 42)
  eq(ns.get("a"), 42, "cache.memory: set/get roundtrip")

  local s1 = ns.stats()
  eq(s1.hits, 1, "cache.memory: stats.hits after one hit")
  eq(s1.misses, 1, "cache.memory: stats.misses after one miss")

  vim.wait(40) -- outlast the 0.02s TTL
  eq(ns.get("a"), nil, "cache.memory: entry expires after its TTL")
  ok(ns.stats().evictions >= 1, "cache.memory: expiry counts as an eviction")

  -- changedtick-bound entries
  local bufnr = vim.api.nvim_create_buf(false, true)
  local ns2 = memory.namespace("spec.tickbound")
  ns2.set("k", "v1", bufnr)
  eq(ns2.get("k", bufnr), "v1", "cache.memory: tick-bound get before any edit")

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "changed" })
  eq(ns2.get("k", bufnr), nil, "cache.memory: tick-bound entry evicted after the buffer changes")

  ns2.set("k2", "v2")
  ns2.invalidate("k2")
  eq(ns2.get("k2"), nil, "cache.memory: invalidate drops a single key")

  ns2.set("k3", "v3")
  ns2.clear()
  eq(ns2.get("k3"), nil, "cache.memory: clear drops every key in the namespace")

  -- Active sweep: lazy per-key eviction in `get` alone leaves an entry alive
  -- forever if nothing ever queries that exact key again -- the shape
  -- `lib.nvim.fs.scan_cached` hits when a caller passes a freshly-created
  -- `ignore` closure on every call, since the key is derived from the
  -- closure's own identity. `set` runs a full sweep every so often instead,
  -- so stale entries are reclaimed even without a single matching `get`.
  local ns4 = memory.namespace("spec.sweep", { ttl = 0.01 })
  for i = 1, 80 do
    ns4.set("stale-" .. i, i)
  end
  vim.wait(20) -- outlast the 0.01s TTL
  for i = 1, 80 do
    ns4.set("fresh-" .. i, i)
  end
  ok(
    ns4.stats().evictions >= 80,
    "cache.memory: a periodic sweep on set() reclaims entries nothing ever re-queries by key"
  )
  -- The still-live fresh-* entries prove the sweep is not indiscriminate --
  -- only entries whose own TTL had actually elapsed were dropped.
  eq(ns4.get("fresh-1"), 1, "cache.memory: entries set after the sweep are untouched by it")

  local all = memory.get_all_stats()
  ok(#all >= 2, "cache.memory: get_all_stats reports every namespace")
  memory.print_all_stats() -- smoke: must not error

  -- entries (size), the aligned text and the `:Lib cache stats` route
  local sized = memory.namespace("spec.size")
  sized.set("a", 1)
  sized.set("b", 2)
  eq(sized.stats().entries, 2, "cache.memory: stats().entries counts the live entries")
  local found
  for _, s in ipairs(memory.get_all_stats()) do
    if s.name == "spec.size" then
      found = s
    end
  end
  eq(found and found.entries, 2, "cache.memory: get_all_stats carries entries too")
  local lines = memory.format_stats()
  eq(lines[1], "Cache Statistics:", "cache.memory: format_stats starts with its title")
  ok(
    lines[2]:find("Entries", 1, true) and lines[2]:find("Hit Rate", 1, true),
    "cache.memory: ... the header names the columns"
  )
  local row
  for _, l in ipairs(lines) do
    if l:find("spec.size", 1, true) == 1 then
      row = l
    end
  end
  ok(row ~= nil, "cache.memory: ... one row per namespace")
  ok(lines[#lines]:find("total (", 1, true) == 1, "cache.memory: ... and a total row")
  eq(
    memory.format_stats({})[4],
    "(no namespaces yet)",
    "cache.memory: format_stats of nothing says so"
  )
  local function zero(name)
    return {
      name = name,
      hits = 0,
      misses = 0,
      invalidations = 0,
      evictions = 0,
      total_requests = 0,
      hit_rate = 0,
    }
  end
  local given = { zero("zzz.last"), zero("aaa.first") }
  local given_lines = memory.format_stats(given)
  eq(given[1].name, "zzz.last", "cache.memory: format_stats does not reorder the table it is given")
  ok(
    given_lines[4]:find("aaa.first", 1, true) == 1,
    "cache.memory: ... and lists the namespaces sorted by name"
  )
  local routes = require("lib.nvim.cache").routes()
  eq(
    table.concat(routes[1].path, " "),
    "cache stats",
    "cache: routes() names the `cache stats` route"
  )
  eq(type(routes[1].run), "function", "cache: ... with a run function")

  -- auto-invalidation is opt-in and toggleable
  eq(memory.is_auto_invalidation_enabled(), false, "cache.memory: auto-invalidation off by default")

  memory.setup_auto_invalidation({ prefix = "lib.nvim.cache.memory.spec" })
  eq(
    memory.is_auto_invalidation_enabled(),
    true,
    "cache.memory: setup_auto_invalidation enables it"
  )

  -- Idempotent: calling setup again must not duplicate the autocmds. Note
  -- nvim_create_autocmd({"TextChanged", "TextChangedI"}, ...) registers one
  -- entry per event, so the group holds 3 entries (2 + BufWritePost) for a
  -- single `setup_auto_invalidation` call — stable across repeats, not 6.
  memory.setup_auto_invalidation({ prefix = "lib.nvim.cache.memory.spec" })
  local autocmds = vim.api.nvim_get_autocmds({ group = "lib.nvim.cache.memory.spec" })
  eq(#autocmds, 3, "cache.memory: re-running setup does not duplicate autocmds")

  local ns3 = memory.namespace("spec.auto")
  ns3.set("x", "y", bufnr)
  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr })
  eq(ns3.get("x", bufnr), nil, "cache.memory: BufWritePost clears namespaces while enabled")

  memory.disable_auto_invalidation()
  eq(
    memory.is_auto_invalidation_enabled(),
    false,
    "cache.memory: disable_auto_invalidation turns it off"
  )

  ns3.set("x2", "y2", bufnr)
  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr })
  eq(ns3.get("x2", bufnr), "y2", "cache.memory: BufWritePost is a no-op once disabled")

  vim.api.nvim_buf_delete(bufnr, { force = true })
end
