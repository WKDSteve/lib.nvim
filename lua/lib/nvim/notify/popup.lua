---@module 'lib.nvim.notify.popup'
---@brief Popup delivery for notifications: a corner toast plus a yankable history.
---@description
--- `vim.notify` on a plain Neovim UI is `nvim_echo`, so long or multi-line text
--- (a rejected `git push`, say) pops up as a `:messages` / more-prompt and
--- steals focus. This module shows the message as a non-focus-stealing
--- `ui.kit` toast in the top-right corner instead -- wrapped to the toast
--- width and colored by level -- and keeps every message in a bounded history
--- that opens in a scratch buffer, so the full text can be yanked later.
---
--- Delivery order for a message:
---   1. recorded in the popup history (always) -- `:Lib notify history`/
---      `:Lib notify last` read this back in full, regardless of `messages`
---   1b. ALSO written to real `:messages` when `messages = true` is passed
---      (default: false, see below) -- see `write_messages`
---   2. if `ui.notify` (ui.nvim) is enabled it already turns `vim.notify` into
---      toasts, so the message is handed to `vim.notify` to avoid a second popup
---   3. else shown via `ui.kit.toast` (soft dependency on ui.nvim)
---   3b. without ui.nvim, a multi-line message is shown via lib.nvim's own
---      toast (`lib.nvim.ui.kit.toast`, which `ui.kit.toast` re-exports): as an
---      echo it would stop the editor at a hit-enter prompt when it comes from a
---      callback; a one-line message stays an echo (step 4). This toast has
---      no time limit: it stays until it is closed (`:Lib notify dismiss`,
---      `popup.dismiss()`), so command output that is meant to be read does
---      not vanish. `setup({ fallback_toast = false })` turns this step off
---      (the message goes to `vim.notify` again) -- the switch for specs that
---      stub `vim.notify`
---   4. else, when no toast can be shown, `vim.notify` -- a message is never lost
---
--- `messages` defaults to false, not true: Neovim has no API to add a message
--- to |message-history| without also echoing it (see `write_messages`'s own
--- doc comment for the two approaches that tried and failed), so a `true`
--- default meant every popup-delivered message briefly flashed at the bottom
--- of the screen too, on top of its corner toast -- confusing next to a chip
--- that already showed it, and especially visible for a plugin (a git
--- dashboard's pull/push, say) that notifies often. The trade-off: a message
--- delivered with the default no longer reaches real `:messages` or a
--- `:messages`-reading tool (`noice.nvim` included) -- `:Lib notify
--- history`/`:Lib notify last` is the one place its full text is guaranteed
--- to still be. Pass `messages = true` per call (or `popup.setup({ messages
--- = true })` to restore the old default everywhere) for a message that must
--- land in real `:messages` regardless.
---
--- Use it through `require("lib.nvim.notify").create(prefix, { popup = true })`
--- or call `deliver` directly.

local fast_event = require("lib.nvim.notify.internal.fast_event")
local strings = require("lib.lua.strings.core")

---@class Lib.Notify.Popup
local M = {}

---@class Lib.Notify.Popup.Config
---@field messages boolean Also record every message in real `:messages` (default: false -- see the module doc comment for why; `:Lib notify history`/`:Lib notify last` always have the full text regardless)
---@field max_lines integer Toast line cap (default 12)
---@field width integer|nil Toast wrap width in columns; nil (default) follows the toast's own text budget (`ui.kit.toast.inner_width()`, 40% of the editor minus border/padding), falling back to 38 when ui.nvim's toast is too old to report it
---@field toast_max_bytes integer Bytes of a message considered when wrapping for the toast (default 4000); a message can be arbitrarily large (a whole command's output) but only its head is ever shown in a toast
---@field entry_max_bytes integer Bytes kept per history entry (default 64 KiB)
---@field toast_min_level integer Below this vim.log.levels value: recorded in history/`:messages` only, no toast (default INFO)
---@field timeouts table<integer, integer> Per-level toast lifetime override in ms, merged over `LEVELS[*].timeout`
---@field history_full boolean `show_history()` shows entries in full instead of collapsed to `max_lines` (default false)
---@field fallback_toast boolean Without ui.nvim, show a multi-line message as lib.nvim's own toast (default true); false hands it to `vim.notify`, as before -- the switch for specs that stub `vim.notify` and read the text

---Partial form of `Lib.Notify.Popup.Config` accepted by `M.setup`: every
---field optional, a field left unset keeps its current value.
---@class Lib.Notify.Popup.SetupOpts
---@field messages? boolean
---@field max_lines? integer
---@field width? integer|false  `false` resets to "follow the chip's text budget"
---@field toast? table Forwarded to `ui.kit.toast.setup` (`width`, `min_width`, `padding`: columns or "NN%") when ui.nvim is installed -- the size of the chip itself
---@field toast_max_bytes? integer
---@field entry_max_bytes? integer
---@field toast_min_level? integer
---@field timeouts? table<integer, integer>
---@field history_full? boolean
---@field fallback_toast? boolean

---@type Lib.Notify.Popup.Config
local config = {
  messages = false,
  max_lines = 12,
  width = nil, -- nil: follow the toast's text budget (see Lib.Notify.Popup.Config.width)
  toast_max_bytes = 4000,
  entry_max_bytes = 64 * 1024,
  toast_min_level = vim.log.levels.INFO,
  timeouts = {},
  history_full = false,
  fallback_toast = true,
}

local FALLBACK_WIDTH = 38 -- wrap width when the toast cannot report its own

local HISTORY_MAX = 200 -- capped number of entries kept, independent of config

-- Per level: title, toast highlight group, milliseconds on screen.
local LEVELS = {
  [vim.log.levels.TRACE] = { name = "trace", hl = "Comment", timeout = 3000 },
  [vim.log.levels.DEBUG] = { name = "debug", hl = "Comment", timeout = 3000 },
  [vim.log.levels.INFO] = { name = "info", hl = "DiagnosticInfo", timeout = 4000 },
  [vim.log.levels.WARN] = { name = "warn", hl = "DiagnosticWarn", timeout = 6000 },
  [vim.log.levels.ERROR] = { name = "error", hl = "DiagnosticError", timeout = 10000 },
}

---@class Lib.Notify.Popup.Entry
---@field time string
---@field level integer
---@field message string
---@field source string|nil

---@class Lib.Notify.Popup.Opts
---@field source? string Tag for the history and, absent an explicit `title`, the toast title (e.g. "reposcope")
---@field baked_prefix? string Internal: the exact text `lib.nvim.notify.create()` already prepended to `message`, if any -- lets `derive_title` recognize precisely (not guess from `source`, which is a separate, often differently-spelled option) that a multi-line message's first line already carries this notifier's own tag, so it isn't added a second time. A direct `popup.deliver()` caller (no `create()` involved) never sets this.
---@field title? string Overrides the toast's default `source level-name` title (e.g. "sessions.marks"); also passed to the plain `vim.notify` fallback so a rich backend still sees it
---@field timeout? integer Toast lifetime in ms (default per level, or config.timeouts[level])
---@field messages? boolean Override the module default for writing to `:messages`
---@field max_lines? integer Override config.max_lines for this call
---@field width? integer Override config.width for this call
---@field toast_max_bytes? integer Override config.toast_max_bytes for this call
---@field entry_max_bytes? integer Override config.entry_max_bytes for this call
---@field toast_min_level? integer Override config.toast_min_level for this call
---@field hl? string Toast border/title highlight group override, independent of `level` -- lets a caller show e.g. a green "success" toast (`level = INFO`, for correct `toast_min_level` filtering and `:messages`/history semantics) without vim.log.levels having a distinct SUCCESS value of its own. See `notifier.success` in `lib.nvim.notify`'s `init.lua`.

---@type Lib.Notify.Popup.Entry[]
local history = {}
---@type Lib.Notify.Popup.Entry|nil
local last_entry = nil

---@internal
---Backs `n` off to the nearest UTF-8 character boundary at or before it, so
---`s:sub(1, utf8_safe_cut(s, n))` never lands inside a multibyte sequence. A
---raw `s:sub(1, n)` byte cap can split a codepoint's lead byte from its own
---continuation bytes, which Neovim then renders as a `<xx>` escape for the
---orphaned byte(s) instead of the intended character.
---
---Backs off AT MOST 3 bytes -- a well-formed UTF-8 sequence has at most 3
---continuation bytes after its lead byte, so a real boundary is always
---within that reach. If none turns up (the bytes around the cut are not
---valid UTF-8 to begin with -- Latin-1/CP1252 output from some Windows
---tools, say, which this module's own doc comments cite as a realistic
---message source), backing off further would just keep walking through
---more "continuation-shaped" bytes and could silently discard the entire
---kept prefix instead of stopping near the intended budget. Falling back to
---the original `n` there accepts the one already-broken byte at the edge --
---the same trade-off a raw byte cap already made for non-UTF-8 content --
---rather than trading a cosmetic glitch for real data loss.
---@param s string
---@param n integer
---@return integer
local function utf8_safe_cut(s, n)
  if n >= #s then
    return #s
  end
  if n <= 0 then
    return 0
  end
  -- Backing off 3 bytes means checking 4 candidate cut points -- n itself,
  -- then n-1, n-2, n-3 -- so the loop must include `floor`, not stop short
  -- of it: a `while m > floor` guard (checking only n, n-1, n-2) silently
  -- skipped the maximal-backoff candidate, so a well-formed 4-byte
  -- character needing the full 3-byte backoff (cut landing right after its
  -- lead byte + 2 continuation bytes, missing only the last one) fell
  -- through to the "not valid UTF-8" fallback below and got split anyway --
  -- exactly the defect this function exists to prevent.
  local floor = math.max(0, n - 3)
  for m = n, floor, -1 do
    local b = s:byte(m + 1)
    if not b or b < 0x80 or b >= 0xC0 then
      return m
    end
  end
  return n
end

---@internal
---Number of leading characters of `s` that fit within `max_cols` display
---columns. Binary-searches the character index rather than scanning
---linearly: `f(i) = strdisplaywidth(strcharpart(s, 0, i))` is monotonically
---non-decreasing in `i` (appending characters -- even zero-width combining
---marks -- never shrinks display width), so the largest `i` with `f(i) <=
---max_cols` can be found in O(log n) probes instead of one per character.
---
---A linear growing-prefix scan (measuring `f(i)` from scratch at each step,
---the only way to avoid double-counting a combining mark's width -- see
---`truncate_to_width`'s doc comment) costs O(i) per step and so degrades to
---O(n^2) overall; for a string with a long run of zero-width characters
---before the budget is finally crossed (stacked combining marks, i.e.
---"zalgo text"), that `n` can be the string's full length, turning a single
---popup.deliver() call with crafted or pathological input into a
---multi-second stall on Neovim's main thread. Binary search keeps each of
---the O(log n) probes at O(n) worst case but the total at O(n log n),
---closing that off. Shared by `truncate_to_width` (cuts a title to a
---budget) and `wrap` (cuts a line to the toast width): both need "how many
---characters until display width X", not "how many characters" on its own
----- `max_cols` is a COLUMN count, and double-width text (CJK, many emoji)
---needs fewer characters than columns to fill the same budget.
---@param s string
---@param max_cols integer
---@return integer
local function width_cut_chars(s, max_cols)
  local total_chars = vim.fn.strchars(s)
  local lo, hi = 0, total_chars
  while lo < hi do
    local mid = lo + math.ceil((hi - lo) / 2)
    if vim.fn.strdisplaywidth(vim.fn.strcharpart(s, 0, mid)) <= max_cols then
      lo = mid
    else
      hi = mid - 1
    end
  end
  return lo
end

---Hard-wraps `text` to `width` display columns and caps the line count.
---@param text string
---@param width integer
---@param max_lines integer
---@param max_bytes integer Bytes of `text` considered before wrapping
---@return string[]
local function wrap(text, width, max_lines, max_bytes)
  -- A caller-supplied max_lines of 0 (or negative) would make
  -- vim.list_slice(out, 1, max_lines) return an empty table below, and the
  -- truncation marker would then land on out[0] -- invisible to ipairs/#,
  -- silently losing the whole message instead of showing at least one line.
  max_lines = math.max(1, max_lines)
  local truncated = false
  if #text > max_bytes then
    text = text:sub(1, utf8_safe_cut(text, max_bytes))
    truncated = true
  end

  local out = {}
  for _, raw in ipairs(vim.split(text, "\n", { plain = true })) do
    local line = strings.rtrim((raw:gsub("\t", "  ")))
    if line == "" then
      out[#out + 1] = ""
    else
      while vim.fn.strdisplaywidth(line) > width do
        -- `width` is a COLUMN budget, not a character count: sizing `head`
        -- to `width` characters (as this used to) grabs up to twice the
        -- intended column width for double-width text (CJK, many emoji) --
        -- see `width_cut_chars`'s doc comment.
        local cut = width_cut_chars(line, width)
        if cut == 0 then
          -- A single character wider than the whole budget (an unusually
          -- narrow `width`, or one very wide codepoint) -- take it anyway so
          -- the loop always shrinks `line` instead of spinning forever.
          cut = 1
        end
        -- Prefer a break at the last space inside the window. `cut` counts
        -- characters (strcharpart), while the match position is a byte index,
        -- so convert before comparing.
        local head = vim.fn.strcharpart(line, 0, cut)
        local space = head:match("^.*() ")
        if space then
          local chars = vim.fn.strchars(head:sub(1, space - 1))
          if chars > width / 3 then
            cut = chars
          end
        end
        out[#out + 1] = vim.fn.strcharpart(line, 0, cut)
        line = vim.fn.strcharpart(line, cut):gsub("^%s+", "")
        if #out > max_lines then
          break
        end
      end
      out[#out + 1] = line
    end
    if #out > max_lines then
      break
    end
  end

  if #out > max_lines or truncated then
    out = vim.list_slice(out, 1, max_lines)
    out[#out] = "... (:Lib notify last)"
  end
  return out
end

local MSG_HL = {
  [vim.log.levels.WARN] = "WarningMsg",
  [vim.log.levels.ERROR] = "ErrorMsg",
}

---Adds `message` to `:messages` (the message history).
---
---A previous version of this function ran `:silent! echohl X | echomsg "..."
---| echohl None` through `vim.cmd`, on the theory that `:silent!` would
---suppress the on-screen echo while `:echomsg` still recorded into
---|message-history|. It did not: a command modifier such as `:silent` only
---applies to the FIRST bar (`|`)-separated command on the line (see
---`:h :verbose-cmd`'s own worked example), so the `echomsg` clause ran
---completely unsilenced -- every delivery with the default `messages = true`
---was, in practice, an ordinary visible echo, for any message length. And
---repeating `silent!` on every clause is not a fix either (verified
---directly): `:silent` does not just suppress display, it also stops the
---message from being added to history at all (see `:h :silent`), so that
---"fix" would have silently defeated this function's entire purpose instead.
---
---Neovim has no API to add a message to |message-history| without ever
---touching the screen -- `nvim_echo(..., true, {})` is the only way to
---record one, and it echoes as it records. This calls that directly instead
---of going through a hand-built Ex command: it removes both the `:silent`
---scoping bug above and any question of escaping `message` into a Vimscript
---string literal safely (there is no command string left to build). `more`
---is toggled off for the call so a long or multi-line message can never
---block on a `--More--` prompt.
---
---An earlier version instead attached a throwaway `ext_messages` UI
---consumer (`vim.ui_attach`) for the call, specifically to swallow the
---on-screen echo while still recording history. That approach is dropped:
---`vim.ui_attach` is documented as experimental/unstable, and it was found
---to hang indefinitely -- never returning -- once any floating window was
---already open; a `pcall` around it only catches errors, not a call that
---never comes back, so it gave no real protection against that.
---
---A message that must never be echoed at all -- not even briefly -- should
---pass `messages = false` instead of relying on this function to hide it.
---@param message string
---@param level integer
---@return nil
local write_messages = fast_event.guard(function(message, level)
  local hl = MSG_HL[level] or "None"
  local more = vim.o.more
  vim.o.more = false
  pcall(vim.api.nvim_echo, { { message, hl } }, true, {})
  vim.o.more = more
end)

---True when ui.nvim's `ui.notify` already routes `vim.notify` into toasts.
---@return boolean
local function ui_notify_active()
  -- `ui.notify` is loaded by whoever enabled it; looking at package.loaded
  -- neither pays for a failed rtp search per message nor loads it as a side
  -- effect.
  local ui_notify = package.loaded["ui.notify"]
  return type(ui_notify) == "table"
      and type(ui_notify.is_enabled) == "function"
      and ui_notify.is_enabled()
    or false
end

-- A toast's title bar is one line, ~toast-width wide -- a first line longer
-- than this is truncated with an ellipsis rather than pushed into `wrap()`'s
-- own (wider) body budget, which would misjudge how much of it actually
-- fits next to the border decoration.
local TITLE_MAX_WIDTH = 40

-- A first line further into `message` than this is not a title candidate at
-- all, however short the *rendered* title would end up -- a message that is
-- one enormous unbroken line plus `deliver()`'s own appended
-- "\n... (truncated)" marker (`entry_max_bytes`) technically "has a first
-- line" by the same `:find("\n", ...)` test below, but treating 64KB of
-- text as a title and the marker alone as the body would be exactly
-- backwards. A real title-shaped first line (a git error's summary, an
-- exception's message) is never anywhere close to this bound.
local MAX_FIRST_LINE_BYTES = 200

---@internal
---Truncate `s` to at most `max_cols` DISPLAY COLUMNS, measuring and cutting
---with Neovim's own `strdisplaywidth`/`strcharpart` throughout (the same
---pair `wrap()` below already uses) rather than `lib.lua.strings.width`'s
---hand-maintained Unicode-width table. That table is a deliberate
---approximation (its own doc comment says so -- built for the
---editor-independent, `vim.fn`-less context `lib.lua.*` exists for, not
---needed here) and disagreed with `strdisplaywidth` for some double-width
---codepoints outside it (newer emoji blocks, e.g.), so a "truncated" title
---could still overflow the very budget it had just been measured against
---by the authoritative function.
---
---Measures the GROWING PREFIX's own display width on each step, not each
---character's width in isolation summed up: a combining mark (an accent on
---a decomposed "e", say) has a real width of its own when
---`strdisplaywidth`d alone, but contributes 0 once actually attached to its
---base character in context -- summing isolated per-character widths
---double-counted exactly that case, both under-filling the budget by
---roughly half for accented text and risking a cut landing between a base
---character and its own combining mark. Asking "what does the real prefix
---built so far actually cost" instead of "what does this one isolated
---codepoint cost" gets both double-width text and combining sequences
---right with the same one measurement. That measurement itself lives in
---`width_cut_chars`, shared with `wrap()`'s line-wrapping below, which used
---to conflate the same column budget with a character count for its own
---cut point.
---@param s string
---@param max_cols integer
---@return string
local function truncate_to_width(s, max_cols)
  -- Defensive cap, same shape as `MAX_FIRST_LINE_BYTES`/`entry_max_bytes`
  -- elsewhere in this file: nothing legitimate needs more than a few
  -- hundred bytes to produce `max_cols` (<=40 in practice) columns of
  -- visible text, and without this an unreasonably large `s` (a caller bug
  -- feeding a huge computed string into what should be a short tag, or a
  -- string built entirely from zero-width codepoints that never trips the
  -- budget check below) would cost an O(n) full scan -- or worse, this
  -- function's own O(n²) growing-prefix measurement -- before truncation
  -- even starts. `utf8_safe_cut` keeps this raw byte cap from splitting the
  -- multibyte character straddling byte 2048.
  if #s > 2048 then
    s = s:sub(1, utf8_safe_cut(s, 2048))
  end
  if vim.fn.strdisplaywidth(s) <= max_cols then
    return s
  end
  local ellipsis_w = vim.fn.strdisplaywidth("…")
  local budget = max_cols - ellipsis_w
  if budget < 0 then
    return ""
  end
  local cut_chars = width_cut_chars(s, budget)
  return vim.fn.strcharpart(s, 0, cut_chars) .. "…"
end

---Splits `message` into a (title, body) pair for a caller that gave no
---`opts.title` of its own: the first line becomes the title (so "[gitsuite]
---docmap-desktop: push failed" reads as a title, not buried in the body next
---to three lines of git's own hint text), the rest is what `wrap()` renders
---below it. A single-line message, or one whose first line is empty, keeps
---the previous "source level-name" title with the message untouched --
---this only kicks in for a message that actually has more to show.
---
---`source` is only prepended when `first_line` doesn't ALREADY start with
---`baked_prefix` -- the exact text `notify.create(prefix, {...})` prepended
---to `message` before `popup.deliver` ever saw it. That is a precise check
---against a known exact string, not a guess against `source` itself: an
---earlier version compared a fuzzy "core" of `source` to the start of
---`first_line` instead, which both mismatched a `source` spelled
---differently from the real baked-in `prefix` (e.g. `"gitsuite"` vs.
---`"[gitsuite.nvim]"`) AND, worse, could strip a legitimate `source` prefix
---from a message that simply started with similar-looking words on its own
---(a direct `popup.deliver()` call, no `create()` involved -- so nothing
---was ever actually baked in, `baked_prefix` is nil there, and the prefix
---is always added, matching the library's behavior before this feature
---existed).
---@param message string
---@param source string|nil
---@param baked_prefix string|nil
---@param spec { name: string }
---@return string title
---@return string body
local function derive_title(message, source, baked_prefix, spec)
  local source_prefix = source and (source .. " ") or ""
  local nl = message:find("\n", 1, true)
  if nl and nl <= MAX_FIRST_LINE_BYTES then
    local first_line = message:sub(1, nl - 1)
    if first_line ~= "" then
      local already_baked = baked_prefix
        and baked_prefix ~= ""
        and first_line:sub(1, #baked_prefix) == baked_prefix
      local prefix = already_baked and "" or source_prefix
      -- The budget is the WHOLE title (prefix + first_line) against
      -- TITLE_MAX_WIDTH, not first_line's own width alone -- truncating
      -- only first_line and then concatenating an unmeasured prefix in
      -- front of the result could still overflow the toast's title bar.
      -- `prefix` is kept whole when it fits on its own; a `source` long
      -- enough to fill the entire budget by itself is truncated too
      -- (rather than silently overflowing regardless of first_line).
      local prefix_width = vim.fn.strdisplaywidth(prefix)
      if prefix_width >= TITLE_MAX_WIDTH then
        prefix = truncate_to_width(prefix, TITLE_MAX_WIDTH)
        return prefix, message:sub(nl + 1)
      end
      local budget = TITLE_MAX_WIDTH - prefix_width
      if vim.fn.strdisplaywidth(first_line) > budget then
        first_line = truncate_to_width(first_line, budget)
      end
      return prefix .. first_line, message:sub(nl + 1)
    end
  end
  -- Same TITLE_MAX_WIDTH budget as the multi-line branch above -- a long or
  -- wide `source` here (the single-line notify shape, the most common one)
  -- was never bounded at all before this: `source_prefix .. spec.name` was
  -- handed to the toast as-is, with no truncation, so a source alone could
  -- overflow the title bar by an arbitrary amount. `spec.name` itself
  -- (`"info"`/`"warn"`/`"error"`/...) is always short and kept whole;
  -- `source_prefix` is what gets truncated into whatever budget remains.
  local fallback_title = source_prefix .. spec.name
  if vim.fn.strdisplaywidth(fallback_title) > TITLE_MAX_WIDTH then
    local name_width = vim.fn.strdisplaywidth(spec.name)
    if name_width >= TITLE_MAX_WIDTH then
      return truncate_to_width(spec.name, TITLE_MAX_WIDTH), message
    end
    source_prefix = truncate_to_width(source_prefix, TITLE_MAX_WIDTH - name_width)
    fallback_title = source_prefix .. spec.name
  end
  return fallback_title, message
end

---@param message string
---@param level integer
---@param opts Lib.Notify.Popup.Opts
---@return boolean shown
local function show_toast(message, level, opts)
  local sticky = false -- the fallback toast without ui.nvim: no time limit
  local ok_toast, toast = pcall(require, "ui.kit.toast")
  if not ok_toast then
    -- No ui.nvim. A one-line message stays an echo (`vim.notify`), as it always
    -- was. A multi-line one would be an echo of several lines, which -- from a
    -- callback rather than a command -- stops the editor at a hit-enter prompt:
    -- it gets lib.nvim's own toast instead (`ui.kit.toast` is a re-export of
    -- it), so it is short-lived, needs no key and shows the whole text.
    -- It has no time limit (`timeout = 0`, unless the caller passed one): it
    -- is often command output meant to be read (`--dry-run` plans), and
    -- unlike ui.nvim's toasts it has no history chip to fall back on. It stays
    -- until `:Lib notify dismiss` / `M.dismiss()` closes it.
    if not config.fallback_toast or not vim.trim(message):find("\n", 1, true) then
      return false
    end
    ok_toast, toast = pcall(require, "lib.nvim.ui.kit.toast")
    if not ok_toast then
      return false
    end
    sticky = true
  end

  local spec = LEVELS[level] or LEVELS[vim.log.levels.INFO]
  local hl = opts.hl or spec.hl
  local title, body = opts.title, message
  if not title then
    -- `pcall`ed, not called bare: `derive_title` is reached with
    -- `opts.source`/`opts.baked_prefix` straight from the caller, and
    -- `popup.deliver` is a directly callable public API, not gated behind
    -- `notify.create()` -- a caller passing a non-string there (an `{}` or
    -- `true` typo'd into `source`) must not turn a notification, often
    -- itself an error report, into a hard crash instead of just showing
    -- with the fallback title. The `pcall(toast.open, {...})` a few lines
    -- below does NOT cover this: its argument table, including this call,
    -- is built before that pcall's callee ever runs.
    local ok_title, derived_title, derived_body =
      pcall(derive_title, message, opts.source, opts.baked_prefix, spec)
    if ok_title then
      title, body = derived_title, derived_body
    else
      title = spec.name
    end
  end
  local width = opts.width or config.width
  if not width then
    local ok_w, inner = pcall(toast.inner_width)
    width = ok_w and type(inner) == "number" and inner or FALLBACK_WIDTH
  end
  local max_lines = opts.max_lines or config.max_lines
  local max_bytes = opts.toast_max_bytes or config.toast_max_bytes
  local timeout = opts.timeout or (sticky and 0) or config.timeouts[level] or spec.timeout
  local ok = pcall(toast.open, {
    title = title,
    message = wrap(body, width, max_lines, max_bytes),
    timeout = timeout,
    theme = { hl = { border = hl, title = hl } },
  })
  return ok
end

---Records `message` and shows it as a popup.
---@param message string
---@param level? integer vim.log.levels value (default: INFO)
---@param opts? Lib.Notify.Popup.Opts
---@return nil
M.deliver = fast_event.guard(function(message, level, opts)
  level = level or vim.log.levels.INFO
  opts = opts or {}
  -- A message containing a raw NUL crosses the vim.fn bridge as a Blob, not a
  -- String -- wrap()'s vim.fn.strdisplaywidth/strcharpart/strchars calls then
  -- raise E976 and this whole delivery is lost. A message can be arbitrary
  -- command output (see toast_max_bytes above), so a stray NUL is realistic.
  message = tostring(message):gsub("%z", "\\0")
  local entry_max = opts.entry_max_bytes or config.entry_max_bytes
  if #message > entry_max then
    message = message:sub(1, utf8_safe_cut(message, entry_max)) .. "\n... (truncated)"
  end

  ---@type Lib.Notify.Popup.Entry
  local entry = {
    time = os.date("%H:%M:%S") --[[@as string]],
    level = level,
    message = message,
    source = opts.source,
  }
  history[#history + 1] = entry
  last_entry = entry
  if #history > HISTORY_MAX then
    table.remove(history, 1)
  end

  -- lib.nvim.messages' own attach policy never sees notify/toast traffic
  -- (see its module doc) -- this is the one place that writes it in
  -- directly, unconditionally, regardless of toast_min_level below.
  pcall(function()
    require("lib.nvim.messages").push({
      level = level,
      kind = "notify",
      content = message,
      source = opts.source,
    })
  end)

  -- Resolved into a local: `opts` belongs to the caller, who may reuse it, and
  -- writing the default into it would freeze a later `setup({ messages = ... })`
  -- out of that table.
  local to_messages = opts.messages
  if to_messages == nil then
    to_messages = config.messages
  end
  if to_messages then
    write_messages(message, level)
  end

  -- Below toast_min_level: stays in history/:messages only. This is what
  -- keeps a chatty plugin (dozens of INFO-level lib_notify call sites) from
  -- spamming the corner -- deliberately skips vim.notify too, not just the
  -- toast, since either would still be a visible popup on a plain UI.
  local toast_min_level = opts.toast_min_level or config.toast_min_level
  if level < toast_min_level then
    return
  end

  if ui_notify_active() or not show_toast(message, level, opts) then
    -- Handing off to vim.notify -- either because a rich backend (ui.notify)
    -- already turns it into a toast, or because no toast could be shown --
    -- is also the caller's only remaining chance to see its title: forward
    -- it the same way a plain vim.notify() call would have taken it.
    vim.notify(message, level, opts.title and { title = opts.title } or nil)
  end
end)

---Changes module-wide defaults.
---@param opts? Lib.Notify.Popup.SetupOpts `timeouts` merges per level rather
---than replacing the whole table.
---@return nil
function M.setup(opts)
  opts = opts or {}
  if opts.messages ~= nil then
    config.messages = opts.messages and true or false
  end
  if opts.max_lines ~= nil then
    config.max_lines = opts.max_lines
  end
  if opts.width == false then
    config.width = nil -- back to following the chip's own text budget
  elseif opts.width ~= nil then
    config.width = opts.width
  end
  if type(opts.toast) == "table" then
    -- The chip's size lives in ui.nvim's toast; without it (or with a version
    -- that predates `setup`) there is nothing to tune and nothing to raise.
    local ok_toast, toast = pcall(require, "ui.kit.toast")
    if ok_toast and type(toast.setup) == "function" then
      toast.setup(opts.toast)
    end
  end
  if opts.toast_max_bytes ~= nil then
    config.toast_max_bytes = opts.toast_max_bytes
  end
  if opts.entry_max_bytes ~= nil then
    config.entry_max_bytes = opts.entry_max_bytes
  end
  if opts.toast_min_level ~= nil then
    config.toast_min_level = opts.toast_min_level
  end
  if opts.timeouts ~= nil then
    for lvl, ms in pairs(opts.timeouts) do
      config.timeouts[lvl] = ms
    end
  end
  if opts.history_full ~= nil then
    config.history_full = opts.history_full and true or false
  end
  if opts.fallback_toast ~= nil then
    config.fallback_toast = opts.fallback_toast and true or false
  end
end

---Closes every visible toast -- the way to close the fallback toast without
---ui.nvim, which has no time limit (see the module doc comment, step 3b).
---Leaves the history alone (`M.clear` forgets it). Loads no toast module that
---is not loaded yet: with none loaded, no toast can be open.
---@return nil
function M.dismiss()
  local toast = package.loaded["lib.nvim.ui.kit.toast"]
  if type(toast) == "table" and type(toast.clear) == "function" then
    toast.clear()
  end
end

---Opens the last delivered message in full, in a read-only viewer panel
---(yankable, `q`/`<Esc>` closes). No-op when nothing has been delivered yet.
---@return nil
function M.expand_last()
  if not last_entry then
    return
  end
  require("lib.nvim.ui.kit.viewer").open({
    lines = vim.split(last_entry.message, "\n", { plain = true }),
    title = last_entry.source or "notify",
  })
end

---Toggles `config.history_full` (collapsed vs. full entries in
---`show_history()`). Exposed separately from `setup` so a keymap -- the
---buffer-local `<C-s>` in a history buffer, or a global one from the user's
---own config -- can flip it without reading the current value back out.
---@return nil
function M.toggle_full()
  config.history_full = not config.history_full
end

---Matches an entry against an optional source filter.
---@param entry Lib.Notify.Popup.Entry
---@param source string|nil
---@return boolean
local function matches(entry, source)
  return source == nil or entry.source == source
end

---The recorded messages, oldest first.
---@param source? string Only messages delivered with this source
---@return Lib.Notify.Popup.Entry[]
function M.history(source)
  if source == nil then
    return vim.list_slice(history)
  end
  return vim.tbl_filter(function(entry)
    return matches(entry, source)
  end, history)
end

---Forgets recorded messages.
---@param source? string Only forget messages of this source (default: all)
---@return nil
function M.clear(source)
  if source == nil then
    history = {}
    last_entry = nil
    return
  end
  history = vim.tbl_filter(function(entry)
    return not matches(entry, source)
  end, history)
  if last_entry and matches(last_entry, source) then
    last_entry = nil
  end
end

---Renders the recorded messages (optionally filtered by `source`) into
---display lines, prefixed with time and level. Collapsed to `config.max_lines`
---per entry (plus a `[+N lines, <C-s>]` marker) unless `config.history_full`.
---@param source? string
---@return string[]
local function render_history_lines(source)
  local lines = {}
  for _, entry in ipairs(M.history(source)) do
    local spec = LEVELS[entry.level] or LEVELS[vim.log.levels.INFO]
    local prefix = ("%s %-5s "):format(entry.time, spec.name:upper())
    local pad = (" "):rep(#prefix)
    local entry_lines = vim.split(entry.message, "\n", { plain = true })
    if not config.history_full and #entry_lines > config.max_lines then
      local hidden = #entry_lines - config.max_lines
      entry_lines = vim.list_slice(entry_lines, 1, config.max_lines)
      entry_lines[#entry_lines + 1] = ("[+%d lines, <C-s>]"):format(hidden)
    end
    for i, text in ipairs(entry_lines) do
      lines[#lines + 1] = (i == 1 and prefix or pad) .. text
    end
  end
  if #lines == 0 then
    lines = { "(no messages yet)" }
  end
  return lines
end

---Opens the history in a scratch buffer (newest last) so it can be yanked.
---`<C-s>` (buffer-local) toggles collapsed/full entries, same effect as
---`M.toggle_full()`.
---@param source? string Only show messages of this source
---@return integer bufnr
function M.show_history(source)
  -- A buffer name is unique: reopening while the previous history buffer is
  -- still around would fail with E95, so retire the old one first.
  local name = "notify://" .. (source or "messages")
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == name then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end

  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()

  local function render()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, render_history_lines(source))
    vim.bo[buf].modifiable = false
  end
  render()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, name)
  vim.cmd("normal! G")
  vim.keymap.set(
    "n",
    "q",
    "<Cmd>close<CR>",
    { buffer = buf, silent = true, desc = "Close message history" }
  )
  vim.keymap.set("n", "<C-s>", function()
    M.toggle_full()
    render()
  end, { buffer = buf, nowait = true, silent = true, desc = "Toggle collapsed/full messages" })
  return buf
end

---The `:Lib notify …` routes, for `lib.nvim_usrcmds` to merge into the `:Lib`
---verb it already builds. Exposed as data rather than registered here so
---there is exactly one place that owns the `:Lib` verb (same pattern as
---`lib.nvim.deps.routes()`).
---@return table[] routes
function M.routes()
  return {
    {
      path = { "notify", "last" },
      desc = "Show the last delivered message in full (viewer)",
      run = function()
        M.expand_last()
      end,
    },
    {
      path = { "notify", "history" },
      args = {
        {
          name = "source",
          type = "STRING",
          optional = true,
          desc = "Only show messages of this source; default: all",
        },
      },
      desc = "Open the notify history (optionally filtered by source)",
      run = function(ctx)
        M.show_history(ctx.args.source)
      end,
    },
    {
      path = { "notify", "dismiss" },
      desc = "Close every visible notification toast (history stays)",
      run = function()
        M.dismiss()
      end,
    },
    {
      path = { "notify", "clear" },
      args = {
        {
          name = "source",
          type = "STRING",
          optional = true,
          desc = "Only forget messages of this source; default: all",
        },
      },
      desc = "Clear the notify history (optionally by source)",
      run = function(ctx)
        M.clear(ctx.args.source)
      end,
    },
  }
end

return M
