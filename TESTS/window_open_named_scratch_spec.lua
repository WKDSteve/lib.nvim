-- TESTS/window_open_named_scratch_spec.lua — lib.nvim.window.open_named_scratch:
-- a name finds only the buffer of exactly that name (no `bufnr()` pattern or
-- partial match).

return function(H)
  local eq, ok = H.eq, H.ok
  local open = require("lib.nvim.window.open_named_scratch")
  local api = vim.api

  local function lines_of(b)
    return table.concat(api.nvim_buf_get_lines(b, 0, -1, false), "|")
  end

  local made = {}
  -- Every call opens a split; close the others first so the headless screen
  -- never runs out of room (E36).
  local function o(name, lines, opts)
    vim.cmd("silent! only")
    local b, w = open(name, lines, opts)
    made[#made + 1] = b
    return b, w
  end

  vim.cmd("silent! only")

  -- The reported bug: `x.log` next to `x.log.1` got `x.log.1`'s buffer and
  -- overwrote its content (a unique partial match of `bufnr()`).
  local a = o("caselog://E:/c/x.log.1", { "one" })
  local b = o("caselog://E:/c/x.log", { "two" })
  ok(a ~= b, "a name that is a prefix of another gets its own buffer")
  eq(lines_of(a), "one", "the longer-named buffer keeps its content")
  eq(lines_of(b), "two", "the new buffer holds its own content")
  eq(api.nvim_buf_get_name(a), "caselog://E:/c/x.log.1", "longer name unchanged")
  eq(api.nvim_buf_get_name(b), "caselog://E:/c/x.log", "scheme:// name kept as given")

  -- The other way round: the longer name created second is no match either.
  local p = o("lib.nvim://deps/lsp", { "p" })
  local q = o("lib.nvim://deps/lsp.nvim", { "q" })
  ok(p ~= q, "a longer name does not reuse its prefix's buffer")
  eq(lines_of(p), "p", "prefix buffer untouched")

  -- Same name again: same buffer, content replaced, window reused.
  local _, w1 = o("caselog://E:/c/x.log", { "three" })
  vim.cmd("wincmd p")
  local b2, w2 = open("caselog://E:/c/x.log", { "three" })
  eq(w2, w1, "same name again: its open window is reused")
  eq(b2, b, "same name again: same buffer")
  eq(lines_of(b), "three", "same name again: content replaced")
  local wins = 0
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(w) == b then
      wins = wins + 1
    end
  end
  eq(wins, 1, "same name again: no second window")
  eq(api.nvim_get_current_win(), w2, "same name again: its window is focused")

  -- Pattern characters are literal: neither a wildcard here nor a match for
  -- a buffer they would match as a pattern.
  local lit = o("scratch://a[bc]*?%#.log", { "lit" })
  local abc = o("scratch://abc-x-y.log", { "abc" })
  ok(lit ~= abc, "[ ] * ? are not wildcards")
  eq(lines_of(lit), "lit", "the literal-named buffer keeps its content")
  eq(o("scratch://a[bc]*?%#.log", { "lit2" }), lit, "a name with [ * ? % # finds itself")
  eq(api.nvim_buf_get_name(lit), "scratch://a[bc]*?%#.log", "special characters kept as given")

  -- `%` and `#` alone mean the current and the alternate buffer to `bufnr()`.
  local cur = api.nvim_get_current_buf()
  local pct = o("scratch://%", { "pct" })
  ok(pct ~= cur, "`%` in a name is not the current buffer")
  local hash = o("scratch://#", { "hash" })
  ok(hash ~= pct and hash ~= cur, "`#` in a name is not the alternate buffer")

  -- A plain (non-URL) name: found again although Neovim stores it as an
  -- absolute path, and a name containing it is still no match.
  local rel = o("lib-ons-spec[1].txt", { "rel" })
  eq(
    api.nvim_buf_get_name(rel),
    vim.fn.fnamemodify("lib-ons-spec[1].txt", ":p"),
    "a plain name is stored as an absolute path"
  )
  eq(o("lib-ons-spec[1].txt", { "rel2" }), rel, "a plain name finds its buffer again")
  local rel_long = o("lib-ons-spec[1].txt.bak", { "bak" })
  ok(rel_long ~= rel, "a plain name's extension is no match")
  eq(lines_of(rel), "rel2", "the plain-named buffer keeps its content")

  -- After a `:cd` a plain name still finds its scratch buffer (Neovim keeps
  -- its short name), and the lookup neither creates a buffer nor fires
  -- BufNew/BufAdd (the full-name probe goes through `bufadd()`).
  -- `:only` runs before the counting starts: closing windows left by
  -- earlier specs of the shared run wipes their `bufhidden=wipe` buffers.
  local cwd = vim.fn.getcwd()
  vim.cmd("silent! only")
  local count = #api.nvim_list_bufs()
  local events = {}
  local au = api.nvim_create_autocmd({ "BufNew", "BufAdd", "BufWipeout", "OptionSet" }, {
    callback = function(ev)
      if ev.event ~= "OptionSet" or ev.match == "eventignore" then
        events[#events + 1] = ev.event .. ":" .. ev.match
      end
    end,
  })
  eq(open("lib-ons-spec[1].txt", { "rel3" }), rel, "found again without new buffers")
  vim.cmd.cd(vim.fn.fnameescape(vim.fn.fnamemodify(cwd, ":h")))
  local after_cd = open("lib-ons-spec[1].txt", { "rel4" })
  vim.cmd.cd(vim.fn.fnameescape(cwd))
  api.nvim_del_autocmd(au)
  eq(after_cd, rel, "a plain name finds its buffer after :cd")
  eq(#api.nvim_list_bufs(), count, "the lookup creates no buffer")
  eq(
    table.concat(events, ","),
    "",
    "the lookup fires no BufNew/BufAdd/BufWipeout and no OptionSet for eventignore"
  )
  eq(vim.bo[rel].buftype, "nofile", "the found buffer is still the scratch buffer")

  -- A leading `~` stays a folder name below the cwd, as Neovim stores it.
  local tilde = o("~lib-ons-spec/x.log", { "t" })
  eq(o("~lib-ons-spec/x.log", { "t2" }), tilde, "a name with a leading ~ finds itself")

  -- Neovim's own name equality: on Windows `\` equals `/`, and case folds
  -- under 'fileignorecase'. Such a spelling must find the buffer, or
  -- `nvim_buf_set_name` would refuse the new one with E95.
  if vim.fn.has("win32") == 1 then
    local bs = string.char(92)
    eq(o("caselog://E:" .. bs .. "c" .. bs .. "x.log", { "bs" }), b, "\\ equals / on Windows")
  end
  if vim.o.fileignorecase then
    eq(o("CASELOG://E:/C/X.LOG", { "case" }), b, "case folds under 'fileignorecase'")
  end

  -- A wiped buffer is gone: the name opens a fresh one.
  api.nvim_buf_delete(abc, { force = true })
  local abc2 = o("scratch://abc-x-y.log", { "again" })
  ok(api.nvim_buf_is_valid(abc2) and abc2 ~= abc, "a wiped name opens a new buffer")

  -- Bad names fail loudly.
  ok(not pcall(open, ""), "empty name raises")
  ok(not pcall(open, nil), "nil name raises")

  vim.cmd("silent! only")
  for _, x in ipairs(made) do
    pcall(api.nvim_buf_delete, x, { force = true })
  end
end
