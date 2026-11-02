---@module 'lib.nvim.ui.kit.preview'
--- Live theme playground. Opens a new tab split in two: a left window with an
--- editable Lua config (a theme preset name or an override table) and a right
--- window that re-renders a gallery of kit widgets with that theme as you type.
---
---   :KitPreview            -- or require("lib.nvim.ui.kit").preview()
---
--- The command is not registered by requiring this module (LUA-92): `kit.setup()`
--- or the first `open()` installs it.
---
--- The gallery is a static, faithful rendering (borders + KitSelection /
--- KitAccent / KitTitle / KitMuted highlights bounded to each box) rather than
--- live interactive floats, so editing the config never fights the components
--- for focus. <Tab> in the config buffer cycles the built-in presets.
---
--- The config buffer's contents are `loadstring`d and `pcall`d to produce the
--- theme (that IS the live-preview feature, not an oversight -- the buffer is
--- only ever plugin-seeded, never fed from a file/picker/shell history).
--- Evaluation is debounced (EVAL_DEBOUNCE_MS) rather than firing on every
--- keystroke, so a paste or completion-insert has a brief window to be seen
--- and undone before it runs with full Lua/vim API rights.

local theme = require("lib.nvim.ui.kit.theme")

local api = vim.api
local autocmd = require("lib.nvim.bindings.autocmd")
local debounce = require("lib.nvim.debounce")

local M = {}

local NS = api.nvim_create_namespace("lib_kit_preview")

local PRESETS = { "minimal", "rounded", "solid", "double", "ascii" }

-- SEC-50: eval_config loadstrings + pcall(chunk)s the whole buffer, and this
-- is genuinely the feature (a static file/picker/shell-history origin never
-- feeds this buffer -- it is only ever plugin-seeded, so gating eval behind
-- an opt-in flag would kill live preview, not fix anything). The real gap
-- was firing on every single keystroke: a paste or completion-insert then
-- executed with full Lua/vim API rights before it could be read. Debouncing
-- (same pattern as kit.live_input / kit.picker / kit.compare) gives a brief
-- window to see and undo a fragment before it runs.
local EVAL_DEBOUNCE_MS = 300

--- Reference block shown BELOW the return value in the config buffer.
local REFERENCE = {
  "",
  "-- ── reference ─────────────────────────────────────────────",
  ("-- This buffer's contents are executed as Lua %dms after you stop typing"):format(
    EVAL_DEBOUNCE_MS
  ),
  "-- (not on every keystroke) -- never paste in a config snippet from a",
  "-- source you have not read.",
  '-- Return a preset name   →   return "double"',
  "--   presets: minimal | rounded | solid | double | ascii",
  "-- …or the override table above (merged over the active default).",
  "--   border : none | single | double | rounded | solid | ascii",
  "--   hl.*   : normal border title selection accent muted error",
  "--            flash hover   status: ok warn info dim",
  "--            (each is a HIGHLIGHT GROUP name to link to, or",
  '--             { fg=, bg=, bold=true }; e.g. hl.title = "ErrorMsg")',
  "-- <Tab>   cycles presets",
  "-- <S-Tab> cycles nvim colorschemes (restored on close)",
  "-- updates shortly after you stop typing · q closes",
}

---@internal
--- Initial config: an override table on top, reference below.
---@return string[]
local function initial_lines()
  local out = {
    "return {",
    '  border = "rounded",',
    "  hl = {",
    '    selection = "PmenuSel",   -- current item / focused button',
    '    accent    = "Special",    -- marked items / accents',
    '    title     = "FloatTitle",',
    "  },",
    "}",
  }
  vim.list_extend(out, REFERENCE)
  return out
end

---@internal
--- Config buffer contents for a bare preset name, reference below.
---@param name string
---@return string[]
local function preset_lines(name)
  local out = { ("return %q"):format(name) }
  vim.list_extend(out, REFERENCE)
  return out
end

---@internal
--- Evaluate the config buffer to a theme argument.
---@param bufnr integer
---@return boolean ok, any theme_arg_or_error
local function eval_config(bufnr)
  local src = table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local chunk, load_err = loadstring(src, "kit-preview-config")
  if not chunk then
    return false, load_err
  end
  local ok, result = pcall(chunk)
  if not ok then
    return false, result
  end
  return true, result
end

