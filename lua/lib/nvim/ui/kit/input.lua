---@module 'lib.nvim.ui.kit.input'
--- Input component: a single-line themed prompt (a `vim.ui.input` replacement).
--- Opens focused in insert mode; `<CR>` submits the line, `<Esc>` cancels. It is
--- one line: a newline in `opts.default` (or in a button label) becomes a space.
---
--- `opts.secret = true` masks the displayed content character-by-character
--- via `conceal` (each char replaced with `opts.mask`, default `"*"`, which is also what
--- a mask that is not a string, or that nvim cannot show, becomes) — a
--- `vim.fn.inputsecret` replacement. The mask is re-derived from the actual
--- buffer content on every edit (paste, backspace, mid-line insert all just
--- work, no keystroke-diffing needed) rather than tracked in a shadow
--- variable, so submission still reads the real text straight off the
--- buffer. This only hides the on-screen rendering, matching a terminal
--- password prompt's own echo-suppression rather than the visible-input
--- default; buffer-local `undolevels = -1` additionally keeps the plaintext
--- out of the undo tree. It was never written to disk in the first place —
--- every kit scratch buffer already has `swapfile = false` (make_scratch),
--- and the buffer is wiped when the float closes (`bufhidden = "wipe"`). The
--- Insert run that typed it is also what the `.` register and the redo buffer
--- keep, so once the prompt is gone those are overwritten by an empty run
--- (`M.scrub_insert_traces`); a macro that is being recorded keeps the keys it
--- saw, as it does for `inputsecret()`. Two more doors are shut: insert-mode
--- completion would offer the words of the buffer -- the secret -- in a popup in clear
--- text, so `<C-n>`, `<C-p>` and `<C-x>` do nothing in a secret prompt (but move in
--- the popup of its own `completion`) and 'autocomplete' is off there; and the buffer
--- carries `vim.b.ui_kit_secret = true` (`lib.nvim.ui.kit.surface.SECRET_VAR`), which a keystroke
--- HUD such as `ui.screenkey` reads to leave the keys typed into it out.
---
--- `opts.completion = "file"` (or any other `getcompletion()` type: "dir",
--- "shellcmd", "buffer", ...) is a `completion = "file"` cmdline-input
--- replacement: `<Tab>` completes the last whitespace-delimited fragment
--- before the cursor via `vim.fn.getcompletion()` and opens Neovim's native
--- completion popup (`vim.fn.complete()`) — real ins-completion, so `<C-n>`/
--- `<C-p>` cycle it same as anywhere else. While the popup is open, `<Tab>`/
--- `<S-Tab>` advance/retreat the selection instead of re-triggering, and
--- `<CR>` accepts the highlighted candidate instead of submitting the whole
--- prompt (a second `<CR>` submits, exactly like confirming a shell
--- completion then pressing enter again). With `"file"` or `"dir"` and more than 300
--- candidates (entries the fragment starts; for `"dir"` the files among them count) the
--- list is built from one directory listing instead (no `stat` per candidate, matched and
--- sorted as `getcompletion()` does, cut to 300): `getcompletion()` took half a second
--- for five thousand files.
--- A fragment that holds a backtick is never completed: `getcompletion()` would run
--- the span between backticks through the shell, and a pasted line is not to be
--- trusted with that.
---
--- `opts.on_back` makes the prompt one step of a larger flow (`kit.form` with
--- `back = true`): `<BS>` on an EMPTY line, `<S-Tab>` and `<C-p>` close the
--- prompt and call `on_back(line)` -- the line as it stood, so the caller can
--- keep a half-typed answer -- instead of `on_submit`/`on_cancel`. A press of
--- those keys while a completion popup is open still belongs to the popup,
--- and without `on_back` none of the three is touched. A `<BS>` that follows
--- another one of the same prompt by less than 300 ms is a held key repeating,
--- not a new press, and never goes back (see `BS_RUN_MS`): holding it down
--- empties the field and stops there instead of deleting the answers before it.
---
--- `opts.buttons` adds a clickable row of `[ Label ]` buttons under the field
--- (`{ { id = "back"|"skip"|"submit", label = "..." }, ... }`; `submit` is
--- `<CR>`, `skip` is `<Esc>`, `back` is the `on_back` keys, and a `back` button
--- is dropped when there is no `on_back`). `<Down>` (and `<Tab>`, unless
--- `completion` owns it) moves the focus from the field onto the row, starting
--- on the `submit` button; there `h`/`l`/arrows/`<Tab>`/`<S-Tab>` move it,
--- `<CR>` presses the focused button, `<Esc>` still cancels and `<Up>`/`k`/`i`/
--- `a` return to the field. A left click on a button focuses *and* presses it
--- in one action, exactly as in `kit.confirm`. The row's layout, focus
--- highlight and hit-test are `lib.nvim.ui.kit.buttons`, shared with `kit.confirm`.
--- The row is line 2 of the buffer, so it is kept honest: it is laid out again,
--- shifted, when a long answer scrolls the window sideways (every line goes
--- with it), and a paste or `<C-j>` that splits the field into several lines
--- is joined back into one with a space, the row put back under it.

local surface = require("lib.nvim.ui.kit.surface")
local buttons = require("lib.nvim.ui.kit.buttons")
local hook = require("lib.nvim.ui.kit.hook")
local expand_path = require("lib.nvim.cross.fs.expand_path")
local is_windows = require("lib.nvim.cross.platform.is_windows")
-- A NUL in caller text raises E976 out of `vim.fn.strdisplaywidth()` and `split()`: text that is
-- only measured or split goes through this first (see `lib.lua.strings.core.nul_safe`).
local nul_safe = require("lib.lua.strings.core").nul_safe

local api = vim.api
local autocmd = require("lib.nvim.bindings.autocmd")
local fn = vim.fn
local uv = vim.uv or vim.loop

local M = {}

