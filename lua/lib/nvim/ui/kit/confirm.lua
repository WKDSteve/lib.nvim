---@module 'lib.nvim.ui.kit.confirm'
--- Button-confirm component: a question with a row of horizontal buttons
--- reachable with h/l (or arrows / <Tab>), <CR> confirms the focused button,
--- <Esc>/q cancels. A left click on a button focuses *and* confirms it in
--- one action, like a real button (not a two-step "click to focus, Enter to
--- confirm" — `state.ranges`, already tracked for the focus-highlight
--- extmark, is exactly the per-button screen geometry a click needs to hit-
--- test against, so this is additive over existing state, not new state).
--- The focused button is highlighted with the theme's `KitSelection` group.
--- This is the Phase-4 "cherry on top" of the UI-kit design
--- §9; sketch: assets/ui-kit/confirm-buttons.svg.
---
--- Answer contract (matches the list-based confirm in prompt.lua):
---   - default { "Yes", "No" }  -> on_answer(boolean)  (Yes == true)
---   - custom `choices`         -> on_answer(choice_string)
---   - cancel (<Esc>/q)         -> on_answer(false) for the default case,
---                                 on_answer(nil) for a custom choice list.
---
--- Options beyond `question`/`choices`/`title`/`theme`:
---   - `default`: the button that starts focused (index or label; default the safe
---     button: No, else a no/cancel-style label, else the first button).
---   - `choices` as a list of labels, or as a `vim.fn.confirm` string ("&Delete\n&Cancel": buttons
---     separated by a newline, `&` before the letter that picks the button). Every button has a
---     hotkey, marked in its label: `y`/`n` for Yes/No, the `&` letters, else the first free letter
---     of the label, and the digits 1-9 (see `hotkeys`). h, l and q stay navigation.
---   - `<C-c>` cancels like <Esc>; so does focus moving elsewhere, unless `keep_on_focus_lost`.
---   - `kind = "danger" | "warn" | "info"`: border and title in the status colour.
---   - `legend = true`: a one-line key legend in the window's winbar.
---
--- Every way the dialog can end answers exactly once: a button, <Esc>/q, the float closed from
--- outside (`:q`, `:only`), another dialog replacing it, or `close()`. The last three count as
--- a cancel.

local surface = require("lib.nvim.ui.kit.surface")
local buttons = require("lib.nvim.ui.kit.buttons")
local map = require("lib.nvim.bindings.keymap")
local nul_safe = require("lib.lua.strings.core").nul_safe
local max_float_width = require("lib.nvim.window.max_float_width")
local hook = require("lib.nvim.ui.kit.hook")

local api = vim.api

local M = {}

--- A question longer than this is cut (with an ellipsis) before it is wrapped: the window shows a few
--- dozen lines at most, and wrapping what cannot be shown is wasted time on a huge text.
local MAX_QUESTION_CHARS = 4000

