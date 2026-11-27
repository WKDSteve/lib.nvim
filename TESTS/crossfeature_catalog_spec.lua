-- Test code: a nil here (a require, a fixture read) must crash and name it.
---@diagnostic disable: need-check-nil
-- TESTS/crossfeature_catalog_spec.lua -- lib.nvim.crossfeature: entry validation, registration,
-- the generated built-in data, queries (plugin/from/to/kind/status/idea/task/visibility/available),
-- the links to the context-menu catalogue and the generated overview docs/CROSSFEATURE-CATALOG.md.

return function(H)
  local function eq(a, b, msg)
    if type(a) == "table" or type(b) == "table" then
      a, b = vim.inspect(a), vim.inspect(b)
    end
    H.eq(a, b, msg)
  end
  local ok = H.ok
  local cf = require("lib.nvim.crossfeature")
  local menu = require("lib.nvim.contextmenu.catalog")

  ---A valid entry to start from; `over` replaces fields.
  local function entry(over)
    return vim.tbl_extend("force", {
      id = "cfdemo_a>cfdemo_b",
      from = "cfdemo_a",
      to = "cfdemo_b",
      kind = "optional",
      status = "present",
      text = "a uses b.",
    }, over or {})
  end

  ---@param list Lib.CrossFeature.Entry[]
  ---@return string[]
  local function ids(list)
    local out = {}
    for _, e in ipairs(list) do
      out[#out + 1] = e.id
    end
    table.sort(out)
    return out
  end

  ---@param list Lib.CrossFeature.Entry[]
  ---@param id string
  local function contains(list, id)
    return vim.tbl_contains(ids(list), id)
  end

  cf.reset()

  -- ---------- validate ----------

  do
    eq(cf.validate(entry()), nil, "validate: a complete entry passes")
    ok(cf.validate("x") ~= nil, "validate: not a table")
    ok(cf.validate(entry({ id = "" })) ~= nil, "validate: id required")
    ok(cf.validate(entry({ text = "" })) ~= nil, "validate: text required")
    ok(cf.validate(entry({ to = "cfdemo_a" })) ~= nil, "validate: two different sides")
    ok(cf.validate(entry({ status = "done" })) ~= nil, "validate: status from the list")
    ok(cf.validate(entry({ ideas = "K-1" })) ~= nil, "validate: ideas is a list")
    ok(
      cf.validate(entry({ status = "planned" })) ~= nil,
      "validate: a planned entry names its task"
    )
    eq(
      cf.validate(entry({ status = "planned", tasks = { "x/y" } })),
      nil,
      "validate: a planned entry with a task passes"
    )
    ok(cf.validate(entry({ evidence = { repo = "r" } })) ~= nil, "validate: evidence needs a file")
  end

  -- ---------- register / get / reset ----------

  do
    cf.register(entry())
    eq(cf.get("cfdemo_a>cfdemo_b").text, "a uses b.", "register: get returns the entry")
    cf.register(entry({ text = "Renamed." }))
    eq(cf.get("cfdemo_a>cfdemo_b").text, "Renamed.", "register: same id replaces")
    eq(#cf.list({ from = "cfdemo_a" }), 1, "register: replacing keeps one row")
    cf.register({ from = "cfdemo_b", to = "cfdemo_c", kind = "event", status = "idea", text = "b." })
    ok(cf.get("cfdemo_b>cfdemo_c") ~= nil, "register: an entry without id gets from>to")
    ok(not pcall(cf.register, entry({ status = "done" })), "register: an invalid entry raises")
    cf.reset()
    eq(cf.get("cfdemo_a>cfdemo_b"), nil, "reset: runtime entries are gone")
  end

  -- ---------- the built-in data (generated from integrations.json) ----------

  do
    local all = cf.all()
    ok(#all > 200, "builtin: the generated data is loaded (" .. #all .. ")")
    local seen, bad = {}, nil
    for _, e in ipairs(all) do
      if seen[e.id] then
        bad = bad or ("duplicate id " .. e.id)
      end
      seen[e.id] = true
      bad = bad or (cf.validate(e) and (e.id .. ": " .. cf.validate(e)))
      if not cf.repo(e.from) or not cf.repo(e.to) then
        bad = bad or (e.id .. ": a side is no repo of the data")
      end
    end
    eq(bad, nil, "builtin: every entry is valid, unique and names known repos")
    eq(cf.repo("images").repo, "images.nvim", "builtin: plugins carry the catalogue name")
    eq(cf.repo("tasks").module, "tasks_nvim", "builtin: a plugin knows its main module")
    eq(cf.repo("casedesk").visibility, "private", "builtin: casedesk is marked private")
    eq(cf.repo("images").visibility, nil, "builtin: a public repo has no mark")
    ok(#cf.list({ status = "planned" }) > 0, "builtin: planned connections are there")
  end

  -- ---------- queries ----------

  do
    local of_images = cf.list({ plugin = "images" })
    ok(contains(of_images, "hover>images"), "list: plugin matches the used side")
    ok(contains(of_images, "images>ui"), "list: plugin matches the using side")
    for _, e in ipairs(cf.list({ from = "images" })) do
      ok(e.from == "images", "list: from = images keeps " .. e.id)
    end
    for _, e in ipairs(cf.list({ kind = "event" })) do
      ok(e.kind == "event", "list: kind = event keeps " .. e.id)
    end
    eq(
      ids(cf.list({ idea = "K-6" })),
      { "hover>images", "pickers>images" },
      "list: idea finds the connections an idea built"
    )
    ok(
      #cf.list({ task = "ALL/verwaiste-events-anschliessen", status = "planned" }) >= 5,
      "list: task finds what a task builds"
    )
    local private = cf.list({ visibility = "private" })
    ok(#private > 0, "list: visibility = private finds the private connections")
    for _, e in ipairs(private) do
      ok(cf.is_private(e), "list: private keeps " .. e.id)
    end
    for _, e in ipairs(cf.list({ visibility = "public" })) do
      ok(not cf.is_private(e), "list: public drops " .. e.id)
    end
  end

  -- ---------- availability ----------

  do
    package.preload["cfdemo_a"] = function()
      return {}
    end
    package.preload["cfdemo_b"] = function()
      return {}
    end
    cf.register(entry())
    cf.register(entry({ id = "cfdemo_a>cfdemo_missing", to = "cfdemo_missing" }))
    local yes, missing = cf.available("cfdemo_a>cfdemo_b")
    eq({ yes, missing }, { true, {} }, "available: both sides installed")
    yes, missing = cf.available("cfdemo_a>cfdemo_missing")
    eq({ yes, missing }, { false, { "cfdemo_missing" } }, "available: names the missing side")
    eq((cf.available("cfdemo.unknown")), false, "available: an unknown id is not available")
    eq(
      ids(cf.list({ from = "cfdemo_a", available = true })),
      { "cfdemo_a>cfdemo_b" },
      "list: available = true keeps only the usable ones"
    )
    eq(cf.installed("lib"), true, "installed: lib.nvim itself is there (module from the data)")
    package.preload["cfdemo_a"], package.preload["cfdemo_b"] = nil, nil
    package.loaded["cfdemo_a"], package.loaded["cfdemo_b"] = nil, nil
    cf.reset()
  end

  -- ---------- the links to the context-menu catalogue ----------

  do
    eq(
      cf.unlinked_menu_entries(),
      {},
      "menu: every context-menu entry with cross has a present connection (fix integrations.json)"
    )
    local m = menu.list({ cross = true })[1]
    ok(m ~= nil, "menu: the context-menu catalogue has cross entries")
    if m then
      local behind = cf.for_menu(m.id)
      ok(#behind > 0, "menu: for_menu finds the connection behind " .. m.id)
      if behind[1] then
        eq(behind[1].status, "present", "menu: present connections come first")
        ok(
          vim.tbl_contains(ids(cf.menu_entries(behind[1])), m.id),
          "menu: menu_entries points back at " .. m.id
        )
      end
    end
    eq(cf.for_menu("cfdemo.none"), {}, "menu: an unknown menu id has no connection")
  end

  -- ---------- markdown ----------

  do
    local md = cf.markdown()
    ok(md:find("## Present (", 1, true) ~= nil, "markdown: a section for present ones")
    ok(md:find("## Planned (", 1, true) ~= nil, "markdown: a section for planned ones")
    ok(md:find("`hover>images`", 1, true) ~= nil, "markdown: lists a public connection")
    ok(md:find("`casedesk>", 1, true) == nil, "markdown: no connection of casedesk (private)")
    ok(md:find(">casedesk`", 1, true) == nil, "markdown: none into casedesk either")
    ok(md:find("| my |", 1, true) == nil, "markdown: my.nvim (private) is not named")
    ok(
      md:find("connections with a private repo are not listed", 1, true) ~= nil,
      "markdown: counts them"
    )
    cf.register(entry({ text = "A | B" }))
    ok(cf.markdown():find("A \\| B", 1, true) ~= nil, "markdown: a pipe in a text is escaped")
    cf.reset()
  end

  -- ---------- the generated overview ----------

  do
    local this = debug.getinfo(1, "S").source:sub(2)
    local root = vim.fn.fnamemodify(this, ":p:h:h")
    local path = root .. "/docs/CROSSFEATURE-CATALOG.md"
    ok(vim.fn.filereadable(path) == 1, "overview: docs/CROSSFEATURE-CATALOG.md exists")
    if vim.fn.filereadable(path) == 1 then
      local on_disk = table.concat(vim.fn.readfile(path), "\n")
      local fresh = cf.markdown():gsub("\n+$", "")
      eq(
        on_disk:gsub("\n+$", ""),
        fresh,
        "overview: in sync with the data (run scripts/gen-crossfeature-catalog.lua or gen-contextmenu-catalog.lua)"
      )
    end
  end

  cf.reset()
end
