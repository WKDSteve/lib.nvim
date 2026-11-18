-- TESTS/collect_gitignore_spec.lua — collect_recursive.files_async with gitignore = true: on a tree
-- without ignore files the same files as the plain walk (in every tier of lib.nvim.fs.fast this machine
-- has), the `ignore` predicate pruning whole folders as the walk prunes them, and inside a git
-- repository what .gitignore names left out (tiers that read .gitignore only).

return function(H)
  local eq, ok = H.eq, H.ok
  local uv = vim.uv or vim.loop

  local collect = require("lib.nvim.fs.collect_recursive")
  local fast = require("lib.nvim.fs.fast")
  local helper = require("lib.nvim.fs.helper")

  local tmp =
    fast.norm(tostring(uv.fs_realpath(vim.fn.tempname():match("^(.*)[/\\]")) or vim.fn.tempname()))
  local root = ("%s/lib_gitignore_%d"):format(tmp, uv.hrtime() % 1e9)
  for _, rel in ipairs({
    "a.txt",
    ".dot",
    "sub/b.txt",
    "sub/deep/c.txt",
    "keep/d.txt",
    "keep/skipme/e.txt",
  }) do
    local path = root .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({ "x" }, path, "b")
  end

  local function rel(paths)
    local out = {}
    for _, p in ipairs(paths) do
      out[#out + 1] = fast.norm(p):sub(#root + 2)
    end
    table.sort(out)
    return table.concat(out, ",")
  end

  local function via_fast(opts)
    local got, errs, done = nil, nil, false
    collect.files_async(root, opts, function(paths, errors)
      got, errs, done = paths, errors, true
    end)
    vim.wait(10000, function()
      return done
    end, 5)
    return rel(got or {}), errs
  end

  -- a program next to this repository is used when there is one; the lib CI has none
  local program = vim.env.LIB_FS_HELPER_TEST
  if not program or program == "" then
    program = vim.fn.fnamemodify(vim.fn.getcwd(), ":h")
      .. "/filetree.nvim/helper/target/release/"
      .. helper.binary_name()
  end
  helper.configure(uv.fs_stat(program) and program or false)

  local plain = rel((collect.files(root)))
  local tiers = { "lua" }
  if helper.available() then
    tiers[#tiers + 1] = "helper"
  end
  if vim.fn.executable("fd") == 1 or vim.fn.executable("fdfind") == 1 then
    tiers[#tiers + 1] = "fd"
  end
  if vim.fn.executable("rg") == 1 then
    tiers[#tiers + 1] = "rg"
  end
  local skip_keep = function(path, is_dir)
    return is_dir and (path:match("[^/\\]+$") == "skipme")
  end
  local pruned = rel((collect.files(root, { ignore = skip_keep })))
  for _, tier in ipairs(tiers) do
    local got, errs = via_fast({ gitignore = true, tier = tier })
    eq(got, plain, tier .. ": no ignore files, the same files as the walk")
    eq(errs, nil, tier .. ": no errors")
    eq(
      (via_fast({ gitignore = true, tier = tier, ignore = skip_keep })),
      pruned,
      tier .. ": ignore prunes a folder"
    )
  end

  local threw = pcall(collect.collect_async, root, { gitignore = true }, function() end)
  eq(threw, false, "gitignore = true with kind all: refused")

  -- inside a git repository, what .gitignore names is left out
  if
    vim.fn.executable("git") == 1 and vim.system({ "git", "init", "-q", root }):wait().code == 0
  then
    vim.fn.writefile({ "sub/" }, root .. "/.gitignore", "b")
    local reading = vim.tbl_filter(function(t)
      return t ~= "lua"
    end, tiers)
    for _, tier in ipairs(reading) do
      local got = via_fast({ gitignore = true, tier = tier })
      ok(not got:find("sub/", 1, true), tier .. ": .gitignore leaves out sub/ (" .. got .. ")")
      ok(
        got:find("keep/d.txt", 1, true) ~= nil and not got:find(".git/", 1, true),
        tier .. ": the rest, never .git"
      )
    end
    if #reading == 0 then
      H.skipped(".gitignore", "no helper, fd or rg on this host")
    end
  else
    H.skipped(".gitignore", "no git")
  end

  helper.configure(false)
  vim.fn.delete(root, "rf")
end