--- Single active confirm dialog (mirrors the chooser's single-instance model).
local state = {
  surf = nil,
  labels = {},
  focus = 1,
  ranges = {}, -- per-button { row, start_col, end_col } (0-based, byte cols)
  custom = false,
  on_answer = nil,
  ns = api.nvim_create_namespace("lib_kit_confirm"),
  hot_ns = api.nvim_create_namespace("lib_kit_confirm_hotkeys"),
}

---@internal
--- `line` cut into lines of at most `width` display cells: at spaces where there are some, inside
--- a word that is wider than `width` itself. A line that fits is returned as it is (indent and
--- repeated spaces kept); only a line that has to be cut is re-joined from its words.
---@param line string
---@param width integer
---@return string[]
local function wrap_line(line, width)
  if vim.fn.strdisplaywidth(line) <= width then
    return { line }
  end
  local out, cur = {}, ""
  local function push_word(word)
    local sep = cur == "" and "" or " "
    if vim.fn.strdisplaywidth(cur .. sep .. word) <= width then
      cur = cur .. sep .. word
      return
    end
    if cur ~= "" then
      out[#out + 1] = cur
      cur = ""
    end
    -- A word wider than the width: break it between characters, in one pass over them (a long
    -- unbroken line must not cost time quadratic in its length).
    if vim.fn.strdisplaywidth(word) > width then
      local piece, used = {}, 0
      for _, ch in ipairs(vim.fn.split(word, "\\zs")) do
        local w = vim.fn.strdisplaywidth(ch)
        if used + w > width and #piece > 0 then
          out[#out + 1] = table.concat(piece)
          piece, used = {}, 0
        end
        piece[#piece + 1] = ch
        used = used + w
      end
      word = table.concat(piece)
    end
    cur = word
  end
  for word in line:gmatch("%S+") do
    push_word(word)
  end
  if cur ~= "" or #out == 0 then
    out[#out + 1] = cur
  end
  return out
end

---@internal
---@param s string
---@param width integer
---@return string
local function center(s, width)
  local pad = math.max(0, math.floor((width - vim.fn.strdisplaywidth(s)) / 2))
  return string.rep(" ", pad) .. s
end

---@internal
--- Repaint the focus highlight on the current button.
local function render_focus()
  buttons.paint(state.surf and state.surf.bufnr, state.ns, state.ranges, state.focus)
end

--- Whether a confirm dialog is currently open.
---@return boolean
function M.is_open()
  return state.surf ~= nil and state.surf:is_valid()
end

---@internal
--- Take the dialog's state and reset it, so whatever happens next (the float's `WinClosed`
--- hook, a second `finish`) finds nothing left to answer. Returns what the answer needs.
---@return Lib.UI.Kit.Surface|nil surf
---@return function|nil cb
---@return boolean custom
---@return string[] labels
---@return integer focus
local function take_state()
  local surf, cb, custom, labels, focus =
    state.surf, state.on_answer, state.custom, state.labels, state.focus
  state.surf = nil
  state.labels = {}
  state.ranges = {}
  state.focus = 1
  state.custom = false
  state.on_answer = nil
  return surf, cb, custom, labels, focus
end

---@internal
--- Call `cb` with the answer: the focused button when `confirmed` (a label and its 1-based index
--- for a custom choice list), the cancel value otherwise (`false`, or `nil` for a custom list).
---@param cb function|nil
---@param custom boolean
---@param labels string[]
---@param focus integer
---@param confirmed boolean
local function deliver(cb, custom, labels, focus, confirmed)
  if not cb then
    return
  end
  if confirmed then
    if custom then
      -- the index as well: a caller that needs the position must not search the labels for it
      -- (two buttons can carry the same text)
      cb(labels[focus], focus)
    else
      cb(focus == 1)
    end
  elseif custom then
    cb(nil)
  else
    cb(false)
  end
end

---@internal
--- Take the dialog's state, close its float and hand back what the answer needs. The state is
--- already empty when the float's `WinClosed` hook runs, so it finds nothing to answer.
---@return function|nil cb
---@return boolean custom
---@return string[] labels
---@return integer focus
local function retire()
  local surf, cb, custom, labels, focus = take_state()
  if surf then
    -- A float that cannot be closed must not take the answer with it.
    pcall(surf.close, surf)
  end
  return cb, custom, labels, focus
end

---@internal
--- End the dialog and answer it once: with the focused button when `confirmed`, with the
--- cancel value otherwise. Idempotent.
---@param confirmed boolean
local function finish(confirmed)
  local cb, custom, labels, focus = retire()
  deliver(cb, custom, labels, focus, confirmed)
end

--- Close the dialog (idempotent). An open dialog is answered as cancelled: the module
--- promises an answer on every path, and a `kit.ask` or a caller waiting on it relies on that.
function M.close()
  finish(false)
end

--- A copy of the open dialog's button ranges (`{ row, start_col, end_col }`, 0-based, byte
--- columns), in button order. Empty when no dialog is open.
---@return Lib.UI.Kit.ButtonRange[]
function M.button_ranges()
  return vim.deepcopy(state.ranges)
end

--- 1-based index of the currently focused button.
---@return integer
function M.current_focus()
  return state.focus
end

---@internal
--- Which button (if any) the mouse is currently over -- the hit-test itself
--- (live `getmousepos()` against `state.ranges`) is `lib.nvim.ui.kit.buttons.hit`.
---@return integer|nil
local function button_at_mousepos()
  if not M.is_open() then
    return nil
  end
  return (buttons.hit(state.ranges, state.surf.winid))
end

--- Focus and confirm whichever button is under the mouse, if any. A click
--- that misses every button (blank space in the dialog) is a no-op, not a
--- cancel — matches clicking empty space anywhere else in the kit, which
--- never dismisses the surface either.
function M.click()
  local i = button_at_mousepos()
  if not i then
    return
  end
  state.focus = i
  render_focus()
  M.confirm()
end

--- Focus button `index` and confirm it, like a click on it (what a hotkey does).
---@param index integer  # 1-based
function M.pick(index)
  if not M.is_open() or not state.labels[index] then
    return
  end
  state.focus = index
  render_focus()
  M.confirm()
end

--- Move focus by `delta` buttons, wrapping around.
---@param delta integer
function M.move(delta)
  if not M.is_open() then
    return
  end
  state.focus = buttons.wrap(state.focus, delta, #state.labels)
  render_focus()
end

--- Confirm the focused button, fire on_answer, then close.
function M.confirm()
  if not M.is_open() then
    return
  end
  finish(true)
end

--- Cancel the dialog (Esc/q), fire on_answer with the cancelled value, close.
function M.cancel()
  if not M.is_open() then
    return
  end
  finish(false)
end

---@internal
--- The one-line key legend of the winbar. A `%` in a key or text is a statusline item to the
--- winbar (`%{...}` even evaluates an expression), so it is doubled.
---@param entries { lhs: string, legend: string }[]
---@return string
local function legend_text(entries)
  local function plain(x)
    return (tostring(x):gsub("%%", "%%%%"))
  end
  local parts = {}
  for _, e in ipairs(entries) do
    parts[#parts + 1] = ("%%#KitAccent#%s %%#KitMuted#%s"):format(plain(e.lhs), plain(e.legend))
  end
  return " " .. table.concat(parts, "%#KitDim#  │  ") .. "%*"
end

---@internal
--- Set entries of a window's 'winhighlight' (`FloatBorder` -> group), replacing an entry of the same
--- name in place and keeping the others.
---@param winid integer
---@param entries table<string, string>
local function set_winhighlight(winid, entries)
  local parts, seen = {}, {}
  for item in vim.gsplit(vim.wo[winid].winhighlight or "", ",", { plain = true }) do
    local from = item:match("^([^:]+):")
    if from and entries[from] then
      parts[#parts + 1] = from .. ":" .. entries[from]
      seen[from] = true
    elseif item ~= "" then
      parts[#parts + 1] = item
    end
  end
  for from, to in pairs(entries) do
    if not seen[from] then
      parts[#parts + 1] = from .. ":" .. to
    end
  end
  vim.wo[winid].winhighlight = table.concat(parts, ",")
end

--- Keys that move or cancel and so cannot be a button's hotkey.
local RESERVED_KEYS = { h = true, l = true, q = true }

--- The status group of a `kind`, drawn on the border and the title.
local KIND_GROUPS = { danger = "KitError", warn = "KitWarn", info = "KitInfo" }

---@internal
--- Choices given as a `vim.fn.confirm` string -- buttons separated by a newline, `&` in front of
--- the letter that is the button's hotkey -- as labels and hotkeys. A list of labels is taken as
--- it is (a `&` in a list is part of the text); its hotkeys come from `hotkeys` (y/n, first free
--- letter, digits).
---@param choices string|string[]|nil
---@return string[]|nil labels  # nil: use the Yes/No default
---@return table<integer, { key: string, col: integer }> marks  # per button: its `&` key and the byte column of that letter in the label
local function parse_choices(choices)
  if type(choices) == "table" and #choices > 0 then
    return choices, {}
  end
  if type(choices) ~= "string" or choices == "" then
    return nil, {}
  end
  local labels, marks = {}, {}
  for piece in vim.gsplit(choices, "\n", { plain = true }) do
    if piece ~= "" then
      -- `&&` is a literal ampersand, the first single `&` marks the hotkey (as in vim.fn.confirm)
      local out, mark = {}, nil
      local i = 1
      while i <= #piece do
        local c = piece:sub(i, i)
        if c == "&" and piece:sub(i + 1, i + 1) == "&" then
          out[#out + 1] = "&"
          i = i + 2
        elseif c == "&" and not mark and i < #piece then
          local char = vim.fn.strcharpart(piece:sub(i + 1), 0, 1)
          mark = { key = char, col = #table.concat(out) }
          i = i + 1
        else
          out[#out + 1] = c
          i = i + 1
        end
      end
      labels[#labels + 1] = table.concat(out)
      marks[#labels] = mark
    end
  end
  if #labels == 0 then
    return nil, {}
  end
  return labels, marks
end

---@internal
--- Hand a dialog hook's answer (`kit.set_dialog_hook`) to `opts.on_answer` the way the dialog would:
--- with `choices` an index or a label picks the button (`nil`: dismissed), a plain question takes
--- `true` / `1` as yes and anything else as no.
---@param opts table
---@param value any
local function answer_hooked(opts, value)
  local labels = parse_choices(opts.choices)
  local focus ---@type integer|nil
  if labels then
    if type(value) == "number" and labels[value] then
      focus = value
    elseif type(value) == "string" then
      for i, label in ipairs(labels) do
        if label == value then
          focus = i
          break
        end
      end
    end
  elseif value == true or value == 1 then
    focus = 1
  end
  deliver(opts.on_answer, labels ~= nil, labels or {}, focus or 1, focus ~= nil)
end

---@internal
--- 1-based index of the button `default` names (an index, or a label). When it names none, the
--- safe button: "No" of the Yes/No default, else the first button labelled no/cancel/nein/abbrechen
--- (case-insensitive, hotkey `&` ignored), else the first button (a menu-like list has no safer
--- one). A stray <CR> then never confirms a destructive action where the dialog offers a way out.
---@param default integer|string|nil
---@param labels string[]
---@return integer
local function default_index(default, labels)
  if type(default) == "number" and labels[default] then
    return default
  end
  if type(default) == "string" then
    for i, l in ipairs(labels) do
      if l == default then
        return i
      end
    end
  end
  if #labels == 2 and labels[1] == "Yes" and labels[2] == "No" then
    return 2
  end
  for i, l in ipairs(labels) do
    local plain = tostring(l):lower():gsub("&", "")
    if plain == "no" or plain == "cancel" or plain == "nein" or plain == "abbrechen" then
      return i
    end
  end
  return 1
end

---@internal
--- Whether `ch` (one character) is a letter: it has an upper and a lower case. Digits and
--- punctuation are not, and neither is a letter of a script without case (those can still be
--- given with `&`).
---@param ch string
---@return boolean
local function is_letter(ch)
  return ch ~= "" and vim.fn.tolower(ch) ~= vim.fn.toupper(ch)
end

---@internal
--- The answer word a label starts with: "yes" for "Yes" / "Yes, delete", "no" for "No" /
--- "No, keep", nil otherwise ("Nope" and "Not now" are neither).
---@param label string
---@return "yes"|"no"|nil
local function answer_word(label)
  -- a NUL byte is E976 to `tolower()`; the SOH `nul_safe` puts in its place is as long
  local lower = vim.fn.tolower(nul_safe(tostring(label)))
  if lower:match("^yes%f[%A]") then
    return "yes"
  end
  if lower:match("^no%f[%A]") then
    return "no"
  end
  return nil
end

--- Superscript digits, drawn after the label of a button that has no letter key.
local SUPERSCRIPT = {
  ["0"] = "⁰",
  ["1"] = "¹",
  ["2"] = "²",
  ["3"] = "³",
  ["4"] = "⁴",
  ["5"] = "⁵",
  ["6"] = "⁶",
  ["7"] = "⁷",
  ["8"] = "⁸",
  ["9"] = "⁹",
}

--- The one-cell glyph for digit `d`: its superscript, or the plain digit where the superscript
--- is wider ('ambiwidth' = double makes ¹ ² ³ two cells, which would cover the `]`).
---@param d string
---@return string
local function digit_glyph(d)
  local sup = SUPERSCRIPT[d]
  return (sup and vim.fn.strdisplaywidth(sup) == 1) and sup or d
end

---@internal
--- Which key picks which button, and where each button shows its key. Deterministic, in this
--- order (a key goes to the first claim; nothing later takes it away):
---
---   1. `y` / `n`: the Yes and No buttons -- the Yes/No default, or the first button whose label
---      starts with the word "Yes" / "No" ("Yes, delete") -- as in the `more` prompt.
---   2. The `&` letters of a `vim.fn.confirm` string, in button order. One that is reserved (`h`,
---      `l`, `q` move or cancel) or already taken is refused and reported.
---   3. Every button still without a letter: the first letter of its label, else the next letter of
---      the label that is still free, left to right; buttons earlier in the row choose first.
---   4. Digits: a button labelled with a single digit owns that digit (a 0-5 scale), the other
---      digits 1-9 pick the button at that position -- every button, with a letter or without.
---      A button still without any key then takes the first free digit (1-9, then 0); one past
---      that (more than ten buttons without a free letter) is reached with h/l only.
---
--- Keys are lower-case here; the dialog maps the capital too.
---@param labels string[]
---@param marks table<integer, { key: string, col: integer }>  # the `&` letters of `parse_choices`
---@param custom boolean
---@return table<string, integer> keys  # lower-case key -> button index
---@return string[] refused  # the `&` letters that could not be used, for a warning
---@return table<integer, { col: integer, text: string }[]> shown  # per button: the label letters to mark (byte column, text)
---@return table<integer, string> digits  # per button without a letter key: its digit key ("0"-"9"), shown next to its label
---@return boolean answers  # y and n both went to Yes/No buttons in step 1
local function hotkeys(labels, marks, custom)
  local keys, refused, shown = {}, {}, {}
  local function show(i, col, text)
    shown[i] = shown[i] or {}
    shown[i][#shown[i] + 1] = { col = col, text = text }
  end
  --- Claim `key` for button `i`; `col`/`text` mark the letter in the label (nil: not in it).
  ---@return boolean taken
  local function claim(key, i, col, text)
    local k = vim.fn.tolower(key)
    if RESERVED_KEYS[k] or (keys[k] and keys[k] ~= i) then
      return false
    end
    keys[k] = i
    if col then
      show(i, col, text)
    end
    return true
  end

  -- 1. y/n on the Yes/No buttons
  if not custom then
    claim("y", 1, 0, "Y")
    claim("n", 2, 0, "N")
  else
    for i, label in ipairs(labels) do
      local word = answer_word(label)
      local key = word and word:sub(1, 1)
      if key and not keys[key] then
        claim(key, i, 0, tostring(label):sub(1, 1))
      end
    end
  end
  -- only a y/n pair that answers Yes/No is worth the legend's "y/n answer" (not Yank/Next)
  local answers = keys.y ~= nil and keys.n ~= nil

  -- 2. the `&` letters, in button order, so the first button that asks for a key gets it
  for i = 1, #labels do
    local m = marks[i]
    if m then
      local k = vim.fn.tolower(m.key)
      if keys[k] == i then
        -- already this button's (`&Yes`): the `&` says where the letter is
        shown[i] = { { col = m.col, text = m.key } }
      elseif not claim(m.key, i, m.col, m.key) then
        local why = RESERVED_KEYS[k] and "moves or cancels" or "taken"
        refused[#refused + 1] = ("%q of %q (%s)"):format(m.key, tostring(labels[i]), why)
      end
    end
  end

  -- 3. a letter of the label for every button that has none yet
  for i, label in ipairs(labels) do
    if not shown[i] then
      local text = nul_safe(tostring(label))
      local col = 0
      for _, ch in ipairs(vim.fn.split(text, "\\zs")) do
        if is_letter(ch) and claim(ch, i, col, ch) then
          break
        end
        col = col + #ch
      end
    end
  end

  -- 4. digits
  for i, label in ipairs(labels) do
    if type(label) == "string" and label:match("^[0-9]$") and not keys[label] then
      keys[label] = i
      if not shown[i] then
        show(i, 0, label)
      end
    end
  end
  local digits = {}
  for i = 1, math.min(#labels, 9) do
    local d = tostring(i)
    keys[d] = keys[d] or i
    if not shown[i] and keys[d] == i then
      digits[i] = d
    end
  end
  -- a button still without any key (its place digit went to a digit label, or it is past the
  -- ninth) takes the first free digit, 1-9 then 0; past that it is reached with h/l only
  local has_key = {}
  for _, i in pairs(keys) do
    has_key[i] = true
  end
  for i = 1, #labels do
    if not has_key[i] then
      for _, d in ipairs({ "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" }) do
        if not keys[d] then
          keys[d], has_key[i], digits[i] = i, true, d
          break
        end
      end
    end
  end
  return keys, refused, shown, digits, answers
end

--- How long a waiting `ask` waits for a free moment at most, before it is answered "no".
M.ASK_MAX_WAIT_MS = 10 * 60 * 1000

--- How often a waiting `ask` looks again whether the dialog in front of it is still there.
M.ASK_RECHECK_MS = 1000

--- A question that pops up on its own ignores letter and digit hotkeys for this long after it
--- opens: keys typed ahead for the editor must not answer a question nobody saw coming.
M.ASK_HOTKEY_GRACE_MS = 500

--- The questions `ask` is holding back, oldest first (a ticket each).
---@type table[]
local waiting = {}

---@param ticket table
local function leave_queue(ticket)
  for i, t in ipairs(waiting) do
    if t == ticket then
      table.remove(waiting, i)
      return
    end
  end
end

--- A question that waits its turn and always answers, "no" included.
---
--- `open` is single-instance: opening a dialog closes the open one and answers it as
--- cancelled, so a question raised while another is showing (a stream that ends minutes
--- after the command was typed) would be dropped with a "no" nobody gave, and the user's open
--- dialog would vanish under their hands. `ask` instead waits until no modal kit dialog is
--- open (a confirm, but also an input, a select or a sheet: `lib.nvim.ui.kit.modal`), then shows its
--- own. It subscribes once and is woken when the last one closes; nothing polls. Anything
--- that is not an explicit answer -- the wait lasts `max_wait_ms` -- calls `on_answer` with the
--- cancel value (`false`, or `nil` for a `choices` list), so callers treat an unanswered
--- question as "no" without a second code path. When the float cannot be opened at all it
--- falls back to `vim.ui.select` (Yes/No, or the choices).
---
--- Takes the options of `open` (`question`, `choices`, `title`, `theme`, ...). Several waiting
--- questions are shown in the order they were asked, whichever of them is woken first.
---
--- `on_answer` fires at most once, and never when `abandoned()` is true by
--- the time the question's turn comes.
---@param opts { question: string, on_answer: fun(answer: boolean|string|nil, index?: integer), abandoned?: (fun(): boolean), choices?: string|string[], default?: integer|string, kind?: string, legend?: boolean, keep_on_focus_lost?: boolean, theme?: any, title?: string, max_wait_ms?: integer }
---@return nil
function M.ask(opts)
  opts = opts or {}
  if hook.intercept("ask", opts, function(value)
    answer_hooked(opts, value)
  end) then
    return
  end
  local modal = require("lib.nvim.ui.kit.modal")
  local max_wait = opts.max_wait_ms or M.ASK_MAX_WAIT_MS
  local labels = parse_choices(opts.choices)
  local custom = labels ~= nil
  local answered = false
  local done = false -- left the queue: shown, abandoned or failed; the timer must not answer for it
  local ticket = {}
  waiting[#waiting + 1] = ticket
  local timer ---@type uv.uv_timer_t|nil
  local recheck ---@type uv.uv_timer_t|nil
  local cancel_wait ---@type (fun())|nil

  local function stop_timer()
    if timer then
      pcall(timer.stop, timer)
      pcall(timer.close, timer)
      timer = nil
    end
    if recheck then
      pcall(recheck.stop, recheck)
      pcall(recheck.close, recheck)
      recheck = nil
    end
  end

  local function answer(value, index)
    if answered then
      return
    end
    answered = true
    stop_timer()
    if opts.on_answer then
      if custom then
        opts.on_answer(value, index)
      else
        opts.on_answer(value == true)
      end
    end
  end

  --- Leave the queue for good: no more waiting, no timer.
  local function drop()
    done = true
    leave_queue(ticket)
    stop_timer()
    if cancel_wait then
      cancel_wait()
      cancel_wait = nil
    end
  end

  local attempt
  local function step()
    cancel_wait = nil
    if answered then
      return
    end
    if opts.abandoned and opts.abandoned() then
      drop()
      return
    end
    if modal.busy() then
      cancel_wait = modal.on_free(attempt)
      -- A dialog can go without the event that wakes the subscribers (a close made with
      -- `eventignore` or `:noautocmd`): look again now and then, slowly, so the question is
      -- not left waiting behind a window that is no longer there.
      if recheck then
        pcall(recheck.stop, recheck)
        pcall(recheck.close, recheck)
      end
      recheck = vim.defer_fn(function()
        recheck = nil
        if answered or done then
          return
        end
        if cancel_wait then
          cancel_wait()
          cancel_wait = nil
        end
        attempt()
      end, M.ASK_RECHECK_MS)
      return
    end
    if waiting[1] ~= ticket then
      -- An older question is first in line and is about to open: look again in a moment rather
      -- than subscribing to a registry that is already free (which would wake at once, for ever).
      local retry = vim.defer_fn(attempt, 20)
      cancel_wait = function()
        pcall(retry.stop, retry)
        pcall(retry.close, retry)
      end
      return
    end
    drop()
    -- `open` answers "no" synchronously and returns nil when the float cannot be
    -- created: a failure to show the question, not an answer, so it is not
    -- forwarded. A dialog that did open and answers at once (a stub, another
    -- implementation) is a real answer and counts.
    local open_opts = vim.tbl_extend("force", {}, opts)
    open_opts.abandoned, open_opts.max_wait_ms = nil, nil
    open_opts.hotkey_grace_ms = M.ASK_HOTKEY_GRACE_MS
    if open_opts.keep_on_focus_lost == nil then
      open_opts.keep_on_focus_lost = true
    end
    local opening = true
    local sync_answer, sync_index, has_sync = nil, nil, false
    open_opts.on_answer = function(value, index)
      if opening then
        sync_answer, sync_index, has_sync = value, index, true
      else
        answer(value, index)
      end
    end
    local shown = M.open(open_opts)
    opening = false
    if shown then
      if has_sync then
        answer(sync_answer, sync_index)
      end
    elseif custom then
      vim.ui.select(labels, { prompt = tostring(opts.question or "") }, function(choice, index)
        answer(choice, index)
      end)
    else
      vim.ui.select({ "Yes", "No" }, { prompt = tostring(opts.question or "") }, function(choice)
        answer(choice == "Yes")
      end)
    end
  end

  -- A step that raises (a throwing `abandoned`, a failing `open`) must not leave its
  -- place in the queue, or every question behind it would wait for ever.
  attempt = function()
    local ok, err = pcall(step)
    if not ok then
      drop()
      -- the question was not shown: it is answered as cancelled rather than left hanging (the
      -- caller may be a coroutine that waits for the answer), and the failure is still raised
      pcall(answer, nil)
      error(err, 0)
    end
  end

  -- One timer for the whole wait: a dialog that stays open for ever must not hold the question.
  timer = vim.defer_fn(function()
    timer = nil
    if answered or done then
      return
    end
    drop()
    -- a question its owner has withdrawn is not answered, not even with "no"
    if opts.abandoned and opts.abandoned() then
      return
    end
    answer(nil)
  end, max_wait)

  attempt()
end

---@internal
--- Build and install the dialog; see `M.open`.
---@param opts table
---@param settle_old fun()  # answers the dialog this one replaces, once this one is in place
---@return Lib.UI.Kit.Surface|nil
local function open_new(opts, settle_old)
  local parsed, marks = parse_choices(opts.choices)
  local custom = parsed ~= nil
  local labels = parsed or { "Yes", "No" }
  local focus0 = default_index(opts.default, labels)

  -- The float is never wider than the window `make_scratch` would clamp it to: sizing and
  -- centering against a wider width pushed the buttons out of the visible window. The question is
  -- wrapped to what fits, the buttons are packed into as many rows as it takes.
  local max_w = max_float_width()
  local wrap_w = math.max(10, max_w - 4)
  local qlines = {}
  local question = nul_safe(tostring(opts.question or ""))
  if vim.fn.strchars(question) > MAX_QUESTION_CHARS then
    question = vim.fn.strcharpart(question, 0, MAX_QUESTION_CHARS) .. "…"
  end
  for _, ql in ipairs(vim.split(question, "\n", { plain = true, trimempty = false })) do
    -- A NUL byte in the question (a case title, say) would raise E976 out of the
    -- `strdisplaywidth()` that sizes and centers it: it is shown as the SOH that measures alike.
    vim.list_extend(qlines, wrap_line(ql, wrap_w))
  end

  -- Width: fit the wider of the question and the button row, plus margin.
  local btn_w = buttons.row_width(labels)
  local q_w = 0
  for _, ql in ipairs(qlines) do
    q_w = math.max(q_w, vim.fn.strdisplaywidth(ql))
  end
  local width = math.min(math.max(btn_w, q_w) + 4, max_w)

  -- The buttons first: how many rows they take decides how much room the question has.
  local button_lines, ranges = buttons.layout_rows(labels, width, 0)
  local max_h = math.max(1, vim.o.lines - 4)
  local room = max_h - #button_lines - 1 - (opts.legend and 1 or 0)
  if room < 1 then
    -- Buttons alone fill the editor: no question, no blank line (the rest is the editor's limit).
    qlines = {}
  elseif #qlines > room then
    qlines = vim.list_slice(qlines, 1, room)
    qlines[room] = wrap_line(qlines[room], wrap_w - 1)[1] .. "…"
  end

  -- Compose lines: question (centered), blank, buttons.
  local lines = {}
  for _, ql in ipairs(qlines) do
    lines[#lines + 1] = center(ql, width)
  end
  if #qlines > 0 then
    lines[#lines + 1] = ""
  end
  local button_row = #lines -- 0-based row of the first button row
  for _, r in ipairs(ranges) do
    r.row = r.row + button_row
  end
  vim.list_extend(lines, button_lines)

  local surf = surface.open({
    modal = true,
    lines = lines,
    theme = opts.theme,
    title = opts.title,
    width = width,
    -- the legend is a winbar: it takes one row of the window
    height = #lines + (opts.legend and 1 or 0),
    relative = opts.relative or "editor",
    enter = true,
    filetype = "lib-kit-confirm",
  })
  if not surf then
    settle_old()
    -- `surface.open` failed to open the float -- a genuine break, not a
    -- user-driven cancel. Without this, on_answer never fires (despite the
    -- module's own "Answer contract" implying it always does) and a
    -- caller (a coroutine, a chain) waiting on it stalls silently. Same "no answer" value
    -- as M.cancel() uses.
    deliver(opts.on_answer, custom, {}, 1, false)
    return nil
  end

  state.surf = surf
  state.labels = labels
  state.ranges = ranges
  state.focus = focus0
  state.custom = custom
  state.on_answer = opts.on_answer
  render_focus()

  -- The float going away by any other route (`:q`, `<C-w>c`, `:only`) is a cancel: without
  -- this the answer never came. Only for this dialog: a replaced one has already been taken
  -- out of `state` by `open`'s own `retire()` and its late `WinClosed` finds nothing to do.
  -- The state is taken here, at once, so a dialog opened next is never answered by mistake; the
  -- answer itself is scheduled: the surface runs this hook under `pcall` inside `WinClosed`,
  -- where an error in the caller's `on_answer` would vanish and window changes are restricted.
  surf:on_close(function()
    if state.surf ~= surf then
      return
    end
    -- Held until the answer is out: a question waiting in `kit.ask` must not open between the
    -- close and the answer (whose handler may open a dialog of its own).
    local release = require("lib.nvim.ui.kit.modal").hold()
    local gone_cb, gone_custom, gone_labels, gone_focus = retire()
    vim.schedule(function()
      local ok, err = pcall(deliver, gone_cb, gone_custom, gone_labels, gone_focus, false)
      release()
      if not ok then
        error(err, 0)
      end
    end)
  end)

  local keys, refused, shown, digits, answers = hotkeys(labels, marks, custom)

  -- The decoration (accents, kind colour, legend, focus hook) is cosmetic: whatever raises in it
  -- must not leave a dialog on screen without keys and without a way to answer.
  local function decorate()
    -- Every button shows its key. A letter of the label is drawn with the accent and underlined
    -- (`KitHotkey`: the underline survives the focus highlight, which recolours the letter), where
    -- the label is shown whole -- a label cut to fit loses the mark of a letter that was cut. A
    -- button without a letter key gets its digit as a small superscript in the space before `]`,
    -- so the box keeps its size and a click still lands where it is drawn. Their own namespace:
    -- the focus highlight clears `state.ns` on every repaint.
    for i, list in pairs(shown) do
      local r = ranges[i]
      local line = r and lines[r.row + 1]
      for _, m in ipairs(line and list or {}) do
        local col = r.start_col + 2 + m.col -- "[ " in front of the label
        if line:sub(col + 1, col + #m.text) == m.text and col + #m.text <= r.end_col - 2 then
          for _, group in ipairs({ "KitAccent", "KitHotkey" }) do
            api.nvim_buf_set_extmark(surf.bufnr, state.hot_ns, r.row, col, {
              end_col = col + #m.text,
              hl_group = group,
              priority = group == "KitAccent" and 90 or 91,
            })
          end
        end
      end
    end
    for i, digit in pairs(digits) do
      local r = ranges[i]
      if r then
        api.nvim_buf_set_extmark(surf.bufnr, state.hot_ns, r.row, r.end_col - 2, {
          virt_text = { { digit_glyph(digit), "KitMuted" } },
          virt_text_pos = "overlay",
          hl_mode = "combine",
          priority = 90,
        })
      end
    end

    -- `kind` colours the border and the title with the status group of the theme, replacing the
    -- theme's own entries of 'winhighlight' (not adding a second one that a re-theme would drop).
    if opts.kind ~= nil then
      local group = KIND_GROUPS[opts.kind]
      if group then
        set_winhighlight(surf.winid, { FloatBorder = group, FloatTitle = group })
      else
        local msg = ("lib.nvim.ui.kit.confirm: unknown kind %q"):format(tostring(opts.kind))
        vim.notify(msg .. " (danger, warn or info)", vim.log.levels.WARN)
      end
    end

    if opts.legend then
      local entries = { { lhs = "←/→", legend = "move" }, { lhs = "⏎", legend = "select" } }
      if answers then
        entries[#entries + 1] = { lhs = "y/n", legend = "answer" }
      end
      entries[#entries + 1] = { lhs = "q", legend = "cancel" }
      vim.wo[surf.winid].winbar = legend_text(entries)
    end

    if #refused > 0 then
      vim.notify(
        "lib.nvim.ui.kit.confirm: hotkey not used: " .. table.concat(refused, ", "),
        vim.log.levels.WARN
      )
    end

    -- Focus moving elsewhere (a click outside, another plugin switching windows) dismisses the
    -- dialog as a cancel instead of leaving it open behind the cursor. It looks again on the next
    -- loop turn: focus that went and came back at once leaves the dialog alone.
    -- `keep_on_focus_lost = true` keeps it; `kit.ask` does by default, since a question nobody
    -- asked for must not be answered "no" by a window change.
    if not opts.keep_on_focus_lost then
      local group = require("lib.nvim.window.close_on_focus_lost")(surf.winid, {
        events = { "WinLeave" },
        recheck = true,
        -- the answer is the cancel, and closes the float with it
        close = function()
          if state.surf == surf then
            finish(false)
          end
        end,
      })
      surf:on_close(function()
        if group then
          pcall(api.nvim_del_augroup_by_id, group)
        end
      end)
    end
  end

  -- Throwaway buffer-local keys: not recorded (see lib.nvim.ui.kit.chooser's `mo`).
  local mo = { buffer = surf.bufnr, nowait = true, record = false }
  for _, key in ipairs({ "l", "<Right>", "<Tab>" }) do
    map("n", key, function()
      M.move(1)
    end, mo)
  end
  for _, key in ipairs({ "h", "<Left>", "<S-Tab>" }) do
    map("n", key, function()
      M.move(-1)
    end, mo)
  end
  map("n", "<CR>", M.confirm, mo)
  map("n", "<Esc>", M.cancel, mo)
  map("n", "<C-c>", M.cancel, mo)
  map("n", "q", M.cancel, mo)
  map("n", "<LeftMouse>", M.click, mo)
  local opened_at = vim.uv.now()
  local grace = tonumber(opts.hotkey_grace_ms) or 0
  for key, index in pairs(keys) do
    local pick = function()
      if grace > 0 and vim.uv.now() - opened_at < grace then
        return
      end
      M.pick(index)
    end
    map("n", key, pick, mo)
    local upper = vim.fn.toupper(key)
    if upper ~= key then
      map("n", upper, pick, mo)
    end
  end

  local decorated, decorate_err = pcall(decorate)
  if not decorated then
    vim.notify("lib.nvim.ui.kit.confirm: " .. tostring(decorate_err), vim.log.levels.WARN)
  end

  settle_old()
  return surf
end

--- Open a button-confirm dialog.
---@param opts table  # { question, choices?: string|string[], default?: integer|string, kind?: 'danger'|'warn'|'info', legend?: boolean, keep_on_focus_lost?: boolean, title?, theme?, on_answer }
---@return Lib.UI.Kit.Surface|nil
function M.open(opts)
  opts = opts or {}
  local hooked = hook.intercept("confirm", opts, function(value)
    answer_hooked(opts, value)
  end)
  if hooked then
    return hooked
  end
  -- A dialog this one replaces is answered as cancelled, but only once this one is in place: its
  -- answer is user code and may open a dialog itself, which must not land in the middle of this
  -- call and be overwritten by it. If building the new one raises, the old one is still answered.
  local old_cb, old_custom, old_labels, old_focus = retire()
  local settled = false
  local function settle_old()
    if settled then
      return
    end
    settled = true
    if not old_cb then
      return
    end
    -- On the next loop turn, not inside this call: the answer is user code, and one that opens a
    -- dialog (a coroutine that asks again) would replace the dialog this call is still handing
    -- back. `modal.hold` keeps a waiting `ask` from opening in the gap.
    local release = require("lib.nvim.ui.kit.modal").hold()
    vim.schedule(function()
      local delivered, err = pcall(deliver, old_cb, old_custom, old_labels, old_focus, false)
      release()
      if not delivered then
        error(err, 0)
      end
    end)
  end
  local ok, res = pcall(open_new, opts, settle_old)
  if not ok then
    settle_old()
    error(res, 0)
  end
  return res
end

return M
