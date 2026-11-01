---@module 'lib.nvim.messages'
---@brief Time-stamped message/event ring buffer -- the data source behind a
---"recent messages" popup. No UI at all; a renderer (ui.nvim) queries it.
---@description
--- Two feeds write into the same ring buffer:
---
---   1. `lib.nvim.notify`'s own delivery pipeline (`notify.popup.M.deliver`)
---      pushes every toast/history entry directly, at the source -- not
---      through the `ui_attach` logger below. A real-TUI spike found that
---      routing notify traffic through the logger instead loses vim.notify
---      (when noice owns it) and lib.nvim.notify toasts entirely (neither
---      ever reaches `ext_messages` as a `msg_show` event); writing straight
---      into the store at the point of delivery is the only path that sees
---      everything.
---   2. `vim.ui_attach(ns, {ext_messages=true}, cb)` -- every other message
---      Neovim shows (`:messages`, `:write`, search counts, Lua errors, raw
---      `nvim_echo`, ...). Only `history=true` `msg_show` events are kept by
---      default, plus the shell output of `:!cmd` (`shell_out`/`shell_err`/
---      `shell_ret`: `history=false`, but exactly what one looks for after running
---      a command); `config.kinds` opts further `history=false` kinds in
---      (`kinds = { shell_out = false }` opts a default one back out);
---      `replace_last=true` events overwrite the previous entry instead of
---      appending (Neovim's own signal for "this updates the prior line",
---      e.g. a search count after the pattern echo, the second half of a
---      `:write` message) -- skipping that would double every search/write
---      in the popup.
---
--- **Attach policy** (real-TUI spike, `ext-messages-tui-spike-2026-10-01.md`):
--- attaching as the *only* `ext_messages` listener takes over message AND
--- cmdline rendering from the TUI entirely -- nothing gets drawn, not just
--- "nothing recorded". This module therefore only attaches while a renderer
--- is already active (noice loaded, or an explicit override) and detaches
--- the moment that stops being true -- call `M.notify_renderer_changed()`
--- after toggling noice (it fires no enable/disable event of its own, so
--- nothing else can tell); `M.wrap_noice()` is an opt-in convenience that
--- patches `require("noice").enable/disable` to call it automatically.
--- With no renderer this module simply doesn't attach -- `M.push()` (feed 1
--- above) keeps working regardless, only the `ui_attach` feed is gated.
---
--- Entries carry `time_ms` from `vim.uv.hrtime() / 1e6` (monotonic,
--- sub-millisecond) -- `snapshot()`'s `since_ms`/`until_ms` are the same
--- clock, not wall-clock/epoch time. "Last 10 seconds" only ever needs a
--- relative comparison, so a monotonic clock sidesteps DST/epoch-rollover
--- entirely (the trade-off: entries don't survive a Neovim restart, which
--- this module never claimed to support -- it is a ring buffer, not a log
--- file).

require("lib.nvim.messages.@types")

local fast_event = require("lib.nvim.notify.internal.fast_event")

local M = {}

---@type Lib.Messages.Config
local DEFAULTS = {
  ring_size = 1000,
  -- `history=false` kinds kept anyway: what `:!cmd` prints is not in `:messages`, but
  -- it is exactly what one looks for in a "recent messages" popup after running it.
  kinds = { shell_out = true, shell_err = true, shell_ret = true },
  renderer_override = nil,
}

---@type Lib.Messages.Config
local config = vim.deepcopy(DEFAULTS)

---@type Lib.Messages.Entry[]
local entries = {}

---@type integer
local head = 1

---@type integer
local count = 0

---A `lib.lua.listeners` list of `fun(entry: Lib.Messages.Entry)`.
local listeners = require("lib.lua.listeners").new()

-- `kind` -> `vim.log.levels` value, for `msg_show` events (Neovim gives no
-- level of its own). Verified against a real TUI, not guessed from docs --
-- see the spike's "Kind-Katalog". Anything absent here defaults to INFO.
local KIND_LEVEL = {
  lua_error = vim.log.levels.ERROR,
  echoerr = vim.log.levels.ERROR,
  -- `E518: Unknown option`, `E492: Not an editor command`, ... arrive as `emsg`; without
  -- this they were INFO and showed up under "messages" instead of "errors".
  emsg = vim.log.levels.ERROR,
  rpc_error = vim.log.levels.ERROR,
  wmsg = vim.log.levels.WARN,
  shell_err = vim.log.levels.WARN,
  shell_ret = vim.log.levels.WARN, -- 'shell returned N', only fires on a non-zero exit
}

