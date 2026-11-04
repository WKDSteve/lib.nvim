-- Test code: when something here comes back nil, this file must crash and
-- name it rather than silently skip -- see TESTS/ui_kit_spec.lua's header.
---@diagnostic disable: need-check-nil, param-type-mismatch, undefined-field, redundant-parameter
-- TESTS/ui_kit_theme_scope_spec.lua -- the Kit* role groups of lib.nvim.ui.kit.theme are per window: a
-- surface in another theme neither recolours the globals nor a window that is already open, and every
-- 'winhighlight' target that names a role points at the window's own group ('winhighlight' does not
-- remap its targets a second time).

return function(H)
  local eq, ok = H.eq, H.ok
  local api = vim.api
  local theme = require("lib.nvim.ui.kit.theme")
  local surface = require("lib.nvim.ui.kit.surface")
  local winhighlight = require("lib.nvim.ui.winhighlight")

  local HACKER_OK = tonumber("33ff66", 16)
  local HACKER_SELECTION_BG = tonumber("33ff66", 16)
  local HACKER_ACCENT = tonumber("7cffa0", 16)
  local HACKER_WARN = tonumber("ffcc33", 16)

  ---@param group string
  ---@return table
  local function hl_of(group)
    return api.nvim_get_hl(0, { name = group, link = true })
  end

  --- The target of `from` in a window's 'winhighlight', nil without an entry.
  ---@param win integer
  ---@param from string
  ---@return string|nil
  local function target(win, from)
    for _, pair in ipairs(winhighlight.parse(winhighlight.get(win))) do
      if pair.from == from then
        return pair.to
      end
    end
    return nil
  end

  theme.materialize(theme.resolve(nil))

  -- A failed assertion must not leave a dialog or a float behind for the specs after this one.
  H.after_spec(function()
    pcall(require("lib.nvim.ui.kit.confirm").close)
    pcall(require("lib.nvim.ui.kit.chooser").close)
    pcall(require("lib.nvim.ui.kit.sidebar").close_all)
    for _, win in ipairs(api.nvim_list_wins()) do
      if api.nvim_win_get_config(win).relative ~= "" then
        pcall(api.nvim_win_close, win, true)
      end
    end
  end)

  -- ---------------------------------------------------------------- every role has a window group
  local hacker = theme.resolve("hacker")
  local groups = theme.window_groups(hacker)
  for _, role in ipairs({
    "normal",
    "border",
    "title",
    "selection",
    "accent",
    "muted",
    "error",
    "flash",
    "hover",
    "ok",
    "warn",
    "info",
    "dim",
    "hotkey",
  }) do
    ok(groups[role], "window_groups names role " .. role)
    ok(vim.fn.hlexists(groups[role]) == 1, "and defines it: " .. role)
  end
  eq(hl_of(groups.ok).fg, HACKER_OK, "the group carries the theme's colour")
  eq(theme.window_groups(hacker).ok, groups.ok, "the same colours share one group")
  ok(
    theme.window_groups(theme.resolve("rounded")).ok ~= groups.ok,
    "other colours get another group"
  )

  -- ---------------------------------------------------------------- the bug: a toast recolours the list
  local list = surface.open({ theme = "hacker", lines = { "passed" }, enter = false })
  local ns = api.nvim_create_namespace("ui_kit_theme_scope_spec")
  api.nvim_buf_set_extmark(list.bufnr, ns, 0, 0, { end_col = 6, hl_group = "KitOk" })
  eq(hl_of("KitOk").link, "DiagnosticOk", "a hacker surface leaves the global KitOk alone")
  eq(target(list.winid, "KitOk"), groups.ok, "its KitOk extmark paints the window's group")

  local toast = surface.open({ lines = { "done" }, enter = false })
  eq(hl_of("KitOk").link, "DiagnosticOk", "a default surface: the global KitOk is unchanged")
  eq(hl_of(target(list.winid, "KitOk")).fg, HACKER_OK, "and the list keeps its colour")
  ok(target(toast.winid, "KitOk") ~= groups.ok, "the toast has a KitOk of its own")
  toast:close()
  list:close()

  -- ---------------------------------------------------------------- targets are the window's groups
  local surf = surface.open({ theme = "hacker", lines = { "x" }, enter = false })
  eq(
    theme.scoped_group(surf.winid, "KitSelection"),
    groups.selection,
    "scoped_group reads the entry"
  )
  eq(theme.scoped_group(surf.winid, "Search"), "Search", "a group that is not remapped stays")
  surf:close()
  eq(theme.scoped_group(surf.winid, "KitOk"), "KitOk", "a closed window: the global name")

  local chooser = require("lib.nvim.ui.kit.chooser")
  chooser.open({ items = { "a", "b" }, theme = "hacker", on_select = function() end })
  local chooser_win = api.nvim_get_current_win()
  eq(hl_of(target(chooser_win, "CursorLine")).bg, HACKER_SELECTION_BG, "chooser: the row")
  chooser.close()

  local picker = require("lib.nvim.ui.kit.picker").open({
    theme = "hacker",
    items = { "a", "b" },
    on_select = function() end,
  })
  ok(picker, "the picker opens")
  local picker_row
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    picker_row = target(win, "CursorLine") or picker_row
  end
  eq(hl_of(picker_row).bg, HACKER_SELECTION_BG, "picker: the row")
  picker.close()

  local kit = require("lib.nvim.ui.kit")
  local confirm = require("lib.nvim.ui.kit.confirm")
  local dialog = kit.confirm({
    question = "Careful",
    kind = "warn",
    theme = "hacker",
    default = 1,
    on_answer = function() end,
  })
  eq(hl_of(target(dialog.winid, "FloatBorder")).fg, HACKER_WARN, "confirm: the kind on the border")
  eq(hl_of(target(dialog.winid, "FloatTitle")).fg, HACKER_WARN, "and on the title")
  confirm.cancel()

  local side = require("lib.nvim.ui.kit.sidebar").open({
    name = "theme-scope",
    lines = { "a" },
    theme = "hacker",
  })
  eq(hl_of(target(side.winid, "CursorLine")).bg, HACKER_SELECTION_BG, "sidebar: the row")
  eq(hl_of(target(side.winid, "KitOk")).fg, HACKER_OK, "sidebar: the role entries")
  eq(hl_of("KitOk").link, "DiagnosticOk", "sidebar: the global KitOk is unchanged")
  require("lib.nvim.ui.kit.sidebar").close_all()
  vim.wait(50)

  local shortlist = kit.shortlist({
    theme = "hacker",
    items = { "a", "b" },
    render = function(item, pane)
      pane:set_lines({ item })
    end,
  })
  ok(shortlist, "the shortlist opens")
  vim.wait(50)
  local results = shortlist.results.winid
  eq(hl_of(target(results, "FloatBorder")).fg, HACKER_ACCENT, "shortlist: the focused border")
  eq(
    hl_of(api.nvim_win_get_config(results).footer[1][2]).fg,
    tonumber("1f7a1f", 16),
    "shortlist: the footer"
  )
  shortlist.close()
  vim.wait(50)

  -- ---------------------------------------------------------------- a spec naming its own global
  local self_named = theme.resolve({ hl = { ok = "KitOk" } })
  local named = surface.open({ theme = { hl = { ok = "KitOk" } }, lines = { "x" }, enter = false })
  eq(target(named.winid, "KitOk"), nil, "no remap entry for a role naming its own global")
  ok(target(named.winid, "KitWarn"), "the other roles keep theirs")
  eq(theme.role_remaps(self_named).KitOk, nil, "role_remaps leaves it out too")
  named:close()
  theme.materialize(theme.resolve(nil))
  eq(hl_of("KitOk").link, "DiagnosticOk", "and the global is not linked to itself")

  -- ---------------------------------------------------------------- :colorscheme clears user groups
  local kept = surface.open({ theme = "hacker", lines = { "x" }, enter = false })
  local kept_ok = target(kept.winid, "KitOk")
  local function source_plugin()
    vim.g.loaded_lib_ui_kit_theme = nil
    dofile("plugin/lib_ui_kit_theme.lua")
  end
  source_plugin()
  vim.cmd.colorscheme("default")
  eq(hl_of(kept_ok).fg, HACKER_OK, "the plugin hook defines a window group again")
  eq(hl_of("KitOk").link, "DiagnosticOk", "and the global one")
  kept:close()

  -- `-u NONE` or a lib.nvim loaded late has no hook: the next surface repairs them.
  vim.api.nvim_create_augroup("lib_ui_kit_theme", { clear = true })
  vim.cmd.colorscheme("default")
  eq(next(hl_of("KitOk")), nil, "without the hook the global is gone")
  local healed = surface.open({ theme = "hacker", lines = { "x" }, enter = false })
  eq(hl_of("KitOk").link, "DiagnosticOk", "a new surface defines the global again")
  eq(hl_of(target(healed.winid, "KitOk")).fg, HACKER_OK, "and its window group")
  healed:close()

  source_plugin()
end
