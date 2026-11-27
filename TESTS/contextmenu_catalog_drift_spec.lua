-- Test code: a nil here (a require, a fixture read) must crash and name it.
---@diagnostic disable: need-check-nil
-- TESTS/contextmenu_catalog_drift_spec.lua -- lib.nvim.contextmenu.catalog.drift: the check that
-- every catalogue row still has its counterpart in the code of the plugin it describes. First on a
-- fixture (so a check that reports nothing is proven able to report), then on the real checkouts
-- next to lib.nvim when they are there.

return function(H)
  local ok = H.ok
  local function eq(a, b, msg)
    if type(a) == "table" or type(b) == "table" then
      a, b = vim.inspect(a), vim.inspect(b)
    end
    H.eq(a, b, msg)
  end
  local drift = require("lib.nvim.contextmenu.catalog.drift")
  local catalog = require("lib.nvim.contextmenu.catalog")

  -- ---------- label parts ----------

  eq(
    drift.bare_label("  Reveal in filetree.nvim"),
    "Reveal in filetree.nvim",
    "bare_label: leading space goes"
  )
  eq(drift.bare_label("󰆓 Save"), "Save", "bare_label: a leading icon glyph goes")
  eq(
    drift.label_parts("Mark / Unmark"),
    { "Mark", "Unmark" },
    "label_parts: states are searched alone"
  )
  eq(
    drift.label_parts("Copy path ▸ Absolute / Relative"),
    { "Copy path", "Absolute", "Relative" },
    "label_parts: a fly-out and its items"
  )
  eq(
    drift.label_parts("Checkbox: <state>"),
    {},
    "label_parts: a placeholder is built at click time"
  )
  eq(drift.label_parts("Plain"), { "Plain" }, "label_parts: one label")

  -- ---------- on a fixture checkout ----------

  local root = vim.fn.tempname()
  local function write(rel, text)
    local path = root .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile(vim.split(text, "\n", { plain = true }), path)
  end
  write(
    "demo.nvim/lua/demo/integrations/menu.lua",
    'entry(true, "Do the thing", f)\nentry(true, "Unpin", f)'
  )
  write("demo.nvim/lua/demo/other.lua", 'local x = "Elsewhere label"')
  write("friend.nvim/lua/friend/menu.lua", 'submenu("Friend tools", items)')

  local function row(over)
    return vim.tbl_extend("force", {
      id = "demo.x",
      plugin = "demo",
      label = "Do the thing",
      group = "g",
      context = { "file" },
      effect = "open",
      source = "demo.integrations.menu",
    }, over or {})
  end
  local function kinds(entries)
    local findings = drift.check(root, entries)
    local out = {}
    for _, f in ipairs(findings) do
      out[#out + 1] = f.kind
    end
    return out
  end

  eq(kinds({ row() }), {}, "fixture: a row that matches reports nothing")
  eq(
    kinds({ row({ label = "Renamed away" }) }),
    { "label-missing" },
    "fixture: a renamed label is found"
  )
  eq(
    kinds({ row({ label = "Elsewhere label" }) }),
    {},
    "fixture: the label may be in any file of the plugin"
  )
  eq(
    kinds({ row({ source = "demo.integrations.gone" }) }),
    { "source-missing" },
    "fixture: a moved or removed module is found"
  )
  eq(
    kinds({ row({ source = "demo.integrations" }) }),
    { "source-missing" },
    "fixture: a module is a file, not a folder name"
  )
  eq(
    kinds({ row({ label = "Do the thing / Unpin" }) }),
    {},
    "fixture: every part of a composite label is looked for"
  )
  eq(
    kinds({ row({ label = "Do the thing / Vanished" }) }),
    { "label-missing" },
    "fixture: one missing part of a composite label is found"
  )
  eq(kinds({ row({ label = "Item: <state>" }) }), {}, "fixture: a placeholder row is skipped")
  eq(
    kinds({ row({ plugin = "ghost", id = "ghost.x", source = nil }) }),
    { "no-checkout" },
    "fixture: a plugin without checkout is reported as such, once"
  )
  eq(
    kinds({
      row({ plugin = "ghost", id = "ghost.a", source = nil }),
      row({ plugin = "ghost", id = "ghost.b", source = nil }),
    }),
    { "no-checkout" },
    "fixture: no-checkout is reported once per plugin"
  )
  eq(
    kinds({ row({ label = "Friend tools", cross = { "friend" } }) }),
    {},
    "fixture: a cross-feature row may find its label in the other plugin"
  )
  eq(
    kinds({ row({ label = "Friend tools" }) }),
    { "label-missing" },
    "fixture: without `cross` the other plugin is not searched"
  )
  vim.fn.delete(root, "rf")

  -- ---------- on the real checkouts ----------

  local this = debug.getinfo(1, "S").source:sub(2)
  local repos = vim.fn.fnamemodify(this, ":p:h:h:h")
  local findings, checked = drift.check(repos, catalog.all())
  if vim.tbl_count(checked) == 0 then
    H.skipped("catalogue vs code", "no plugin checkouts next to lib.nvim")
  else
    local bad = {}
    for _, f in ipairs(findings) do
      if f.kind ~= "no-checkout" then
        bad[#bad + 1] = f.id .. ": " .. f.detail
      end
    end
    ok(
      #bad == 0,
      "catalogue vs code: every row has its counterpart (" .. table.concat(bad, "; ") .. ")"
    )
  end
end
