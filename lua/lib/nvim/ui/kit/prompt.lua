---@module 'lib.nvim.ui.kit.prompt'
--- Prompt component: ask a question and collect an answer, either a yes/no
--- `confirm` (a list chooser in Phase 2; horizontal buttons arrive in Phase 4)
--- or free `text` (via the input component).

local select = require("lib.nvim.ui.kit.select")
local input = require("lib.nvim.ui.kit.input")
local confirm = require("lib.nvim.ui.kit.confirm")

local M = {}

--- Open a prompt.
---@param opts table  # { question, answer_type = "confirm"|"text", choices?, default?, theme?, on_answer, expand_env? }
--- `expand_env = true` (only meaningful for `answer_type = "text"`) runs the
--- answer through `lib.nvim.cross.fs.expand_path` before `on_answer` — see
--- `lib.nvim.ui.kit.input`.
---@return any
function M.open(opts)
  opts = opts or {}
  local answer_type = opts.answer_type or "confirm"
  ---@type fun(answer: any)
  local on_answer = opts.on_answer or function(_) end

  if answer_type == "text" then
    local surf = input.open({
      title = opts.question,
      default = opts.default,
      theme = opts.theme,
      expand_env = opts.expand_env,
      on_submit = function(text)
        on_answer(text)
      end,
      on_cancel = function()
        on_answer(nil)
      end,
    })

    -- `input.open` returns nil when the float itself could not be opened
    -- (surface.open failure) -- on_answer must still fire so a caller
    -- waiting on it learns immediately instead of stalling.
    if not surf then
      on_answer(nil)
    end
    return surf
  end

  -- confirm: yes/no (or a custom `choices` list). `layout = "buttons"` uses the
  -- horizontal button dialog; the default is a vertical list chooser. on_answer
  -- receives a boolean for the default two-choice case, or the chosen string
  -- when `choices` is set.
  -- a `vim.fn.confirm` string of choices ("&Yes\n&No") is the button dialog's: the list has no hotkeys
  if opts.layout == "buttons" or type(opts.choices) == "string" then
    return confirm.open({
      question = opts.question,
      choices = opts.choices,
      theme = opts.theme,
      default = opts.default,
      kind = opts.kind,
      legend = opts.legend,
      keep_on_focus_lost = opts.keep_on_focus_lost,
      title = opts.title,
      on_answer = on_answer,
    })
  end

  local custom = type(opts.choices) == "table" and #opts.choices > 0
  local choices = custom and opts.choices or { "Yes", "No" }

  local surf = select.open({
    title = opts.question,
    selection = choices,
    theme = opts.theme,
    on_select = function(choice, idx)
      if custom then
        on_answer(choice)
      else
        on_answer(idx == 1) -- Yes == true
      end
    end,
    -- Without this, `select.open`'s own on_cancel (which fires on Esc/q, an
    -- empty list, and a failed surface open) has nothing to call, so
    -- on_answer never fires on any of those paths -- contradicting
    -- lib.nvim.ui.kit.confirm's documented "Answer contract (matches the list-based
    -- confirm in prompt.lua)". Same no-answer values kit.confirm uses.
    on_cancel = function()
      if custom then
        on_answer(nil)
      else
        on_answer(false)
      end
    end,
  })

  -- The default Yes/No list answers to y and n as the button dialog does. A custom list has no such pair.
  if surf and not custom and surf.bufnr and vim.api.nvim_buf_is_valid(surf.bufnr) then
    local chooser = require("lib.nvim.ui.kit.chooser")
    local function answer_with(row)
      chooser.move(row - (chooser.current_index() or row))
      chooser.submit()
    end
    local mo = { buffer = surf.bufnr, nowait = true, record = false }
    local map = require("lib.nvim.bindings.keymap")
    map("n", "y", function()
      answer_with(1)
    end, mo)
    map("n", "n", function()
      answer_with(2)
    end, mo)
  end
  return surf
end

return M