--- A `<BS>` on an empty field that follows another `<BS>` of the same field
--- within this many milliseconds is a held key repeating, not a new press (a
--- terminal cannot tell the two apart): it does not go back. A repeat runs at
--- ~30 Hz; a deliberate second press after emptying a field takes longer.
local BS_RUN_MS = 300

--- Extmark namespace of the focus highlight on the button row.
local BTN_NS = api.nvim_create_namespace("lib_kit_input_buttons")

--- How many windows to be typed into have ever been opened: this prompt, and
--- whatever else calls `M.mark_opened` (a sheet, a picker, a live_input, a compare).
--- `finish` compares it before and after the callbacks it runs to tell whether one
--- of them opened the next prompt of a chain.
---@type integer
local opened = 0

--- A component that has just opened a window to type into, and asks for Insert mode
--- with `:startinsert`, says so here. A prompt that closes while a callback opens
--- one of these must not stop Insert mode: `:startinsert` is ignored while the
--- closing prompt's own Insert mode is still on, and the new window would stand in
--- Normal mode, where the first thing typed is a command.
function M.mark_opened()
  opened = opened + 1
end

--- The number `M.mark_opened` has counted so far: read it before something that may
--- open such a window and compare after.
---@return integer
function M.opened_count()
  return opened
end

--- The group of the one `InsertLeave` hook `scrub_insert_traces` may leave waiting.
--- Asking for it again clears it, so a second request replaces the first.
local SCRUB_GROUP = "lib_kit_input_scrub"

---@internal
--- Overwrite what the last Insert run left behind, by running an empty one in a
--- buffer nobody sees.
local function scrub_now()
  local buf = api.nvim_create_buf(false, true)
  -- The keys of this run are not the user's: a keystroke HUD that reads the mark leaves the
  -- `i<Esc>` out instead of showing it right after the prompt closed.
  surface.mark_secret(buf)
  pcall(api.nvim_buf_call, buf, function()
    vim.cmd("silent! noautocmd normal! i\27")
  end)
  pcall(api.nvim_buf_delete, buf, { force = true })
end

--- A secret that was typed into a prompt is still the last Insert run when the
--- prompt is gone: the `.` register holds it (`:registers`, `<C-r>.`), and the redo
--- buffer replays it -- a `.` in any buffer types the password there. Neither is
--- a place `undolevels = -1` reaches. This overwrites both with an empty run (a
--- `.` afterwards does nothing but step the cursor left, like `i<Esc>`).
---
--- Never synchronously: the register is written when the Insert run ENDS, which
--- for a prompt that closes is after its mapping returns. And not while the run
--- is still on (a callback opened the next prompt of a chain, which carries it
--- on): that waits for the `InsertLeave` that ends it (a `<C-o>` fires one too, and
--- has finished the run so far: what is typed after it is another run). A macro being
--- recorded keeps the keys it saw, as `inputsecret()` does.
function M.scrub_insert_traces()
  vim.schedule(function()
    if api.nvim_get_mode().mode:sub(1, 1) == "i" then
      autocmd.create("InsertLeave", function()
        vim.schedule(scrub_now)
      end, {
        group = autocmd.group(SCRUB_GROUP, true),
        once = true,
        record = false,
        desc = "lib.nvim.ui.kit.input: scrub the secret out of the last Insert run",
      })
      return
    end
    scrub_now()
  end)
end

--- The ids `opts.buttons` understands.
---@type table<string, true>
local BUTTON_IDS = { back = true, skip = true, submit = true }

---@internal
--- Hand `keys` back to Neovim un-remapped and AHEAD of whatever is still
--- queued, for a mapping that only wants to intercept some presses of a key
--- (`<BS>` on an empty line, `<S-Tab>` with no popup open). Appending them
--- instead would reorder a pasted or fast-typed run.
---@param keys string
local function pass_through(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "ni", false)
end

