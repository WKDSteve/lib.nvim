---@module 'lib.nvim.ui.dialog'
--- The one way a plugin asks the user something: a yes/no, a choice of a few buttons, a line of text.
---
--- Every plugin used to carry its own wrapper around `ui.kit.confirm` with its own fallback when
--- ui.nvim is missing (`vim.ui.select`, `vim.fn.confirm`, nothing at all). This module is that
--- wrapper, once. The backend is the first that loads and has the function asked for:
---
---   1. `ui.kit` (ui.nvim)           -- the user's themed kit, presets included
---   2. `lib.nvim.ui.kit`            -- the copy that ships with lib.nvim; looks the same
---   3. native                       -- `vim.ui.select` / `vim.ui.input` (a float that cannot open
---                                      lands here too)
---
--- Contract, whichever backend answers:
---   - the callback runs exactly once, and never before the call has returned (an answer given
---     while the dialog is being opened is delivered on the next loop turn). The one exception is
---     `ask` with an `abandoned()` that turns true: it is answered `nil`, never asked;
---   - a dismissed dialog answers `false` (yes/no), `nil` (choices, text) or index `0` (`choose`).
---
---   local dialog = require("lib.nvim.ui.dialog")
---   dialog.confirm({ question = "Delete init.lua?", on_answer = function(yes) ... end })
---   dialog.choose("Save changes?", "&Save\n&Discard\n&Cancel", 1, function(i) ... end)
---   dialog.input({ prompt = "Name" }, function(name) ... end)   -- nil when cancelled
---
--- `confirm` shows at once and replaces an open confirm (answering it as cancelled). `ask` waits
--- behind whatever dialog is open and is the call for questions raised at a moment the user did not
--- pick (a stream that ends later): see `ui.kit.ask`. Natively there is no queue and no timeout: the
--- question is asked at once (an `abandoned()` that is true by then still drops it).
---
--- An error raised by the kit (a bad option, a throwing callback) is not a float that failed to
--- open: it is raised again, not answered by a second, native question.

require("lib.nvim.ui.dialog.@types")

local nul_safe = require("lib.lua.strings.core").nul_safe
local truncate = require("lib.lua.strings.width").truncate

local M = {}

--- The kits in order of preference.
local KITS = { "ui.kit", "lib.nvim.ui.kit" }

--- Load errors of a kit that is installed but broken, by module name (a kit that is simply not
--- there leaves none). `:checkhealth lib` shows them: a broken ui.nvim must not look like an absent
--- one.
---@type table<string, string>
local load_errors = {}

--- The kit that answers, and its name; `nil, "native"` when none loads with `need` in it.
---@param need? string  # the kit function the call needs (default "confirm")
---@return table|nil kit
---@return Lib.UI.Dialog.Backend name
local function resolve(need)
  need = need or "confirm"
  for _, name in ipairs(KITS) do
    local ok, kit = pcall(require, name)
    if ok and type(kit) == "table" then
      load_errors[name] = nil
      if type(kit[need]) == "function" then
        return kit, name
      end
    elseif not ok then
      local msg = tostring(kit)
      if msg:find("module '" .. name .. "' not found", 1, true) then
        load_errors[name] = nil -- simply not installed
      elseif msg:find("loop or previous error loading module", 1, true) then
        -- the runtime remembers a failed load and only says so on every later try: keep the
        -- first message, it is the one that names the cause
        load_errors[name] = load_errors[name] or msg
      else
        load_errors[name] = msg
      end
    end
  end
  return nil, "native"
end

--- The backend that would answer right now: for a `confirm` by default, or for the call `need`
--- names (`"ask"`, `"input"`): the kit is chosen per function.
---@param need? string
---@return Lib.UI.Dialog.Backend
function M.backend(need)
  local _, name = resolve(need)
  return name
end

--- What failed to load, by module name: a kit that is installed but raises when required.
---@return table<string, string>
function M.load_errors()
  resolve()
  return vim.deepcopy(load_errors)
end

