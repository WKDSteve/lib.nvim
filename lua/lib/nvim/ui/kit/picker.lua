---@module 'lib.nvim.ui.kit.picker'
--- Interactive picker built on the layout `picker` template: an insert-mode
--- prompt that debounces keystrokes into `on_change(query)` (the caller fills
--- the results slot), moves the selection in the results slot with
--- <C-n>/<C-p>/arrows, submits the highlighted result with <CR>, and closes on
--- <Esc>. This is the "works like Telescope out of the box" behavior from
--- the layout engine.
---
--- `opts.prompt = "plain"` falls back to a bare `kit.layout.template("picker")`
--- whose prompt slot the caller wires itself.

local layout = require("lib.nvim.ui.kit.layout")
local input = require("lib.nvim.ui.kit.input")
local theme = require("lib.nvim.ui.kit.theme")
local map = require("lib.nvim.bindings.keymap")

local api = vim.api
local autocmd = require("lib.nvim.bindings.autocmd")
local debounce = require("lib.nvim.debounce")

local M = {}

--- The resumes of Insert mode that wait for the detour's own Insert mode to end: a prompt
--- the focus came back to while that was still on feeds a `<Cmd>` key that runs its entry.
---@type table<integer, fun()>
local waiting = {}
---@type integer
local last_wait = 0

---@internal
--- Run the waiting resume `id` (the `<Cmd>` key a picker prompt fed, see `M.open`).
---@param id integer
function M._resume(id)
  local fn = waiting[id]
  waiting[id] = nil
  if fn then
    fn()
  end
end

---@internal
--- Move the cursor in `win` by `delta` rows, wrapping around.
---@param win integer
---@param buf integer
---@param delta integer
local function move_in(win, buf, delta)
  if not api.nvim_win_is_valid(win) then
    return
  end
  local count = math.max(1, api.nvim_buf_line_count(buf))
  local line = api.nvim_win_get_cursor(win)[1] + delta
  if line < 1 then
    line = count
  elseif line > count then
    line = 1
  end
  pcall(api.nvim_win_set_cursor, win, { line, 0 })
end

