-- TESTS/fs_listing_spec.lua — lib.nvim.fs.listing: the order of a directory listing (folders first,
-- then by name without regard to case, case-only twins by their bytes) and what counts as a folder
-- (a link to a directory does).

return function(H)
  local ok, eq = H.ok, H.eq
  local listing = require("lib.nvim.fs.listing")
  local uv = vim.uv

  ---@param names string[]  A name that ends in `/` is a folder.
  ---@return Lib.Fs.Listing.Entry[]
  local function entries(names)
    local out = {}
    for _, name in ipairs(names) do
      local dir = name:sub(-1) == "/"
      out[#out + 1] = { name = dir and name:sub(1, -2) or name, is_dir = dir }
    end
    return out
  end
  ---@param list Lib.Fs.Listing.Entry[]
  ---@return string
  local function shown(list)
    local out = {}
    for _, entry in ipairs(list) do
      out[#out + 1] = entry.name .. (entry.is_dir and "/" or "")
    end
    return table.concat(out, " ")
  end
  ---@param names string[]
  ---@param cmp fun(a: any, b: any): boolean
  ---@return string
  local function sorted(names, cmp)
    local list = entries(names)
    table.sort(list, cmp)
    return shown(list)
  end

  -- ── the order by name ──────────────────────────────────────────────────────
  eq(
    sorted({ "foo.bar", "Foo-x", "foo" }, listing.compare),
    "foo Foo-x foo.bar",
    "case does not decide: foo, Foo-x, foo.bar"
  )
  eq(sorted({ "B.md", "a.txt", "a" }, listing.compare), "a a.txt B.md", "a, a.txt, B.md")
  eq(
    sorted({ "readme", "Readme", "README" }, listing.compare),
    "README Readme readme",
    "names that differ in case only: by their bytes"
  )
  eq(
    sorted({ "b.lua", "src/", "a.lua", "Docs/", "zeta/" }, listing.compare),
    "Docs/ src/ zeta/ a.lua b.lua",
    "folders first, each group by name"
  )
  eq(
    sorted({ "b", "a/", "c/" }, listing.sorter()),
    "a/ c/ b",
    "a sorter without options is the same order"
  )

  -- ── descending ─────────────────────────────────────────────────────────────
  eq(
    sorted({ "b.lua", "src/", "a.lua", "Docs/" }, listing.sorter({ descending = true })),
    "src/ Docs/ b.lua a.lua",
    "descending: z to a, folders still first"
  )
  eq(
    sorted({ "readme", "Readme", "a" }, listing.sorter({ descending = true })),
    "Readme readme a",
    "descending: case-only twins stay in byte order"
  )

  -- ── a key of the caller before the name ────────────────────────────────────
  local size = { ["big"] = 9, ["small"] = 1, ["same-b"] = 5, ["same-a"] = 5, ["dir"] = 100 }
  local by_size = listing.sorter({
    first = function(a, b)
      if size[a.name] ~= size[b.name] then
        return size[a.name] < size[b.name]
      end
      return nil
    end,
  })
  eq(
    sorted({ "big", "same-b", "dir/", "small", "same-a" }, by_size),
    "dir/ small same-a same-b big",
    "a key of the caller decides after folders first; the name breaks its ties"
  )

  -- a comparator must never say "a before b" and "b before a"
  local twins = entries({ "x", "x" })
  ok(not listing.compare(twins[1], twins[2]), "equal entries: not before one another")
  ok(not listing.compare(twins[2], twins[1]), "... either way")
  -- an entry without the flag is a file
  ok(
    listing.compare({ name = "z", is_dir = true }, { name = "a" }),
    "an entry without is_dir is a file"
  )

  -- ── what counts as a folder ────────────────────────────────────────────────
  local dir, exists = listing.is_dir("/nowhere/at/all", "directory")
  ok(dir and exists, "kind directory: a folder, nothing is asked")
  dir, exists = listing.is_dir("/nowhere/at/all", "file")
  ok(not dir and exists, "kind file: no folder, nothing is asked")
  dir, exists = listing.is_dir("/nowhere/at/all", "link")
  ok(not dir and not exists, "a link whose target is gone: no folder, and it does not exist")

  local base = vim.fn.tempname()
  vim.fn.mkdir(base .. "/real", "p")
  vim.fn.writefile({ "x" }, base .. "/file.txt")
  H.after_spec(function()
    vim.fn.delete(base, "rf")
  end)
  dir, exists = listing.is_dir(base .. "/real", "unknown")
  ok(dir and exists, "a file system that names no kind: asked, a folder")
  dir, exists = listing.is_dir(base .. "/file.txt", nil)
  ok(not dir and exists, "... and a file")
  -- a junction on Windows needs no privilege; a symlink elsewhere
  local linked = uv.fs_symlink(base .. "/real", base .. "/link", { dir = true, junction = true })
  if linked then
    dir, exists = listing.is_dir(base .. "/link", "link")
    ok(dir and exists, "a link to a directory is a folder")
    vim.fn.delete(base .. "/real", "d")
    dir, exists = listing.is_dir(base .. "/link", "link")
    ok(not dir and not exists, "... until its target is gone")
  else
    H.skipped("a link to a directory is a folder", "no link could be made here")
  end
end
