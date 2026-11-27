-- Test code: when something here comes back nil, this file must crash and
-- name it rather than silently skip -- see TESTS/ui_kit_spec.lua's header.
---@diagnostic disable: need-check-nil
-- TESTS/ui_kit_viewer_keys_spec.lua -- the winbar legend of a kit.viewer with `keys` (`viewer_keys`), the `kit.keys` export and the status tokens of the theme. The full spec of the viewer keys lives in ui.nvim, which runs it through `ui.kit`.

return function(H)
  local eq, ok = H.eq, H.ok
  local kit = require("lib.nvim.ui.kit")
  local viewer_keys = require("lib.nvim.ui.kit.viewer_keys")

  ok(kit.keys == viewer_keys, "kit.keys is the viewer_keys module")

  local bar = viewer_keys.legend({
    { lhs = "r", legend = "Refresh" },
    { lhs = "x", desc = "works, is not advertised" },
    { lhs = "<CR>", legend = "Open" },
  })
  ok(bar:find("r %%#Comment#Refresh"), "an entry with a legend is listed")
  ok(bar:find("<CR> %%#Comment#Open"), "in order")
  ok(not bar:find("x %%#Comment#"), "an entry without a legend is not advertised")
  ok(bar:find("%? %%#Comment#Keys%%#Normal#$"), "`? Keys` comes last")

  local escaped = viewer_keys.legend({ { lhs = "%", legend = "50%{&shell}" } })
  ok(escaped:find("%%#Special#%%%% %%#Comment#50%%%%{&shell}"), "% in a key or text is escaped")
  ok(not escaped:find("[^%%]%%{"), "so the winbar never evaluates it")

  local moved = viewer_keys.legend({ { lhs = "r", legend = "Refresh" } }, {
    help_lhs = "g?",
    help_label = "Tasten",
  })
  ok(moved:find("g%? %%#Comment#Tasten%%#Normal#$"), "a moved help key and its own text")

  local theme = require("lib.nvim.ui.kit.theme")
  eq(type(theme.resolve), "function", "theme resolves")
  local hl = theme.resolve().hl
  for _, token in ipairs({ "ok", "warn", "info", "dim" }) do
    ok(hl[token] ~= nil, "the theme has the status token " .. token)
  end

  -- <C-c> in any kit.viewer copies the whole text: the editor-wide <C-c> only copies file
  -- buffers, so a nofile panel used to copy nothing. `copy_all = false` leaves the key to the caller.
  do
    local notes, orig = {}, vim.notify
    vim.notify = function(msg)
      notes[#notes + 1] = msg
    end
    local surf = kit.viewer({ lines = { "alpha", "beta" }, title = "t" })
    local map
    vim.api.nvim_buf_call(surf.bufnr, function()
      map = vim.fn.maparg("<C-c>", "n", false, true)
    end)
    eq(type(map.callback), "function", "a viewer maps <C-c>")
    vim.fn.setreg('"', "stale")
    vim.fn.setreg("+", "stale")
    map.callback()
    vim.notify = orig
    eq(
      vim.fn.getreg(vim.fn.has("clipboard") == 1 and "+" or '"'),
      "alpha\nbeta\n",
      "the whole text, linewise"
    )
    eq(notes[#notes], "Copied 2 lines", "and it says so")
    surf:close()
    local own = kit.viewer({ lines = { "x" }, title = "t", copy_all = false })
    vim.api.nvim_buf_call(own.bufnr, function()
      map = vim.fn.maparg("<C-c>", "n", false, true)
    end)
    eq(map.buffer ~= 1, true, "copy_all = false binds nothing")
    own:close()
  end
end