-- history=true events are always kept; history=false ones only when listed in
-- `config.kinds` (default: the shell kinds, see DEFAULTS).
local ns = nil ---@type integer|nil
local attached = false

---@internal
---@return boolean
local function has_renderer()
  if config.renderer_override ~= nil then
    return config.renderer_override
  end
  if package.loaded["noice"] == nil then
    return false
  end
  -- `package.loaded["noice"]` stays non-nil for the rest of the session once
  -- noice has been required, even after `:Noice disable` -- that only flips
  -- noice's own `Config._running` flag. Checking module-loaded state alone
  -- would mean this module never detaches again once noice has loaded once.
  local ok, noice_config = pcall(require, "noice.config")
  return ok and noice_config.is_running() == true
end

---@internal
---Append `entry` into the ring (a true circular buffer: `head`/`count`
---index into a fixed-size `entries`, so both append and eviction are O(1)
---instead of shifting the whole array on every push once the ring is
---full). Notifies listeners after the entry is actually stored. A listener
---unsubscribing itself or another mid-dispatch (e.g. a "fire once" pattern via
---`off_message`) must not perturb the in-progress walk: the others are still
---called, only the one that was removed is skipped.
---@param entry Lib.Messages.Entry
local function store(entry)
  local ring_size = config.ring_size
  if entry.replace_last and count > 0 then
    entries[(head + count - 2) % ring_size + 1] = entry
  else
    if count < ring_size then
      count = count + 1
      entries[(head + count - 2) % ring_size + 1] = entry
    else
      entries[head] = entry
      head = head % ring_size + 1
    end
  end
  listeners:each(function(fn)
    local ok, err = pcall(fn, entry)
    if not ok then
      vim.schedule(function()
        vim.notify(("[lib.nvim.messages] a listener errored: %s"):format(err), vim.log.levels.WARN)
      end)
    end
  end)
end

---@internal
---Whether `history`/`kind` should be kept by the ui_attach feed.
---@param kind string
---@param history boolean
---@return boolean
local function should_keep(kind, history)
  if history then
    return true
  end
  return config.kinds[kind] == true
end

-- Was the previous msg_show event stored? `replace_last` refers to the previous event, so
-- it may only overwrite our newest slot when that event is the one sitting there: `:w` sends
-- a dropped `bufwrite` (history=false) and then a replace_last one, which would otherwise
-- erase an unrelated older entry (the output of a `:!cmd`, say).
local last_stored = false

-- The open shell stream: the entry the previous chunk of the same `:!cmd` went into.
-- Neovim delivers shell output in arbitrary pipe-read chunks, all `append=true` (even the
-- first of a command), so `append` cannot mark a run boundary; any other msg_show event
-- closes the stream (a new `:!cmd` opens with a `shell_cmd` event, which is not kept).
---@type { kind: string, entry: Lib.Messages.Entry }|nil
local stream = nil

-- A stream entry stops growing here: bounds the quadratic `..` cost and the entry size.
local MERGE_MAX_BYTES = 65536

---@internal
---The newest entry in the ring, nil when it is empty.
---@return Lib.Messages.Entry|nil
local function newest_entry()
  if count == 0 then
    return nil
  end
  return entries[(head + count - 2) % config.ring_size + 1]
end

---@internal
---Forget the stream/replace bookkeeping (ring reset, detach).
local function reset_feed_state()
  last_stored = false
  stream = nil
end

