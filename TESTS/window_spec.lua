-- TESTS/window_spec.lua — lib.nvim.window: tag.lua and open_scratch_split.lua.

return function(H)
  local window = require("lib.nvim.window")

  -- tag: set / get / find ------------------------------------------------------
  do
    vim.cmd("new")
    local win = vim.api.nvim_get_current_win()

    H.eq(window.tag.get(win), nil, "tag.get: untagged window returns nil")

    window.tag.set(win, "lib.nvim.window_spec.tag")
    H.eq(window.tag.get(win), "lib.nvim.window_spec.tag", "tag.get: reads back the tag just set")

    local found = window.tag.find("lib.nvim.window_spec.tag")
    H.eq(found, win, "tag.find: locates the tagged window")

    H.eq(
      window.tag.find("lib.nvim.window_spec.does-not-exist"),
      nil,
      "tag.find: nil for unknown tag"
    )

    vim.api.nvim_win_close(win, true)
    H.eq(window.tag.get(win), nil, "tag.get: invalid window id returns nil")
  end

  -- open_scratch_split -----------------------------------------------------
  do
    local bufnr, winid = window.open_scratch_split(
      { "hello", "world" },
      { filetype = "window-spec" }
    )

    H.ok(vim.api.nvim_buf_is_valid(bufnr), "open_scratch_split: returns a valid bufnr")
    H.ok(vim.api.nvim_win_is_valid(winid), "open_scratch_split: returns a valid winid")
    H.eq(
      vim.api.nvim_win_get_buf(winid),
      bufnr,
      "open_scratch_split: window shows the returned buffer"
    )
    H.eq(vim.bo[bufnr].buftype, "nofile", "open_scratch_split: buftype is nofile")
    H.eq(vim.bo[bufnr].filetype, "window-spec", "open_scratch_split: filetype applied")
    H.eq(vim.bo[bufnr].modifiable, false, "open_scratch_split: locked read-only by default")
    H.eq(
      table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n"),
      "hello\nworld",
      "open_scratch_split: content set"
    )

    local bufnr2, winid2 = window.open_scratch_split({ "second" })
    H.ok(bufnr2 ~= bufnr, "open_scratch_split: a second call opens its own buffer (no de-dup)")
    H.ok(winid2 ~= winid, "open_scratch_split: a second call opens its own window")

    pcall(vim.api.nvim_win_close, winid, true)
    pcall(vim.api.nvim_win_close, winid2, true)
  end

  -- ---------- set_title ----------

  do
    local set_title = require("lib.nvim.window.set_title")
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = 1,
      col = 1,
      width = 12,
      height = 2,
      style = "minimal",
      border = "rounded",
      title = "Parent",
    })
    local function frame_title()
      local cfg = vim.api.nvim_win_get_config(win)
      return cfg.title and cfg.title[1] and cfg.title[1][1] or nil
    end
    H.eq(frame_title(), "Parent", "set_title: fixture starts titled")

    H.ok(set_title(win, "Child"), "set_title: applies a new title")
    H.eq(frame_title(), "Child", "set_title: the new title is on the frame")

    -- The documented "pass nil to clear" contract. It used to be written as
    -- `{ title = nil }`, which in Lua is the *omitted* key -- and an omitted
    -- key leaves nvim_win_set_config's existing value alone, so clearing
    -- silently did nothing. Only an empty string removes it.
    H.ok(set_title(win, nil), "set_title: clearing reports success")
    H.eq(frame_title(), nil, "set_title: nil actually removes the title")

    pcall(vim.api.nvim_win_close, win, true)
  end

  -- ---------- make_scratch: anchor flip near a screen edge ----------
  --
  -- relative="cursor"/"mouse" floats used to always anchor NW (extend
  -- downward) with no check for whether that fits -- a click low on screen
  -- plus a tall enough float (a long context menu, say) opened anyway,
  -- extending past the bottom edge with nothing to show there. Should flip
  -- to anchor SW (extend upward) instead whenever it doesn't fit below.

  do
    local make_scratch = require("lib.nvim.window.make_scratch")
    local orig_screenrow = vim.fn.screenrow
    local orig_getmousepos = vim.fn.getmousepos
    local orig_lines = vim.o.lines

    vim.o.lines = 40

    -- Cursor near the bottom (row 38 of 40), a float 10 rows tall: 38+1+10
    -- would overshoot -- must flip.
    vim.fn.screenrow = function()
      return 38
    end
    local winid = make_scratch({ lines = { "x" }, height = 10, relative = "cursor" })
    H.ok(winid ~= nil, "make_scratch: cursor-relative float near the bottom opens")
    local cfg = vim.api.nvim_win_get_config(winid)
    H.eq(cfg.anchor, "SW", "make_scratch: flips to SW when it doesn't fit below the cursor")
    H.eq(cfg.row, 0, "make_scratch: SW row is 0 (bottom edge right at the anchor point)")
    pcall(vim.api.nvim_win_close, winid, true)

    -- Cursor near the top: the same float fits below it -- no flip.
    vim.fn.screenrow = function()
      return 2
    end
    local winid2 = make_scratch({ lines = { "x" }, height = 10, relative = "cursor" })
    local cfg2 = vim.api.nvim_win_get_config(winid2)
    H.eq(cfg2.anchor, "NW", "make_scratch: stays NW when it fits below the cursor")
    H.eq(cfg2.row, 1, "make_scratch: NW keeps the default 1-row downward offset")
    pcall(vim.api.nvim_win_close, winid2, true)

    -- Same check for relative="mouse", via getmousepos() instead of screenrow().
    vim.fn.getmousepos = function()
      return { screenrow = 39, screencol = 10 }
    end
    local winid3 = make_scratch({ lines = { "x" }, height = 10, relative = "mouse" })
    local cfg3 = vim.api.nvim_win_get_config(winid3)
    H.eq(cfg3.anchor, "SW", "make_scratch: mouse-relative also flips near the bottom")
    pcall(vim.api.nvim_win_close, winid3, true)

    -- relative="editor" is untouched: still centers, anchor stays the
    -- (explicit-but-equivalent) default NW.
    local winid4 = make_scratch({ lines = { "x" }, height = 5, width = 10, relative = "editor" })
    local cfg4 = vim.api.nvim_win_get_config(winid4)
    H.eq(cfg4.anchor, "NW", "make_scratch: editor-relative float keeps the default NW anchor")
    pcall(vim.api.nvim_win_close, winid4, true)

    -- Explicit widths of 1 and 2 are honoured; only a width that was never
    -- given (empty content, nothing to derive from) falls back to 60. An
    -- explicit 1 or 2 used to be widened to 60 as well -- a one-cell hint
    -- became a 60-cell bar.
    -- Each window is closed right after reading the property under test, and
    -- before the H.eq that checks it -- H.eq raises on mismatch, and
    -- TESTS/run.lua pcalls this whole spec file as one unit, so a close after
    -- a failing H.eq would never run: the float leaks for the rest of the
    -- headless session and every later `do` block in this file is skipped too.
    for _, want in ipairs({ 1, 2, 3 }) do
      local w = make_scratch({ lines = { "x" }, width = want, height = 1, border = "none" })
      local got = w and vim.api.nvim_win_get_width(w) or nil
      pcall(vim.api.nvim_win_close, w, true)
      H.eq(got, want, "make_scratch: explicit width " .. want .. " is honoured, not widened to 60")
    end

    local wempty = make_scratch({ lines = {}, border = "none" })
    local wempty_width = wempty and vim.api.nvim_win_get_width(wempty) or nil
    pcall(vim.api.nvim_win_close, wempty, true)
    H.eq(
      wempty_width,
      math.min(60, math.max(1, vim.o.columns - 4)),
      "make_scratch: no width and no content still falls back to 60"
    )

    local wblank = make_scratch({ lines = { "", "" }, border = "none" })
    local wblank_width = wblank and vim.api.nvim_win_get_width(wblank) or nil
    pcall(vim.api.nvim_win_close, wblank, true)
    H.eq(
      wblank_width,
      math.min(60, math.max(1, vim.o.columns - 4)),
      "make_scratch: non-empty but zero-display-width lines still fall back to 60, not just literally empty ones"
    )

    -- a title (or footer) wider than the content is drawn cut by Neovim (`╭<port all to╮` for
    -- "Export all to" over the items "Clipboard", "New buffer", "File"): a derived width makes room for it
    local items = { "Clipboard", "New buffer", "File" }
    local wtitle = make_scratch({ lines = items, border = "rounded", title = "Export all to" })
    local wtitle_width = wtitle and vim.api.nvim_win_get_width(wtitle) or nil
    pcall(vim.api.nvim_win_close, wtitle, true)
    H.eq(
      wtitle_width,
      #"Export all to" + 2,
      "make_scratch: a derived width fits a title wider than the lines"
    )
    local wchunks = make_scratch({
      lines = items,
      border = "rounded",
      title = { { "Export ", "Title" }, { "all to", "Title" } },
    })
    local wchunks_width = wchunks and vim.api.nvim_win_get_width(wchunks) or nil
    pcall(vim.api.nvim_win_close, wchunks, true)
    H.eq(
      wchunks_width,
      #"Export all to" + 2,
      "make_scratch: a title of chunks is measured as its text"
    )
    local wfoot = make_scratch({ lines = items, border = "rounded", footer = "q close, <CR> pick" })
    local wfoot_width = wfoot and vim.api.nvim_win_get_width(wfoot) or nil
    pcall(vim.api.nvim_win_close, wfoot, true)
    H.eq(wfoot_width, #"q close, <CR> pick" + 2, "make_scratch: the same for a footer")
    local wshort = make_scratch({ lines = items, border = "rounded", title = "To" })
    local wshort_width = wshort and vim.api.nvim_win_get_width(wshort) or nil
    pcall(vim.api.nvim_win_close, wshort, true)
    H.eq(
      wshort_width,
      #"New buffer" + 2,
      "make_scratch: a short title leaves the width to the lines"
    )
    local wgiven =
      make_scratch({ lines = items, border = "rounded", title = "Export all to", width = 8 })
    local wgiven_width = wgiven and vim.api.nvim_win_get_width(wgiven) or nil
    pcall(vim.api.nvim_win_close, wgiven, true)
    H.eq(wgiven_width, 8, "make_scratch: an explicit width is kept, whatever the title")

    local wfrac = make_scratch({ lines = {}, width = 0.001, border = "none" })
    local wfrac_width = wfrac and vim.api.nvim_win_get_width(wfrac) or nil
    pcall(vim.api.nvim_win_close, wfrac, true)
    H.eq(
      wfrac_width,
      math.min(60, math.max(1, vim.o.columns - 4)),
      "make_scratch: a fraction rounding to zero cells counts as not given"
    )

    -- height mirrors width: a fraction that rounds to zero rows must fall
    -- back to the line count, not get forced down to a bare 1 row (`0` is
    -- truthy in Lua, so a naive `resolve_size(...) or #lines` never reaches
    -- `#lines` for it).
    local many_lines = { "a", "b", "c", "d", "e" }
    local hfrac = make_scratch({ lines = many_lines, height = 0.001, border = "none" })
    local hfrac_height = hfrac and vim.api.nvim_win_get_height(hfrac) or nil
    pcall(vim.api.nvim_win_close, hfrac, true)
    H.eq(
      hfrac_height,
      #many_lines,
      "make_scratch: a height fraction rounding to zero rows falls back to the line count, not 1"
    )

    -- Unlike width, height has no "comfort bump" second fallback stage: no
    -- height option and no content (`#lines == 0`) just floor-clamps to a
    -- bare 1 row (a 1-cell width would be unreadably thin, but a 1-row float
    -- for empty content is exactly what a prompt/spacer wants). Deliberate,
    -- but previously unpinned -- nothing caught a regression that added a
    -- comfort bump here, or dropped the floor clamp entirely.
    local hempty = make_scratch({ lines = {}, border = "none" })
    local hempty_height = hempty and vim.api.nvim_win_get_height(hempty) or nil
    pcall(vim.api.nvim_win_close, hempty, true)
    H.eq(hempty_height, 1, "make_scratch: no height and no content falls back to a bare 1 row")

    -- The mainline branch of the given_h guard (a valid explicit cell height,
    -- not one that rounds to zero) had no direct nvim_win_get_height
    -- assertion anywhere in this file -- every other explicit-height call
    -- site above only checks anchor/row/width, never height itself.
    local hgiven = make_scratch({ lines = { "x" }, height = 7, border = "none" })
    local hgiven_height = hgiven and vim.api.nvim_win_get_height(hgiven) or nil
    pcall(vim.api.nvim_win_close, hgiven, true)
    H.eq(hgiven_height, 7, "make_scratch: an explicit cell height is honoured")

    vim.fn.screenrow = orig_screenrow
    vim.fn.getmousepos = orig_getmousepos
    vim.o.lines = orig_lines
  end

  -- ---------- make_scratch: scrolloff/sidescrolloff pinned to 0 ----------
  --
  -- Both are window-local but fall back to the global value when unset, so
  -- a scratch float otherwise inherits whatever a user's own config sets
  -- (up to the "keep the cursor centered" 999) instead of behaving like the
  -- self-contained overlay it is meant to be. Confirms the window-local
  -- value itself, regardless of what the global one is set to.

  do
    local make_scratch = require("lib.nvim.window.make_scratch")
    local saved_so, saved_siso = vim.o.scrolloff, vim.o.sidescrolloff
    vim.o.scrolloff = 10
    vim.o.sidescrolloff = 10

    local winid = make_scratch({ lines = { "one line" }, height = 3, relative = "editor" })
    assert(winid, "make_scratch: fixture window failed to open")

    H.eq(vim.wo[winid].scrolloff, 0, "make_scratch: scrolloff pinned to 0 regardless of the global")
    H.eq(
      vim.wo[winid].sidescrolloff,
      0,
      "make_scratch: sidescrolloff pinned to 0 regardless of the global"
    )

    pcall(vim.api.nvim_win_close, winid, true)
    vim.o.scrolloff = saved_so
    vim.o.sidescrolloff = saved_siso
  end

  -- A line with a newline in it is refused by the API: make_scratch still raises,
  -- but the buffer it made a moment before is gone again (it stayed behind,
  -- never shown and never wiped, once per failing call).
  do
    local make_scratch = require("lib.nvim.window.make_scratch")
    local before = #vim.api.nvim_list_bufs()
    local raised, err = pcall(make_scratch, { lines = { "a\nb" } })
    H.ok(not raised, "make_scratch: a line with a newline still raises")
    H.ok(
      tostring(err):find("newlines", 1, true) ~= nil,
      "make_scratch: and says why: " .. tostring(err)
    )
    H.eq(#vim.api.nvim_list_bufs(), before, "make_scratch: the buffer it made is not left behind")
  end

  -- A NUL byte in a line (a case title read from a file, a pasted name) is measured as the
  -- `^@` it is drawn as: `strdisplaywidth()` raises E976 on a NUL in a Lua string, so a single
  -- such line kept the whole list -- every `kit.select`, `kit.viewer` and `kit.note` goes through
  -- here -- from opening. The float is as wide as one with two plain characters in its place.
  do
    local make_scratch = require("lib.nvim.window.make_scratch")
    local nul = string.char(0)
    local opened, winid =
      pcall(make_scratch, { lines = { "ab" .. nul .. "cd", "x" }, border = "none" })
    H.ok(opened and winid ~= nil, "make_scratch: a line with a NUL opens: " .. tostring(winid))
    local width = opened and winid and vim.api.nvim_win_get_width(winid) or nil
    pcall(vim.api.nvim_win_close, winid, true)
    local control = make_scratch({ lines = { "abxxcd", "x" }, border = "none" })
    local control_width = vim.api.nvim_win_get_width(control)
    pcall(vim.api.nvim_win_close, control, true)
    H.eq(width, control_width, "make_scratch: the NUL counts two cells, as drawn")
  end

  -- footer / footer_pos reach the window config, spelled out like a title, and are left
  -- out when there is no frame to draw them on (Neovim 0.10 refuses a footer there).
  do
    local make_scratch = require("lib.nvim.window.make_scratch")
    local function frame_footer(win)
      local cfg = vim.api.nvim_win_get_config(win)
      return cfg.footer and cfg.footer[1] and cfg.footer[1][1] or nil, cfg.footer_pos
    end

    local winid = make_scratch({ lines = { "body" }, footer = " ? Help ", footer_pos = "right" })
    local text, pos = frame_footer(winid)
    H.eq(text, " ? Help ", "make_scratch: footer is on the frame")
    H.eq(pos, "right", "make_scratch: footer_pos is passed on")
    pcall(vim.api.nvim_win_close, winid, true)

    winid = make_scratch({ lines = { "body" }, footer = "a" .. string.char(27) .. "b" })
    H.eq((frame_footer(winid)), "a^[b", "make_scratch: a hostile footer is spelled out")
    pcall(vim.api.nvim_win_close, winid, true)

    for _, border in ipairs({ "none", "", { "", "", "", "", "", "", "", "" } }) do
      local opened, win = pcall(make_scratch, { lines = { "body" }, border = border, footer = "x" })
      H.ok(opened and win ~= nil, "make_scratch: an unframed float with a footer still opens")
      H.eq(
        opened and win and (frame_footer(win)) or nil,
        nil,
        "make_scratch: no footer without a border: " .. vim.inspect(border)
      )
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  -- A float title is spelled out, never drawn raw: `nvim_open_win` / `nvim_win_set_config` keep
  -- the control characters of a plain-string title as grid cells of their own, which the TUI
  -- writes to the terminal verbatim (an ESC ] 0 ; ... BEL in a pasted file name sets the
  -- terminal's window title). Every kit float titles itself through here.
  do
    local printable = require("lib.nvim.window.printable_title")
    local esc, bel = string.char(27), string.char(7)
    H.eq(printable("plain title"), "plain title", "printable_title: plain text is untouched")
    H.eq(
      printable("héllo › ✓"),
      "héllo › ✓",
      "printable_title: printable UTF-8 is untouched"
    )
    H.eq(printable(""), "", "printable_title: the empty title stays empty")
    H.eq(printable(nil), nil, "printable_title: nil stays nil")
    H.eq(
      printable("x" .. esc .. "[31my" .. bel .. "z"),
      "x^[[31my^Gz",
      "printable_title: ESC and BEL are spelled out"
    )
    H.eq(printable("a\tb\nc"), "a^Ib^@c", "printable_title: TAB and LF are not exempt")
    H.eq(printable("a" .. string.char(127) .. "b"), "a^?b", "printable_title: DEL is spelled out")
    H.eq(
      printable("a" .. string.char(194, 155) .. "b"),
      "a<9b>b",
      "printable_title: the C1 control CSI (U+009B) is spelled out"
    )
    H.eq(
      printable("a" .. string.char(155) .. "b"),
      "a<9b>b",
      "printable_title: ... so is the stray byte that Neovim would read as one"
    )
    H.eq(
      printable("a" .. string.char(0) .. "b"),
      "a^@b",
      "printable_title: a NUL is the ^@ it is drawn as, not an E976"
    )
    local chunks = { { "x" .. esc } }
    H.eq(printable(chunks), chunks, "printable_title: a chunk list is Neovim's to spell out")

    local function frame_title(win)
      local cfg = vim.api.nvim_win_get_config(win)
      return cfg.title and cfg.title[1] and cfg.title[1][1] or nil
    end
    local hostile = "my" .. esc .. "]0;evil" .. bel .. ".txt"
    local shown = "my^[]0;evil^G.txt"

    local make_scratch = require("lib.nvim.window.make_scratch")
    local winid = make_scratch({ lines = { "body" }, title = hostile })
    H.eq(frame_title(winid), shown, "make_scratch: a hostile title is spelled out")
    local set_title = require("lib.nvim.window.set_title")
    H.ok(set_title(winid, "Child"), "set_title: plain title applies")
    H.eq(frame_title(winid), "Child", "set_title: ... as it is")
    H.ok(set_title(winid, hostile), "set_title: a hostile title applies")
    H.eq(frame_title(winid), shown, "set_title: ... spelled out")
    H.ok(set_title(winid, hostile, { pos = "center" }), "set_title: ... with a position too")
    H.eq(frame_title(winid), shown, "set_title: ... spelled out with a position as well")
    pcall(vim.api.nvim_win_close, winid, true)

    -- The chooser rewrites its title in place when a menu walks into a submenu.
    local chooser = require("lib.nvim.ui.kit.chooser")
    chooser.open({ items = { "a", "b" }, title = "top", on_select = function() end })
    H.ok(chooser.is_open(), "chooser.set_items: fixture is open")
    H.ok(
      chooser.set_items({ items = { "c", "d" }, title = hostile }),
      "chooser.set_items: replaces the list"
    )
    local chooser_win
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(w)].filetype == "lib-kit-chooser" then
        chooser_win = w
      end
    end
    H.eq(frame_title(chooser_win), shown, "chooser.set_items: a hostile title is spelled out")
    chooser.close()
  end
end
