-- TESTS/view_file_spec.lua — lib.nvim.view_file

return function(H)
  local ok = H.ok
  local function eq(a, b, msg)
    H.eq(vim.inspect(a), vim.inspect(b), msg)
  end
  local fm = require("lib.nvim.markdown.frontmatter")
  local view_file = require("lib.nvim.view_file")

  local vf = view_file.new({
    displays = { "list", "matrix" },
    is_field = function(f)
      return f == "status" or f == "prio" or f == "kind"
    end,
    fields_hint = "status, prio, kind",
    select = { { name = "statuses", key = "sel_statuses" }, { name = "tags", key = "sel_tags" } },
  })

  local function def(extra)
    return vim.tbl_extend(
      "force",
      { title = " Open ", display = "list", group_by = "status" },
      extra or {}
    )
  end

  -- normalize
  local v =
    vf.normalize(def({ select = { statuses = { "open", "open", "doing" }, query = "  x " } }))
  eq(v.title, "Open", "view_file: title trimmed")
  eq(v.select.statuses, { "open", "doing" }, "view_file: duplicates in a list dropped")
  eq(v.select.tags, {}, "view_file: an unset list is empty")
  eq(v.select.query, "x", "view_file: query trimmed")
  local _, err = vf.normalize(def({ group_by = "nope" }))
  eq(
    err,
    "group_by 'nope' is not a field to group by (expected status, prio, kind)",
    "view_file: bad field message"
  )
  _, err = vf.normalize(def({ group_by2 = "prio" }))
  eq(err, "group_by2 is for a matrix only", "view_file: group_by2 needs a matrix")
  _, err = vf.normalize(def({ display = "matrix" }))
  eq(err, "a matrix needs group_by2", "view_file: matrix needs group_by2")
  _, err = vf.normalize(def({ select = { bogus = {} } }))
  eq(err, "select: unknown entry 'bogus'", "view_file: unknown selection entry")
  _, err = vf.normalize(def({ select = { statuses = { "" } } }))
  eq(
    err,
    "select.statuses holds an entry that is not a word",
    "view_file: an empty word is refused by default"
  )
  local lax = view_file.new({
    displays = { "list" },
    is_field = function()
      return true
    end,
    fields_hint = "any",
    select = {},
    allow_empty_word = true,
  })
  ok(
    lax.normalize({ title = "t", display = "list", group_by = "a", collapsed = { "" } }),
    "view_file: allow_empty_word"
  )

  -- pairs_of: new file leaves out what is unset, a patch removes it
  local plain = vf.normalize(def())
  local keys = {}
  for _, p in ipairs(vf.pairs_of(plain, { created = "2026-01-01", updated = "2026-01-02" }, false)) do
    keys[#keys + 1] = p[1]
  end
  eq(
    keys,
    { "title", "display", "group_by", "created", "updated" },
    "view_file: a new file has only what is set"
  )
  local patched = vf.pairs_of(plain, { updated = "2026-01-02" }, true)
  local removed = {}
  for _, p in ipairs(patched) do
    if p[2] == fm.REMOVE then
      removed[#removed + 1] = p[1]
    end
  end
  eq(
    removed,
    { "group_by2", "collapsed", "sel_statuses", "sel_tags", "sel_query" },
    "view_file: a patch removes what is no longer set"
  )

  -- write, change with a patch, read back: nothing of the old text is left that the new view no longer has
  local full =
    vf.normalize(def({ select = { statuses = { "open" }, query = "q" }, collapsed = { "a" } }))
  local text = fm.update_text(
    "\n",
    vf.pairs_of(full, { created = "2026-01-01", updated = "2026-01-01" }, false),
    { create = true }
  )
  local back = vf.parse_text(text, "fallback")
  eq(back.select.statuses, { "open" }, "view_file: round trip selection")
  eq(back.collapsed, { "a" }, "view_file: round trip collapsed")
  eq({ back.created, back.updated }, { "2026-01-01", "2026-01-01" }, "view_file: round trip dates")
  local text2 = fm.update_text(
    text,
    vf.pairs_of(plain, { updated = "2026-01-05", created = "2026-01-01" }, true)
  )
  local back2 = vf.parse_text(text2, "fallback")
  eq(back2.select.statuses, {}, "view_file: a field no longer set is removed from the file")
  eq(back2.select.query, nil, "view_file: the query is removed too")
  eq(back2.updated, "2026-01-05", "view_file: updated moves")

  -- the title of a file without one is its name; a file that is no view is a problem, not an error
  local nt = vf.parse_text("---\ndisplay: list\ngroup_by: status\n---\n", "my-view")
  eq(nt.title, "my-view", "view_file: default title")
  local bad, problem = vf.parse_text("---\ndisplay: list\n---\n", "x")
  eq(bad, nil, "view_file: no group_by is no view")
  ok(problem and problem:find("group_by"), "view_file: the problem names the field")
end