---@internal
local function on_ui_event(event, kind, content, replace_last, history, append)
  if event ~= "msg_show" then
    return
  end
  local open = stream
  stream = nil
  local previous_stored = last_stored
  local keep = should_keep(kind, history == true)
  last_stored = keep
  if not keep then
    return
  end
  local text = {}
  for _, chunk in ipairs(content or {}) do
    text[#text + 1] = chunk[2]
  end
  local joined = table.concat(text)

  local is_shell = (kind == "shell_out" or kind == "shell_err") and append == true
  if
    is_shell
    and open
    and open.kind == kind
    and newest_entry() == open.entry
    and #open.entry.content + #joined <= MERGE_MAX_BYTES
  then
    -- In place, no store(): listeners already hold this table, and re-notifying would make
    -- a popup add one cumulative copy per chunk. The time moves on so a long-running
    -- command stays inside a since_ms window.
    open.entry.content = open.entry.content .. joined
    open.entry.time_ms = vim.uv.hrtime() / 1e6
    stream = open
    return
  end

  local entry = {
    time_ms = vim.uv.hrtime() / 1e6,
    level = KIND_LEVEL[kind] or vim.log.levels.INFO,
    kind = kind,
    content = joined,
    source = nil,
    replace_last = replace_last == true and previous_stored,
  }
  store(entry)
  if is_shell then
    stream = { kind = kind, entry = entry }
  end
end

---@internal
---Attach the `ext_messages` logger if a renderer exists and it isn't
---already attached. Deferred past the current fast-event tick, pcall-
---guarded against a genuine error.
---
---A prior version of this function also refused to attach while ANY
---floating window was open, retrying on `WinClosed`, based on a historical
---finding in `notify/popup.lua`'s own doc comment ("`vim.ui_attach` ...
---found to hang indefinitely ... once any floating window was already
---open"). Live-tested against this exact config on 2026-10-01 (real TUI,
---`-FullConfig`, `WKDBooks/.../TOOLS/scripts/tui-spike/s7.lua`): that guard
---made the logger never attach at all, because ui.nvim's own statusline
---chips (`ui.kit.chip`) are themselves persistent floating windows that
---are open for the entire session -- `any_float_open()` was permanently
---true, `maybe_attach` deferred forever, and the `ext_messages` feed never
---worked. Two direct probes in that same session -- `vim.ui_attach` called
---with those chip floats open, and again while this module's own, entered/
---focused recent-messages popup was open -- both attached and detached in
---under 2ms, no hang. The guard was a net loss (total feature breakage
---traded for a hang this Neovim version/config does not reproduce) and was
---removed. If a real hang resurfaces, reproduce it with that same harness
---before re-adding a guard -- and scope it to whatever the real trigger
---turns out to be, not "any floating window anywhere."
local function maybe_attach()
  if attached or not has_renderer() then
    return
  end
  vim.schedule(function()
    if attached or not has_renderer() then
      return
    end
    ns = ns or vim.api.nvim_create_namespace("lib_nvim_messages")
    local ok = pcall(vim.ui_attach, ns, { ext_messages = true }, on_ui_event)
    attached = ok
  end)
end

---@internal
---Detach the moment no renderer is left -- the logger must never become the
---sole `ext_messages` listener (it would take over message AND cmdline
---rendering from the TUI with nothing to draw either).
local function maybe_detach()
  if not attached then
    return
  end
  pcall(vim.ui_detach, ns)
  attached = false
  reset_feed_state()
end

---Change module-wide defaults. Safe to call more than once (e.g. a config
---reload) -- resets to `DEFAULTS` merged with `opts`, not an accumulation.
---A `ring_size` change resets the ring itself: the circular buffer's
---indices are only valid for the size they were written under.
---@param opts? Lib.Messages.Config
---@return nil
function M.setup(opts)
  local new_config = vim.tbl_deep_extend("force", vim.deepcopy(DEFAULTS), opts or {})
  -- Floored, not just clamped: ring_size indexes the circular buffer via `%`
  -- (store()/snapshot()), which silently corrupts on a fractional divisor --
  -- the old array-with-table.remove(1) design tolerated a float harmlessly,
  -- this one does not.
  new_config.ring_size = math.max(1, math.floor(new_config.ring_size))
  if new_config.ring_size ~= config.ring_size then
    entries = {}
    head = 1
    count = 0
    reset_feed_state()
  end
  config = new_config
  M.notify_renderer_changed()
end

---Re-evaluate the attach policy -- call after toggling whatever renderer
---`has_renderer()` depends on (e.g. `:Noice enable`/`disable`, which fires
---no event of its own to detect this any other way).
---@return nil
function M.notify_renderer_changed()
  if has_renderer() then
    maybe_attach()
  else
    maybe_detach()
  end
end

