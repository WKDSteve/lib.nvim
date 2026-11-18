---@module 'lib.lua.time.format'
--- Format a unix timestamp using a small set of named style presets, pure
--- Lua (`os.date`), no `vim.*`.
---
--- Styles built from `os.date` patterns (`iso`, `human`, `short`, `log`,
--- `filename`, `iso-date`, `iso-time`, `time`) and styles built by hand
--- (`unix`, `12h`, `weekday`, `long`, `rfc2822`): `%p` (AM/PM) vanishes on
--- Windows' C runtime and `%A`/`%B` follow the C locale (a German locale
--- writes `Di` for Tuesday), so those use fixed English names instead.

local M = {}

---@type table<string, string>
local PATTERNS = {
  iso = "%Y-%m-%dT%H:%M:%S",
  human = "%b %d, %Y %H:%M",
  short = "%Y-%m-%d",
  log = "[%Y-%m-%d %H:%M:%S]",
  filename = "%Y%m%d_%H%M%S",
  ["iso-date"] = "%Y-%m-%d",
  ["iso-time"] = "%H:%M:%S",
  time = "%H:%M:%S",
}

---English weekday names, `os.date("*t").wday` order (1 = Sunday).
M.WEEKDAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }

---English month names, January first.
M.MONTHS = {
  "January",
  "February",
  "March",
  "April",
  "May",
  "June",
  "July",
  "August",
  "September",
  "October",
  "November",
  "December",
}

---@param ts integer
---@param utc? boolean
---@return osdate
local function date_table(ts, utc)
  -- Only a "*t"/"!*t" pattern makes `os.date` return a table.
  return os.date(utc and "!*t" or "*t", ts) --[[@as osdate]]
end

---@type table<string, fun(t: osdate): string>
local BUILT = {
  ["12h"] = function(t)
    local hour = t.hour % 12
    if hour == 0 then
      hour = 12
    end
    return ("%02d:%02d:%02d %s"):format(hour, t.min, t.sec, t.hour < 12 and "AM" or "PM")
  end,
  weekday = function(t)
    return M.WEEKDAYS[t.wday]
  end,
  long = function(t)
    return ("%s, %s %d, %d"):format(M.WEEKDAYS[t.wday], M.MONTHS[t.month], t.day, t.year)
  end,
  rfc2822 = function(t)
    return ("%s, %02d %s %d %02d:%02d:%02d"):format(
      M.WEEKDAYS[t.wday]:sub(1, 3),
      t.day,
      M.MONTHS[t.month]:sub(1, 3),
      t.year,
      t.hour,
      t.min,
      t.sec
    )
  end,
}

---Every style name `format_timestamp` knows, sorted.
---@type string[]
M.STYLES = { "unix" }
for name in pairs(PATTERNS) do
  M.STYLES[#M.STYLES + 1] = name
end
for name in pairs(BUILT) do
  M.STYLES[#M.STYLES + 1] = name
end
table.sort(M.STYLES)

---Format a unix timestamp. `opts.patterns` adds or overrides `os.date`
---patterns by style name (a plugin that spells `short` as `%d.%m.%Y`); a
---hand-built style (`12h`, `weekday`, `long`, `rfc2822`, `unix`) always wins.
---@nodiscard
---@param ts? integer Defaults to `os.time()`
---@param fmt? LibTimeFormatStyle|string Defaults to `"iso"` for unrecognized/nil values
---@param opts? LibTimeFormatOpts
---@return string
function M.format_timestamp(ts, fmt, opts)
  ts = ts or os.time()
  opts = opts or {}

  if fmt == "unix" then
    return tostring(ts)
  end

  local built = fmt and BUILT[fmt]
  if built then
    return built(date_table(ts, opts.utc))
  end

  local pattern = (opts.patterns and fmt and opts.patterns[fmt]) or PATTERNS[fmt] or PATTERNS.iso
  if opts.utc then
    pattern = "!" .. pattern
  end

  -- Only a "*t" pattern makes `os.date` return a table; these never do.
  return os.date(pattern, ts) --[[@as string]]
end

---@type LibTimeFormat
return M