--- A callback that runs at most once and not before `settle()` has been called. An answer that
--- comes in while the dialog is still being opened waits for the next loop turn.
---@param cb function|nil
---@return fun(...) answer
---@return fun() settle  # call once the open call has returned
---@return fun() discard  # forget an answer given while opening (the float turned out not to open)
local function once(cb)
  local opening, done, pending = true, false, nil
  local function fire(...)
    if done then
      return
    end
    done = true
    if cb then
      cb(...)
    end
  end
  local function answer(...)
    if opening then
      pending = pending or vim.F.pack_len(...)
    else
      fire(...)
    end
  end
  local function settle()
    opening = false
    if pending then
      local args = pending
      pending = nil
      vim.schedule(function()
        fire(vim.F.unpack_len(args))
      end)
    end
  end
  local function discard()
    pending = nil
  end
  return answer, settle, discard
end

--- A text for a native prompt, which neither wraps nor scrolls: no NUL byte (E976), every line cut
--- to the width of the screen, at most `NATIVE_MAX_LINES` of them (a long list of names must not
--- push the choices off the screen).
local NATIVE_MAX_LINES = 12

---@param text any
---@return string
local function native_text(text)
  local width = math.max(40, vim.o.columns - 12)
  local lines = vim.split(nul_safe(tostring(text or "")), "\n", { plain = true })
  local out = {}
  for i, line in ipairs(lines) do
    if i > NATIVE_MAX_LINES then
      out[#out + 1] = "…"
      break
    end
    out[#out + 1] = (truncate(line, width, { ellipsis = "…" }))
  end
  return table.concat(out, "\n")
end

---@param t table|nil
---@return table
local function copy(t)
  return vim.tbl_extend("force", {}, t or {})
end

--- Button labels of `choices` as the kit shows them: a list as it is, a `vim.fn.confirm` string
--- split at newlines, `&` before a hotkey dropped, `&&` a literal `&`, empty pieces skipped.
---@param choices string|string[]|nil
---@return string[]|nil
local function labels_of(choices)
  if type(choices) == "table" then
    return #choices > 0 and choices or nil
  end
  if type(choices) ~= "string" or choices == "" then
    return nil
  end
  local labels = {}
  for piece in vim.gsplit(choices, "\n", { plain = true }) do
    if piece ~= "" then
      local out, marked, i = {}, false, 1
      while i <= #piece do
        local c = piece:sub(i, i)
        if c == "&" and piece:sub(i + 1, i + 1) == "&" then
          out[#out + 1] = "&"
          i = i + 2
        elseif c == "&" and not marked and i < #piece then
          marked = true
          i = i + 1
        else
          out[#out + 1] = c
          i = i + 1
        end
      end
      labels[#labels + 1] = table.concat(out)
    end
  end
  return #labels > 0 and labels or nil
end

--- Ask through `vim.ui.select`. A plain select cannot preselect a button, so the default is listed
--- first (the one a lazy <CR> takes) and the position is mapped back to the caller's order.
---@param opts table
---@param answer fun(...)
local function native_confirm(opts, answer)
  local labels = labels_of(opts.choices)
  local custom = labels ~= nil
  local items = labels or { "Yes", "No" }

  local default = tonumber(opts.default)
  if not default and not custom and opts.default == nil then
    -- A plain question has no focused button natively: "No" goes first, so a stray <CR> is the safe answer.
    default = 2
  end
  if not default and type(opts.default) == "string" then
    for i, l in ipairs(items) do
      if l == opts.default then
        default = i
        break -- the first of equal labels, as the kit does
      end
    end
  end
  local order = {}
  if default and items[default] then
    order[1] = default
  end
  for i = 1, #items do
    if i ~= order[1] then
      order[#order + 1] = i
    end
  end
  local shown = {}
  for pos, i in ipairs(order) do
    shown[pos] = nul_safe(items[i])
  end

  -- A NUL byte reaches `vim.fn` as a Blob (E976): the text is shown with the SOH that measures alike.
  vim.ui.select(shown, { prompt = native_text(opts.question or opts.title) }, function(choice, pos)
    -- a provider that calls back with the choice only is read by its text
    if not pos and choice ~= nil then
      for p, l in ipairs(shown) do
        if l == choice then
          pos = p
          break
        end
      end
    end
    local idx = pos and order[pos] or nil
    if custom then
      answer(items[idx or 0], idx)
    else
      answer(idx == 1)
    end
  end)
end

--- Show a question and call `opts.on_answer(answer)` once. The options are those of `kit.confirm`
--- (`question`, `choices`, `default`, `kind`, `legend`, `title`, `theme`, `keep_on_focus_lost`).
--- The answer is `true`/`false`, or with `choices` the chosen label (`nil` when dismissed) and, as a
--- second value, its 1-based position.
---@param opts Lib.UI.Dialog.ConfirmOpts
---@return Lib.UI.Dialog.Backend backend  # which backend took the question
function M.confirm(opts)
  opts = opts or {}
  local kit, name = resolve("confirm")
  local answer, settle, discard = once(opts.on_answer)

  if kit then
    local o = copy(opts)
    o.on_answer = answer
    local ok, surf = pcall(kit.confirm, o)
    if not ok then
      settle()
      error(surf, 0)
    end
    if surf ~= nil then
      settle()
      return name
    end
    -- The float did not open (the kit has answered "no" on its own by now): ask natively instead.
    discard()
  end

  -- an error of the provider must not leave the callback waiting for a turn that never comes
  local asked, err = pcall(native_confirm, opts, answer)
  settle()
  if not asked then
    error(err, 0)
  end
  return "native"
end

--- Like `confirm`, for a question raised at a moment the user did not pick: it waits behind the
--- dialog that is open instead of replacing it, and a question that stays unanswered for
--- `max_wait_ms` is answered "no". Options as `kit.ask`. An `abandoned()` that turns true drops the
--- question and answers `nil`.
---@param opts Lib.UI.Dialog.ConfirmOpts
---@return Lib.UI.Dialog.Backend backend
function M.ask(opts)
  opts = opts or {}
  local kit, name = resolve("ask")
  local answer, settle = once(opts.on_answer)

  local user_abandoned = opts.abandoned
  local function abandoned()
    local dropped = user_abandoned ~= nil and user_abandoned()
    if dropped then
      answer(nil)
    end
    return dropped
  end

  if kit then
    local o = copy(opts)
    o.on_answer = answer
    if user_abandoned then
      o.abandoned = abandoned
    end
    local ok, err = pcall(kit.ask, o)
    settle()
    if not ok then
      error(err, 0)
    end
    return name
  end

  local asked, err = pcall(function()
    if not abandoned() then
      native_confirm(opts, answer)
    end
  end)
  settle()
  if not asked then
    error(err, 0)
  end
  return "native"
end

--- A yes/no question whose answer is a boolean, the safe one first: "No" is the first button and the
--- focused one (so `<CR>` is never the destructive answer), "Yes, <yes_label>" the second; `n` and `y`
--- are keys. `cb(accepted)` is called once, `false` when dismissed. Options (all optional):
--- `unprompted` (a question the user did not pick, e.g. raised by a file watcher: asked through `ask`,
--- which waits behind an open dialog and ignores typed-ahead keys), `kind`, `title`, `max_wait_ms`.
---@param question string
---@param yes_label? string  # "delete" is shown as "Yes, delete"; nil: "Yes"
---@param cb fun(accepted: boolean)
---@param opts? { unprompted?: boolean, kind?: "danger"|"warn"|"info", title?: string, max_wait_ms?: integer }
---@return Lib.UI.Dialog.Backend backend
function M.yesno(question, yes_label, cb, opts)
  opts = opts or {}
  local yes = yes_label and ("Yes, " .. yes_label) or "Yes"
  local ask = opts.unprompted and M.ask or M.confirm
  return ask({
    question = question,
    -- `&` marks the hotkeys; `&&` is a literal ampersand in the label
    choices = "&No\n&" .. yes:gsub("&", "&&"),
    default = 1,
    kind = opts.kind,
    title = opts.title,
    max_wait_ms = opts.max_wait_ms,
    on_answer = function(choice)
      -- the label, or `true` from a kit old enough to show its plain Yes/No for a choices string
      cb(choice == yes or choice == true)
    end,
  })
end

--- Map `vim.fn.confirm`'s fifth argument to a kit `kind`.
local KIND_OF_TYPE = { Error = "danger", Warning = "warn", Info = "info" }

--- `vim.fn.confirm` as a callback: `cb(index)` with the 1-based number of the chosen button, `0`
--- when dismissed. `choices` is the `vim.fn.confirm` string (`"&Yes\n&No"`) or a list of labels
--- (nil or empty: a single "OK" button, as `vim.fn.confirm` shows); `default` the button that starts
--- focused (0 or nil: the first); `msg_type` is `Error`, `Warning`, `Info`, `Question` or `Generic`
--- and only colours the border. `opts.title` is the window title; `opts.kind` overrides the kind
--- `msg_type` implies; `opts.keep_on_focus_lost` keeps the dialog open when focus moves away (else
--- that dismisses it, i.e. `cb(0)`).
---@param msg string
---@param choices string|string[]|nil
---@param default? integer
---@param cb fun(index: integer)
---@param msg_type? string
---@param opts? { title?: string, kind?: "danger"|"warn"|"info", keep_on_focus_lost?: boolean }
---@return Lib.UI.Dialog.Backend backend
function M.choose(msg, choices, default, cb, msg_type, opts)
  opts = opts or {}
  local labels = labels_of(choices)
  if not labels then
    choices, labels = { "OK" }, { "OK" }
  end
  return M.confirm({
    question = msg,
    choices = choices,
    default = (default and default > 0) and default or 1,
    kind = opts.kind or KIND_OF_TYPE[msg_type or ""],
    title = opts.title,
    keep_on_focus_lost = opts.keep_on_focus_lost,
    on_answer = function(label, index)
      -- the kit says which button; searching the labels is for a backend that only says its text
      -- (and cannot tell two buttons of the same text apart)
      if not index and label ~= nil then
        for i, l in ipairs(labels) do
          if l == label then
            index = i
            break
          end
        end
      end
      cb(index or 0)
    end,
  })
end

--- Ask for a line of text. `cb(value)` is called once with the text, or `nil` when cancelled, the
--- way `vim.ui.input` does; without `cb`, `opts.on_submit` / `opts.on_cancel` are called as in
--- `kit.input`. Options as `kit.input` (`prompt`, `default`, `completion`, `secret`, ...). Natively
--- a `secret` goes through `vim.fn.inputsecret`, where an empty line counts as cancelled (Esc and an
--- empty Enter cannot be told apart there).
---@param opts Lib.UI.Dialog.InputOpts
---@param cb? fun(value: string|nil)
---@return Lib.UI.Dialog.Backend backend
function M.input(opts, cb)
  opts = opts or {}
  local function deliver(value)
    if cb then
      cb(value)
    elseif value ~= nil then
      if opts.on_submit then
        opts.on_submit(value)
      end
    elseif opts.on_cancel then
      opts.on_cancel()
    end
  end
  local answer, settle, discard = once(deliver)
  local kit, name = resolve("input")

  if kit then
    local o = copy(opts)
    o.on_submit = function(value)
      answer(value)
    end
    o.on_cancel = function()
      answer(nil)
    end
    if opts.on_back then
      -- leaving through the caller's "back" is leaving too: the callback must not wait for ever
      o.on_back = function(...)
        local back = opts.on_back
        local ok_back, err_back = pcall(back, ...)
        answer(nil)
        if not ok_back then
          error(err_back, 0)
        end
      end
    end
    local ok, surf = pcall(kit.input, o)
    if not ok then
      settle()
      error(surf, 0)
    end
    if surf ~= nil then
      settle()
      return name
    end
    discard()
  end

  -- the kit runs a submitted line through `expand_path` on request; the value must not depend on the backend
  local function native_answer(value)
    if value ~= nil and opts.expand_env then
      value = require("lib.nvim.cross.fs.expand_path")(value)
    end
    answer(value)
  end
  local prompt = native_text(opts.prompt or opts.title)
  local asked, err = pcall(function()
    if opts.secret then
      -- vim.ui.input has no masking: the prompt of the command line does.
      local ok, text = pcall(vim.fn.inputsecret, prompt, opts.default or "")
      native_answer(ok and text ~= "" and text or nil)
    else
      vim.ui.input({
        prompt = (opts.prompt or opts.title) and prompt or nil,
        default = opts.default,
        completion = opts.completion,
      }, native_answer)
    end
  end)
  settle()
  if not asked then
    error(err, 0)
  end
  return "native"
end

return M