---@internal
--- Split `opts.buttons` into parallel id/label lists. Unknown ids, labels that
--- are not strings and a `back` button without an `on_back` to call are
--- dropped: a button that can do nothing is worse than no button.
---@param opts table
---@return string[] ids
---@return string[] labels
local function resolve_buttons(opts)
  local ids, labels = {}, {}
  if type(opts.buttons) ~= "table" then
    return ids, labels
  end
  for _, b in ipairs(opts.buttons) do
    if
      type(b) == "table"
      and BUTTON_IDS[b.id]
      and type(b.label) == "string"
      and (b.id ~= "back" or type(opts.on_back) == "function")
    then
      ids[#ids + 1] = b.id
      labels[#labels + 1] = b.label
    end
  end
  return ids, labels
end

---@internal
---Conceal every character of buffer row `row` (0-based) with `mask`, on top of
---whatever `ns` already holds. Shared with `lib.nvim.ui.kit.sheet`, whose secret fields
---are rows of one buffer. A NUL in the line (a paste, `<C-v>000`) is masked like any
---other character: the split below would raise out of the `TextChanged` handler instead,
---after the namespace had been cleared, and leave the whole secret on screen.
---@param bufnr integer
---@param ns integer
---@param row integer
---@param mask string
local function conceal_line(bufnr, ns, row, mask)
  local line = nul_safe(api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or "")
  -- nvim refuses a mask that does not start with a printable character (a newline, NUL,
  -- escape, a lone continuation byte, U+200B ...) and asks only for that first one. Raised
  -- from the loop below, after the caller cleared the namespace, it would leave the secret
  -- on screen.
  local ok, probe = pcall(api.nvim_buf_set_extmark, bufnr, ns, row, 0, { conceal = mask })
  if ok then
    api.nvim_buf_del_extmark(bufnr, ns, probe)
  else
    mask = "*"
  end
  -- One string per character (a base plus its combining marks is one), walked once:
  -- `byteidx(line, i)` rescans the line from its start for every `i`, which made this
  -- quadratic in the length of a pasted token -- and `lib.nvim.ui.kit.sheet` runs it for every
  -- secret row at every repaint.
  local col = 0
  for _, ch in ipairs(fn.split(line, "\\zs")) do
    local stop = col + #ch
    api.nvim_buf_set_extmark(bufnr, ns, row, col, { end_col = stop, conceal = mask })
    col = stop
  end
end

---@internal
---Re-conceal every character of the input's single line with `mask`.
---@param bufnr integer
---@param ns integer
---@param mask string
local function apply_mask(bufnr, ns, mask)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  conceal_line(bufnr, ns, 0, mask)
end

---@internal
---Close the ways out of a secret buffer that the mask does not cover. Shared with
---`lib.nvim.ui.kit.sheet`, whose fields are rows of one buffer.
---
--- * The buffer is marked (`surface.SECRET_VAR`), so a keystroke HUD or recorder leaves
---   the keys typed into it out.
--- * Insert-mode completion works on the words of the buffer, and the buffer is the
---   secret: `<C-n>`/`<C-p>` offered them in a popup in clear text and inserted the pick
---   unmasked, and so did `<C-x><C-n>`/`<C-x><C-p>` (whatever 'complete' says). All of
---   them do nothing now, except to move in the popup that `opts.completion`'s own `<Tab>`
---   opened. (An empty buffer-local 'complete' is not the way: `<C-n>` then types a
---   literal ^N into the secret, and `<C-x><C-n>` still completes.)
--- * The same goes for 'autocomplete' (Neovim 0.12), which opens that popup by itself as
---   one types: off for this buffer. Older Neovim has no such option, hence the pcall.
---@param bufnr integer
local function protect_secret_buffer(bufnr)
  surface.mark_secret(bufnr)
  pcall(function()
    vim.bo[bufnr].autocomplete = false
  end)
  ---@param key string
  ---@return fun()
  local function popup_only(key)
    return function()
      if fn.pumvisible() == 1 then
        pass_through(key)
      end
    end
  end
  local key_opts = { buffer = bufnr, nowait = true }
  vim.keymap.set("i", "<C-n>", popup_only("<C-n>"), key_opts)
  vim.keymap.set("i", "<C-p>", popup_only("<C-p>"), key_opts)
  vim.keymap.set("i", "<C-x>", "<Nop>", key_opts)
end

--- More path candidates than this are not a menu to read -- typing the next letter
--- narrows them faster than scrolling does -- and `getcompletion()` pays a file-system
--- `stat` per candidate, ~0.1 ms each: a directory of five thousand files froze the
--- editor for half a second at every <Tab>. Past this many the list is built without.
--- A candidate is an entry whose name starts with the fragment, whatever it is: with
--- `completion = "dir"` the files among them count as well, `getcompletion()` pays for
--- those too before it drops them.
local MAX_PATH_MATCHES = 300

---@internal
---A file name folded for matching and ordering where Neovim ignores case: upper-cased,
---because Neovim's `pathcmp()` -- what `getcompletion()` orders by -- compares through
---`mb_toupper()`, and the characters `[ ] ^ _` and the backtick sort between the capitals
---and the small letters. Lower-cased, `item_1` would come before `itemA` where
---`getcompletion()` has it behind. A name with a non-ASCII byte goes through `toupper()`:
---`string.upper` folds ASCII only and would leave an a-umlaut behind a capital U-umlaut.
---That orders names; whether one STARTS with a fragment is not settled by it where a
---non-ASCII byte is involved (see `prefix_regex`).
---@param s string
---@return string
local function fold_key(s)
  return s:find("[\128-\255]") and fn.toupper(s) or s:upper()
end

---@internal
---Neovim's own "starts with `name`" test, for the names the byte comparison of
---`many_path_matches` cannot judge. `toupper()` and Neovim's case folding (`utf_fold()`)
---do not fall together: upper-cased, a dotless i (U+0131) would be an "I" and the Kelvin
---sign (U+212A) stay apart from "k", where Neovim has it the other way round. And Neovim
---refuses a match whose next character is a combining mark -- "U" is no prefix of "U" plus
---U+0308 -- which no byte comparison sees. `\V`: `name` is literal text, but for the
---backslash. `\c` or `\C` is said outright, whatever 'ignorecase' says.
---@param name string
---@param fold boolean
---@return vim.regex|nil  # nil when the pattern does not compile
local function prefix_regex(name, fold)
  local ok, re =
    pcall(vim.regex, "^" .. (fold and "\\c" or "\\C") .. "\\V" .. (name:gsub("\\", "\\\\")))
  return ok and re or nil
end

---@internal
---`key` without its marks U+0300..U+036F (bytes CC 80..BF and CD 80..AF) -- the base
---characters the split in `order_by_base_characters` leaves -- for a name of nothing but ASCII,
---Latin-1 and those marks: `e` + U+0301, the macOS way. The split costs ten times what these
---few patterns do. nil for any other name, which is left to the split: one with a byte that
---makes no such character (a mark behind it is then a character of its own, not a part of
---it), one with a mark where nothing stands before it to take it in (no separator in front),
---one with a control character or U+00AD (they take no mark, to `strchars()`), or any other
---character.
---@param key string
---@param after_sep boolean
---@return string|nil
local function without_common_marks(key, after_sep)
  if
    key:find("[\194\195][\204\205]") -- a mark cut a character in two
    or key:find("\194[\128-\159\173]") -- U+0080..U+009F and U+00AD
    or (not after_sep and key:find("^[\204\205]")) -- a mark with no base
  then
    return nil
  end
  local plain = key:gsub("\204[\128-\191]", ""):gsub("\205[\128-\175]", "")
  if plain:gsub("[\194\195][\128-\191]", ""):find("[%c\128-\255]") then
    return nil
  end
  return plain
end

---@internal
---Sort key of the candidates that may hold a combining mark, as `pathcmp()` -- what
---`getcompletion()` orders by -- has it: it steps over a character and the marks after it
---as one (`utfc_ptr2len`) but compares only the first code point of each. "Abe" + U+0308 +
---"x" therefore sorts beside "Abex", where its bytes would put it behind "Abez". Rewrites
---`key` of those candidates to the sequence of their base characters; names that then share
---a key stay with the caller's tie-break (`getcompletion()` leaves those to an unstable
---`qsort`, which nothing can reproduce).
---
---`wides` are the indices into `found` of the candidates with a byte from CC on: U+0300, the
---first mark of all, starts with CC 80, so no other name can hold one. Whether any of them
---does is asked once, of all the names together: asked per name, a big directory of Cyrillic
---or CJK names (every one has such a byte) paid two `vim.fn` calls each for an answer that
---is nearly always no. That answer only says that a mark exists SOMEWHERE, so once it is yes
---each name is asked on its own (a pair of `strchars()`, about 1.5 us) and only those that
---hold a mark are taken apart (`split()`, about 20 us): a directory of five thousand Cyrillic
---names and one written the macOS way would otherwise split every one of them for keys that
---come out as they went in. Of those, a name that is nothing but ASCII, Latin-1 and the
---marks U+0300..U+036F is not taken apart either (`without_common_marks`).
---
---`after_sep`: a separator stands right before the name in what `pathcmp()` compares -- the
---path has a directory part -- and a mark at the very start of a name belongs to that
---separator (`utfc_ptr2len` takes the two as one character, of which the code point of the
---separator is the first), so it does not count. Without a directory part the same mark is
---a character of its own, and it does. The separator is put in front of every name for the
---questions and the split, and the character it makes is left out of the key.
---@param found {key: string, name: string, kind: string?}[]
---@param wides integer[]
---@param after_sep boolean
local function order_by_base_characters(found, wides, after_sep)
  local lead = after_sep and "/" or ""
  local names = {}
  for i = 1, #wides do
    names[i] = lead .. found[wides[i]].name
  end
  local joined = table.concat(names, "\n")
  if fn.strchars(joined) == fn.strchars(joined, 1) then
    return -- no mark among them (strchars() counts a mark of its own, unless told to skip it)
  end
  local first = after_sep and 2 or 1 -- the first cluster is the separator and its marks
  for i = 1, #wides do
    local it = found[wides[i]]
    local text = lead .. it.key
    local plain = without_common_marks(it.key, after_sep)
    if plain then
      it.key = plain
    elseif fn.strchars(text) ~= fn.strchars(text, 1) then
      local clusters = fn.split(text, "\\zs")
      local bases = {}
      for c = first, #clusters do
        -- the first code point of the cluster; bytes that are no UTF-8 are their own character
        bases[#bases + 1] = clusters[c]:match("^[\1-\127\194-\244][\128-\191]*") or clusters[c]
      end
      it.key = table.concat(bases)
    end
  end
end

---@internal
---The candidates for a path fragment that MORE than `MAX_PATH_MATCHES` entries of its
---directory start with, built from one directory listing, matched and ordered the way
---`getcompletion()` does and cut to that many. The listing says what an entry is, so a
---file or a directory costs no `stat`; a link, or a file system that does not say, is
---asked about only in the ordered list and only until `MAX_PATH_MATCHES` entries are
---accepted. With `dirs_only` that can be every link of the directory (a link to a file is
---no directory), and the list is then the whole answer -- possibly short, possibly empty,
---which is an answer too: `getcompletion()` would stat each of them once more for the
---same result. A link that leads nowhere has no type and is left out, as `getcompletion()`
---leaves it. A fragment with too few candidates to need the list costs no `stat`.
---
---Whether an entry starts with the fragment is a byte comparison, folded to upper case
---where Neovim ignores case -- except where a non-ASCII byte is involved, when Neovim's own
---regex engine decides (`prefix_regex`), as it does for `getcompletion()`: always under case
---folding, and otherwise, for a fragment that is not ASCII, for every name with a non-ASCII
---byte (the fragment can end inside a character, and a lone Latin-1 byte is the same character
---as its UTF-8 spelling to the regex: neither is a byte comparison), and for a fragment that is
---ASCII, for a name whose next character is a combining mark. A name
---with a combining mark is ordered by its base characters, as `pathcmp()` does
---(`order_by_base_characters`); a mark right after the separator in front of the name belongs to
---that separator there, and is no part of the key.
---
---nil for anything else -- a pattern, a fragment with a NUL byte, a directory that cannot
---be listed, a fragment with few candidates -- which is `getcompletion()`'s as before.
---@param frag string
---@param dirs_only boolean
---@return string[]|nil
local function many_path_matches(frag, dirs_only)
  if frag:find("[*?%[{]") then
    return nil -- a pattern: only getcompletion() expands those
  end
  if frag:find("\0", 1, true) then
    -- No file name holds a NUL, and one in a Lua string reaches `vim.fn` (`fold_key`) as
    -- a Blob: E976. getcompletion() refuses such a fragment itself, under its `pcall`.
    return nil
  end
  local cut = frag:find("[/\\][^/\\]*$")
  local head = cut and frag:sub(1, cut) or ""
  local name = cut and frag:sub(cut + 1) or frag
  local dir = head == "" and "." or expand_path(head)
  local handle = uv.fs_scandir(dir)
  if not handle then
    return nil
  end
  -- Neovim matches case-blind under 'fileignorecase' or 'wildignorecase' (and always on
  -- Windows, whose directory search is), but orders case-blind under 'fileignorecase' only.
  local fic = vim.o.fileignorecase
  local fold = fic or vim.o.wildignorecase or is_windows()
  local want = fold and fold_key(name) or name
  local ascii_want = not name:find("[\128-\255]")
  local dotted = name:sub(1, 1) == "." -- dot files only when asked for by name
  local re ---@type vim.regex|false|nil  # Neovim's matcher, built at the first entry that needs it
  --- Does `entry` start with `name`, as Neovim has it?
  ---@param entry string
  ---@return boolean
  local function by_regex(entry)
    if re == nil then
      re = prefix_regex(name, fold) or false
    end
    return re and re:match_str(entry) ~= nil or false
  end
  local seen = 0 -- every candidate: what `getcompletion()` has to look at
  local found = {} -- the ones that can still be an answer
  local wides = {} -- the indices into `found` of those that may hold a combining mark
  while true do
    local entry, kind = uv.fs_scandir_next(handle)
    if not entry then
      break
    end
    if dotted or entry:sub(1, 1) ~= "." then
      local wide = entry:find("[\128-\255]") ~= nil -- a non-ASCII byte in the name
      local key = fold and fold_key(entry) or entry
      local hit
      if not ascii_want or (fold and wide) then
        -- A non-ASCII byte on either side, and the bytes do not settle it: under case folding
        -- the Kelvin sign is a "k"; and a fragment that is not ASCII may end inside a character,
        -- or be written in another encoding than the name (a lone Latin-1 byte E4 is the same
        -- character as the UTF-8 pair C3 A4 to Neovim's regex, and the other way round), which
        -- no byte comparison sees in either direction. Without folding an ASCII name cannot
        -- start with such a fragment, so only a name with a non-ASCII byte of its own is asked.
        hit = (fold or wide) and by_regex(entry)
      else
        hit = key:sub(1, #want) == want
        if hit and wide then
          -- An ASCII fragment, and no folding (that is the branch above): only the next
          -- character matters, and a combining mark starts with CC or later.
          local after = entry:byte(#name + 1)
          if after and after >= 0xCC then
            hit = by_regex(entry)
          end
        end
      end
      if hit then
        seen = seen + 1
        -- a file is no directory, and need not be kept
        if not (dirs_only and kind == "file") then
          found[#found + 1] = { key = fic and key or entry, name = entry, kind = kind }
          if wide and entry:find("[\204-\255]") then
            wides[#wides + 1] = #found
          end
        end
      end
    end
  end
  if re == false then
    return nil -- Neovim's matcher could not be built: nothing above can be relied on
  end
  -- Too few candidates for a long list, whatever their types turn out to be: up to
  -- this many `getcompletion()` costs a few tens of milliseconds and stays the authority.
  if seen <= MAX_PATH_MATCHES then
    return nil
  end
  order_by_base_characters(found, wides, head ~= "")
  table.sort(found, function(a, b)
    if a.key ~= b.key then
      return a.key < b.key
    end
    return a.name < b.name -- names that fold alike: not left to the order of the listing
  end)
  local out = {}
  for _, it in ipairs(found) do
    if #out == MAX_PATH_MATCHES then
      break -- the menu is full; what follows would only be cut
    end
    local kind = it.kind
    if kind ~= "file" and kind ~= "directory" then
      -- a link, or a file system that does not say: the target decides. A link that leads
      -- nowhere has no type, and `getcompletion()` lists none of those either.
      local st = uv.fs_stat(dir .. "/" .. it.name)
      kind = st and st.type
    end
    if kind == "directory" or (kind and not dirs_only) then
      out[#out + 1] = head .. it.name .. (kind == "directory" and "/" or "")
    end
  end
  return out -- the walk is done: this is the answer, cut to a menu, and short or empty or not
end

---@internal
---Complete the fragment before the cursor via `vim.fn.getcompletion()` and
---open the native completion popup at the right start column. The line is the
---one the cursor is on: the prompt's own single line here, a field's row for
---`lib.nvim.ui.kit.sheet`, which shares this.
---@param bufnr integer
---@param winid integer
---@param completion string  # a `getcompletion()` type, e.g. "file", "dir"
local function trigger_completion(bufnr, winid, completion)
  local cursor = api.nvim_win_get_cursor(winid)
  local line = api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
  local col = cursor[2]
  local prefix = line:sub(1, col)
  -- Scanned from the end: `match("%S*$")` retries the rest of a long word from
  -- every start byte, which is quadratic for one pasted line without spaces.
  local frag = prefix:reverse():match("^%S*"):reverse()
  -- getcompletion() hands a backtick span in its argument to 'shell' (the
  -- "file", "dir", "shellcmd" and "file_in_path" types), and the fragment is text
  -- from wherever the user pasted it: never pass one on (SEC-34). A backtick
  -- belongs to no sensible file-name fragment anyway.
  if frag:find("`", 1, true) then
    return
  end
  local matches = (completion == "file" or completion == "dir")
    and many_path_matches(frag, completion == "dir")
  if not matches then
    local ok, got = pcall(fn.getcompletion, frag, completion)
    if not ok or not got then
      return
    end
    matches = got
  end
  if #matches == 0 then
    return -- nothing to offer: `complete()` is not called with an empty list
  end
  -- getcompletion() returns full replacement strings (e.g. "/etc/passwd" for
  -- fragment "/etc/pas"), so complete()'s start column is where `frag` began.
  pcall(fn.complete, col - #frag + 1, matches)
end

--- Open a single-line input.
---@param opts table  # { title|prompt, default, theme, width, relative, on_submit, on_cancel, expand_env, secret, mask, completion, on_back, buttons }
--- `expand_env = true` runs the submitted line through `lib.nvim.cross.fs.expand_path`
--- (`~`, `$VAR`, `${VAR}`, `%VAR%`) before it reaches `on_submit` — opt-in, for
--- callers that know they're prompting for a path.
--- `on_back` / `buttons`: see the module doc — opt-in, nothing changes without them.
---@return Lib.UI.Kit.Surface|nil
function M.open(opts)
  opts = opts or {}

  local hooked = hook.intercept("input", opts, function(value)
    if value == nil then
      if opts.on_cancel then
        opts.on_cancel()
      end
    elseif opts.on_submit then
      opts.on_submit(tostring(value))
    end
  end)
  if hooked then
    return hooked
  end

  local title = opts.title or opts.prompt
  -- A float's title is drawn within its content width; a title longer than
  -- the default 40 cols gets silently truncated by Neovim (with a leading
  -- ellipsis) instead of wrapping, so widen the box to fit it.
  local title_width = title and vim.fn.strdisplaywidth(nul_safe(title)) or 0

  local btn_ids, btn_labels = resolve_buttons(opts)
  local has_buttons = #btn_ids > 0
  local can_back = type(opts.on_back) == "function"

  local width = opts.width or math.max(40, title_width)
  if has_buttons and width >= 1 then
    -- A row clipped by the border has buttons the mouse cannot hit. (A
    -- fraction of the editor, `width < 1`, is left to make_scratch.)
    width = math.max(width, buttons.row_width(btn_labels) + 2)
  end

  -- No auto-indent in a prompt. A line opened by a linewise paste or `<C-j>` makes
  -- Neovim remember an indent it added, and `stopinsert` then deletes the white space
  -- under the cursor -- which `park_cursor` leaves on the space after the `[` of a
  -- button when it moves the focus onto the row: the row came back one space short
  -- and `keep_layout` folded it into the answer.
  local bo = { autoindent = false, smartindent = false, cindent = false }
  if opts.secret then
    bo.undolevels = -1
  end

  -- The line must be one line: a newline in a buffer line is an error in
  -- `nvim_buf_set_lines` (a default from a data file, say, with a multi-line note).
  local default = (tostring(opts.default or ""):gsub("[\r\n]+", " "))

  local surf = surface.open({
    modal = true,
    lines = has_buttons and { default, "" } or { default },
    theme = opts.theme,
    title = title,
    width = width,
    height = has_buttons and 2 or 1,
    relative = opts.relative or "cursor",
    enter = true,
    modifiable = true,
    wo = opts.secret and { conceallevel = 2, concealcursor = "nvic" } or nil,
    bo = bo,
  })
  if not surf then
    return nil
  end

  M.mark_opened()
  local bufnr = surf.bufnr
  local done = false

  ---@return string
  local function get_line()
    -- The buffer can be gone while the window lives on (a forced swap of the buffer
    -- shown in it): `finish` must still run, through `surf:on_close`, or no callback fires.
    if not api.nvim_buf_is_valid(bufnr) then
      return ""
    end
    return api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  end

  -- The button row, when there is one: line 2 of the buffer. `btn_focus` is the
  -- 1-based button the focus is on, nil while it is in the field (line 1).
  local btn_focus = nil
  local ranges = {}
  local row_text = "" -- what line 2 holds right now
  local row_scroll = 0 -- the window's `leftcol` that `row_text` was laid out for
  local default_btn = 1 -- where <Down>/<Tab> land: the button <CR> would press anyway
  for i, id in ipairs(btn_ids) do
    if id == "submit" then
      default_btn = i
    end
  end

  if opts.secret then
    local ns = api.nvim_create_namespace("lib_kit_input_secret_" .. bufnr)
    -- `conceal` takes a string: any other type (a number, `true`, a table from a config that
    -- was passed through) would raise out of `TextChanged` after `apply_mask` had cleared the
    -- marks, and leave the secret on screen. `lib.nvim.ui.kit.sheet` makes the same choice.
    local mask = type(opts.mask) == "string" and opts.mask or "*"
    apply_mask(bufnr, ns, mask)
    protect_secret_buffer(bufnr)
    -- `TextChangedP` too: a candidate picked in a completion popup is a change that fires
    -- it, not `TextChangedI`, and was inserted unmasked.
    autocmd.create({ "TextChangedI", "TextChangedP", "TextChanged" }, function()
      apply_mask(bufnr, ns, mask)
    end, {
      -- Buffer-local and in no group: a group shared by every prompt, cleared at each open,
      -- took the first prompt's re-mask away when a second one opened (what was typed after
      -- that showed in clear text), and one named after the buffer was a group and a record
      -- per prompt that nothing ever removed. The autocmd goes with the buffer, which is
      -- wiped when the float closes. `record = false`: a throwaway hook of one float (see
      -- `lib.nvim.ui.kit.surface`).
      buffer = bufnr,
      record = false,
      desc = "lib.nvim.ui.kit.input: re-mask secret input",
    })
  end

  --- `action`: `true` submits (<CR>), `false` cancels (<Esc>), `"back"` steps
  --- back (`on_back`).
  ---@param action boolean|"back"
  local function finish(action)
    if done then
      return
    end
    done = true
    local line = get_line()
    local opened_before = opened
    surf:close()
    local ok, err = pcall(function()
      if action == "back" then
        if opts.on_back then
          opts.on_back(line)
        end
      elseif action then
        if opts.expand_env then
          line = expand_path(line)
        end
        if opts.on_submit then
          opts.on_submit(line)
        end
      elseif opts.on_cancel then
        opts.on_cancel()
      end
    end)
    -- Leave insert mode now that the prompt is gone (a lingering mode state
    -- otherwise) -- unless a callback opened the next prompt of a chain (a
    -- form's next field, or the one before it; a sheet, a picker, a live_input:
    -- anything that counts itself with `mark_opened`). That prompt is waiting for
    -- Insert mode, and `:startinsert` is ignored while this one's is still on:
    -- stopping here as well would strand it in Normal mode, where the first
    -- thing typed is a command.
    if opened == opened_before then
      pcall(function()
        vim.cmd("stopinsert")
      end)
    end
    if opts.secret then
      M.scrub_insert_traces()
    end
    if not ok then
      error(err, 0)
    end
  end

  --- Press button `i`: each one is one of the keys that already do it.
  ---@param i integer
  local function press(i)
    local id = btn_ids[i]
    if id == "back" then
      finish("back")
    elseif id == "skip" then
      finish(false)
    else
      finish(true)
    end
  end

  local function paint()
    buttons.paint(bufnr, BTN_NS, ranges, btn_focus)
  end

  --- Put the cursor on the focused button. Leaving insert mode (which is what
  --- a `<Down>` from the field is about to do) steps the cursor one column
  --- left, so aim one column right of the box's start to land on it.
  local function park_cursor()
    local r = ranges[btn_focus]
    if r then
      local from_insert = api.nvim_get_mode().mode:sub(1, 1) == "i"
      pcall(api.nvim_win_set_cursor, surf.winid, { 2, r.start_col + (from_insert and 1 or 0) })
    end
  end

  --- Run `write` with the buffer writable and no undo recorded for it: the row
  --- is not the user's to edit (the buffer is locked while the buttons have the
  --- focus), and `u` in the field must never reach it.
  ---@param write fun()
  local function write_silently(write)
    local modifiable = vim.bo[bufnr].modifiable
    local undolevels = vim.bo[bufnr].undolevels
    vim.bo[bufnr].modifiable = true
    vim.bo[bufnr].undolevels = -1
    local ok, err = pcall(write)
    vim.bo[bufnr].undolevels = undolevels
    vim.bo[bufnr].modifiable = modifiable
    if not ok then
      error(err, 0)
    end
  end

  --- Lay the button row out, again when the window has scrolled sideways. A
  --- long answer scrolls the whole window, every line with it, so a row laid out
  --- for column 0 would end up off screen: it is padded by the same amount
  --- instead, which keeps it where it was drawn. The click ranges are byte
  --- columns of the line -- what `getmousepos()` reports, scrolled or not -- so
  --- they move with the padding.
  ---@param force? boolean  # lay out even when the scroll is the one the row was drawn for
  local function layout_row(force)
    local scroll = api.nvim_win_call(surf.winid, function()
      return fn.winsaveview().leftcol
    end)
    if scroll == row_scroll and not force then
      return
    end
    row_scroll = scroll
    -- Laid out after the window exists, so the row is centered in the width the
    -- float actually got (make_scratch clamps it to the editor).
    local text, laid = buttons.layout(btn_labels, api.nvim_win_get_width(surf.winid), 1)
    if scroll > 0 then
      text = string.rep(" ", scroll) .. text
      for _, r in ipairs(laid) do
        r.start_col = r.start_col + scroll
        r.end_col = r.end_col + scroll
      end
    end
    ranges = laid
    row_text = text
    write_silently(function()
      api.nvim_buf_set_lines(bufnr, 1, 2, false, { text })
    end)
    paint()
    if btn_focus then
      park_cursor()
    end
  end

  --- The field is one line and the row sits right under it. A paste with a
  --- newline in it (a clipboard that ends in one is the usual case) or a `<C-j>`
  --- splits the field and pushes the row out of the two lines the window shows:
  --- join what was typed back into one line and put the row under it again.
  local function keep_layout()
    if btn_focus then
      return -- the buffer is locked: nothing can have been typed
    end
    local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    if #lines == 2 and lines[2] == row_text then
      return
    end
    if lines[#lines] == row_text then
      lines[#lines] = nil
    end
    local parts = {}
    for _, l in ipairs(lines) do
      if l ~= "" then
        parts[#parts + 1] = l
      end
    end
    local field = table.concat(parts, " ")
    write_silently(function()
      api.nvim_buf_set_lines(bufnr, 0, -1, false, { field, row_text })
    end)
    pcall(api.nvim_win_set_cursor, surf.winid, { 1, #field })
  end

  if has_buttons then
    layout_row(true)
  end

  local focus_field
  local function move_focus(delta)
    if not btn_focus then
      return
    end
    btn_focus = buttons.wrap(btn_focus, delta, #btn_ids)
    paint()
    park_cursor()
  end

  -- Normal-mode keys that only mean something while the focus is on the row.
  -- Bound on entering it and removed on leaving it, so the field keeps every
  -- native key (`h`, `i`, ...) the rest of the time. Keys the field also
  -- binds (<Tab>, <S-Tab>, <Down>, <CR>, <Esc>) are static and check
  -- `btn_focus` themselves instead.
  local button_keys = {
    {
      { "l", "<Right>" },
      function()
        move_focus(1)
      end,
    },
    {
      { "h", "<Left>" },
      function()
        move_focus(-1)
      end,
    },
    {
      { "<Up>", "k", "i", "a", "I", "A" },
      function()
        focus_field()
      end,
    },
  }

  ---@param bind boolean
  local function set_button_keys(bind)
    for _, entry in ipairs(button_keys) do
      for _, lhs in ipairs(entry[1]) do
        if bind then
          vim.keymap.set("n", lhs, entry[2], { buffer = bufnr, nowait = true })
        else
          pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
        end
      end
    end
  end

  --- Move the focus from the field onto the button row (on `submit` unless
  --- told otherwise). The buffer is locked while it is there, so no stray
  --- edit key can touch the labels.
  ---@param index? integer
  local function focus_buttons(index)
    if not has_buttons or btn_focus then
      return
    end
    btn_focus = index or default_btn
    pcall(function()
      vim.cmd("stopinsert")
    end)
    vim.bo[bufnr].modifiable = false
    set_button_keys(true)
    paint()
    park_cursor()
  end

  --- Move the focus from the button row back into the field, in insert mode
  --- at byte column `col` (the end of the line when nil or past it). With the
  --- focus already in the field it only places the cursor.
  ---@param col? integer
  function focus_field(col)
    local line = get_line()
    if not btn_focus then
      if col then
        pcall(api.nvim_win_set_cursor, surf.winid, { 1, math.min(col, #line) })
      end
      return
    end
    btn_focus = nil
    set_button_keys(false)
    paint()
    vim.bo[bufnr].modifiable = true
    if col and col < #line then
      pcall(api.nvim_win_set_cursor, surf.winid, { 1, col })
      vim.cmd("startinsert")
    else
      pcall(api.nvim_win_set_cursor, surf.winid, { 1, #line })
      vim.cmd("startinsert!")
    end
  end

  --- A left click: on a button it focuses *and* presses it (as in
  --- `kit.confirm`); elsewhere in this float it puts the cursor on the field's
  --- text; anywhere else it is the click it would have been without this
  --- mapping. Hit-tested from `getmousepos()` rather than from where the
  --- cursor ended up, which is not something Neovim promises for a mapped
  --- `<LeftMouse>`.
  local function on_click()
    local i, pos = buttons.hit(ranges, surf.winid)
    if i then
      btn_focus = i
      paint()
      press(i)
    elseif not pos then
      pass_through("<LeftMouse>")
    elseif pos.line == 1 then
      focus_field(pos.column - 1)
    end
  end

  if opts.completion then
    -- <Tab>/<S-Tab> drive the native pum once it's open (advance/retreat);
    -- otherwise <Tab> triggers completion and <S-Tab> is a no-op literal tab.
    -- <Tab> is NOT an <expr> mapping: `complete()` raises E565 under the textlock
    -- one holds, and `trigger_completion`'s pcall swallowed it, so <Tab> did nothing.
    vim.keymap.set("i", "<Tab>", function()
      if fn.pumvisible() == 1 then
        pass_through("<C-n>")
      else
        trigger_completion(bufnr, surf.winid, opts.completion)
      end
    end, { buffer = bufnr, nowait = true })
    vim.keymap.set("i", "<S-Tab>", function()
      if fn.pumvisible() == 1 then
        return api.nvim_replace_termcodes("<C-p>", true, false, true)
      end
      return ""
    end, { buffer = bufnr, nowait = true, expr = true })
  end

  local key_opts = { buffer = bufnr, nowait = true }

  if can_back then
    -- handrolled-ok: the gap between two <BS> presses tells a held key from a
    -- new press; nothing is rate-limited, so `patterns.throttle` does not apply.
    -- Going back must not eat text: <BS> is only "back" once there is nothing
    -- left for it to delete, and a popup that is open keeps <C-p>. A key held
    -- down repeats faster than anyone presses it again: the repeat that finds
    -- the field emptied by the run before it is swallowed (and counts as part
    -- of the run), or one held <BS> would walk back through every earlier
    -- field and delete each answer in turn.
    local last_bs ---@type number|nil  # ms clock of the previous <BS> of this field
    vim.keymap.set({ "i", "n" }, "<BS>", function()
      if btn_focus then
        return
      end
      local now = uv.hrtime() / 1e6
      local in_run = last_bs ~= nil and now - last_bs < BS_RUN_MS
      last_bs = now
      if get_line() ~= "" then
        pass_through("<BS>")
      elseif not in_run then
        finish("back")
      end
    end, key_opts)
    vim.keymap.set({ "i", "n" }, "<C-p>", function()
      if btn_focus then
        return
      end
      if fn.pumvisible() == 1 then
        pass_through("<C-p>")
      else
        finish("back")
      end
    end, key_opts)
  end

  if can_back or has_buttons then
    -- Replaces the completion block's <S-Tab> above: same popup behaviour,
    -- plus what it does with the popup closed.
    vim.keymap.set({ "i", "n" }, "<S-Tab>", function()
      if btn_focus then
        move_focus(-1)
      elseif fn.pumvisible() == 1 then
        pass_through("<C-p>")
      elseif can_back then
        finish("back")
      end
    end, key_opts)
  end

  if has_buttons then
    if not opts.completion then
      vim.keymap.set("i", "<Tab>", function()
        focus_buttons()
      end, key_opts)
    end
    vim.keymap.set("n", "<Tab>", function()
      if btn_focus then
        move_focus(1)
      else
        focus_buttons()
      end
    end, key_opts)
    vim.keymap.set({ "i", "n" }, "<Down>", function()
      if btn_focus then
        return
      end
      if fn.pumvisible() == 1 then
        pass_through("<Down>")
      else
        focus_buttons()
      end
    end, key_opts)
    vim.keymap.set({ "i", "n" }, "<LeftMouse>", on_click, key_opts)

    -- The two lines are two places for the cursor, not one text: keep it on
    -- the field (or on the focused button) whatever tried to move it (`j`,
    -- `<C-o>G`, ...), so an edit can never land on the labels. The same hook
    -- keeps the row under the field when the text around it changed shape
    -- (a paste) and in view when the window scrolled (a long answer).
    autocmd.create(
      { "CursorMoved", "CursorMovedI", "TextChanged", "TextChangedI", "TextChangedP" },
      function()
        if not surf:is_valid() then
          return
        end
        keep_layout()
        layout_row()
        local row = api.nvim_win_get_cursor(surf.winid)[1]
        if btn_focus then
          if row ~= 2 then
            park_cursor()
          end
        elseif row ~= 1 then
          pcall(api.nvim_win_set_cursor, surf.winid, { 1, #get_line() })
        end
      end,
      {
        buffer = bufnr,
        record = false,
        desc = "lib.nvim.ui.kit.input: keep the field one line, the row under it and in view",
      }
    )
  end

  vim.keymap.set({ "i", "n" }, "<CR>", function()
    -- Accept the highlighted completion candidate instead of submitting the
    -- whole prompt; a second <CR> (pum now closed) submits as usual. This
    -- must NOT be an <expr> mapping: finish() closes the window, and Neovim
    -- silently blocks window/buffer changes while an <expr> mapping is
    -- still being evaluated (textlock) -- feeding <C-y> for real instead of
    -- returning it keeps that whole call chain outside of textlock.
    if opts.completion and fn.pumvisible() == 1 then
      api.nvim_feedkeys(api.nvim_replace_termcodes("<C-y>", true, false, true), "n", false)
      return
    end
    -- With the focus on the button row, <CR> presses the focused button.
    if btn_focus then
      press(btn_focus)
      return
    end
    finish(true)
  end, { buffer = bufnr, nowait = true })
  vim.keymap.set({ "i", "n" }, "<Esc>", function()
    finish(false)
  end, { buffer = bufnr, nowait = true })
  surf:on_close(function()
    finish(false)
  end)

  -- Place the cursor at end of the default text and enter insert mode.
  if surf:is_valid() then
    api.nvim_win_set_cursor(surf.winid, { 1, #default })
    vim.cmd("startinsert!")
  end

  return surf
end

--- The two helpers `lib.nvim.ui.kit.sheet` shares (its fields are rows of one buffer, so
--- it cannot reuse the single-line prompt itself).
M.conceal_line = conceal_line
M.protect_secret_buffer = protect_secret_buffer
M.complete = trigger_completion
M.order_by_base_characters = order_by_base_characters

return M