---Opt-in convenience: patches `require("noice").enable`/`disable` to call
---`notify_renderer_changed()` automatically. pcall-guarded, a no-op when
---noice isn't installed. Call once, e.g. from setup.
---@return nil
function M.wrap_noice()
  local ok, noice = pcall(require, "noice")
  if not ok or type(noice) ~= "table" then
    return
  end
  for _, name in ipairs({ "enable", "disable" }) do
    local orig = noice[name]
    if type(orig) == "function" then
      noice[name] = function(...)
        local results = { orig(...) }
        M.notify_renderer_changed()
        return unpack(results)
      end
    end
  end
end

---Low-level append, bypassing the `ext_messages` feed entirely. Used by
---`lib.nvim.notify`'s delivery pipeline so notify/toast traffic is never
---lost to the attach policy above (see the module doc).
---@param entry Lib.Messages.PushEntry
---@return nil
M.push = fast_event.guard(function(entry)
  store({
    time_ms = entry.time_ms or (vim.uv.hrtime() / 1e6),
    level = entry.level or vim.log.levels.INFO,
    kind = entry.kind or "notify",
    content = entry.content or "",
    source = entry.source,
    replace_last = entry.replace_last == true,
  })
end)

---Entries in `[since_ms, until_ms]` (both ends optional), oldest first,
---optionally narrowed to `kinds`/`levels` allow-lists. A plain copy -- the
---caller can't mutate the internal ring through it.
---@param opts? Lib.Messages.SnapshotOpts
---@return Lib.Messages.Entry[]
function M.snapshot(opts)
  opts = opts or {}
  local kinds_filter = opts.kinds and {} or nil
  if kinds_filter then
    for _, k in ipairs(opts.kinds) do
      kinds_filter[k] = true
    end
  end
  local levels_filter = opts.levels and {} or nil
  if levels_filter then
    for _, l in ipairs(opts.levels) do
      levels_filter[l] = true
    end
  end

  local out = {}
  for i = 0, count - 1 do
    local entry = entries[(head + i - 1) % config.ring_size + 1]
    local in_range = (not opts.since_ms or entry.time_ms >= opts.since_ms)
      and (not opts.until_ms or entry.time_ms <= opts.until_ms)
    local kind_ok = not kinds_filter or kinds_filter[entry.kind]
    local level_ok = not levels_filter or levels_filter[entry.level]
    if in_range and kind_ok and level_ok then
      out[#out + 1] = vim.deepcopy(entry)
    end
  end
  return out
end

---Subscribe to every entry stored from now on (both feeds). Returns `fn`
---itself, usable as the `off_message` handle.
---@param fn fun(entry: Lib.Messages.Entry)
---@return fun(entry: Lib.Messages.Entry)
function M.on_message(fn)
  listeners:add(fn)
  return fn
end

---What `M.status()` reports about the `ext_messages` logger. Read-only: nothing is attached, and noice is
---looked at only through `package.loaded`, never `require`d.
---
---`renderer` names what keeps the logger attached:
---  * `"renderer_override"` -- `setup({ renderer_override = true })` forces it on;
---  * `"noice"` -- noice is loaded and reports running;
---  * `nil` -- no renderer: the feed is not attached, and the popup holds only what `lib.nvim.notify` pushed
---    (`renderer_override = false` is this too, by choice).
---`noice_loaded` tells "noice is not installed or loaded" from "noice is loaded but disabled".
---@return Lib.Messages.Status
function M.status()
  local override = config.renderer_override
  local noice_loaded = package.loaded["noice"] ~= nil
  local renderer ---@type "renderer_override"|"noice"|nil
  if override ~= nil then
    renderer = override and "renderer_override" or nil
  elseif noice_loaded then
    local noice_config = package.loaded["noice.config"]
    local running = false
    if type(noice_config) == "table" and type(noice_config.is_running) == "function" then
      local ok, value = pcall(noice_config.is_running)
      running = ok and value == true
    end
    renderer = running and "noice" or nil
  end
  return {
    attached = attached,
    renderer = renderer,
    renderer_override = override,
    noice_loaded = noice_loaded,
    ring_size = config.ring_size,
    count = count,
  }
end

---Unsubscribe a handle returned by `on_message`.
---@param fn fun(entry: Lib.Messages.Entry)
---@return nil
function M.off_message(fn)
  listeners:remove(fn)
end

---@type Lib.Messages
return M
