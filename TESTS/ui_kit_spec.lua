-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read, a uv handle -- this file must crash and name it. The nil
-- guards LuaLS asks for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
-- TESTS/ui_kit_spec.lua — lib.nvim.ui.kit
-- Phase 1 (theme, surface, note), Phase 2 (toast, input, prompt),
-- Phase 3 (layout + picker, native chooser + hover_select shim, interactive picker),
-- Phase 4 (button-confirm), Phase 5 (viewer: read-only info panel),
-- Phase 6 (form: sequential multi-field prompt),
-- Phase 7 (live_input: debounced on_change as you type).

return function(H)
  local eq, ok = H.eq, H.ok
  local kit = require("lib.nvim.ui.kit")
  local theme = kit.theme

  --- wait_for(cond) -- poll `cond` every 10ms for up to `timeout` (default
  --- 1000ms) instead of sleeping a fixed duration and hoping some async
  --- effect (a debounce timer, a flash extmark, a menu action) landed
  --- inside that window. A flat `vim.wait(N)` always burns the full N ms
  --- and, worse, races real wall-clock scheduling jitter against whatever
  --- fixed N was guessed -- see the live_input section below for the flake
  --- that caused (ported fix from ui.nvim's TESTS/ui_kit_spec.lua).
  ---@param cond fun(): boolean
  ---@param timeout integer|nil
  ---@return nil
  local function wait_for(cond, timeout)
    vim.wait(timeout or 1000, cond, 10)
  end

  -- --------------------------------------------------------------- theme
  -- preset by name
  local double = theme.resolve("double")
  eq(double.border, "double", "preset name resolves border")

  -- default when nil
  local def = theme.resolve(nil)
  eq(def.border, "rounded", "nil resolves to default preset (rounded)")

  -- ascii preset flag
  eq(theme.resolve("ascii").ascii_border, true, "ascii preset sets ascii_border")

  -- presets differ beyond the border: distinct highlight link targets
  eq(
    theme.resolve("minimal").hl.selection,
    "Visual",
    "minimal preset has a distinct selection link"
  )
  eq(theme.resolve("double").hl.accent, "WarningMsg", "double preset has a distinct accent link")
  eq(theme.resolve("rounded").hl.normal, "NormalFloat", "rounded (default) keeps the base palette")

  -- partial override merges over the active default
  local custom = theme.resolve({ hl = { accent = "WarningMsg" } })
  eq(custom.border, "rounded", "override keeps default preset's border")
  eq(custom.hl.accent, "WarningMsg", "override replaces one hl key")
  eq(custom.hl.normal, "NormalFloat", "override leaves other hl keys intact")

  -- unknown preset name falls back to default
  eq(theme.resolve("does-not-exist").border, "rounded", "unknown preset -> default")

  -- setup registers a user preset and can switch the default
  kit.setup({ presets = { spec_preset = { border = "single" } } })
  eq(theme.resolve("spec_preset").border, "single", "user preset registered")
  ok(vim.tbl_contains(theme.presets(), "spec_preset"), "preset listed")

  -- setup() validates rather than silently dropping a bad option: an unknown
  -- key, a non-table `presets`, or a `default` naming no registered preset
  -- must all be reported, matching lib.config.setup()'s own contract.
  do
    local before_default = theme.default()
    local warnings = {}
    local real_notify = vim.notify
    vim.notify = function(msg, level)
      warnings[#warnings + 1] = { msg = msg, level = level }
    end

    ---@type any
    kit.setup({ default = "drak" })
    eq(theme.default(), before_default, "setup: unknown default preset name is not applied")
    eq(#warnings, 1, "setup: the unknown default preset is reported once")
    ok(
      warnings[1].msg:find("drak", 1, true) ~= nil,
      "setup: the report names the bad preset: " .. warnings[1].msg
    )
    eq(warnings[1].level, vim.log.levels.WARN, "setup: reported as a warning")

    ---@type any
    kit.setup({ presets = "not-a-table" })
    eq(#warnings, 2, "setup: a non-table presets value is reported once")

    ---@type any
    kit.setup({ preests = { foo = {} } })
    eq(#warnings, 3, "setup: an unknown top-level key is reported once")
    ok(
      warnings[3].msg:find("preests", 1, true) ~= nil,
      "setup: the report names the unknown key: " .. warnings[3].msg
    )

    kit.setup({ default = "double" })
    eq(theme.default(), "double", "setup: a known default preset is still applied")
    eq(#warnings, 3, "setup: a valid call reports nothing")

    kit.setup({ default = before_default })
    vim.notify = real_notify
  end

  -- --------------------------------------------------------------- surface
  local s = assert(
    kit.surface.open({ lines = { "hello", "world" }, theme = "double", title = "T" }),
    "surface.open returns a handle"
  )
  ok(s:is_valid(), "surface window is valid")
  eq(vim.api.nvim_buf_get_lines(s.bufnr, 0, -1, false)[1], "hello", "surface content set")

  -- winhighlight wired to the Kit* groups
  local winhl = vim.api.nvim_get_option_value("winhighlight", { win = s.winid })
  ok(winhl:find("NormalFloat:KitNormal", 1, true), "winhighlight maps NormalFloat->KitNormal")

  -- Kit* highlight groups were materialized
  ok(vim.fn.hlexists("KitNormal") == 1, "KitNormal highlight group defined")
  ok(vim.fn.hlexists("KitBorder") == 1, "KitBorder highlight group defined")

  -- set_lines respects the modifiable lock
  s:set_lines({ "changed" })
  eq(vim.api.nvim_buf_get_lines(s.bufnr, 0, -1, false)[1], "changed", "set_lines updates content")

  -- on_close fires exactly once
  local closes = 0
  s:on_close(function()
    closes = closes + 1
  end)
  s:close()
  ok(not s:is_valid(), "surface closed")
  eq(closes, 1, "on_close fired once")
  s:close() -- idempotent
  eq(closes, 1, "on_close not fired again on second close")

  -- --------------------------------------------------------------- note
  local n = assert(kit.note({ title = "Saved", message = "wrote 3 files" }), "note opens")
  ok(n:is_valid(), "note float is valid")
  eq(vim.api.nvim_buf_get_lines(n.bufnr, 0, -1, false)[1], "wrote 3 files", "note shows message")
  n:close()

  -- note accepts a multiline (array) message
  local n2 = assert(kit.note({ message = { "a", "b", "c" } }), "note (array) opens")
  eq(#vim.api.nvim_buf_get_lines(n2.bufnr, 0, -1, false), 3, "note renders array message lines")
  n2:close()

  -- -------------------------------------------------------------- viewer
  local vw = assert(kit.viewer({ title = "Info", lines = { "line 1", "line 2" } }), "viewer opens")
  ok(vw:is_valid(), "viewer float is valid")
  eq(#vim.api.nvim_buf_get_lines(vw.bufnr, 0, -1, false), 2, "viewer shows every line")
  eq(
    vim.api.nvim_get_option_value("modifiable", { buf = vw.bufnr }),
    false,
    "viewer buffer is read-only"
  )
  vw:close()

  -- viewer accepts `message` as an alias for `lines` (single string, split on \n)
  local v2 = assert(kit.viewer({ message = "a\nb\nc" }), "viewer (message alias) opens")
  eq(
    #vim.api.nvim_buf_get_lines(v2.bufnr, 0, -1, false),
    3,
    "viewer splits a string message on newlines"
  )
  v2:close()

  -- viewer closes itself the moment focus moves elsewhere (unlike note)
  local v3 = assert(kit.viewer({ message = "dismiss me" }), "viewer opens for focus-loss test")
  ok(v3:is_valid(), "viewer valid before losing focus")
  vim.cmd("new")
  vim.wait(50)
  ok(not v3:is_valid(), "viewer auto-closes on WinLeave")
  vim.cmd("only")

  -- close_on_focus_lost = false opts out of that behavior
  local v4 = assert(
    kit.viewer({ message = "stay open", close_on_focus_lost = false }),
    "viewer opens with close_on_focus_lost disabled"
  )
  vim.cmd("new")
  vim.wait(50)
  ok(v4:is_valid(), "viewer stays open when close_on_focus_lost = false")
  v4:close()
  vim.cmd("only")

  -- --------------------------------------------------------------- toast
  local toast_mod = require("lib.nvim.ui.kit.toast")
  toast_mod.clear()
  local t1 = assert(kit.toast({ message = "first", timeout = 0 }), "toast opens")
  ok(t1:is_valid(), "toast float valid")
  eq(toast_mod.active(), 1, "one toast active")
  local t2 = assert(kit.toast({ message = "second", timeout = 0 }), "second toast opens")
  eq(toast_mod.active(), 2, "two toasts stack")
  -- stacked below the first (higher row)
  local r1 = vim.api.nvim_win_get_config(t1.winid).row
  local r2 = vim.api.nvim_win_get_config(t2.winid).row
  ok(tonumber(tostring(r2)) > tonumber(tostring(r1)), "second toast sits below the first")
  toast_mod.clear()
  eq(toast_mod.active(), 0, "clear removes all toasts")

  -- --------------------------------------------------------------- input
  local inp = assert(kit.input({ prompt = "Name", default = "sb" }), "input opens")
  ok(inp:is_valid(), "input float valid")
  eq(vim.api.nvim_buf_get_lines(inp.bufnr, 0, 1, false)[1], "sb", "input seeded with default")
  vim.cmd("stopinsert")
  inp:close()

  -- input(secret = true): masked entry (vim.fn.inputsecret replacement)
  local sec_submitted
  local sec = assert(
    kit.input({
      prompt = "Password",
      secret = true,
      on_submit = function(v)
        sec_submitted = v
      end,
    }),
    "secret input opens"
  )
  eq(
    vim.api.nvim_get_option_value("conceallevel", { win = sec.winid }),
    2,
    "secret input sets conceallevel=2"
  )
  ok(
    vim.api.nvim_get_option_value("concealcursor", { win = sec.winid }):find("i") ~= nil,
    "secret input's concealcursor covers insert mode"
  )
  eq(
    vim.api.nvim_get_option_value("undolevels", { buf = sec.bufnr }),
    -1,
    "secret input disables undo on its buffer"
  )
  vim.api.nvim_buf_set_lines(sec.bufnr, 0, 1, false, { "hunter2" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = sec.bufnr })
  eq(
    vim.api.nvim_buf_get_lines(sec.bufnr, 0, 1, false)[1],
    "hunter2",
    "secret input's real buffer content is untouched -- only the rendering is masked"
  )
  local sec_ns = vim.api.nvim_get_namespaces()["lib_kit_input_secret_" .. sec.bufnr]
  local sec_marks = vim.api.nvim_buf_get_extmarks(sec.bufnr, sec_ns, 0, -1, { details = true })
  eq(#sec_marks, 7, "one conceal extmark per character of the typed secret")
  for _, m in ipairs(sec_marks) do
    eq(m[4].conceal, "*", "each character is concealed behind the default mask")
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  eq(sec_submitted, "hunter2", "on_submit still receives the real (unmasked) text")

  -- custom mask character
  local mask_surf = assert(
    kit.input({ secret = true, mask = "•", on_submit = function() end }),
    "secret input with custom mask opens"
  )
  vim.api.nvim_buf_set_lines(mask_surf.bufnr, 0, 1, false, { "ab" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = mask_surf.bufnr })
  local mask_ns = vim.api.nvim_get_namespaces()["lib_kit_input_secret_" .. mask_surf.bufnr]
  local mask_marks =
    vim.api.nvim_buf_get_extmarks(mask_surf.bufnr, mask_ns, 0, -1, { details = true })
  eq(mask_marks[1][4].conceal, "•", "opts.mask overrides the default '*' placeholder")
  mask_surf:close()

  -- plain (non-secret) input never sets conceallevel
  local plain_sec = assert(kit.input({ prompt = "x" }), "plain input opens")
  eq(
    vim.api.nvim_get_option_value("conceallevel", { win = plain_sec.winid }),
    0,
    "a plain input leaves conceallevel untouched"
  )
  vim.cmd("stopinsert")
  plain_sec:close()

  -- No auto-indent in a prompt (with or without buttons, secret or not): an indent
  -- Neovim added to a line opened by a paste is deleted by `stopinsert` under the
  -- cursor, which `park_cursor` leaves on a space of the button row.
  for _, o in ipairs({
    {},
    { buttons = { { id = "submit", label = "OK" } } },
    { secret = true },
  }) do
    local r = kit.input(o)
    for _, name in ipairs({ "autoindent", "smartindent", "cindent" }) do
      eq(vim.bo[r.bufnr][name], false, name .. " is off in a prompt")
    end
    vim.cmd("stopinsert")
    r:close()
  end

  -- input(completion = "file"): file-path completion (vim.fn.inputsecret's
  -- cousin, `completion = "file"` on the old vim.fn.input). `vim.fn.complete()`
  -- itself only works in real Insert mode, which this headless -l runner
  -- never actually enters (confirmed: even after startinsert!/feedkeys("A"),
  -- `vim.api.nvim_get_mode().mode` stays "n" -- there's no live redraw loop
  -- to carry the mode transition through), so the pum-interaction half of
  -- this feature isn't exercisable here. What IS tested: the buffer-local
  -- <Tab>/<S-Tab> mappings only exist when opts.completion is set, and the
  -- <CR>/<Esc> submit/cancel paths are unaffected by having it set.
  do
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    for _, name in ipairs({ "file_alpha.txt", "file_beta.txt" }) do
      local f = io.open(dir .. "/" .. name, "w")
      f:write("")
      f:close()
    end

    -- getcompletion() expands its argument as a Vim path pattern, so the raw
    -- tempname() is unusable as a prefix on Windows for two reasons:
    --   * it comes back in 8.3 short form ("C:\Users\STEFAN~1\..."), and the
    --     "~" is taken as a home-directory reference mid-pattern;
    --   * "\" is the pattern escape character, so backslash separators eat the
    --     component that follows them.
    -- fs_realpath() gives the long name, and forward slashes are accepted as
    -- separators on both platforms -- on Linux/macOS both steps are no-ops.
    local comp_dir = (vim.uv or vim.loop).fs_realpath(dir) or dir
    comp_dir = comp_dir:gsub("\\", "/")

    -- getcompletion() itself (the piece trigger_completion drives) works
    -- headless -- no Insert mode needed for this call.
    local matches = vim.fn.getcompletion(comp_dir .. "/fi", "file")
    eq(#matches, 2, "getcompletion(file) finds both real files under the prefix")

    local comp =
      assert(kit.input({ prompt = "Path", completion = "file" }), "completion input opens")
    local tab_map = vim.fn.maparg("<Tab>", "i", false, true)
    eq(tab_map.buffer, 1, "opts.completion registers a buffer-local <Tab> mapping")
    -- Not an <expr> mapping: complete() raises E565 under the textlock of one, and the
    -- pcall around it hid that (ui.nvim's TESTS/ui_kit_input_ui_spec.lua opens the popup).
    eq(tab_map.expr, 0, "<Tab> is no <expr> mapping")
    local stab_map = vim.fn.maparg("<S-Tab>", "i", false, true)
    eq(stab_map.buffer, 1, "opts.completion registers a buffer-local <S-Tab> mapping")

    -- What <Tab> hands to getcompletion(): the whitespace-delimited run that ends
    -- at the cursor, and never one with a backtick in it -- getcompletion() runs
    -- a backtick span through 'shell' (SEC-34). The two vim.fn calls are stubbed
    -- (the popup needs Insert mode); only the fragment is read.
    do
      local real_getcompletion, real_complete = vim.fn.getcompletion, vim.fn.complete
      local seen_frag
      vim.fn.getcompletion = function(frag)
        seen_frag = frag
        return { "x" }
      end
      vim.fn.complete = function() end
      local function press_tab(line, col)
        seen_frag = nil
        vim.api.nvim_buf_set_lines(comp.bufnr, 0, -1, false, { line })
        vim.api.nvim_win_set_cursor(comp.winid, { 1, col })
        tab_map.callback()
        return seen_frag
      end
      local ok_run, err = pcall(function()
        eq(press_tab("cd /etc/pas", 11), "/etc/pas", "the fragment is the run before the cursor")
        eq(press_tab("`touch${IFS}x`", 14), nil, "a backtick fragment never reaches getcompletion")
        eq(press_tab("cd a`b", 6), nil, "a backtick anywhere in the fragment blocks it")
        eq(
          press_tab("`x` /etc/pas", 12),
          "/etc/pas",
          "a backtick before the whitespace is not part of it"
        )
        eq(press_tab("ab`cd", 2), "ab", "a backtick behind the cursor blocks nothing")
      end)
      vim.fn.getcompletion, vim.fn.complete = real_getcompletion, real_complete
      assert(ok_run, err)
    end

    -- <CR>/<Esc> still submit/cancel normally (pum never opens here, so this
    -- exercises the same finish() path as plain kit.input).
    local comp_submitted
    kit.input({
      prompt = "Path",
      completion = "file",
      default = "seed",
      on_submit = function(v)
        comp_submitted = v
      end,
    })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    eq(comp_submitted, "seed", "<CR> still submits normally when completion is set (pum closed)")

    local plain_no_completion = assert(kit.input({ prompt = "x" }), "no-completion input opens")
    local plain_tab_map = vim.fn.maparg("<Tab>", "i", false, true)
    eq(plain_tab_map.buffer, 0, "a plain input registers no buffer-local <Tab> mapping")
    vim.cmd("stopinsert")
    plain_no_completion:close()
    comp:close()
  end

  -- --------------------------------------------------------------- live_input
  -- `TextChangedI`/`TextChanged` don't fire for API-driven buffer edits in
  -- this headless runner (no real insert-mode session), so tests fire them
  -- explicitly via nvim_exec_autocmds after editing the buffer -- exactly
  -- the event live_input's own debounce timer listens for.
  local li_changes = {}
  local li = assert(
    kit.live_input({
      prompt = "Search",
      debounce = 20,
      on_change = function(q)
        table.insert(li_changes, q)
      end,
    }),
    "live_input opens"
  )
  ok(li:is_valid(), "live_input float valid")
  vim.api.nvim_buf_set_lines(li.bufnr, 0, 1, false, { "h" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = li.bufnr })
  wait_for(function()
    return #li_changes >= 1
  end)
  vim.api.nvim_buf_set_lines(li.bufnr, 0, 1, false, { "he" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = li.bufnr })
  wait_for(function()
    return #li_changes >= 2
  end)
  eq(table.concat(li_changes, ","), "h,he", "on_change fires once per debounce window, in order")
  li:close()

  -- rapid edits within one debounce window coalesce into a single on_change
  -- call carrying only the final value.
  local li_coalesced = {}
  local li2 = assert(
    kit.live_input({
      debounce = 50,
      on_change = function(q)
        table.insert(li_coalesced, q)
      end,
    }),
    "live_input (coalescing) opens"
  )
  vim.api.nvim_buf_set_lines(li2.bufnr, 0, 1, false, { "h" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = li2.bufnr })
  vim.api.nvim_buf_set_lines(li2.bufnr, 0, 1, false, { "he" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = li2.bufnr })
  vim.api.nvim_buf_set_lines(li2.bufnr, 0, 1, false, { "hel" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = li2.bufnr })
  wait_for(function()
    return #li_coalesced >= 1
  end)
  eq(#li_coalesced, 1, "rapid edits within the debounce window fire on_change only once")
  eq(li_coalesced[1], "hel", "the coalesced on_change carries the final value")
  li2:close()

  -- row/col are forwarded to the surface (anchoring next to a host window,
  -- e.g. filetree.nvim's live_search bar at the bottom of the tree window),
  -- overriding the default editor-centered placement.
  local li_pos = assert(
    kit.live_input({
      relative = "editor",
      row = 3,
      col = 5,
      on_change = function() end,
    }),
    "live_input (row/col) opens"
  )
  local win_cfg = vim.api.nvim_win_get_config(li_pos.winid)
  eq(win_cfg.row, 3, "row is forwarded to the surface")
  eq(win_cfg.col, 5, "col is forwarded to the surface")
  li_pos:close()

  -- <CR> submits the current query and closes
  local li_submitted
  kit.live_input({
    default = "seed",
    on_change = function() end,
    on_submit = function(q)
      li_submitted = q
    end,
  })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  eq(li_submitted, "seed", "<CR> submits the current query")

  -- <Esc> cancels without submitting
  local li_cancelled, li_wrongly_submitted
  local li3 = assert(
    kit.live_input({
      on_change = function() end,
      on_submit = function()
        li_wrongly_submitted = true
      end,
      on_cancel = function()
        li_cancelled = true
      end,
    }),
    "live_input (cancel) opens"
  )
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  ok(li_cancelled, "<Esc> fires on_cancel")
  ok(not li_wrongly_submitted, "<Esc> never fires on_submit")
  ok(not li3:is_valid(), "<Esc> closes the float")

  -- routed via kit.popup({ type = "live_input" })
  local li_popup_changes = {}
  local li4 = assert(
    kit.popup({
      type = "live_input",
      debounce = 20,
      on_change = function(q)
        table.insert(li_popup_changes, q)
      end,
    }),
    'kit.popup({ type = "live_input" }) opens'
  )
  vim.api.nvim_buf_set_lines(li4.bufnr, 0, 1, false, { "x" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = li4.bufnr })
  wait_for(function()
    return #li_popup_changes >= 1
  end)
  eq(li_popup_changes[1], "x", 'kit.popup({ type = "live_input" }) routes to live_input')
  li4:close()

  -- --------------------------------------------------------------- form
  -- Buffer edits + <CR>/<Esc> feedkeys stand in for typing: this headless
  -- runner never actually enters insert mode (no UI attached to redraw into
  -- it), but the input component binds <CR>/<Esc> in both "i" and "n" modes,
  -- so driving it from Normal mode exercises the same finish() path.
  local function submit_field(text)
    vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, 1, false, { text })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  end
  local function skip_field()
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  end

  -- full submit: both fields typed, on_submit gets a keyed table
  local form_values
  local form_surf = assert(
    kit.form({
      fields = {
        { name = "a", label = "A", default = "defA" },
        { name = "b", label = "B", default = "defB" },
      },
      on_submit = function(values)
        form_values = values
      end,
    }),
    "form opens (returns the first field's surface)"
  )
  ok(form_surf:is_valid(), "form's first field is a real surface")
  eq(
    vim.api.nvim_buf_get_lines(form_surf.bufnr, 0, 1, false)[1],
    "defA",
    "first field seeded with its default"
  )
  submit_field("hello")
  submit_field("world")
  eq(form_values.a, "hello", "form collects the first field under its name")
  eq(form_values.b, "world", "form collects the second field under its name")

  -- optional fields: <Esc> skips (keeps the default) and the form continues
  local skip_values
  kit.form({
    fields = {
      { name = "a", label = "A", default = "" },
      { name = "b", label = "B", default = "keepme" },
    },
    on_submit = function(values)
      skip_values = values
    end,
  })
  skip_field() -- skip "a"
  skip_field() -- skip "b" -> keeps default
  eq(skip_values.a, "", "skipping an optional field with no default -> empty string")
  eq(skip_values.b, "keepme", "skipping an optional field keeps its default")

  -- required field: <Esc> aborts the whole form, on_cancel fires, no on_submit
  local aborted, abort_submitted
  kit.form({
    fields = {
      { name = "a", label = "A", default = "defA" },
      { name = "b", label = "B", default = "defB", required = true },
    },
    on_submit = function()
      abort_submitted = true
    end,
    on_cancel = function()
      aborted = true
    end,
  })
  submit_field("first ok") -- advance past the optional field
  skip_field() -- <Esc> on the required field -> abort
  ok(aborted, "on_cancel fires when <Esc> hits a required field")
  ok(not abort_submitted, "on_submit never fires once the form was aborted")

  -- routed via kit.popup({ type = "form" })
  local popup_values
  kit.popup({
    type = "form",
    fields = { { name = "only", label = "Only", default = "x" } },
    on_submit = function(values)
      popup_values = values
    end,
  })
  submit_field("via-popup")
  eq(popup_values.only, "via-popup", 'kit.popup({ type = "form" }) routes to the form component')

  -- --------------------------------------------------------------- chooser (native select)
  local chooser = require("lib.nvim.ui.kit.chooser")

  -- single select: submit fires on_select(item, idx) and closes
  local picked_item, picked_idx
  kit.select({
    selection = { "alpha", "beta", "gamma" },
    on_select = function(it, i)
      picked_item, picked_idx = it, i
    end,
  })
  ok(chooser.is_open(), "chooser opened")
  chooser.move(1) -- alpha -> beta
  eq(chooser.current_index(), 2, "move advances selection")
  chooser.submit()
  eq(picked_item, "beta", "single-select returned the highlighted item")
  eq(picked_idx, 2, "single-select returned its index")
  ok(not chooser.is_open(), "chooser closed after submit")

  -- move wraps around
  kit.select({ selection = { "a", "b" }, on_select = function() end })
  chooser.move(-1) -- from line 1 wraps to line 2
  eq(chooser.current_index(), 2, "move(-1) wraps to the last row")
  chooser.close()

  -- multi-select: toggle marks then submit returns (items[], indices[])
  local multi_items, multi_idx
  kit.select({
    selection = { "one", "two", "three" },
    multi = true,
    on_select = function(items, idxs)
      multi_items, multi_idx = items, idxs
    end,
  })
  chooser.toggle() -- mark line 1
  chooser.move(2) -- to line 3
  chooser.toggle() -- mark line 3
  chooser.submit()
  eq(table.concat(multi_items, ","), "one,three", "multi-select returned marked items in order")
  eq(table.concat(multi_idx, ","), "1,3", "multi-select returned marked indices")

  -- theme selection highlight is wired
  ok(vim.fn.hlexists("KitSelection") == 1, "KitSelection group defined for the chooser")

  -- initial_index: lands the cursor on a specific item at open time (e.g.
  -- restoring position across a close+reopen refresh), instead of item 1.
  kit.select({
    selection = { "a", "b", "c" },
    initial_index = 3,
    on_select = function() end,
  })
  eq(chooser.current_index(), 3, "initial_index lands the cursor on the requested item")
  chooser.close()

  -- out-of-range initial_index falls back to item 1 rather than erroring.
  kit.select({
    selection = { "a", "b" },
    initial_index = 99,
    on_select = function() end,
  })
  eq(chooser.current_index(), 1, "out-of-range initial_index falls back to item 1")
  chooser.close()

  -- kit.chooser is exposed directly, and current_item() reads the
  -- highlighted item's original value without submitting/closing -- for a
  -- consumer building extra actions on top of the picker (e.g.
  -- recommender.nvim's yank-without-closing).
  ok(kit.chooser ~= nil, "kit.chooser is exposed publicly")
  kit.select({ selection = { "x", "y" }, on_select = function() end })
  eq(kit.chooser.current_item(), "x", "current_item() reads the highlighted item")
  kit.chooser.move(1)
  eq(kit.chooser.current_item(), "y", "current_item() follows navigation")
  kit.chooser.close()
  eq(kit.chooser.current_item(), nil, "current_item() is nil once closed")

  -- --------------------------------------------------------------- chooser: rich items
  -- Multi-line entries with per-span highlights (recommender.nvim's
  -- motivating use case: a 3-line suggestion with per-column highlight
  -- groups) mixed with a plain string, exercising navigation-by-item,
  -- click-anywhere-in-an-item resolution, and highlight placement.
  do
    local rich = {
      lines = { "-> my_chain (3 hits)", "  local alias = my_chain", "" },
      highlights = {
        { line = 0, col_start = 0, col_end = 2, hl_group = "Special" },
        { line = 1, hl_group = "Statement" }, -- col_end omitted -> whole line
      },
    }
    local plain = "plain item"

    local picked, picked_at
    local surf = kit.select({
      items = { rich, plain },
      on_select = function(it, i)
        picked, picked_at = it, i
      end,
    })
    ok(surf ~= nil, "chooser opens with a rich item mixed in")
    eq(
      vim.api.nvim_buf_line_count(surf.bufnr),
      4,
      "buffer has rich item's 3 lines + plain item's 1 line"
    )
    eq(chooser.current_index(), 1, "opens with logical item 1 (the rich item) current")

    -- Move the raw cursor to the rich item's 2nd line (not its anchor row) --
    -- current_index() must still resolve to item 1, the way a mouse click
    -- landing anywhere in a multi-line item should.
    vim.api.nvim_win_set_cursor(surf.winid, { 2, 0 })
    eq(chooser.current_index(), 1, "cursor on a non-anchor row still resolves to its item")

    chooser.move(1) -- item 1 (rich, 3 lines) -> item 2 (plain, 1 line)
    eq(chooser.current_index(), 2, "move(1) advances by logical item, not raw line")
    eq(vim.api.nvim_win_get_cursor(surf.winid)[1], 4, "cursor lands on item 2's buffer row (4)")

    chooser.move(-1) -- back to item 1
    eq(vim.api.nvim_win_get_cursor(surf.winid)[1], 1, "move(-1) lands back on item 1's anchor row")

    chooser.submit()
    eq(picked, rich, "submit() returns the original rich item table, not a stringified copy")
    eq(picked_at, 1, "submit() returns the logical item index")
  end

  do
    -- Highlight extmarks land on the right row/columns.
    local rich = {
      lines = { "abcdef" },
      highlights = { { line = 0, col_start = 1, col_end = 3, hl_group = "Special" } },
    }
    local surf = kit.select({ items = { rich }, on_select = function() end })
    local marks = vim.api.nvim_buf_get_extmarks(surf.bufnr, -1, 0, -1, { details = true })
    local found = false
    for _, m in ipairs(marks) do
      local row, col, details = m[2], m[3], m[4]
      if row == 0 and col == 1 and details.end_col == 3 and details.hl_group == "Special" then
        found = true
      end
    end
    ok(found, "rich item's highlight extmark placed at the declared row/col span")
    chooser.close()
  end

  do
    -- Multi-select marks a rich item's whole row span, not just its anchor row.
    local rich = { lines = { "line one", "line two" } }
    local chosen
    kit.select({
      items = { rich, "b" },
      multi = true,
      on_select = function(items)
        chosen = items
      end,
    })
    chooser.toggle() -- mark the rich item (currently item 1)
    chooser.submit()
    eq(#chosen, 1, "multi-select: one item marked")
    eq(chosen[1], rich, "multi-select: the marked rich item is returned whole")
  end

  -- --------------------------------------------------------------- layout (pure)
  local geo = kit.layout.compute(kit.layout.templates.picker.spec)
  ok(geo.slots.prompt ~= nil, "picker layout has a prompt slot")
  ok(geo.slots.results ~= nil, "picker layout has a results slot")
  ok(geo.slots.preview ~= nil, "picker layout has a preview slot")

  -- prompt spans the full outer width; results+preview are narrower halves
  ok(geo.slots.prompt.width >= geo.slots.results.width, "prompt wider than results")
  ok(geo.slots.results.width < geo.slots.preview.width, "results (0.4) narrower than preview (0.6)")

  -- prompt sits above the results/preview row
  ok(geo.slots.prompt.row < geo.slots.results.row, "prompt above results")
  eq(geo.slots.results.row, geo.slots.preview.row, "results and preview share a row")

  -- gap = 0, border = 1 -> preview.col == results.col + results.width + 2
  eq(
    geo.slots.preview.col,
    geo.slots.results.col + geo.slots.results.width + 2,
    "results and preview align edge-to-edge (shared border, no gap)"
  )

  -- --------------------------------------------------------------- layout (mount)
  local group =
    assert(kit.layout.template("picker", { theme = "double" }), "picker template mounts")
  ok(group.slots.prompt:is_valid(), "prompt slot surface valid")
  ok(group.slots.results:is_valid(), "results slot surface valid")
  ok(group.slots.preview:is_valid(), "preview slot surface valid")
  -- closing the group closes every slot
  group.close()
  ok(not group.slots.results:is_valid(), "group.close() closed the results slot")
  ok(not group.slots.preview:is_valid(), "group.close() closed the preview slot")

  -- unknown template returns nil without throwing
  eq(kit.layout.template("nope"), nil, "unknown template returns nil")

  -- --------------------------------------------------------------- picker (interactive)
  local submit_idx, submit_text
  local p = assert(
    kit.picker({
      on_submit = function(i, t)
        submit_idx, submit_text = i, t
      end,
    }),
    "picker opens"
  )
  ok(p.slots.prompt:is_valid(), "picker prompt slot valid")
  ok(p.slots.results:is_valid(), "picker results slot valid")
  ok(p.slots.preview:is_valid(), "picker preview slot valid")

  -- caller fills the results slot (as on_change would), selection resets to top
  p.set_results({ "match-1", "match-2", "match-3" })
  p.move(1) -- to match-2
  p.submit()
  eq(submit_idx, 2, "picker submit reports the highlighted index")
  eq(submit_text, "match-2", "picker submit reports the highlighted line text")
  vim.cmd("stopinsert")

  -- item mode: format with highlights, word filter, marks, current/marked, set_items, preview, caller keys
  do
    local function same(a, b, msg)
      eq(vim.inspect(a), vim.inspect(b), msg)
    end
    local picked, previewed, closed_called, keyed
    local list = {
      { id = 1, text = "alpha one" },
      { id = 2, text = "beta two" },
      { id = 3, text = "alpha three" },
    }
    local ip = assert(
      kit.picker({
        items = list,
        key = function(item)
          return item.id
        end,
        format = function(item)
          return { { item.text, "Title" }, { " #" .. item.id, "Comment" } }
        end,
        preview = function(item, surface)
          previewed = item.id
          surface:set_lines({ "preview " .. item.id })
        end,
        keys = {
          ["<M-x>"] = function(h)
            keyed = h.current().id
          end,
        },
        on_submit = function(idx, _, item)
          picked = { idx, item.id }
        end,
        on_close = function()
          closed_called = true
        end,
      }),
      "item picker opens"
    )
    local lines = vim.api.nvim_buf_get_lines(ip.slots.results.bufnr, 0, -1, false)
    same(
      lines,
      { "  alpha one #1", "  beta two #2", "  alpha three #3" },
      "rows are the formatted items"
    )
    eq(previewed, 1, "the preview follows the cursor item")
    -- the typed words filter (every word, any case)
    vim.api.nvim_buf_set_lines(ip.slots.prompt.bufnr, 0, -1, false, { "ALPHA th" })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = ip.slots.prompt.bufnr })
    vim.wait(30000, function()
      return #vim.api.nvim_buf_get_lines(ip.slots.results.bufnr, 0, -1, false) == 1
    end)
    same(vim.api.nvim_buf_get_lines(ip.slots.results.bufnr, 0, -1, false), { "  alpha three #3" })
    eq(ip.current().id, 3)
    vim.api.nvim_buf_set_lines(ip.slots.prompt.bufnr, 0, -1, false, { "" })
    ip.set_items(list) -- everything again; the cursor item stays
    ip.move(-1)
    ip.toggle_mark() -- marks the current item (row 2 now: beta) and moves down
    eq(#ip.marked(), 1, "one marked item")
    ip.set_items({ list[2], list[3] }, { cursor_key = 3 })
    eq(ip.marked()[1].id, 2, "a mark survives set_items")
    eq(ip.current().id, 3, "cursor_key puts the cursor back")
    ip.set_items({ list[1] })
    eq(#ip.marked(), 0, "the mark of an item that is gone is dropped")
    eq(ip.current().id, 1)
    ip.submit()
    same(picked, { 1, 1 }, "submit reports the item")
    ok(closed_called and ip.is_closed(), "on_close ran")
    ok(keyed == nil)
    vim.cmd("stopinsert")
  end

  -- item mode, review round: no stale list after a fast keystroke, headings, failing preview, marks in place
  do
    local rows = {}
    for i = 1, 50 do
      rows[#rows + 1] = { id = i, text = "T-" .. i }
    end
    table.insert(rows, 1, { id = 0, text = "HEADING", heading = true })
    local fail_preview = false
    local submitted
    local rp = assert(kit.picker({
      items = rows,
      key = function(item)
        return item.id
      end,
      selectable = function(item)
        return not item.heading
      end,
      format = function(item)
        return { { item.text, "Title" } }
      end,
      preview = function(item, surface)
        if fail_preview then
          error("boom")
        end
        surface:set_lines({ "preview " .. item.id })
      end,
      on_submit = function(_, _, item)
        submitted = item.id
      end,
    }))
    eq(
      rp.current().id,
      1,
      "the cursor starts on the first row that can be acted on, not on the heading"
    )
    rp.move(-1) -- wraps to the last row, never rests on the heading
    ok(rp.current().id ~= 0)
    -- a fast keystroke: the list is flushed before it is read
    vim.api.nvim_buf_set_lines(rp.slots.prompt.bufnr, 0, -1, false, { "T-42" })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = rp.slots.prompt.bufnr })
    eq(rp.current().id, 42, "current() sees the typed query at once")
    -- marks flip in place
    local before = #vim.api.nvim_buf_get_lines(rp.slots.results.bufnr, 0, -1, false)
    rp.toggle_mark()
    eq(#rp.marked(), 1)
    eq(#vim.api.nvim_buf_get_lines(rp.slots.results.bufnr, 0, -1, false), before)
    eq(vim.api.nvim_buf_get_lines(rp.slots.results.bufnr, 0, 1, false)[1], "+ T-42")
    -- a preview that raises says so instead of keeping the old text
    vim.api.nvim_buf_set_lines(rp.slots.prompt.bufnr, 0, -1, false, { "" })
    rp.set_items(rows)
    fail_preview = true
    rp.move(1)
    ok(
      vim.api
        .nvim_buf_get_lines(rp.slots.preview.bufnr, 0, 1, false)[1]
        :find("preview failed", 1, true) ~= nil
    )
    -- nothing to submit: an empty list keeps the picker open
    vim.api.nvim_buf_set_lines(rp.slots.prompt.bufnr, 0, -1, false, { "no-such-text" })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = rp.slots.prompt.bufnr })
    rp.submit()
    ok(not rp.is_closed() and submitted == nil, "an empty list stays open")
    rp.close()
    vim.cmd("stopinsert")
  end

  -- plain mode falls back to a bare template mount
  local plain = assert(kit.picker({ prompt = "plain" }), "plain picker mounts")
  ok(plain.slots.prompt:is_valid(), "plain picker has slots")
  plain.close()
  vim.cmd("stopinsert")

  -- no augroup is left behind per opened picker, whichever way it closes
  do
    local function has_group(name)
      return (pcall(vim.api.nvim_get_autocmds, { group = name }))
    end
    local own = assert(kit.picker({ items = { "a", "b" }, on_submit = function() end }))
    local own_win = own.slots.prompt.winid
    ok(has_group("lib_kit_picker_" .. own_win), "an open picker has its prompt augroup")
    own.close()
    vim.cmd("stopinsert")
    ok(not has_group("lib_kit_picker_" .. own_win), "close(): the prompt augroup is gone")
    ok(not has_group("lib_kit_picker_resize_" .. own_win), "close(): the resize augroup is gone")

    local ext = assert(kit.picker({ items = { "a", "b" }, on_submit = function() end }))
    local ext_win = ext.slots.prompt.winid
    vim.api.nvim_win_close(ext_win, true) -- a plain `:close`, none of the picker's own keys
    vim.cmd("stopinsert")
    ok(
      not has_group("lib_kit_picker_" .. ext_win),
      "closed from outside: the prompt augroup is gone"
    )
    ok(
      not has_group("lib_kit_picker_resize_" .. ext_win),
      "closed from outside: the resize augroup is gone"
    )
  end

  -- --------------------------------------------------------------- confirm (buttons)
  local confirm = require("lib.nvim.ui.kit.confirm")

  -- default Yes/No -> boolean; focus starts on Yes
  local yn
  local cs = assert(
    kit.confirm({
      question = "Delete 3 files?",
      on_answer = function(a)
        yn = a
      end,
    }),
    "confirm opens"
  )
  ok(cs:is_valid(), "confirm float valid")
  eq(confirm.current_focus(), 1, "focus starts on the first button")
  confirm.confirm() -- Yes
  eq(yn, true, "default confirm: Yes -> true")

  -- move to No, confirm -> false
  kit.confirm({
    question = "Sure?",
    on_answer = function(a)
      yn = a
    end,
  })
  confirm.move(1) -- Yes -> No
  eq(confirm.current_focus(), 2, "move advances focus")
  confirm.confirm()
  eq(yn, false, "default confirm: No -> false")

  -- move wraps around
  kit.confirm({ question = "Wrap?", on_answer = function() end })
  confirm.move(-1) -- from Yes wraps to No
  eq(confirm.current_focus(), 2, "move(-1) wraps to the last button")
  confirm.close()

  -- custom choices -> chosen string
  local choice
  kit.confirm({
    question = "Pick",
    choices = { "Keep", "Discard", "Cancel" },
    on_answer = function(c)
      choice = c
    end,
  })
  confirm.move(1) -- Keep -> Discard
  confirm.confirm()
  eq(choice, "Discard", "custom confirm returns the chosen label")

  -- cancel: default -> false, custom -> nil
  kit.confirm({
    question = "X",
    on_answer = function(a)
      yn = a
    end,
  })
  confirm.cancel()
  eq(yn, false, "cancel on default confirm -> false")

  local custom_cancel = "sentinel"
  kit.confirm({
    question = "Y",
    choices = { "A", "B" },
    on_answer = function(a)
      custom_cancel = a
    end,
  })
  confirm.cancel()
  eq(custom_cancel, nil, "cancel on custom confirm -> nil")

  -- routed via prompt(answer_type = "confirm", layout = "buttons")
  kit.prompt({
    question = "Route?",
    answer_type = "confirm",
    layout = "buttons",
    on_answer = function() end,
  })
  ok(confirm.is_open(), "prompt layout=buttons opens the button-confirm")
  confirm.close()

  -- the default list (no layout, no choices) answers to y and n like the button dialog
  for _, case in ipairs({ { key = "y", want = true }, { key = "n", want = false } }) do
    local got = "unset"
    kit.prompt({
      question = "List?",
      answer_type = "confirm",
      on_answer = function(a)
        got = a
      end,
    })
    local chooser_mod = require("lib.nvim.ui.kit.chooser")
    ok(chooser_mod.is_open(), "prompt without layout opens the list chooser")
    vim.api.nvim_feedkeys(case.key, "x", false)
    eq(got, case.want, "prompt list: " .. case.key .. " answers " .. tostring(case.want))
    ok(not chooser_mod.is_open(), "prompt list: " .. case.key .. " closes the list")
  end

  -- a custom choice list has no y/n pair
  kit.prompt({
    question = "Custom?",
    answer_type = "confirm",
    choices = { "A", "B" },
    on_answer = function() end,
  })
  local pressed = vim.fn.maparg("y", "n", false, true)
  ok(pressed.buffer ~= 1, "custom list: y is not mapped in its buffer")
  require("lib.nvim.ui.kit.chooser").close()

  -- focused button carries the selection highlight
  ok(vim.fn.hlexists("KitSelection") == 1, "KitSelection group defined for confirm focus")

  -- --------------------------------------------------------------- menu
  local ran
  local ms = assert(
    kit.menu({
      title = "Actions",
      items = {
        {
          label = "Rename",
          action = function()
            ran = "rename"
          end,
        },
        {
          label = "Delete",
          action = function()
            ran = "delete"
          end,
        },
      },
    }),
    "menu opens"
  )
  ok(ms:is_valid(), "menu float valid")
  -- Every row carries a pad column at each edge, so no label sits flush
  -- against the border, and every row fills the window exactly -- here the
  -- window is wider than the labels because the frame title "Actions" needs
  -- the room, and the surplus goes to the label column rather than being left
  -- as a ragged gap before the right border.
  eq(vim.api.nvim_buf_get_lines(ms.bufnr, 0, 1, false)[1], " Rename  ", "menu pads the item labels")
  eq(
    vim.fn.strdisplaywidth(vim.api.nvim_buf_get_lines(ms.bufnr, 0, 1, false)[1]),
    vim.api.nvim_win_get_width(ms.winid),
    "menu row fills a title-widened window exactly"
  )
  -- Pick the second item -> runs its action, but not instantly: the picked
  -- row is lit for a beat first, the way a button shows its press. The delay
  -- is the feature and not an artefact -- a leaf action closes the menu, so a
  -- flash painted at the same moment would never be on screen to see.
  chooser.move(1)
  chooser.submit()
  eq(ran, nil, "menu holds the action back while the picked row is lit")
  ok(vim.fn.hlexists("KitFlash") == 1, "KitFlash group defined for the pick acknowledgement")
  local flash_ns = vim.api.nvim_get_namespaces()["lib_kit_chooser_flash"]
  ok(flash_ns ~= nil, "chooser owns a namespace for the pick acknowledgement")
  eq(
    #vim.api.nvim_buf_get_extmarks(ms.bufnr, flash_ns, 0, -1, {}),
    1,
    "menu lights exactly the row that was picked"
  )
  wait_for(function()
    return ran ~= nil
  end)
  eq(ran, "delete", "menu runs the picked item's action")

  -- Row geometry: the window is exactly as wide as a padded row (no slack
  -- make_scratch would otherwise put entirely on the right), separators are
  -- indented and stop short of the right edge, and an `rtxt` hint ends one
  -- column before the border rather than against it.
  local gs = assert(
    kit.menu({
      items = {
        { name = "Copy", rtxt = "yy", cmd = function() end },
        { name = "separator" },
        { name = "Delete", rtxt = "dd", cmd = function() end },
      },
    }),
    "menu with rtxt opens"
  )
  local grows = vim.api.nvim_buf_get_lines(gs.bufnr, 0, -1, false)
  local gwidth = vim.api.nvim_win_get_width(gs.winid)
  eq(vim.fn.strdisplaywidth(grows[1]), gwidth, "menu row fills the window width exactly")
  eq(grows[1]:sub(1, 1), " ", "menu row starts with a pad column")
  eq(grows[1]:sub(-1), " ", "menu row ends with a pad column")
  eq(grows[2]:sub(1, 1), " ", "menu separator is indented")
  eq(
    vim.fn.strdisplaywidth(grows[2]),
    gwidth - 1,
    "menu separator stops one column short of the right edge"
  )
  chooser.close()

  -- Icons are a column, not a prefix: an item with one and an item without
  -- start their labels in the same screen column. This is the whole reason
  -- `icon` is a field -- a glyph inside `label` is just text, and indents its
  -- row past every other. A label that arrives with stray leading space (a
  -- real bug two contributors shipped) is trimmed rather than honoured.
  local is = assert(
    kit.menu({
      items = {
        { name = "Alpha", icon = "A", cmd = function() end, rtxt = "<leader>a" },
        { name = "  Beta", cmd = function() end },
        { name = "Gamma", items = { { name = "Leaf", cmd = function() end } } },
      },
    }),
    "menu with icons opens"
  )
  local irows = vim.api.nvim_buf_get_lines(is.bufnr, 0, -1, false)
  ok(irows[1]:match("^ A Alpha ") ~= nil, "menu draws the icon in a column of its own")
  ok(
    irows[2]:match("^   Beta ") ~= nil,
    "menu aligns an icon-less label with the icon-bearing ones"
  )
  -- The fly-out marker has a column of its own, and that column follows the
  -- LABEL rather than the row: the hint column keeps the right edge, so the
  -- marker lands beside the list it belongs to instead of against the frame.
  local mark_at = irows[3]:find("→", 1, true)
  local hint_at = irows[1]:find("<leader>a", 1, true)
  ok(mark_at ~= nil, "menu marks a nested entry")
  ok(hint_at ~= nil and mark_at < hint_at, "menu puts the fly-out marker left of the hint column")
  eq(
    vim.fn.strdisplaywidth(irows[1]),
    vim.fn.strdisplaywidth(irows[3]),
    "menu rows are the same width with and without a marker"
  )
  chooser.close()

  -- Groups. `contextmenu.heading` marks one; the default style frames each,
  -- so a section reads as one thing. A menu that names no section keeps the
  -- old divider look -- that fallback is what stops this from redrawing every
  -- menu that only ever passed separators.
  local group_items = {
    { name = "Clipboard", __heading = true },
    { name = "Copy", cmd = function() end },
    { name = "Delete", __heading = true },
    { name = "Wipe", cmd = function() end },
  }
  local bs = assert(kit.menu({ items = group_items }), "grouped menu opens")
  local brows = vim.api.nvim_buf_get_lines(bs.bufnr, 0, -1, false)
  local bwidth = vim.api.nvim_win_get_width(bs.winid)
  eq(#brows, 6, "menu draws a frame line above and below each named group")
  ok(brows[1]:match("^ ╭─ Clipboard ") ~= nil, "menu sets the group title into its top rule")
  ok(brows[4]:match("^ ╭─ Delete ") ~= nil, "menu opens a frame per group")
  ok(brows[3]:match("^ ╰") ~= nil, "menu closes each group's frame")
  ok(
    brows[2]:match("^ │ ") ~= nil and brows[2]:match(" │ $") ~= nil,
    "menu framed rows carry both rules"
  )
  for i, line in ipairs(brows) do
    eq(vim.fn.strdisplaywidth(line), bwidth, "menu group line " .. i .. " fills the window")
  end
  chooser.close()

  -- A nested level whose children are named: the back entry stays OUTSIDE
  -- every frame. It was briefly wrapped in an empty untitled box of its own,
  -- because `loose and nil or group_open(...)` evaluates the right-hand side
  -- whenever the left is nil -- which nil always is.
  local ns = assert(
    kit.menu({
      items = {
        { name = "Section", __heading = true },
        { name = "Leaf", cmd = function() end },
        {
          name = "Deeper",
          items = {
            { name = "Inner", __heading = true },
            { name = "Child", cmd = function() end },
          },
        },
      },
    }),
    "nested menu opens"
  )
  local deeper
  for i, line in ipairs(vim.api.nvim_buf_get_lines(ns.bufnr, 0, -1, false)) do
    if line:find("Deeper", 1, true) then
      deeper = i
    end
  end
  vim.api.nvim_win_set_cursor(ns.winid, { assert(deeper, "Deeper row"), 0 })
  chooser.submit()
  -- Held back for the length of the pick flash, as above.
  wait_for(function()
    local first = vim.api.nvim_buf_get_lines(ns.bufnr, 0, 1, false)[1]
    return first ~= nil and first:match("◂ Back") ~= nil
  end)
  local nrows = vim.api.nvim_buf_get_lines(ns.bufnr, 0, -1, false)
  ok(nrows[1]:match("◂ Back") ~= nil, "menu back entry leads a nested level")
  ok(nrows[1]:match("│") == nil, "menu back entry is not framed as a section of its own")
  ok(nrows[2]:match("^ ╭─ Inner ") ~= nil, "menu frames the nested level's own group")
  chooser.close()

  local ps = assert(kit.menu({ items = group_items, group_style = "plain" }), "plain menu opens")
  local prows = vim.api.nvim_buf_get_lines(ps.bufnr, 0, -1, false)
  eq(#prows, 4, "group_style=plain draws headings as rows, with no frame")
  ok(prows[1]:match("^ Clipboard") ~= nil, "group_style=plain titles a group with a heading row")
  chooser.close()

  -- No titles anywhere: the pre-group look, untouched.
  local ds = assert(
    kit.menu({
      items = {
        { name = "Copy", cmd = function() end },
        { name = "separator" },
        { name = "Wipe", cmd = function() end },
      },
    }),
    "untitled menu opens"
  )
  local drows = vim.api.nvim_buf_get_lines(ds.bufnr, 0, -1, false)
  eq(#drows, 3, "an unnamed menu keeps its divider rather than gaining a frame")
  eq(
    vim.fn.strdisplaywidth(drows[2]),
    vim.api.nvim_win_get_width(ds.winid) - 1,
    "menu separator still stops one column short of the right edge"
  )
  chooser.close()

  -- The menu turns on the chooser's three presentation options; they stay
  -- off for select/picker/compare, which is why they are options at all.
  local saved_guicursor = vim.o.guicursor
  local hs = assert(kit.menu({ items = { { label = "Only", action = function() end } } }), "opens")
  ok(vim.o.guicursor ~= saved_guicursor, "menu hides the cursor while open")
  hs:close()
  eq(vim.o.guicursor, saved_guicursor, "menu restores 'guicursor' when the window closes")

  local ss = assert(
    kit.select({
      items = { "a", "b" },
      on_select = function() end,
    }),
    "select opens"
  )
  eq(vim.o.guicursor, saved_guicursor, "select leaves the cursor alone")
  chooser.close()
  ok(not ss:is_valid(), "select closed")

  -- --------------------------------------------------------------- compare
  -- `state`/`slots`/`move`/`mark`/`confirm` mirror `kit.picker`'s handle
  -- shape specifically so the SEARCH -> MARKED -> COMPARE flow is drivable
  -- headlessly, same as `picker (interactive)` above.
  local cmp_items = { "apple", "banana", "cherry", "date" }
  local cmp_renders = {}
  local cmp_clears = 0
  local cmp_close_calls, cmp_closed_a, cmp_closed_b = 0, nil, nil
  local cmp_on_compare_calls, cmp_on_compare_a, cmp_on_compare_b = 0, nil, nil
  -- Shared log across on_compare/render so "before either render" is a
  -- provable order, not just an isolated fact about on_compare's own call
  -- count — a caller like images.nvim relies on seeing it BEFORE render, not
  -- merely on it firing at some point.
  local cmp_order = {}

  local ch = assert(
    kit.compare({
      items = cmp_items,
      render = function(item, surf)
        table.insert(cmp_renders, item)
        table.insert(cmp_order, "render:" .. item)
        surf:set_lines({ "preview:" .. item })
      end,
      clear = function()
        cmp_clears = cmp_clears + 1
      end,
      on_close = function(a, b)
        cmp_close_calls = cmp_close_calls + 1
        cmp_closed_a, cmp_closed_b = a, b
      end,
      on_compare = function(a, b)
        cmp_on_compare_calls = cmp_on_compare_calls + 1
        cmp_on_compare_a, cmp_on_compare_b = a, b
        table.insert(cmp_order, "on_compare")
      end,
    }),
    "compare opens"
  )

  eq(ch.state(), "search", "compare starts in SEARCH")
  local search_slots = ch.slots()
  ok(search_slots.prompt:is_valid(), "search: prompt slot valid")
  ok(search_slots.results:is_valid(), "search: results slot valid")
  ok(search_slots.preview:is_valid(), "search: preview slot valid")
  eq(
    vim.api.nvim_buf_get_lines(search_slots.results.bufnr, 0, -1, false)[1],
    "apple",
    "results list shows format_item output (default: tostring)"
  )
  eq(
    vim.api.nvim_buf_get_lines(search_slots.preview.bufnr, 0, -1, false)[1],
    "preview:apple",
    "live preview renders the highlighted item"
  )
  eq(cmp_clears, 1, "clear() runs once for the initial mount")

  ch.move(1) -- apple -> banana
  eq(
    vim.api.nvim_buf_get_lines(ch.slots().preview.bufnr, 0, -1, false)[1],
    "preview:banana",
    "move() re-renders the live preview"
  )

  -- mark "banana" -> MARKED
  ch.mark()
  eq(ch.state(), "marked", "mark() enters MARKED")
  eq(cmp_clears, 2, "clear() runs again for the MARKED transition")
  local marked_slots = ch.slots()
  ok(marked_slots.marked:is_valid(), "marked: frozen slot valid")
  eq(
    vim.api.nvim_buf_get_lines(marked_slots.marked.bufnr, 0, -1, false)[1],
    "preview:banana",
    "frozen slot shows the marked item"
  )
  ok(marked_slots.results:is_valid(), "marked: results slot still there (still searchable)")
  ok(marked_slots.preview:is_valid(), "marked: live preview slot still there")
  eq(
    vim.api.nvim_buf_get_lines(marked_slots.preview.bufnr, 0, -1, false)[1],
    "preview:banana",
    "live preview keeps showing the selection as of the moment it was marked"
  )

  -- move to "cherry" and confirm the second pick -> COMPARE
  ch.move(1) -- banana -> cherry
  eq(
    vim.api.nvim_buf_get_lines(ch.slots().preview.bufnr, 0, -1, false)[1],
    "preview:cherry",
    "the live preview still follows the selection while MARKED"
  )
  ch.confirm()
  eq(ch.state(), "compare", "confirm() enters COMPARE")
  eq(cmp_clears, 3, "clear() runs again for the COMPARE transition")
  local cmp_slots = ch.slots()
  ok(cmp_slots.a:is_valid(), "compare: pane A valid")
  ok(cmp_slots.b:is_valid(), "compare: pane B valid")
  eq(cmp_slots.results, nil, "compare: results slot is gone")
  eq(cmp_slots.prompt, nil, "compare: prompt slot is gone")
  eq(
    vim.api.nvim_buf_get_lines(cmp_slots.a.bufnr, 0, -1, false)[1],
    "preview:banana",
    "pane A renders the marked item"
  )
  eq(
    vim.api.nvim_buf_get_lines(cmp_slots.b.bufnr, 0, -1, false)[1],
    "preview:cherry",
    "pane B renders the confirmed second item"
  )
  eq(cmp_on_compare_calls, 1, "on_compare fires exactly once")
  eq(cmp_on_compare_a, "banana", "on_compare gets the marked item as a")
  eq(cmp_on_compare_b, "cherry", "…and the confirmed second item as b")
  -- The last three log entries, not the whole log: SEARCH-state moves also
  -- rendered "apple"/"banana"/"cherry" for the live preview, so only the
  -- tail proves the COMPARE-state ordering, not just that the strings occur.
  local tail = { cmp_order[#cmp_order - 2], cmp_order[#cmp_order - 1], cmp_order[#cmp_order] }
  eq(
    table.concat(tail, ","),
    "on_compare,render:banana,render:cherry",
    "on_compare fires before either COMPARE-state render() call, with both panes still in a,b order"
  )

  ch.close()
  eq(cmp_clears, 4, "clear() runs once more on close")
  eq(cmp_close_calls, 1, "on_close fires exactly once")
  eq(cmp_closed_a, "banana", "on_close reports the marked item")
  eq(
    cmp_closed_b,
    "cherry",
    "…and the confirmed second item, even closed programmatically from COMPARE"
  )
  ok(not cmp_slots.a:is_valid(), "compare panes close")
  vim.cmd("stopinsert")

  -- default substring filter (no opts.query given) narrows the results list
  local ch2 = assert(
    kit.compare({
      items = { "red", "green", "blue" },
      render = function(item, surf)
        surf:set_lines({ item })
      end,
    }),
    "compare (filter) opens"
  )
  local prompt_buf = ch2.slots().prompt.bufnr
  vim.api.nvim_buf_set_lines(prompt_buf, 0, 1, false, { "bl" })
  vim.api.nvim_exec_autocmds("TextChangedI", { buffer = prompt_buf })
  vim.wait(30000, function()
    return #vim.api.nvim_buf_get_lines(ch2.slots().results.bufnr, 0, -1, false) == 1
  end, 10)
  local results_lines = vim.api.nvim_buf_get_lines(ch2.slots().results.bufnr, 0, -1, false)
  eq(#results_lines, 1, "query narrows the results to matches")
  eq(results_lines[1], "blue", "…the one item containing the query")
  ch2.close()
  vim.cmd("stopinsert")

  -- an empty item list opens no UI and reports (nil, nil) synchronously
  local empty_called, empty_a, empty_b = false, nil, nil
  local empty_handle = kit.compare({
    items = {},
    render = function() end,
    on_close = function(a, b)
      empty_called, empty_a, empty_b = true, a, b
    end,
  })
  eq(empty_handle, nil, "compare with no items returns nil")
  ok(empty_called, "on_close still fires for an empty item list")
  eq(empty_a, nil, "…with a nil first pick")
  eq(empty_b, nil, "…and a nil second pick")

  -- --------------------------------------------------------------- progress (passthrough)
  local ph = kit.progress({ text = "working", style = "notify" })
  ok(
    type(ph) == "table" and type(ph.finish) == "function",
    "kit.progress returns a lib.nvim.progress handle"
  )
  ph:finish() -- stays silent (never became visible)

  -- --------------------------------------------------------------- preview playground
  local P = require("lib.nvim.ui.kit.preview")
  local cfg_buf, prev_buf = kit.preview()
  ok(
    vim.api.nvim_buf_is_valid(cfg_buf) and vim.api.nvim_buf_is_valid(prev_buf),
    "preview opens a config + preview buffer"
  )
  local rendered = table.concat(vim.api.nvim_buf_get_lines(prev_buf, 0, -1, false), "\n")
  ok(rendered:find("border=rounded", 1, true), "preview renders the default (rounded) theme")

  -- editing the config re-renders live
  vim.api.nvim_buf_set_lines(cfg_buf, 0, -1, false, { 'return "double"' })
  P.render(cfg_buf, prev_buf)
  local rendered2 = table.concat(vim.api.nvim_buf_get_lines(prev_buf, 0, -1, false), "\n")
  ok(rendered2:find("border=double", 1, true), "editing the config restyles the preview")

  -- a broken config shows an error instead of throwing
  vim.api.nvim_buf_set_lines(cfg_buf, 0, -1, false, { "return { border =" })
  P.render(cfg_buf, prev_buf)
  local rendered3 = table.concat(vim.api.nvim_buf_get_lines(prev_buf, 0, -1, false), "\n")
  ok(rendered3:find("config error", 1, true), "a broken config shows an error, no throw")
  pcall(function()
    vim.cmd("tabclose")
  end)

  -- popup dispatch: unknown types return nil without throwing
  eq(kit.popup({ type = "does-not-exist" }), nil, "unknown type returns nil (no throw)")

  -- ----------------------------------------------------------- regressions
  -- (ported from ui.nvim's TESTS/ui_kit_spec.lua)

  -- bug: a second concurrent kit.picker cleared the first one's TextChanged
  -- autocmd out from under it (both used the same, non-per-instance augroup
  -- name), silently killing its debounce while it was still open.
  do
    local first_changes = {}
    local first = assert(
      kit.picker({
        debounce = 10,
        on_change = function(q)
          first_changes[#first_changes + 1] = q
        end,
      }),
      "first picker opens"
    )
    local second = assert(
      kit.picker({
        debounce = 10,
        on_change = function() end,
      }),
      "second picker opens"
    )

    vim.api.nvim_buf_set_lines(first.slots.prompt.bufnr, 0, 1, false, { "hello" })
    vim.api.nvim_exec_autocmds("TextChangedI", { buffer = first.slots.prompt.bufnr })
    wait_for(function()
      return #first_changes >= 1
    end)
    eq(
      table.concat(first_changes, ","),
      "hello",
      "the first picker's own TextChanged autocmd still fires after a second picker opens"
    )

    first.close()
    second.close()
  end

  -- bug: kit.shortlist only wired results-closes-preview, not the reverse --
  -- closing the preview pane directly (it is a plain, focusable surface of
  -- its own) left the results window open and preview-less.
  do
    local h = assert(
      kit.shortlist({
        items = { "x" },
        render = function(item, surface)
          surface:set_lines({ item })
        end,
      }),
      "shortlist opens"
    )
    h.preview:close()
    ok(not h.results:is_valid(), "closing the preview pane directly also closes the results window")
  end

  -- kit.shortlist's opt-in number_keys: `1`..`9` submit the first nine entries
  -- like <CR>, each labelled with its digit; without the option, neither.
  do
    local function digit_mapped(bufnr, lhs)
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
        if m.lhs == lhs then
          return true
        end
      end
      return false
    end
    local got
    local opened
    local function open_list(number_keys)
      got = nil
      opened = assert(
        kit.shortlist({
          items = { "a", "b", "c" },
          render = function(item, surface)
            surface:set_lines({ item })
          end,
          on_submit = function(item, idx)
            -- Whether the popup is still up at call time: it must close first.
            got = { item, idx, opened.results:is_valid() }
          end,
          number_keys = number_keys,
        }),
        "shortlist opens"
      )
      return opened
    end

    local unnumbered = open_list(nil)
    eq(
      table.concat(vim.api.nvim_buf_get_lines(unnumbered.results.bufnr, 0, -1, false), ","),
      "a,b,c",
      "shortlist without number_keys: no labels"
    )
    ok(not digit_mapped(unnumbered.results.bufnr, "1"), "shortlist without number_keys: no `1` map")
    unnumbered.close()

    local h = open_list(true)
    eq(
      table.concat(vim.api.nvim_buf_get_lines(h.results.bufnr, 0, -1, false), ","),
      "1 a,2 b,3 c",
      "shortlist number_keys: each entry carries its digit once"
    )
    vim.api.nvim_feedkeys("3", "mx", false)
    eq(got and got[1], "c", "shortlist number_keys: `3` submits the third entry")
    eq(got and got[2], 3, "shortlist number_keys: on_submit gets the index")
    eq(got and got[3], false, "shortlist number_keys: the popup closed before on_submit")
    ok(not h.results:is_valid(), "shortlist number_keys: the popup closed on submit")
  end

  -- make_scratch used to widen any resolved width <= 2 to 60 columns, even one
  -- the caller asked for. The kit passes widths straight through, so these are
  -- the degenerate sizes that change meaning: an explicit 1 or 2, and a layout
  -- slot in a tiny editor (`math.max(1, w - 2 * BORDER)`).
  do
    local function win_width(surf)
      return vim.api.nvim_win_get_width(surf.winid)
    end

    for _, want in ipairs({ 1, 2, 3 }) do
      local surf = assert(
        kit.surface.open({ lines = { "x" }, width = want, height = 1, enter = false }),
        "surface opens with an explicit tiny width"
      )
      eq(
        win_width(surf),
        want,
        "surface: explicit width " .. want .. " is honoured, not widened to 60"
      )
      surf:close()
    end

    -- No width and nothing to derive one from is the only case that still
    -- falls back to 60 (clamped to the editor).
    local empty = assert(kit.surface.open({ lines = {}, enter = false }), "empty surface opens")
    eq(
      win_width(empty),
      math.min(60, math.max(1, vim.o.columns - 4)),
      "surface: no width and no content still falls back to 60"
    )
    empty:close()

    -- An absolute outer width of 4 cells is what a very narrow editor would
    -- clamp to, without having to resize the editor under the other specs.
    local tiny = kit.layout.compute({ width = 4, height = 10, rows = { { name = "only" } } })
    eq(tiny.slots.only.width, 2, "layout: a 4-cell outer width leaves a 2-cell slot")
    local slot = assert(
      kit.surface.open(vim.tbl_extend("force", tiny.slots.only, { lines = { "x" }, enter = false })),
      "a slot surface opens"
    )
    eq(win_width(slot), 2, "a 2-cell layout slot opens as wide as the slot, not 60")
    slot:close()

    -- The menu measures its own width, so an empty one would be the way to land
    -- on a width <= 2 -- it is rejected up front instead, and opens no window.
    local wins_before = #vim.api.nvim_list_wins()
    local silenced_notify = vim.notify
    vim.notify = function() end
    local empty_menu = kit.menu({ items = {} })
    vim.notify = silenced_notify
    eq(empty_menu, nil, "menu: an empty item list is rejected, not sized to a degenerate width")
    eq(#vim.api.nvim_list_wins(), wins_before, "menu: the rejected empty menu opens no window")
  end
end
