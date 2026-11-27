-- Test code: a nil here (a require, a fixture read) must crash and name it.
---@diagnostic disable: need-check-nil
-- TESTS/contextmenu_catalog_spec.lua -- lib.nvim.contextmenu.catalog: entry validation,
-- registration, queries (plugin/context/group/effect/provides/available), the availability
-- check (plugin, tool, Neovim version) and the generated overview docs/CONTEXTMENU-CATALOG.md.

return function(H)
  local function eq(a, b, msg)
    if type(a) == "table" or type(b) == "table" then
      a, b = vim.inspect(a), vim.inspect(b)
    end
    H.eq(a, b, msg)
  end
  local ok = H.ok
  local catalog = require("lib.nvim.contextmenu.catalog")

  ---A valid entry to start from; `over` replaces fields.
  local function entry(over)
    return vim.tbl_extend("force", {
      id = "demo.thing",
      plugin = "demo",
      label = "Do the thing",
      group = "open",
      context = { "file" },
      effect = "open",
    }, over or {})
  end

  catalog.reset()

  -- ---------- validate ----------

  do
    eq(catalog.validate(entry()), nil, "validate: a complete entry passes")
    ok(catalog.validate("x") ~= nil, "validate: not a table")
    ok(catalog.validate(entry({ id = "nodot" })) ~= nil, "validate: id needs <plugin>.<action>")
    ok(
      catalog.validate(entry({ plugin = "other" })) ~= nil,
      "validate: id must start with its plugin"
    )
    ok(catalog.validate(entry({ label = "" })) ~= nil, "validate: label required")
    local no_group = entry()
    no_group.group = nil
    ok(catalog.validate(no_group) ~= nil, "validate: group required")
    ok(catalog.validate(entry({ context = {} })) ~= nil, "validate: one context at least")
    ok(catalog.validate(entry({ effect = "explode" })) ~= nil, "validate: effect from the list")
    ok(
      catalog.validate(entry({ requires = { tools = "git" } })) ~= nil,
      "validate: requires.tools is a list"
    )
  end

  -- ---------- register / get / reset ----------

  do
    catalog.register(entry())
    eq(catalog.get("demo.thing").label, "Do the thing", "register: get returns the entry")
    catalog.register(entry({ label = "Renamed" }))
    eq(catalog.get("demo.thing").label, "Renamed", "register: same id replaces")
    local n = 0
    for _, e in ipairs(catalog.all()) do
      if e.id == "demo.thing" then
        n = n + 1
      end
    end
    eq(n, 1, "register: replacing keeps one row")
    local raised = not pcall(catalog.register, entry({ effect = "explode" }))
    ok(raised, "register: an invalid entry raises")
    catalog.reset()
    eq(catalog.get("demo.thing"), nil, "reset: runtime entries are gone")
  end

  -- ---------- the built-in data ----------

  do
    local all = catalog.all()
    ok(#all > 40, "builtin: the four plugins' entries are loaded (" .. #all .. ")")
    local seen = {}
    local bad
    for _, e in ipairs(all) do
      bad = bad or catalog.validate(e)
      ok(not seen[e.id], "builtin: unique id " .. e.id)
      seen[e.id] = true
    end
    eq(bad, nil, "builtin: every entry validates")
    eq(catalog.plugins(), {
      "cascade",
      "casedesk",
      "color_my_ascii",
      "dap",
      "docmap",
      "fileops",
      "filetree",
      "github_stats",
      "gitsuite",
      "gopath",
      "images",
      "lsp",
      "markdown",
      "media",
      "open",
      "pickers",
      "rules",
      "sandbox",
      "spotlight",
    }, "builtin: plugins with entries")
    eq(
      catalog.get("gopath.reveal_fm").effect,
      "external",
      "builtin: block defaults merge, entry wins"
    )
    eq(
      catalog.get("filetree.trash").source,
      "filetree.integrations.menu",
      "builtin: source comes from the block"
    )
    eq(
      #(catalog.get("filetree.inspect").requires.plugins or {}),
      0,
      "builtin: `requires = {}` is not merged with the block's requires"
    )
    ok(catalog.get("filetree.tree_actions") ~= nil, "builtin: the dynamic tree actions are listed")
    catalog.register(entry({ id = "demo.pipe", label = "A | B" }))
    ok(catalog.markdown():find("A \\| B", 1, true) ~= nil, "markdown: a pipe in a label is escaped")
    catalog.register(entry({ id = "pickers.open_here", plugin = "pickers", label = "Mine" }))
    eq(
      catalog.get("pickers.open_here").label,
      "Mine",
      "register: a runtime entry wins over the builtin row"
    )
    catalog.reset()
  end

  -- ---------- list ----------

  do
    local function ids(list)
      local out = {}
      for _, e in ipairs(list) do
        out[#out + 1] = e.id
      end
      return out
    end
    local function contains(list, id)
      return vim.tbl_contains(ids(list), id)
    end

    local gp = catalog.list({ plugin = "gopath" })
    eq(#gp, 3, "list: by plugin")
    ok(
      contains(catalog.list({ context = "markdown-checkbox" }), "markdown.checkbox_cycle"),
      "list: by context"
    )
    ok(
      not contains(catalog.list({ context = "markdown-checkbox" }), "markdown.toc"),
      "list: context excludes others"
    )
    ok(contains(catalog.list({ group = "marks" }), "filetree.mark_toggle"), "list: by group")
    ok(contains(catalog.list({ effect = "copy" }), "pickers.copy_path"), "list: by effect")

    -- cross-plugin features
    local cross = catalog.list({ cross = true })
    ok(contains(cross, "gopath.reveal_filetree"), "cross: a bridging entry is listed")
    ok(not contains(cross, "filetree.copy"), "cross: an own-feature entry is not")
    local via_images = catalog.list({ cross = "images" })
    ok(
      contains(via_images, "filetree.ocr") and not contains(via_images, "gopath.reveal_filetree"),
      "cross: filtered by the plugin it brings in"
    )
    ok(
      catalog.validate(entry({ cross = { "demo" } })) ~= nil,
      "validate: cross must not name the owner"
    )
    ok(catalog.validate(entry({ cross = {} })) ~= nil, "validate: cross is not empty")
    ok(catalog.validate(entry({ cross = { "images" } })) == nil, "validate: cross with a plugin")
    local md = catalog.markdown()
    local sect = md:find("## Cross-plugin features", 1, true)
    ok(
      sect ~= nil and sect < md:find("## cascade", 1, true),
      "markdown: the cross-plugin section comes first"
    )
    ok(md:find("⇄ images", 1, true) ~= nil, "markdown: the plugin table marks cross entries")

    local path_only = catalog.list({ provides = { "path" } })
    ok(contains(path_only, "filetree.rename"), "provides: an entry that needs only a path")
    ok(not contains(path_only, "pickers.copy_path_line"), "provides: needs a line too, left out")
    ok(not contains(path_only, "pickers.list_copy"), "provides: needs the items, left out")
    local with_line = catalog.list({ provides = { "path", "line" } })
    ok(contains(with_line, "pickers.copy_path_line"), "provides: path and line supplied")
  end

  -- ---------- available ----------

  do
    catalog.register(
      entry({ id = "demo.tool", requires = { tools = { "definitely-not-a-tool-xyz" } } })
    )
    local good, missing = catalog.available("demo.tool")
    eq(good, false, "available: a missing tool hides the entry")
    eq(missing.tools, { "definitely-not-a-tool-xyz" }, "available: names the missing tool")

    catalog.register(
      entry({ id = "demo.plug", requires = { plugins = { "no.such.plugin.module" } } })
    )
    good, missing = catalog.available("demo.plug")
    eq(good, false, "available: a missing plugin hides the entry")
    eq(missing.plugins, { "no.such.plugin.module" }, "available: names the missing plugin")

    catalog.register(entry({ id = "demo.ok", requires = { plugins = { "lib.nvim.contextmenu" } } }))
    eq((catalog.available("demo.ok")), true, "available: an installed plugin passes")

    catalog.register(entry({ id = "demo.future", requires = { nvim = "99.0" } }))
    good, missing = catalog.available("demo.future")
    eq(good, false, "available: a newer Neovim than running hides the entry")
    eq(missing.nvim, "99.0", "available: names the Neovim version")

    catalog.register(entry({ id = "demo.old", requires = { nvim = "0.5" } }))
    eq((catalog.available("demo.old")), true, "available: an older minimum passes")

    eq((catalog.available("demo.unknown")), false, "available: an unknown id is not available")

    local listed = {}
    for _, e in ipairs(catalog.list({ plugin = "demo", available = true })) do
      listed[#listed + 1] = e.id
    end
    table.sort(listed)
    eq(listed, { "demo.ok", "demo.old" }, "list: available = true keeps only the usable ones")
    catalog.reset()
  end

  -- ---------- the generated overview ----------

  do
    local this = debug.getinfo(1, "S").source:sub(2)
    local root = vim.fn.fnamemodify(this, ":p:h:h")
    local path = root .. "/docs/CONTEXTMENU-CATALOG.md"
    ok(vim.fn.filereadable(path) == 1, "overview: docs/CONTEXTMENU-CATALOG.md exists")
    if vim.fn.filereadable(path) == 1 then
      local on_disk = table.concat(vim.fn.readfile(path), "\n")
      local fresh = catalog.markdown():gsub("\n+$", "")
      eq(
        on_disk:gsub("\n+$", ""),
        fresh,
        "overview: in sync with the data (run scripts/gen-contextmenu-catalog.lua)"
      )
    end
  end

  catalog.reset()
end