--- Open an interactive picker. Item mode (`items` / `format`): see the README of the kit.
---@param opts table  # { theme?, debounce?, on_change(query), on_submit(idx, text, item?), prompt?, items?, format?(item), text?(item), key?(item), selectable?(item), preview?(item, surface), keys?, marks?, title?, results_width?, on_close? }
---@return table|nil  # handle: { slots, query(), set_results(lines), move(delta), submit(), close() }
function M.open(opts)
  opts = opts or {}

  if opts.prompt == "plain" then
    return layout.template("picker", opts)
  end

  ---@type fun(query: string)
  local on_change = opts.on_change or function(_) end
  ---@type fun(idx: integer, text: string)
  local on_submit = opts.on_submit or function(_, _) end
  local debounce_ms = tonumber(opts.debounce) or 80

  -- `opts.results_width` (0..1, default 0.4) trades preview room for result room: a list of long rows wants more.
  local spec = layout.templates.picker.spec
  if opts.results_width then
    spec = vim.deepcopy(spec)
    local width = math.min(0.9, math.max(0.1, opts.results_width))
    spec.rows[2].cols[1].width = width
    spec.rows[2].cols[2].width = 1 - width
  end
  local group = layout.mount(spec, {
    theme = opts.theme,
    enter = "prompt",
    slot = {
      prompt = { modifiable = true, filetype = "lib-kit-picker-prompt" },
      results = { wo = { cursorline = true }, filetype = "lib-kit-picker-results" },
    },
  })

  local prompt = group.slots.prompt
  local results = group.slots.results
  if not (prompt and results) then
    group.close()
    return nil
  end

  -- Selection highlight on the results slot.
  local cur = api.nvim_get_option_value("winhighlight", { win = results.winid })
  local sep = cur ~= "" and "," or ""
  pcall(
    api.nvim_set_option_value,
    "winhighlight",
    cur .. sep .. "CursorLine:" .. theme.scoped_group(results.winid, "KitSelection"),
    { win = results.winid }
  )

  -- Declared here, stopped in `finish_close` and in `prompt`'s `on_close`
  -- below: closing the picker before the debounce fires -- whether via our
  -- own keymaps or an external `:q`/`:close`/`<C-w>c` -- must not leave a
  -- stray timer that calls `on_change` on a picker that no longer exists.
  local pending = false -- a change is scheduled and has not been delivered yet
  ---@type Lib.Debounce.Handle|nil  # created below, once `handle` exists
  local change

  local function stop_timer()
    pending = false
    if change then
      change.cancel()
    end
  end

  ---@internal
  ---Recompute the template's geometry for the current editor size and
  ---reapply it to every mounted slot -- `layout.compute` is pure, so calling
  ---it again with the same spec is the whole fix. Keyed off `geo.slots`
  ---itself, not a hardcoded slot-name list: the picker template also mounts
  ---a "preview" slot (`layout.templates.picker.spec`) that `M.open` never
  ---names locally, and a fixed `{"prompt", "results"}` loop silently left it
  ---stuck at its open-time position and size on every resize.
  local function relayout()
    local geo = layout.compute(spec)
    for name, g in pairs(geo.slots) do
      local surf = group.slots[name]
      if surf and surf:is_valid() then
        pcall(api.nvim_win_set_config, surf.winid, g)
      end
    end
  end

  local resize_group = autocmd.group("lib_kit_picker_resize_" .. prompt.winid, true)
  autocmd.create("VimResized", relayout, {
    group = resize_group,
    record = false, -- throwaway per-window hook: not recorded (see lib.nvim.ui.kit.surface)
    desc = "lib.nvim.ui.kit.picker: keep the picker sized to the editor",
  })
  -- Hung off the surface's own close lifecycle, not just `finish_close`:
  -- `layout.mount`'s `close_all` (wired to every slot's `on_close`) tears the
  -- picker down when a slot window is closed externally too (a plain `:q`,
  -- `:close`, `<C-w>c` -- none of which run our own keymaps), and that path
  -- never called `finish_close`, leaking this augroup and its autocmd for
  -- the rest of the session -- and, for the same reason, leaving the
  -- debounce timer running to later call `on_change` on buffers that may
  -- already be gone. `prompt:close()` always runs as part of `close_all`, on
  -- every path, so anchoring cleanup to `prompt`'s own `on_close` covers all
  -- of them, `finish_close` included.
  prompt:on_close(function()
    pcall(api.nvim_del_augroup_by_id, resize_group)
    stop_timer()
  end)

  local function finish_close()
    stop_timer()
    pcall(function()
      vim.cmd("stopinsert")
    end)
    group.close()
  end

  local handle = { slots = group.slots }
  change = debounce.new(function()
    pending = false
    on_change(handle.query())
  end, debounce_ms)

  ---@return string
  function handle.query()
    if not api.nvim_buf_is_valid(prompt.bufnr) then
      return ""
    end
    return api.nvim_buf_get_lines(prompt.bufnr, 0, 1, false)[1] or ""
  end

  ---@param lines string[]
  function handle.set_results(lines)
    results:set_lines(lines or {})
    if results:is_valid() then
      pcall(api.nvim_win_set_cursor, results.winid, { 1, 0 })
    end
  end

  ---@param delta integer
  function handle.move(delta)
    move_in(results.winid, results.bufnr, delta)
  end

  --- Submit the highlighted result: on_submit(index, line_text), then close.
  function handle.submit()
    if not results:is_valid() then
      return
    end
    local idx = api.nvim_win_get_cursor(results.winid)[1]
    local text = api.nvim_buf_get_lines(results.bufnr, idx - 1, idx, false)[1]
    finish_close()
    on_submit(idx, text)
  end

  function handle.close()
    finish_close()
  end

  -- ── item mode ──────────────────────────────────────────────────────────────
  -- `opts.items` (or `opts.format`) turns the results slot into a list of ITEMS: rendered through `format` (text parts
  -- with highlight groups), filtered by the words typed in the prompt (every word must occur, any case), with marks
  -- (<Tab>), the current/marked items for caller actions, a preview slot filled by `opts.preview(item, surface)` and
  -- `set_items` to replace the list while keeping the cursor item and the marks.
  local item_mode = opts.items ~= nil or opts.format ~= nil
  ---@type any[]
  local items = opts.items or {}
  ---@type any[]
  local shown = {}
  ---@type table<any, boolean>
  local marked = {}
  local ns = api.nvim_create_namespace("lib_kit_picker_items")
  local closed = false
  prompt:on_close(function()
    closed = true
    if opts.on_close then
      local ran, err = pcall(opts.on_close)
      if not ran then
        vim.schedule(function()
          vim.notify(
            "lib.nvim.ui.kit.picker: on_close failed: " .. tostring(err),
            vim.log.levels.WARN
          )
        end)
      end
    end
  end)

  local function text_of(item)
    if opts.text then
      return opts.text(item)
    end
    return type(item) == "table" and item.text or tostring(item)
  end
  local function key_of(item)
    return opts.key and opts.key(item) or item
  end
  local function selectable(item)
    return not opts.selectable or opts.selectable(item) ~= false
  end

  ---The typed words are applied with a debounce; an action that reads the list (current, marked, submit, a caller
  ---key) must see the list of what is in the prompt NOW, not of the previous keystroke.
  local function flush()
    if pending then
      stop_timer()
      on_change(handle.query())
    end
  end

  ---@return any|nil
  local function current_item()
    flush()
    if not results:is_valid() then
      return nil
    end
    return shown[api.nvim_win_get_cursor(results.winid)[1]]
  end

  local function sync_preview()
    local preview = group.slots.preview
    if opts.preview and preview and preview:is_valid() then
      local item = current_item()
      if item ~= nil then
        local drawn, err = pcall(opts.preview, item, preview)
        if not drawn then
          -- never leave the previous item's text next to the new cursor row
          pcall(preview.set_lines, preview, { "(preview failed: " .. tostring(err) .. ")" })
        end
      else
        preview:set_lines({})
      end
    end
  end

  ---@param cursor_key any|nil  # The item the cursor goes back to (default: the first row).
  local function render(cursor_key)
    if not results:is_valid() then
      return
    end
    local words = {}
    for w in handle.query():lower():gmatch("%S+") do
      words[#words + 1] = w
    end
    shown = {}
    local lines, spans = {}, {}
    for _, item in ipairs(items) do
      local hay = text_of(item):lower()
      local hit = true
      for _, w in ipairs(words) do
        if not hay:find(w, 1, true) then
          hit = false
          break
        end
      end
      if hit then
        shown[#shown + 1] = item
        local line = marked[key_of(item)] and "+ " or "  "
        local line_spans = {}
        local parts = opts.format and opts.format(item) or text_of(item)
        if type(parts) == "string" then
          parts = { { parts } }
        end
        for _, part in ipairs(parts) do
          local piece = (part[1]:gsub("[\r\n]", " "))
          if part[2] then
            line_spans[#line_spans + 1] = { #line, #line + #piece, part[2] }
          end
          line = line .. piece
        end
        lines[#lines + 1] = line
        spans[#spans + 1] = line_spans
      end
    end
    results:set_lines(lines)
    api.nvim_buf_clear_namespace(results.bufnr, ns, 0, -1)
    for i, line_spans in ipairs(spans) do
      if marked[key_of(shown[i])] then
        pcall(
          api.nvim_buf_set_extmark,
          results.bufnr,
          ns,
          i - 1,
          0,
          { end_col = 1, hl_group = "DiagnosticOk" }
        )
      end
      for _, sp in ipairs(line_spans) do
        pcall(
          api.nvim_buf_set_extmark,
          results.bufnr,
          ns,
          i - 1,
          sp[1],
          { end_col = sp[2], hl_group = sp[3] }
        )
      end
    end
    local row
    if cursor_key ~= nil then
      for i, item in ipairs(shown) do
        if key_of(item) == cursor_key then
          row = i
          break
        end
      end
    end
    if not row then
      -- the first row that can be acted on (a heading is not one)
      row = 1
      for i, item in ipairs(shown) do
        if selectable(item) then
          row = i
          break
        end
      end
    end
    pcall(api.nvim_win_set_cursor, results.winid, { math.min(row, math.max(1, #shown)), 0 })
    sync_preview()
  end

  if item_mode then
    -- the typed words filter the list (a caller's own `on_change` still wins)
    if not opts.on_change then
      on_change = function()
        local item = current_item()
        render(item ~= nil and key_of(item) or nil)
      end
    end
    local plain_move = handle.move
    function handle.move(delta)
      flush()
      plain_move(delta)
      -- step over rows that cannot be acted on (headings), at most once around the list
      local step = delta < 0 and -1 or 1
      for _ = 1, #shown do
        local item = shown[api.nvim_win_get_cursor(results.winid)[1]]
        if item == nil or selectable(item) then
          break
        end
        plain_move(step)
      end
      sync_preview()
    end

    ---The item under the cursor.
    ---@return any|nil
    function handle.current()
      return current_item()
    end

    ---The marked items, in list order.
    ---@return any[]
    function handle.marked()
      flush()
      local out = {}
      for _, item in ipairs(items) do
        if marked[key_of(item)] then
          out[#out + 1] = item
        end
      end
      return out
    end

    ---Replace the list. The cursor stays on its item (`cursor_key` names another one), the marks of items that
    ---are still there stay unless `keep_marks == false`.
    ---@param new_items any[]
    ---@param o? { cursor_key?: any, keep_marks?: boolean }
    function handle.set_items(new_items, o)
      o = o or {}
      local item = current_item()
      local cursor = o.cursor_key
      if cursor == nil and item ~= nil then
        cursor = key_of(item)
      end
      items = new_items or {}
      local present = {}
      for _, it in ipairs(items) do
        present[key_of(it)] = true
      end
      for k in pairs(marked) do
        if o.keep_marks == false or not present[k] then
          marked[k] = nil
        end
      end
      render(cursor)
    end

    ---Mark or unmark the item under the cursor and move down.
    function handle.toggle_mark()
      local item = current_item()
      if item == nil or not selectable(item) then
        return
      end
      local k = key_of(item)
      marked[k] = (not marked[k]) or nil
      -- flip the two-byte prefix of THIS row in place: a full render per <Tab> is thousands of extmarks
      local buf = results.bufnr
      local row = api.nvim_win_get_cursor(results.winid)[1] - 1
      local was_modifiable = api.nvim_get_option_value("modifiable", { buf = buf })
      api.nvim_set_option_value("modifiable", true, { buf = buf })
      pcall(api.nvim_buf_set_text, buf, row, 0, row, 2, { marked[k] and "+ " or "  " })
      api.nvim_set_option_value("modifiable", was_modifiable, { buf = buf })
      for _, mark in
        ipairs(api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, 0 }, { details = true }))
      do
        if mark[4].hl_group == "DiagnosticOk" then
          api.nvim_buf_del_extmark(buf, ns, mark[1])
        end
      end
      if marked[k] then
        pcall(api.nvim_buf_set_extmark, buf, ns, row, 0, { end_col = 1, hl_group = "DiagnosticOk" })
      end
      handle.move(1)
    end

    ---@param title string|nil
    function handle.set_title(title)
      results:set_title(title)
    end

    ---@return boolean
    function handle.is_closed()
      return closed
    end

    -- Submit with the item: on_submit(idx, text, item).
    function handle.submit()
      if not results:is_valid() then
        return
      end
      flush()
      local idx = api.nvim_win_get_cursor(results.winid)[1]
      local item = shown[idx]
      if item == nil or not selectable(item) then
        return -- an empty list or a heading: nothing to submit, the picker stays open
      end
      local text = api.nvim_buf_get_lines(results.bufnr, idx - 1, idx, false)[1]
      finish_close()
      on_submit(idx, text, item)
    end
    if opts.title then
      handle.set_title(opts.title)
    end
  end

  -- Debounced query notifications.
  local function schedule_change()
    pending = true
    change.call()
  end

  -- Per-instance group (matches `resize_group` above): a fixed name here
  -- would let a second concurrent `M.open()` call -- `kit.picker` mounts no
  -- singleton and nothing stops a caller from opening one from inside
  -- another's `on_change`/`on_submit` -- clear the first picker's own
  -- TextChanged autocmd out from under it on `autocmd.group(name, true)`'s
  -- clear-on-create, silently killing its debounce while it is still open.
  local prompt_group = autocmd.group("lib_kit_picker_" .. prompt.winid, true)
  autocmd.create({ "TextChangedI", "TextChanged" }, schedule_change, {
    group = prompt_group,
    buffer = prompt.bufnr,
    record = false, -- throwaway per-window hook: not recorded (see lib.nvim.ui.kit.surface)
    desc = "lib.nvim.ui.kit.picker: query changed",
  })
  -- The autocmds are buffer-local and die with the prompt buffer, but the group itself
  -- would stay (one empty group per opened picker, window ids are never reused). Dropped
  -- on the prompt's own close, which runs on every close path (see `resize_group`).
  prompt:on_close(function()
    pcall(api.nvim_del_augroup_by_id, prompt_group)
  end)

  -- Typing goes into the query after a detour too. A caller key that opens a window to read
  -- (a viewer with the item's details) leaves the prompt in Insert mode, and that window ends
  -- it (see lib.nvim.ui.kit.surface); coming back, the prompt would stand in Normal mode, the
  -- next letter a command (`x` deletes instead of filtering).
  --
  -- A window that is typed into (a kit.input, a nested picker) is still in Insert mode
  -- while it closes back into the prompt: `:startinsert` is ignored then, and the closer
  -- ends that Insert mode right after (its own `:stopinsert`), here, in the prompt. So the
  -- resume waits: a `<Cmd>` key fed in front of whatever is typed next runs it once the
  -- closer is through. Ending Insert mode in the prompt steps its cursor one to the left,
  -- which is why the column is put back.
  ---@type integer|nil
  local resume_col
  ---@param col integer
  local function resume(col)
    local line = api.nvim_get_current_line()
    if col >= #line then
      vim.cmd("startinsert!")
    else
      pcall(api.nvim_win_set_cursor, prompt.winid, { 1, col })
      vim.cmd("startinsert")
    end
  end
  ---@type integer|nil  # this picker's entry in `waiting`, while a fed resume is on its way
  local wait_id
  prompt:on_close(function()
    if wait_id then
      waiting[wait_id] = nil
      wait_id = nil
    end
  end)
  autocmd.create("WinLeave", function()
    local mode = api.nvim_get_mode().mode
    resume_col = nil
    if mode:find("^i") or mode:find("^ni") then
      resume_col = api.nvim_win_get_cursor(0)[2]
    end
  end, {
    group = prompt_group,
    buffer = prompt.bufnr,
    record = false, -- throwaway per-window hook: not recorded (see lib.nvim.ui.kit.surface)
    desc = "lib.nvim.ui.kit.picker: remember Insert mode when the prompt is left",
  })
  autocmd.create("WinEnter", function()
    -- `nvim_open_win` fires WinEnter while the new float still shows the buffer it
    -- was split from (the prompt's), before its own buffer is put in: not a return.
    if resume_col == nil or api.nvim_get_current_win() ~= prompt.winid then
      return
    end
    local col = resume_col
    resume_col = nil
    if not api.nvim_get_mode().mode:find("^[iR]") then
      resume(col)
      return
    end
    if wait_id then
      waiting[wait_id] = nil
    end
    last_wait = last_wait + 1
    local id = last_wait
    wait_id = id
    waiting[id] = function()
      wait_id = nil
      -- Still in Insert mode (the closer kept it on): typing simply goes on in the prompt.
      -- Elsewhere (the closer opened the next window): that window's own way back counts.
      if
        api.nvim_win_is_valid(prompt.winid)
        and api.nvim_get_current_win() == prompt.winid
        and not api.nvim_get_mode().mode:find("^[iR]")
      then
        resume(col)
      end
    end
    -- "i": in front of the keys that are already waiting, "n": no mapping of the user's applies.
    api.nvim_feedkeys(
      api.nvim_replace_termcodes(
        ("<Cmd>lua require('lib.nvim.ui.kit.picker')._resume(%d)<CR>"):format(id),
        true,
        false,
        true
      ),
      "ni",
      false
    )
  end, {
    group = prompt_group,
    buffer = prompt.bufnr,
    record = false, -- throwaway per-window hook: not recorded (see lib.nvim.ui.kit.surface)
    desc = "lib.nvim.ui.kit.picker: back in the prompt, back in Insert mode",
  })

  -- Throwaway buffer-local keys: not recorded (see lib.nvim.ui.kit.chooser's `mo`).
  local mo = { buffer = prompt.bufnr, nowait = true, record = false }
  map({ "i", "n" }, "<CR>", handle.submit, mo)
  map({ "i", "n" }, "<C-n>", function()
    handle.move(1)
  end, mo)
  map({ "i", "n" }, "<C-p>", function()
    handle.move(-1)
  end, mo)
  map({ "i", "n" }, "<Down>", function()
    handle.move(1)
  end, mo)
  map({ "i", "n" }, "<Up>", function()
    handle.move(-1)
  end, mo)
  map({ "i", "n" }, "<Esc>", finish_close, mo)
  if item_mode and opts.marks ~= false then
    map({ "i", "n" }, "<Tab>", handle.toggle_mark, mo)
  end
  -- Caller keys: lhs -> function(handle), in the prompt window (insert and normal mode).
  for lhs, fn in pairs(opts.keys or {}) do
    map({ "i", "n" }, lhs, function()
      fn(handle)
    end, mo)
  end

  if item_mode then
    render(nil)
  end
  prompt:focus()
  -- A prompt that closes while its callback opens this picker must leave Insert mode on.
  input.mark_opened()
  vim.cmd("startinsert")

  return handle
end

return M
