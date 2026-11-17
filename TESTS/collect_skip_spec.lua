-- TESTS/collect_skip_spec.lua — lib.nvim.fs.collect_recursive.skip / files_with_ext: folders skipped by name
-- while walking (their contents never read), dot entries skipped on request, and the replacement for
-- `globpath(root, "**/*.<ext>")` showing what globpath shows minus the skipped folders.

return function(H)
  local eq, ok = H.eq, H.ok

  local collect = require("lib.nvim.fs.collect_recursive")

  local tmp = vim.fn.tempname()
  local root = (tmp .. "/skip"):gsub("\\", "/")
  for _, rel in ipairs({
    "docs/a.md",
    "docs/B.MD",
    "docs/c.txt",
    "src/deep/d.md",
    "node_modules/pkg/README.md",
    ".git/info/e.md",
    ".hidden/f.md",
    "vis/.dotdir/g.md",
    ".top.md",
    "target/h.md",
  }) do
    local path = root .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({ "x" }, path)
  end

  ---@param list string[]
  ---@return string[] # sorted, relative to root, forward slashes
  local function rel(list)
    local out = {}
    for _, p in ipairs(list) do
      out[#out + 1] = (p:gsub("\\", "/")):sub(#root + 2)
    end
    table.sort(out)
    return out
  end

  -- default: the names of lib.nvim.fs.ignore.list pruned, hidden entries kept
  local visited = {}
  local default = collect.skip()
  local files = collect.files(root, {
    ignore = function(p, is_dir)
      visited[#visited + 1] = (p:gsub("\\", "/")):sub(#root + 2)
      return default(p, is_dir)
    end,
  })
  eq(
    table.concat(rel(files), ","),
    table.concat({
      ".hidden/f.md",
      ".top.md",
      "docs/B.MD",
      "docs/a.md",
      "docs/c.txt",
      "src/deep/d.md",
      "vis/.dotdir/g.md",
    }, ","),
    "skip(): .git, node_modules, target pruned; hidden entries kept"
  )
  local entered = false
  for _, v in ipairs(visited) do
    if v:find("^node_modules/") or v:find("^%.git/") then
      entered = true
    end
  end
  eq(entered, false, "skip(): nothing below a skipped folder is even looked at")

  -- hidden = false: also every dot entry
  local nohidden = collect.files(root, { ignore = collect.skip({ hidden = false }) })
  eq(
    table.concat(rel(nohidden), ","),
    "docs/B.MD,docs/a.md,docs/c.txt,src/deep/d.md",
    "skip({ hidden = false }): dot files and dot folders skipped too"
  )

  -- own names replace the default list
  local own = collect.files(root, { ignore = collect.skip({ dirs = { "docs" } }) })
  local has_nm, has_docs = false, false
  for _, p in ipairs(rel(own)) do
    if p:find("^node_modules/") then
      has_nm = true
    end
    if p:find("^docs/") then
      has_docs = true
    end
  end
  ok(has_nm and not has_docs, "skip({ dirs = ... }): only the given names are skipped")

  -- files_with_ext: case-insensitive, globpath-like
  local md = collect.files_with_ext(root, { "md" })
  eq(
    table.concat(rel(md), ","),
    "docs/B.MD,docs/a.md,src/deep/d.md",
    "files_with_ext: .md and .MD, no dot entries, no skipped folders"
  )
  local glob = vim.fn.globpath(root, "**/*.md", false, true)
  local glob_kept = {}
  for _, p in ipairs(rel(glob)) do
    if not p:find("^node_modules/") and not p:find("^target/") then
      glob_kept[#glob_kept + 1] = p
    end
  end
  -- globpath matches the extension case-insensitively on Windows only: elsewhere B.MD is not its hit
  local md_rel = {}
  for _, p in ipairs(rel(md)) do
    if vim.fn.has("win32") == 1 or p:match("%.md$") then
      md_rel[#md_rel + 1] = p
    end
  end
  eq(
    table.concat(md_rel, ","),
    table.concat(glob_kept, ","),
    "files_with_ext shows what globpath shows, minus the skipped folders"
  )
  local multi = collect.files_with_ext(root, { "txt", "MD" })
  eq(#multi, 4, "files_with_ext: several extensions in one walk")

  vim.fn.delete(tmp, "rf")
end
