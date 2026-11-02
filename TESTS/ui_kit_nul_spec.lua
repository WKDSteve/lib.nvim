-- Test code: when something here comes back nil, this file must crash and
-- name it rather than silently skip -- see TESTS/ui_kit_spec.lua's header.
---@diagnostic disable: need-check-nil
-- TESTS/ui_kit_nul_spec.lua -- lib.nvim.ui.kit's copy of ui.nvim's TESTS/ui_kit_nul_spec.lua (the
-- kit exists twice, see ui.nvim's docs/modules.md): a NUL byte in caller text must not keep a kit
-- component from opening.
--
-- A NUL in a Lua string reaches `vim.fn` as a Blob, and `strdisplaywidth()`, `strchars()`,
-- `strcharpart()` and `split()` raise E976 on it -- out of the width every component takes of what
-- it is about to show. Only `kit.input` knew (its secret mask and its title); a case title read
-- from a `.case.json` with a `\u0000` in it kept the whole `kit.select` list from opening, and a NUL
-- in a confirm question, a menu label, a toast, a sheet's label or a button's label did the same to
-- theirs. The text is measured as `lib.lua.strings.core.nul_safe` makes it -- an SOH, one byte and
-- two cells like the `^@` a NUL is drawn as -- and what a caller is handed back stays its own string.

return function(H)
  H.confirm_focus_first() -- the safe button is the default now; these specs drive Yes
  local eq, ok = H.eq, H.ok
  local kit = require("lib.nvim.ui.kit")
  local confirm = require("lib.nvim.ui.kit.confirm")
  local api = vim.api
  local nul = string.char(0)

  vim.o.showmode = false

  local function close_floats()
    for _ = 1, 10 do
      local closed = false
      for _, w in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_is_valid(w) and api.nvim_win_get_config(w).relative ~= "" then
          pcall(api.nvim_win_close, w, true)
          closed = true
        end
      end
      if not closed then
        return
      end
    end
  end

  local function lines_of(bufnr)
    return api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  --- Open `open()` and answer with the surface; the failure names what was raised.
  local function opens(what, open)
    local opened, surf = pcall(open)
    ok(opened, what .. " opens instead of raising: " .. tostring(surf))
    ok(surf ~= nil, what .. " gives a surface")
    return surf
  end

  --- Width of the window `open()` makes.
  local function width_of(open)
    local surf = open()
    local width = api.nvim_win_get_width(surf.winid)
    close_floats()
    return width
  end

  local done, err = pcall(function()
    -- A list or a panel: the width make_scratch takes.
    local selected = opens("a select list", function()
      return kit.select({
        selection = { { t = "a" }, { t = "b" .. nul .. "c" } },
        format_item = function(e)
          return e.t
        end,
        on_select = function() end,
      })
    end)
    ok(
      table.concat(lines_of(selected.bufnr), "\n"):find("b" .. nul .. "c", 1, true) ~= nil,
      "the row holds the caller's text"
    )
    close_floats()

    local function viewer(line)
      return function()
        return kit.viewer({ lines = { line }, relative = "editor" })
      end
    end
    opens("a viewer", viewer("a" .. nul .. "b"))
    close_floats()
    eq(
      width_of(viewer("a" .. nul .. "b")),
      width_of(viewer("axxb")),
      "a viewer: the NUL is as wide as two plain characters"
    )
    opens("a note", function()
      return kit.note({ message = "a" .. nul .. "b", title = "t" .. nul })
    end)
    close_floats()

    -- kit.confirm: the question, and a button's label (the answer stays what was given).
    local function dialog(question)
      return function()
        return kit.confirm({ question = question, on_answer = function() end })
      end
    end
    opens("a confirm dialog", dialog("Delete case a" .. nul .. "b?"))
    confirm.close()
    close_floats()
    eq(
      width_of(dialog("Delete case a" .. nul .. "b?")),
      width_of(dialog("Delete case axxb?")),
      "a confirm question: the NUL is as wide as two plain characters"
    )
    confirm.close()
    local answered
    local choices = opens("a confirm dialog", function()
      return kit.confirm({
        question = "Sure?",
        choices = { "Go" .. nul, "No" },
        on_answer = function(v)
          answered = v
        end,
      })
    end)
    local row = lines_of(choices.bufnr)
    ok(row[#row]:find("[ Go\1 ]  [ No ]", 1, true) ~= nil, "a button label with a NUL: the SOH")
    confirm.confirm()
    eq(answered, "Go" .. nul, "the answer is what was given")
    close_floats()

    -- The prompts.
    local live = opens("a live_input", function()
      return kit.live_input({
        title = string.rep("a", 50) .. nul,
        relative = "editor",
        on_change = function() end,
      })
    end)
    eq(
      api.nvim_win_get_width(live.winid),
      52,
      "a live_input title: 50 letters and the two cells of ^@"
    )
    close_floats()
    local prompt = opens("a prompt", function()
      return kit.input({
        relative = "editor",
        buttons = { { id = "submit", label = "Go" .. nul .. "x" } },
      })
    end)
    ok(lines_of(prompt.bufnr)[2]:find("[ Go\1x ]", 1, true) ~= nil, "a prompt's button: the SOH")
    close_floats()

    -- kit.sheet: the title, a label (drawn by the status column), the buttons, a message.
    local function sheet(opts)
      return function()
        return kit.sheet(vim.tbl_extend("force", {
          fields = { { name = "x", label = "X" } },
          relative = "editor",
          on_submit = function() end,
        }, opts))
      end
    end
    opens("a sheet with a NUL in the title", sheet({ title = "a" .. nul .. "b" }))
    close_floats()
    local labelled = opens(
      "a sheet with a NUL in a label",
      sheet({ fields = { { name = "x", label = "X" .. nul .. "Y" } } })
    )
    local drawn = api.nvim_eval_statusline("%!v:lua.require'lib.nvim.ui.kit.sheet'.column()", {
      winid = labelled.winid,
      use_statuscol_lnum = 1,
    })
    ok(drawn.str:find("X\1Y", 1, true) ~= nil, "the label is drawn: " .. vim.inspect(drawn.str))
    close_floats()
    local buttoned = opens(
      "a sheet with a NUL in a button",
      sheet({
        submit_label = "Go" .. nul,
        fields = {
          {
            name = "x",
            label = "X",
            validate = function()
              return false, "bad" .. nul .. string.rep("m", 80)
            end,
          },
        },
      })
    )
    local srow = lines_of(buttoned.bufnr)
    ok(srow[#srow]:find("[ Go\1 ]", 1, true) ~= nil, "a sheet's button: the SOH")
    local validated, validate_err = pcall(buttoned.validate, buttoned)
    ok(validated, "a message with a NUL is clipped instead of raising: " .. tostring(validate_err))
    close_floats()

    -- kit.menu, kit.toast, kit.chip.
    local menu = require("lib.nvim.ui.kit.menu")
    opens("a menu with a NUL in a label", function()
      return kit.menu({
        relative = "editor",
        items = { { label = "a" .. nul .. "b", action = function() end } },
      })
    end)
    menu.close()
    close_floats()
    opens("a menu with a NUL in the title", function()
      return kit.menu({
        relative = "editor",
        title = "a" .. nul .. "b",
        items = { { label = "ab", action = function() end } },
      })
    end)
    menu.close()
    close_floats()
    opens("a toast", function()
      return kit.toast({ message = "a" .. nul .. "b" })
    end)
    close_floats()
    local wrapped = opens("a toast with a long message", function()
      return kit.toast({ message = string.rep("ab" .. nul, 60) })
    end)
    ok(#lines_of(wrapped.bufnr) > 1, "wrapped to the width of the toast")
    close_floats()
    local mounted, mount_err =
      pcall(kit.chip.mount, { id = "ui_kit_nul_spec", text = "a" .. nul .. "b" })
    ok(mounted, "a chip with a NUL in its text: " .. tostring(mount_err))
    ok(vim.deep_equal(kit.chip.active(), { "ui_kit_nul_spec" }), "and the chip is up")
    pcall(kit.chip.unmount, "ui_kit_nul_spec")
  end)

  confirm.close()
  close_floats()
  assert(done, err)
end
