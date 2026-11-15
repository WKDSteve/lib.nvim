# lib.nvim.fs.listing

The order of a directory listing and what counts as a folder in it, written
once for every plugin that shows one (the own tree of filetree.nvim, the
directory browser of pickers.nvim).

```lua
local listing = require("lib.nvim.fs.listing")

table.sort(entries, listing.compare)                       -- { name, is_dir }[]
table.sort(entries, listing.sorter({ descending = true })) -- z to a, folders still first

-- a key of your own before the name; the name is the tie-break
table.sort(entries, listing.sorter({
  first = function(a, b)
    if size[a] ~= size[b] then return size[a] < size[b] end -- nil: leave it to the name
  end,
}))

local is_dir, exists = listing.is_dir(path, kind)          -- kind: from uv.fs_scandir_next
```

The rule:

1. Folders first.
2. Then by name without regard to case (`foo`, `Foo-x`, `foo.bar`; `a`,
   `a.txt`, `B.md`). Case is folded for ASCII, as `string.lower` does.
3. Names that differ in case only stand in the order of their bytes (`Readme`
   before `readme`), also with `descending`.

`is_dir` takes "directory" and "file" as they are and asks the disk once
(`fs_stat`, which follows links) for everything else: a link to a directory is
a folder, a link whose target is gone is a file with `exists == false`, and a
file system that names no kind is asked too.

`sorter` remembers the lower-cased name per entry table while it lives: make
one per sort. `compare` remembers nothing.
