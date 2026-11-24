---@module 'lib.nvim.ui.kit.sheet'
--- Sheet component: ONE float that shows every field of a form at once, one
--- row per field with its label -- where `kit.form` asks one question at a
--- time. Pick it when the answers belong together and the user should see (and
--- fix) all of them before committing; `kit.form` stays the right tool for a
--- short chain of prompts.
---
--- Field contract: `{ name, label?, kind?, default?, required?, validate?,
--- live?, depends_on?, expand_env?, completion?, secret?, mask?, choices? }`. `name` is the
--- key the answer is stored under in the table handed to `on_submit`.
---   - `kind = "text"` (the default) is an editable line, like `kit.input`:
---     `default`, `expand_env`, `completion` and `secret` work the same.
---   - `kind = "select"` (with `choices`, a list of strings) is a fixed choice
---     cycled with `h`/`l` (or the arrows); `<CR>`/`<Space>` open `kit.select`
---     over the choices, and a pick moves on to the next field. `default` names
---     the choice shown first.
---
--- Validation sits next to the field it belongs to, as red text under the row:
---   - `required = true` rejects an empty (blank) value.
---   - `validate(value) -> ok, err` rejects a value when `ok` is falsy, with
---     `err` as the message ("invalid" when there is none). It is not called
---     for an empty optional field, so it never has to deal with `""`. A
---     validator that raises is a rejection too, with the error as the message.
---   - a field is checked when the user leaves it and on submit; a field that
---     shows an error is checked again on every edit (so the message goes away
---     the moment the value is fixed), and `live = true` checks a field on every
---     edit from the start.
---   - `depends_on = "other"` (or a list of names) says that this field's validity
---     depends on those fields -- a number that has to be free in the chosen area:
---     it is checked again when one of them changes, as long as it has a value or an
---     error to speak of (an untouched, blank one stays quiet).
---   - submit is blocked while any field fails, and the focus jumps to the
---     first one that does.
---
--- Keys (Insert mode on a text row, Normal mode elsewhere -- the same keys):
---   - `<Tab>`/`<S-Tab>` walk the fields and then the button row, wrapping;
---     `<Down>`/`<Up>` (and `j`/`k` in Normal mode) do the same without wrapping.
---     On a field with `completion`, `<Tab>` is the completion key (as in
---     `kit.input`) and `<S-Tab>` still goes back unless a popup is open.
---   - `<CR>` moves to the next field; on the last field it presses the Submit
---     button. On a `select` it opens the chooser; on a button it presses it.
---   - `<Esc>` cancels the whole sheet (`on_cancel`), whatever has the focus.
---   - a left click puts the focus on the field under the pointer (cursor at
---     the click) and presses a button, as in `kit.confirm`.
---   - the button row is `[ Submit ] [ Cancel ]` (`submit_label`/`cancel_label`),
---     reachable by `<Tab>`/`<Down>`, moved along with `h`/`l`, pressed with
---     `<CR>`/`<Space>`.
---
--- How it is drawn: the buffer holds only the VALUES, one per line (the field's
--- text, or a select's current choice), then a blank line and the button row.
--- The labels are not text in the buffer but the window's 'statuscolumn', so an
--- edit can never touch one, the cursor cannot land on one and a long value
--- wraps under the value column, not under the label. Errors are virtual lines
--- under their field, and the window is resized to what is shown, so the sheet
--- grows by a row per message and shrinks when they go.
---
--- The returned surface carries five extra methods, for callers that drive it
--- from code and for specs: `surf:submit()`, `surf:cancel()`,
--- `surf:focus_field(name|index)`, `surf:validate()` (check every field now, so the
--- messages show, without submitting) and `surf:state()` (`{ focus, values, errors }`).

local surface = require("lib.nvim.ui.kit.surface")
local buttons = require("lib.nvim.ui.kit.buttons")
local hook = require("lib.nvim.ui.kit.hook")
local input = require("lib.nvim.ui.kit.input")
local select = require("lib.nvim.ui.kit.select")
local autocmd = require("lib.nvim.bindings.autocmd")
local expand_path = require("lib.nvim.cross.fs.expand_path")
-- A NUL byte in a label, a title or a message would raise E976 out of the measuring below.
local nul_safe = require("lib.lua.strings.core").nul_safe

local api = vim.api
local fn = vim.fn

local M = {}

--- Error text, select hints and the secret mask.
local NS = api.nvim_create_namespace("lib_kit_sheet")
--- The focus highlight of the button row.
local BTN_NS = api.nvim_create_namespace("lib_kit_sheet_buttons")

--- How many cells the buttons need: Submit and Cancel.
local NBUTTONS = 2

--- The window's 'statuscolumn': where the labels are drawn (see `M.column`).
local STATUSCOLUMN = "%!v:lua.require'lib.nvim.ui.kit.sheet'.column()"

--- What `M.column` needs to know about one open sheet, by window id: it runs
--- once per drawn screen row and is only told which window it is drawing.
---@type table<integer, { width: integer, labels: string[], marks: string[], focus: integer|nil }>
local views = {}

---@internal
--- The 'statuscolumn' of a sheet window: one row's label, padded to the width
--- of the widest, with `*` after a required field's. The focused field's label
--- is `KitAccent`, the others `KitMuted`. Wrapped rows and virtual (error) lines
--- get blanks of the same width, so the values stay in one column.
---@return string
function M.column()
  local view = views[vim.g.statusline_winid]
  if not view then
    return ""
  end
  local lnum = vim.v.lnum
  if vim.v.virtnum ~= 0 or not view.labels[lnum] then
    return "%#KitMuted#" .. string.rep(" ", view.width)
  end
  local hl = lnum == view.focus and "KitAccent" or "KitMuted"
  return "%#" .. hl .. "#" .. view.labels[lnum] .. "%#KitError#" .. view.marks[lnum]
end

---@internal
--- `s` cut to `width` cells, with an ellipsis when something was cut. A NUL byte is shown as
--- the SOH that measures alike: the measuring and the splitting both raise E976 on a NUL.
---@param s string
---@param width integer
---@return string
local function clip(s, width)
  s = nul_safe(s)
  if fn.strdisplaywidth(s) <= width then
    return s
  end
  local out = ""
  for i = 0, fn.strchars(s) - 1 do
    local next_out = out .. fn.strcharpart(s, i, 1)
    if fn.strdisplaywidth(next_out .. "…") > width then
      break
    end
    out = next_out
  end
  return out .. "…"
end

---@internal
--- Hand `keys` back to Neovim un-remapped and ahead of whatever is queued, for
--- a mapping that only wants to intercept some presses of a key.
---@param keys string
local function pass_through(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "ni", false)
end

---@internal
--- A one-line string: a field's text must never carry a newline into a buffer.
---@param v any
---@return string
local function one_line(v)
  return (tostring(v):gsub("[\r\n]+", " "))
end

---@internal
---@param raw table
---@param index integer
---@return table
local function normalize(raw, index)
  local name = raw.name ~= nil and tostring(raw.name) or tostring(index)
  local choices = {}
  if type(raw.choices) == "table" then
    for _, c in ipairs(raw.choices) do
      choices[#choices + 1] = one_line(c)
    end
  end
  local is_select = raw.kind == "select" and #choices > 0
  local field = {
    name = name,
    -- Only ever drawn (and measured): the 'statuscolumn' it ends up in is a `v:lua` call, and a
    -- NUL in what that returns is a Blob -- E976 on every redraw -- so it is cleaned here.
    label = nul_safe(one_line(raw.label or raw.prompt or name)),
    kind = is_select and "select" or "text",
    required = raw.required == true,
    validate = type(raw.validate) == "function" and raw.validate or nil,
    live = raw.live == true,
    depends_on = type(raw.depends_on) == "string" and { raw.depends_on }
      or type(raw.depends_on) == "table" and raw.depends_on
      or {},
    expand_env = raw.expand_env == true,
    completion = (type(raw.completion) == "string" or type(raw.completion) == "function")
        and raw.completion
      or nil,
    secret = raw.secret == true,
    mask = type(raw.mask) == "string" and raw.mask or "*",
    choices = choices,
    choice = 1,
    text = "",
  }
  if is_select then
    for i, c in ipairs(choices) do
      if c == raw.default then
        field.choice = i
      end
    end
    field.text = choices[field.choice]
  elseif raw.default ~= nil then
    field.text = one_line(raw.default)
  end
  return field
end

--- Open a sheet.
---@param opts Lib.UI.Kit.SheetOpts
---@return Lib.UI.Kit.Sheet|nil  # nil when there are no fields or the float could not be opened
function M.open(opts)
  opts = opts or {}

  local hooked = hook.intercept("sheet", opts, function(value)
    if type(value) == "table" then
      if opts.on_submit then
        opts.on_submit(value)
      end
    elseif opts.on_cancel then
      opts.on_cancel()
    end
  end)
  if hooked then
    return hooked
  end

  local fields = {}
  for _, raw in ipairs(opts.fields or {}) do
    if type(raw) == "table" then
      fields[#fields + 1] = normalize(raw, #fields + 1)
    end
  end
  local n = #fields
  if n == 0 then
    -- Nothing to ask: the same answer `kit.form` gives for an empty chain.
    if opts.on_submit then
      opts.on_submit({})
    end
    return nil
  end

  local btn_labels = {
    tostring(opts.submit_label or "Submit"),
    tostring(opts.cancel_label or "Cancel"),
  }
  local required_message = tostring(opts.required_message or "required")

  -- The label column: the widest label, a marker slot (`*` on a required
  -- field) and a space before the value.
  local label_w, any_secret = 0, false
  for _, f in ipairs(fields) do
    label_w = math.max(label_w, math.min(fn.strdisplaywidth(f.label), 30))
    any_secret = any_secret or f.secret
  end
  local col_w = label_w + 2

  local view = { width = col_w, labels = {}, marks = {} }
  for i, f in ipairs(fields) do
    local label = clip(f.label, label_w)
    local pad = string.rep(" ", label_w - fn.strdisplaywidth(label))
    view.labels[i] = (label .. pad):gsub("%%", "%%%%")
    view.marks[i] = (f.required and "*" or " ") .. " "
  end

  local title_w = opts.title and fn.strdisplaywidth(nul_safe(opts.title)) or 0
  local btn_w = buttons.row_width(btn_labels)
  local width = opts.width or math.max(60, title_w + 2, col_w + btn_w + 2)
  if width >= 1 then
    width = math.min(width, math.max(1, vim.o.columns - 4))
  end

  local lines = {}
  for i, f in ipairs(fields) do
    lines[i] = f.text
  end
  lines[n + 1] = ""
  lines[n + 2] = ""

  local relative = opts.relative or "editor"
  local surf = surface.open({
    modal = true,
    lines = lines,
    theme = opts.theme,
    title = opts.title,
    width = width,
    height = n + 2,
    relative = relative,
    enter = true,
    modifiable = true,
    wo = vim.tbl_extend("force", {
      wrap = true,
      linebreak = false,
      statuscolumn = STATUSCOLUMN,
    }, any_secret and { conceallevel = 2, concealcursor = "nvic" } or {}),
    -- No auto-indent either: it is what made a prompt's button row come back one
    -- space short (see `lib.nvim.ui.kit.input`); the same cursor parking could do it here.
    bo = { undolevels = -1, autoindent = false, smartindent = false, cindent = false },
  })
  if not surf then
    -- `surface.open` failed -- a genuine break, not a user-driven cancel.
    -- Without this neither callback ever fires and a caller waiting on it stalls.
    if opts.on_cancel then
      opts.on_cancel()
    end
    return nil
  end

  -- A window to be typed into: a prompt that closes while its callback opens this
  -- sheet must leave Insert mode on (see `input.mark_opened`).
  input.mark_opened()
  local bufnr, winid = surf.bufnr, surf.winid
  if any_secret then
    -- Marked, and closed to buffer-word completion, as a whole: the buffer is one for
    -- every row, so the keys of a row that is not secret are left out of a keystroke HUD
    -- too (the conservative choice -- there is no telling which row a key was meant for),
    -- and `<C-n>` in another row would offer the words of the secret one.
    input.protect_secret_buffer(bufnr)
  end
  local centered = relative == "editor"
  local max_height = math.max(3, vim.o.lines - 6)
  local win_w = api.nvim_win_get_width(winid)
  local text_w = math.max(10, win_w - col_w)
  local done = false
  local started = false

  ---@type integer  # 1..n: a field; n+1, n+2: the Submit and Cancel buttons
  local focus = 1
  ---@type string[]  # what each field's row held at the last edit: the repair copy
  local cache = {}
  for i, f in ipairs(fields) do
    cache[i] = f.text
  end
  ---@type (string|nil)[]
  local errors = {}
  local ranges = {} ---@type Lib.UI.Kit.ButtonRange[]
  local btn_line = ""
  --- Puts the rows back as the layout wants them (defined below): `goto_pos` and
  --- `submit` run it first, so they never work from a layout a paste has broken.
  ---@type fun()
  local keep_layout

  views[winid] = view

  --- Run `write_fn` with the buffer writable: it is locked while a select or a
  --- button has the focus.
  ---@param write_fn fun()
  local function write(write_fn)
    local modifiable = vim.bo[bufnr].modifiable
    vim.bo[bufnr].modifiable = true
    local ok, err = pcall(write_fn)
    vim.bo[bufnr].modifiable = modifiable
    if not ok then
      error(err, 0)
    end
  end

  ---@param i integer
  ---@return string
  local function row_text(i)
    if api.nvim_buf_is_valid(bufnr) then
      local line = api.nvim_buf_get_lines(bufnr, i - 1, i, false)[1]
      if line then
        return line
      end
    end
    return cache[i] or ""
  end

  --- The value of field `i` as `on_submit` will get it.
  ---@param i integer
  ---@return string
  local function value_of(i)
    local f = fields[i]
    if f.kind == "select" then
      return f.choices[f.choice]
    end
    local line = row_text(i)
    if f.expand_env then
      line = expand_path(line)
    end
    return line
  end

  ---@return table<string, string>
  local function collect()
    local out = {}
    for i, f in ipairs(fields) do
      out[f.name] = value_of(i)
    end
    return out
  end

  --- Why field `i` is not acceptable, nil when it is.
  ---@param i integer
  ---@return string|nil
  local function problem(i)
    local f = fields[i]
    local value = value_of(i)
    if vim.trim(value) == "" then
      return f.required and required_message or nil
    end
    if not f.validate then
      return nil
    end
    local called, ok, err = pcall(f.validate, value)
    if not called then
      return one_line(ok)
    end
    if ok then
      return nil
    end
    return err ~= nil and one_line(err) or "invalid"
  end

  --- Validate field `i`, remember the message and say whether it passed.
  ---@param i integer
  ---@return boolean
  local function check(i)
    errors[i] = problem(i)
    return errors[i] == nil
  end

  --- Size the window to what is shown (wrapped values and error lines count)
  --- and keep it centered when it was opened that way.
  local function fit()
    if not surf:is_valid() then
      return
    end
    local ok, th = pcall(api.nvim_win_text_height, winid, {})
    local want = ok and th.all or (n + 2 + vim.tbl_count(errors))
    want = math.max(1, math.min(want, max_height))
    if want == api.nvim_win_get_height(winid) then
      return
    end
    local cfg = { height = want }
    if centered then
      cfg.relative = "editor"
      cfg.row = math.max(0, math.floor((vim.o.lines - want) / 2 - 1))
      cfg.col = math.max(0, math.floor((vim.o.columns - win_w) / 2))
    end
    pcall(api.nvim_win_set_config, winid, cfg)
  end

  local function paint()
    if not surf:is_valid() then
      return
    end
    api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
    for i, f in ipairs(fields) do
      local row = i - 1
      if f.kind == "select" then
        pcall(api.nvim_buf_set_extmark, bufnr, NS, row, 0, {
          virt_text = { { "  ◂ ▸", "KitMuted" } },
          virt_text_pos = "eol",
        })
      elseif f.secret then
        input.conceal_line(bufnr, NS, row, f.mask)
      end
      if errors[i] then
        pcall(api.nvim_buf_set_extmark, bufnr, NS, row, 0, {
          virt_lines = { { { "✗ " .. clip(errors[i], text_w - 2), "KitError" } } },
        })
      end
    end
    buttons.paint(bufnr, BTN_NS, ranges, focus > n and focus - n or nil)
    view.focus = focus <= n and focus or nil
    -- The labels are the 'statuscolumn': a change of focus is not a change of
    -- any line, so ask for it to be drawn again.
    pcall(api.nvim__redraw, { win = winid, statuscolumn = true })
  end

  --- Put the focus on position `p` (a field or a button): validate the field
  --- that is left, then set up the mode the new one needs -- Insert mode on a
  --- text row, a locked buffer in Normal mode on a select or a button.
  ---@param p integer
  ---@param col? integer  # byte column for the cursor on a text row (default: the end)
  local function goto_pos(p, col)
    if done or not surf:is_valid() then
      return
    end
    -- Keys that arrive in one go (a macro, a paste that carries a tab) can get here
    -- before the `TextChanged` of the row being left: settle the layout and take that
    -- row's text now, or a later repair would write a stale copy back over it.
    keep_layout()
    local old = focus
    if old <= n and fields[old].kind == "text" then
      cache[old] = row_text(old)
    end
    -- The first call only puts the focus somewhere: no field has been left yet.
    if started and p ~= old and old <= n then
      check(old)
    end
    started = true
    focus = p
    local f = fields[p]
    if f and f.kind == "text" then
      vim.bo[bufnr].modifiable = true
      local line = row_text(p)
      if col and col < #line then
        pcall(api.nvim_win_set_cursor, winid, { p, col })
        vim.cmd("startinsert")
      else
        pcall(api.nvim_win_set_cursor, winid, { p, #line })
        vim.cmd("startinsert!")
      end
    else
      vim.bo[bufnr].modifiable = false
      pcall(vim.cmd, "stopinsert")
      local r = ranges[p - n]
      pcall(api.nvim_win_set_cursor, winid, { p <= n and p or n + 2, p <= n and 0 or r.start_col })
    end
    paint()
    fit()
  end

  --- Leave the sheet. Callbacks run after the window is gone; Insert mode (which
  --- is the editor's, not the window's) is left unless a callback has just
  --- opened a window to type into -- the next prompt of a chain, waiting for it:
  --- one that counts itself with `input.mark_opened`, or any other modifiable float
  --- that the focus did not return to (the window this one was opened from is one
  --- that was there before: it is not waiting for anything).
  ---@param ok boolean
  local function finish(ok)
    if done then
      return
    end
    done = true
    local values = ok and collect() or nil
    views[winid] = nil
    local opened_before = input.opened_count()
    surf:close()
    local back_to = api.nvim_get_current_win()
    local cb = ok and opts.on_submit or opts.on_cancel
    local called, err = pcall(function()
      if cb then
        cb(values)
      end
    end)
    local cur = api.nvim_get_current_win()
    local prompt_open = input.opened_count() ~= opened_before
      or (
        cur ~= back_to
        and api.nvim_win_get_config(cur).relative ~= ""
        and vim.bo[api.nvim_win_get_buf(cur)].modifiable
      )
    if not prompt_open then
      pcall(vim.cmd, "stopinsert")
    end
    if any_secret then
      input.scrub_insert_traces()
    end
    if not called then
      error(err, 0)
    end
  end

  --- Check again the fields that name field `i` in `depends_on`. Only one that has
  --- something to say -- a value, or a message already showing -- so a field the
  --- user has not got to yet stays quiet.
  ---@param i integer
  local function recheck_dependents(i)
    local name = fields[i].name
    for j, g in ipairs(fields) do
      if
        j ~= i
        and vim.tbl_contains(g.depends_on, name)
        and (errors[j] ~= nil or vim.trim(value_of(j)) ~= "")
      then
        check(j)
      end
    end
  end

  --- Check every field; the position of the first one that fails, nil when all pass.
  ---@return integer|nil
  local function check_all()
    local first
    for i = 1, n do
      if not check(i) and not first then
        first = i
      end
    end
    return first
  end

  local function submit()
    if done then
      return
    end
    keep_layout()
    local first = check_all()
    if first then
      goto_pos(first)
      return
    end
    finish(true)
  end

  ---@param b integer  # 1 = Submit, 2 = Cancel
  local function press(b)
    if b == 1 then
      submit()
    else
      finish(false)
    end
  end

  --- Show choice `idx` of select field `i`.
  ---@param i integer
  ---@param idx integer
  local function set_choice(i, idx)
    local f = fields[i]
    f.choice = idx
    f.text = f.choices[idx]
    cache[i] = f.text
    write(function()
      api.nvim_buf_set_lines(bufnr, i - 1, i, false, { f.text })
    end)
    if errors[i] or f.live then
      check(i)
    end
    recheck_dependents(i)
    paint()
    fit()
  end

  ---@param i integer
  ---@param delta integer
  local function cycle(i, delta)
    set_choice(i, buttons.wrap(fields[i].choice, delta, #fields[i].choices))
  end

  --- `kit.select` over a select field's choices; a pick moves on to the next
  --- field. If the chooser cannot open, the choice is cycled instead.
  ---@param i integer
  local function pick(i)
    local f = fields[i]
    local opened = select.open({
      items = f.choices,
      title = f.label,
      initial_index = f.choice,
      on_select = function(_, idx)
        if done then
          return
        end
        set_choice(i, idx)
        surf:focus()
        goto_pos(i + 1)
      end,
      on_cancel = function()
        if not done and surf:is_valid() then
          surf:focus()
        end
      end,
    })
    if not opened then
      cycle(i, 1)
    end
  end

  ---@param delta integer
  ---@param wrap boolean
  local function move(delta, wrap)
    local total = n + NBUTTONS
    local p = focus + delta
    if wrap then
      p = (p - 1) % total + 1
    else
      p = math.max(1, math.min(p, total))
    end
    goto_pos(p)
  end

  local function enter()
    if focus > n then
      press(focus - n)
      return
    end
    local f = fields[focus]
    if f.kind == "select" then
      pick(focus)
    elseif focus == n then
      submit()
    else
      goto_pos(focus + 1)
    end
  end

  --- `h`/`l` and the arrows in Normal mode: along the buttons, through a select's
  --- choices, and what they always are on a text row.
  ---@param delta integer
  ---@param key string
  local function horizontal(delta, key)
    local f = fields[focus]
    if focus > n then
      goto_pos(n + buttons.wrap(focus - n, delta, NBUTTONS))
    elseif f.kind == "select" then
      cycle(focus, delta)
    else
      pass_through(key)
    end
  end

  local function space()
    local f = fields[focus]
    if focus > n then
      press(focus - n)
    elseif f.kind == "select" then
      pick(focus)
    else
      pass_through("<Space>")
    end
  end

  --- A left click: on a button it focuses and presses it (as in `kit.confirm`);
  --- on a field's row it puts the focus there, the cursor where it was clicked;
  --- anywhere else it is the click it would have been without this mapping.
  local function on_click()
    local b, pos = buttons.hit(ranges, winid)
    if b then
      -- No `goto_pos(n + b)` first: it stops Insert mode (which only takes effect once
      -- this mapping returns), and a refused submit then puts the focus back on the
      -- first bad field with a `startinsert` that is ignored while Insert mode is still
      -- on -- the field would end up in Normal mode, typed text being commands. A
      -- refused submit moves the focus itself; a pressed button needs none.
      press(b)
    elseif not pos then
      pass_through("<LeftMouse>")
    elseif pos.line >= 1 and pos.line <= n then
      goto_pos(pos.line, math.max(0, pos.column - 1))
    end
  end

  --- A paste with a newline in it (a clipboard that ends in one is the usual
  --- case), `<C-j>` or a `dd` from `<C-o>` change the number of lines, which
  --- are the layout: join what was pasted into the field's row again, or put the
  --- rows back as they were, and rewrite the button row under them.
  keep_layout = function()
    if not surf:is_valid() then
      return
    end
    local count = api.nvim_buf_line_count(bufnr)
    if count == n + 2 then
      return
    end
    local current = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local extra = count - (n + 2)
    local rows = vim.deepcopy(cache)
    if extra > 0 and focus <= n then
      local parts = {}
      for k = focus, focus + extra do
        if current[k] and current[k] ~= "" then
          parts[#parts + 1] = current[k]
        end
      end
      rows[focus] = table.concat(parts, " ")
    end
    rows[n + 1] = ""
    rows[n + 2] = btn_line
    write(function()
      api.nvim_buf_set_lines(bufnr, 0, -1, false, rows)
    end)
    if focus <= n then
      pcall(api.nvim_win_set_cursor, winid, { focus, #rows[focus] })
    end
  end

  local function on_change()
    if done or not surf:is_valid() then
      return
    end
    keep_layout()
    local f = fields[focus]
    if f and f.kind == "text" then
      -- `TextChanged` also fires once for the writes that built the sheet, and for
      -- anything else that changed no text: only a row that really changed is checked,
      -- so a `live` field is not flagged just because the sheet opened.
      local text = row_text(focus)
      if text ~= cache[focus] then
        cache[focus] = text
        if errors[focus] or f.live then
          check(focus)
        end
        recheck_dependents(focus)
      end
    end
    paint()
    fit()
  end

  --- The focus is the truth, the cursor follows it: whatever moved the cursor
  --- off its row (`<C-o>G`, a stray motion in Normal mode) is undone.
  local function on_cursor()
    if done or not surf:is_valid() then
      return
    end
    local want = focus <= n and focus or n + 2
    if api.nvim_win_get_cursor(winid)[1] ~= want then
      local col = focus <= n and fields[focus].kind == "text" and #row_text(focus) or 0
      pcall(api.nvim_win_set_cursor, winid, { want, col })
    end
  end

  -- The button row, laid out for the width the float really got and centered
  -- across the whole float (the label column is not part of the text area).
  btn_line, ranges = buttons.layout(btn_labels, math.max(win_w - 2 * col_w, btn_w), n + 1)
  write(function()
    api.nvim_buf_set_lines(bufnr, n + 1, n + 2, false, { btn_line })
  end)

  local key = { buffer = bufnr, nowait = true }
  local both = { "i", "n" }

  -- With a popup open, the completion keys keep their meaning.
  local function completing(f)
    return f and f.completion ~= nil and f.kind == "text"
  end

  vim.keymap.set(both, "<Tab>", function()
    local f = fields[focus]
    if completing(f) then
      if fn.pumvisible() == 1 then
        pass_through("<C-n>")
      else
        input.complete(bufnr, winid, f.completion)
      end
      return
    end
    move(1, true)
  end, key)
  vim.keymap.set(both, "<S-Tab>", function()
    if fn.pumvisible() == 1 then
      pass_through("<C-p>")
    else
      move(-1, true)
    end
  end, key)
  vim.keymap.set(both, "<Down>", function()
    if fn.pumvisible() == 1 then
      pass_through("<Down>")
    else
      move(1, false)
    end
  end, key)
  vim.keymap.set(both, "<Up>", function()
    if fn.pumvisible() == 1 then
      pass_through("<Up>")
    else
      move(-1, false)
    end
  end, key)
  vim.keymap.set("n", "j", function()
    move(1, false)
  end, key)
  vim.keymap.set("n", "k", function()
    move(-1, false)
  end, key)
  vim.keymap.set(both, "<CR>", function()
    -- Accept the highlighted completion candidate instead of moving on; a second
    -- <CR> (popup closed) moves. Fed rather than returned: this must not be an
    -- <expr> mapping, whose textlock would block the window changes below.
    if fn.pumvisible() == 1 then
      pass_through("<C-y>")
      return
    end
    enter()
  end, key)
  vim.keymap.set(both, "<Esc>", function()
    finish(false)
  end, key)
  vim.keymap.set("n", "h", function()
    horizontal(-1, "h")
  end, key)
  vim.keymap.set("n", "<Left>", function()
    horizontal(-1, "<Left>")
  end, key)
  vim.keymap.set("n", "l", function()
    horizontal(1, "l")
  end, key)
  vim.keymap.set("n", "<Right>", function()
    horizontal(1, "<Right>")
  end, key)
  vim.keymap.set("n", "<Space>", space, key)
  vim.keymap.set(both, "<LeftMouse>", on_click, key)

  autocmd.create({ "TextChanged", "TextChangedI", "TextChangedP" }, on_change, {
    buffer = bufnr,
    record = false,
    desc = "lib.nvim.ui.kit.sheet: validate an edited field, keep the layout, fit the window",
  })
  autocmd.create({ "CursorMoved", "CursorMovedI" }, on_cursor, {
    buffer = bufnr,
    record = false,
    desc = "lib.nvim.ui.kit.sheet: keep the cursor on the focused row",
  })

  surf:on_close(function()
    views[winid] = nil
    finish(false)
  end)

  ---@param which string|integer
  ---@return integer|nil
  local function index_of(which)
    if type(which) == "number" and fields[which] then
      return which
    end
    for i, f in ipairs(fields) do
      if f.name == which then
        return i
      end
    end
    return nil
  end

  --- Submit as if the Submit button were pressed (validation included).
  function surf.submit()
    submit()
  end

  --- Cancel as if `<Esc>` were pressed.
  function surf.cancel()
    finish(false)
  end

  --- Check every field now, so every message shows, without submitting or moving
  --- the focus. Whether they all passed.
  ---@return boolean
  function surf.validate()
    local first = check_all()
    paint()
    fit()
    return first == nil
  end

  --- Put the focus on a field, by name or position.
  ---@param which string|integer
  function surf.focus_field(_, which)
    local i = index_of(which)
    if i then
      goto_pos(i)
    end
  end

  --- Where the focus is (a field name, or "submit"/"cancel"), the values as
  --- `on_submit` would get them, and the messages showing right now by field name.
  ---@return { focus: string, values: table<string, string>, errors: table<string, string> }
  function surf.state()
    local errs = {}
    for i, f in ipairs(fields) do
      if errors[i] then
        errs[f.name] = errors[i]
      end
    end
    local where = focus <= n and fields[focus].name or (focus == n + 1 and "submit" or "cancel")
    return { focus = where, values = collect(), errors = errs }
  end

  local start = opts.focus ~= nil and index_of(opts.focus) or 1
  goto_pos(start or 1)
  -- The first draw: the focus is set, no field has been left, nothing is checked.
  paint()
  fit()

  return surf
end

return M
