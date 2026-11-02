-- Test code: when something here comes back nil, this file must crash and
-- name it rather than silently skip -- see TESTS/ui_kit_spec.lua's header.
---@diagnostic disable: need-check-nil
-- TESTS/ui_kit_message_log_spec.lua — lib.nvim.ui.kit.message_log,
-- the kit's canonical component since 2026-10-28 (ui.nvim re-exports it).
-- Further behavioral coverage lives in
-- ui.nvim's own TESTS/ui_kit_message_log_spec.lua; this file only pins
-- down the two fixes that this copy must carry too: the `max_entries` cap
-- on a live-feed `append()` (and its deliberate exemption for `load_more`
-- pagination), and the module-level (not per-instance) highlight/arrow
-- namespaces.

return function(H)
  local eq = H.eq
  local message_log = require("lib.nvim.ui.kit.message_log")

  ---@param handle table
  ---@return string[]
  local function lines(handle)
    return vim.api.nvim_buf_get_lines(handle.surf.bufnr, 0, -1, false)
  end

  -- max_entries caps growth, dropping the oldest entries on append().
  do
    local handle = message_log.open({
      now_ms = function()
        return 0
      end,
      max_entries = 2,
      entries = { { time_ms = 0, content = "one" } },
    })
    handle:append({ { time_ms = 0, content = "two" } })
    handle:append({ { time_ms = 0, content = "three" } })
    local got = lines(handle)
    eq(#got, 2, "capped at max_entries")
    eq(got[1]:match("two$") ~= nil, true, "oldest entry was dropped")
    eq(got[2]:match("three$") ~= nil, true, "newest entry kept")
    handle:close()
  end

  -- max_entries does not apply to load_more("older"): pagination is never
  -- trimmed back out.
  do
    local handle = message_log.open({
      now_ms = function()
        return 0
      end,
      max_entries = 2,
      entries = { { time_ms = 0, content = "b" }, { time_ms = 0, content = "c" } },
      load_more = function()
        return { { time_ms = 0, content = "a" } }
      end,
    })
    handle:load_more("older")
    local got = lines(handle)
    eq(#got, 3, "pagination is exempt from max_entries")
    eq(got[1]:match("a$") ~= nil, true, "")
    eq(got[2]:match("b$") ~= nil, true, "")
    eq(got[3]:match("c$") ~= nil, true, "")
    handle:close()
  end

  -- `-` / unload_older takes the last loaded older page out again and tells the caller.
  do
    local unloaded = {}
    local pages = {
      { { time_ms = 0, content = "p2a" }, { time_ms = 0, content = "p2b" } },
      { { time_ms = 0, content = "p1" } },
    }
    local handle = message_log.open({
      now_ms = function()
        return 0
      end,
      entries = { { time_ms = 0, content = "now" } },
      load_more = function()
        return table.remove(pages, 1) or {}
      end,
      on_unload = function(direction, count)
        unloaded[#unloaded + 1] = { direction, count }
      end,
    })
    eq(handle:unload_older(), false, "nothing loaded yet: nothing to unload")
    handle:load_more("older")
    handle:load_more("older")
    handle:load_more("older") -- empty: nothing older left
    eq(#lines(handle), 4, "two pages loaded")
    eq(handle.has_more_older, false, "an empty page says nothing is left")
    eq(handle:unload_older(), true, "the last page goes")
    eq(#lines(handle), 3, "one entry fewer")
    eq(handle.has_more_older, true, "has_more_older is true again")
    eq(
      vim.inspect(unloaded[1]),
      vim.inspect({ "older", 1 }),
      "the caller learns the size of the page"
    )
    eq(handle:unload_older(), true, "the page before it goes")
    eq(vim.inspect(unloaded[2]), vim.inspect({ "older", 2 }), "... with its own size")
    eq(#lines(handle), 1, "only the initial entry is left")
    eq(handle:unload_older(), false, "the stack is empty")
    handle:close()
  end

  -- Two concurrently-open instances share one module-level namespace
  -- (no per-open leak) without cross-instance interference.
  do
    local a = message_log.open({
      now_ms = function()
        return 0
      end,
      entries = { { time_ms = 0, level = vim.log.levels.ERROR, content = "err" } },
    })
    local b = message_log.open({
      now_ms = function()
        return 0
      end,
      entries = { { time_ms = 0, content = "plain" } },
    })
    eq(a._hl_ns, b._hl_ns, "namespace is shared across instances, not per-bufnr")

    local marks_a = vim.api.nvim_buf_get_extmarks(a.surf.bufnr, a._hl_ns, 0, -1, { details = true })
    eq(#marks_a, 1, "the error highlight landed on a's own buffer")
    local line_a = vim.api.nvim_buf_get_lines(a.surf.bufnr, 0, 1, false)[1]
    local d = marks_a[1][4]
    eq(marks_a[1][2] .. ":" .. marks_a[1][3], "0:0", "the highlight starts at the line's start")
    eq(
      d.end_row .. ":" .. d.end_col,
      "0:" .. #line_a,
      "and spans the whole line, like col_end = -1"
    )
    eq(type(d.hl_group), "string", "it carries the level's highlight group")

    local marks_b = vim.api.nvim_buf_get_extmarks(b.surf.bufnr, b._hl_ns, 0, -1, { details = true })
    eq(#marks_b, 0, "b has no highlight and is unaffected by a's, despite the shared namespace")

    a:close()
    b:close()
  end
end