---@internal
--- Build the gallery: returns lines and a list of box-bounded highlights.
--- Each hl is { row, group } (whole box row) or { row, col0, col1, group }.
---@param resolved Lib.UI.Kit.Theme
---@return string[] lines, table[] hls
local function render_gallery(resolved)
  local g = theme.border_glyphs(resolved)
  local W = 34 -- inner width of the demo boxes

  local lines, hls = {}, {}
  local function push(text, group)
    lines[#lines + 1] = text or ""
    if group then
      hls[#hls + 1] = { row = #lines - 1, group = group }
    end
  end

  -- One bordered box with a title and body rows ({ text, group? }).
  local function box(title, body)
    if g then
      push(g.tl .. string.rep(g.h, W) .. g.tr, "KitBorder")
      local t = " " .. title .. " "
      local pad = math.max(0, W - vim.fn.strdisplaywidth(t))
      push(g.v .. t .. string.rep(" ", pad) .. g.v, "KitTitle")
      for _, row in ipairs(body) do
        local w = math.max(0, W - vim.fn.strdisplaywidth(row[1]) - 1)
        push(g.v .. " " .. row[1] .. string.rep(" ", w) .. g.v, row[2])
      end
      push(g.bl .. string.rep(g.h, W) .. g.br, "KitBorder")
    else
      push("  " .. title, "KitTitle")
      for _, row in ipairs(body) do
        push("    " .. row[1], row[2])
      end
    end
    push("")
  end

  push(
    ("Theme preview — border=%s · colorscheme=%s"):format(
      tostring(resolved.border),
      vim.g.colors_name or "default"
    ),
    "KitMuted"
  )
  push("")

  box("note", {
    { "A themed message float." },
    { "second line, muted hint.", "KitMuted" },
  })

  box("select", {
    { "first item" },
    { "selected item (current)", "KitSelection" },
    { "marked item (multi)", "KitAccent" },
    { "another item" },
  })

  -- confirm: a button row with the focused button highlighted (precise cols)
  if g then
    push(g.tl .. string.rep(g.h, W) .. g.tr, "KitBorder")
    push(g.v .. " confirm" .. string.rep(" ", W - 8) .. g.v, "KitTitle")
  else
    push("  confirm", "KitTitle")
  end
  local prefix = g and (g.v .. "   ") or "    "
  push(prefix .. "[ Yes ]  [ No ]  [ Cancel ]")
  do
    local start = #prefix + #"[ Yes ]  "
    hls[#hls + 1] =
      { row = #lines - 1, col0 = start, col1 = start + #"[ No ]", group = "KitSelection" }
    -- the hotkey letter of each button (y, n, c): KitHotkey underlines it, KitAccent colours it
    for _, label in ipairs({ "Yes", "No", "Cancel" }) do
      local at = lines[#lines]:find("[ " .. label .. " ]", 1, true)
      if at then
        local col = at + 1 -- 0-based column of the first letter after "[ "
        for _, group in ipairs({ "KitAccent", "KitHotkey" }) do
          hls[#hls + 1] = { row = #lines - 1, col0 = col, col1 = col + 1, group = group }
        end
      end
    end
  end
  if g then
    push(g.bl .. string.rep(g.h, W) .. g.br, "KitBorder")
  end
  push("")
  push("underlined letter = hotkey (KitHotkey) · q = close · <Tab> cycles presets", "KitMuted")

  return lines, hls
end

--- Re-render the preview buffer from the config buffer.
---@param config_buf integer
---@param preview_buf integer
function M.render(config_buf, preview_buf)
  if not api.nvim_buf_is_valid(preview_buf) then
    return
  end

  local ok, arg = eval_config(config_buf)

  local lines, hls
  if not ok then
    lines = { "⚠ config error:", "", tostring(arg) }
    hls = { { row = 0, col0 = 0, col1 = #lines[1], group = "KitError" } }
  else
    local resolved = theme.resolve(arg)
    theme.materialize(resolved)
    lines, hls = render_gallery(resolved)
  end

  api.nvim_set_option_value("modifiable", true, { buf = preview_buf })
  api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", false, { buf = preview_buf })

  api.nvim_buf_clear_namespace(preview_buf, NS, 0, -1)
  for _, h in ipairs(hls) do
    -- Bound every highlight to the rendered text width (never the whole window
    -- line): explicit col range, or col 0..#line for a "whole box row".
    local col0 = h.col0 or 0
    local col1 = h.col1
    if not col1 then
      local line = api.nvim_buf_get_lines(preview_buf, h.row, h.row + 1, false)[1] or ""
      col1 = #line
    end
    pcall(api.nvim_buf_set_extmark, preview_buf, NS, h.row, col0, {
      end_col = col1,
      hl_group = h.group,
    })
  end
end

--- Install the :KitPreview user command once (idempotent).
function M.ensure_command()
  if M._command_installed then
    return
  end
  M._command_installed = true
  pcall(function()
    require("lib.nvim.bindings.usercmd").create("KitPreview", function()
      M.open()
    end, { desc = "lib.nvim.ui.kit: live theme playground", force = true })
  end)
end

--- Open the live theme playground in a new tab (config left, preview right).
---@return integer config_buf, integer preview_buf
function M.open()
  M.ensure_command()

  vim.cmd("tabnew")
  local config_win = api.nvim_get_current_win()
  local config_buf = api.nvim_create_buf(false, true)
  api.nvim_set_option_value("bufhidden", "wipe", { buf = config_buf })
  api.nvim_set_option_value("filetype", "lua", { buf = config_buf })
  api.nvim_buf_set_lines(config_buf, 0, -1, false, initial_lines())
  api.nvim_win_set_buf(config_win, config_buf)

  vim.cmd("rightbelow vsplit") -- preview window to the right
  local preview_win = api.nvim_get_current_win()
  local preview_buf = api.nvim_create_buf(false, true)
  api.nvim_set_option_value("bufhidden", "wipe", { buf = preview_buf })
  api.nvim_set_option_value("modifiable", false, { buf = preview_buf })
  api.nvim_win_set_buf(preview_win, preview_buf)
  api.nvim_set_option_value("wrap", false, { win = preview_win })

  -- Live re-render as the config changes, debounced (SEC-50): eval_config
  -- executes the buffer as Lua, so firing on every keystroke would run a
  -- pasted/completion-inserted fragment before it could be read. Waiting
  -- for EVAL_DEBOUNCE_MS of quiet gives a window to see and undo it first.
  local render_debounce = debounce.new(function()
    if api.nvim_buf_is_valid(config_buf) then
      M.render(config_buf, preview_buf)
    end
  end, EVAL_DEBOUNCE_MS)
  local stop_render_timer = render_debounce.cancel
  local function schedule_render()
    render_debounce.call()
  end

  local group = autocmd.group("lib_kit_preview_" .. config_buf, true)
  autocmd.create({ "TextChanged", "TextChangedI" }, schedule_render, {
    group = group,
    buffer = config_buf,
    record = false, -- throwaway per-buffer hook: not recorded (see lib.nvim.ui.kit.surface)
    desc = "lib.nvim.ui.kit.preview: debounced live re-render",
  })

  -- <Tab> (normal mode) cycles the built-in presets.
  local preset_idx = 0
  vim.keymap.set("n", "<Tab>", function()
    preset_idx = preset_idx % #PRESETS + 1
    api.nvim_buf_set_lines(config_buf, 0, -1, false, preset_lines(PRESETS[preset_idx]))
    -- nvim_buf_set_lines above fires TextChanged, which schedule_render() (wired
    -- to the config buffer) would turn into a redundant debounced re-render of
    -- the content M.render below is about to draw synchronously. Cancel it.
    stop_render_timer()
    M.render(config_buf, preview_buf)
  end, { buffer = config_buf, nowait = true, desc = "kit preview: next preset" })

  -- <S-Tab> cycles installed nvim colorschemes (kit highlights link to standard
  -- groups, so the whole preview restyles). The original scheme is restored on
  -- close.
  local orig_scheme = vim.g.colors_name
  local schemes = vim.fn.getcompletion("", "color")
  local scheme_idx = 0
  vim.keymap.set("n", "<S-Tab>", function()
    if #schemes == 0 then
      return
    end
    scheme_idx = scheme_idx % #schemes + 1
    pcall(vim.cmd.colorscheme, schemes[scheme_idx])
    -- SEC-50: route through the same debounce as a real edit instead of calling
    -- M.render() synchronously here -- this handler never changes config_buf's
    -- text, but an unpatched direct M.render() call would still re-eval the
    -- buffer's current (possibly just-pasted, not-yet-debounced) content with
    -- full Lua/vim API rights on every colorscheme cycle.
    schedule_render()
  end, { buffer = config_buf, nowait = true, desc = "kit preview: next colorscheme" })

  -- q closes the whole playground tab from either window and restores the scheme.
  local function close()
    stop_render_timer()
    if orig_scheme and orig_scheme ~= vim.g.colors_name then
      pcall(vim.cmd.colorscheme, orig_scheme)
    end
    pcall(function()
      vim.cmd("tabclose")
    end)
  end
  for _, b in ipairs({ config_buf, preview_buf }) do
    vim.keymap.set("n", "q", close, { buffer = b, nowait = true })
  end

  M.render(config_buf, preview_buf)
  api.nvim_set_current_win(config_win)

  return config_buf, preview_buf
end

return M
