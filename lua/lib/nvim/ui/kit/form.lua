---@module 'lib.nvim.ui.kit.form'
--- Form component: a sequential multi-field prompt — one `kit.input` per
--- field, chained field-by-field into a single keyed result table. This is
--- the "several `vim.fn.input`/`vim.ui.input` calls in a row, each optional
--- with its own default" pattern that got hand-rolled independently (e.g.
--- sandbox.nvim's `container_commands.lua` chaining Image/Name/Ports/Volumes/
--- Env prompts by hand, buffer_ctx.nvim's own `boilerplate/templates/utils.lua`
--- `process_prompts` helper).
---
--- Field contract: `{ name, label|prompt, default?, required?, expand_env?,
--- theme?, width?, relative? }`. `name` is the key the field's answer is
--- stored under in the result table handed to `on_submit`.
---
--- `<Esc>` on a field:
---   - `required = true`  -> aborts the whole form; `on_cancel` fires, no
---     further fields are shown (matches sandbox.nvim's Image field: the one
---     mandatory field in that chain, where Esc really means "abort").
---   - otherwise (default) -> skips the field (its value becomes `default`
---     or `""`) and the form continues to the next field (matches
---     sandbox.nvim's Name/Ports/Volumes/Env fields: Esc = "leave this one
---     blank", not "cancel everything").
---
--- `opts.back = true` (opt-in; without it the form behaves exactly as above)
--- lets the user walk back through the chain to fix an earlier answer:
---   - from field `i > 1`, `<BS>` on an EMPTY field, `<S-Tab>` or `<C-p>` (or
---     the `[← Back]` button) reopens field `i - 1` with its previous answer
---     as the editable text, so only the correction has to be typed. The first
---     field has no back (unless `opts.on_back` is given, see below).
---   - answers survive the round trip in both directions: what was typed in
---     the field being left is kept as that field's text for when the user
---     comes back to it, so going back and forth loses nothing.
---   - the title carries a step indicator, "Label (2/5)" (left out for a
---     one-field form).
---   - a clickable row sits under the field: `[← Back]` (not on the first
---     field), `[Skip]` (not on a `required` one: it is `<Esc>`) and
---     `[Next ↵]` (`[Done ↵]` on the last field: it is `<CR>`). `<Down>` or
---     `<Tab>` moves the focus onto it; see `lib.nvim.ui.kit.input` for its keys.
--- `<Esc>` keeps its meaning on every field, back-navigated to or not.
---
--- `opts.on_back(values)` (opt-in, only with `back = true`) gives the first field
--- a back as well, for a form that is itself one step of a longer flow: the
--- same keys and the `[← Back]` button close the form and call `on_back` with the
--- answers so far -- the first field's text as it stood included, and the ones
--- the user had typed further on and walked back from -- so the caller can open
--- whatever comes before it and, coming forward again, reopen the form with those
--- answers as `default`s. Neither `on_submit` nor `on_cancel` fires then.

local input = require("lib.nvim.ui.kit.input")
local hook = require("lib.nvim.ui.kit.hook")

local M = {}

--- The button row of one step: Back unless it is the first field, Skip unless
--- it is `required` (skipping *is* what `<Esc>` does there, and on a required
--- field that aborts), and the one that submits.
---@param i integer  # 1-based step
---@param n integer  # number of steps
---@param field table
---@param leave boolean  # the form has an `on_back`, so the first field has a Back too
---@return table[]
local function button_row(i, n, field, leave)
  local row = {}
  if i > 1 or leave then
    row[#row + 1] = { id = "back", label = "← Back" }
  end
  if not field.required then
    row[#row + 1] = { id = "skip", label = "Skip" }
  end
  row[#row + 1] = { id = "submit", label = i < n and "Next ↵" or "Done ↵" }
  return row
end

--- Open a sequential multi-field form.
---@param opts table  # { fields = { { name, label|prompt, default?, required?, expand_env?, theme?, width?, relative? }, ... }, theme?, width?, relative?, back?, on_back?(values: table), on_submit(values: table), on_cancel? }
---@return Lib.UI.Kit.Surface|nil  # the first field's input surface (nil if `fields` is empty)
function M.open(opts)
  opts = opts or {}
  local hooked = hook.intercept("form", opts, function(value)
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
  local fields = opts.fields or {}
  local values = {}
  local back = opts.back == true
  local leave = back and type(opts.on_back) == "function"

  local function step(i)
    local field = fields[i]
    if not field then
      if opts.on_submit then
        opts.on_submit(values)
      end
      return nil
    end

    local label = field.label or field.prompt
    local title = label
    local default = field.default
    local on_back, buttons
    if back then
      if #fields > 1 then
        local at = ("(%d/%d)"):format(i, #fields)
        title = label and (label .. " " .. at) or at
      end
      -- What the user typed or was shown last time round, else the declared default.
      if values[field.name] ~= nil then
        default = values[field.name]
      end
      if i > 1 then
        on_back = function(line)
          values[field.name] = line
          step(i - 1)
        end
      elseif leave then
        on_back = function(line)
          values[field.name] = line
          opts.on_back(values)
        end
      end
      buttons = button_row(i, #fields, field, leave)
    end

    local surf = input.open({
      title = title,
      prompt = title,
      default = default,
      theme = field.theme or opts.theme,
      width = field.width or opts.width,
      relative = field.relative or opts.relative,
      expand_env = field.expand_env,
      completion = field.completion,
      on_back = on_back,
      buttons = buttons,
      on_submit = function(line)
        values[field.name] = line
        step(i + 1)
      end,
      on_cancel = function()
        if field.required then
          if opts.on_cancel then
            opts.on_cancel()
          end
          return
        end
        values[field.name] = field.default or ""
        step(i + 1)
      end,
    })

    -- `input.open` returns nil when the float itself could not be opened
    -- (surface.open failure) -- a genuine break, not a user-driven skip.
    -- Without this, neither on_submit nor on_cancel ever fires and the
    -- chain (and any caller waiting on it) stalls silently.
    if not surf and opts.on_cancel then
      opts.on_cancel()
    end
    return surf
  end

  return step(1)
end

return M
