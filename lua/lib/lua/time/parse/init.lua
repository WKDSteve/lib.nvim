---@module 'lib.lua.time.parse'
--- Timestamp parser for the notations logs write (ISO with `Z` or an offset,
--- decimal comma, BrowserStack's `:ms`, 12-hour clock, time of day alone,
--- `[...]`-bracketed), mapped onto UTC milliseconds since 1970, so entries
--- of several services can be merged by time and gaps measured. Came from
--- casedesk.nvim's log reading copy (`logview/core/time.lua`, formats F1-F11).
---
--- Pure Lua on purpose: no `vim.*`, no `os.time`/`os.date`. Both of the
--- latter read the host's local time zone, and a log written in Vienna must
--- give the same millisecond on a CI runner in UTC. Calendar arithmetic is
--- the days-from-civil algorithm (H. Hinnant), valid for the proleptic
--- Gregorian calendar.

local M = {}

local MS_SECOND = 1000
local MS_MINUTE = 60 * MS_SECOND
local MS_HOUR = 60 * MS_MINUTE
local MS_DAY = 24 * MS_HOUR

--- Longest accepted timestamp text. The longest real notation
--- (`[2026-08-29 01:11:00.510+02:00]`, or ISO with 7 fraction digits and an
--- offset) is about 35 characters; the cap keeps a whole log line passed in
--- by mistake from being trimmed and scanned (SEC-32).
M.MAX_RAW = 64

--- Longest file name (basename) `date_from_filename` scans: Windows' MAX_PATH.
--- Guards the candidate loop against an unbounded string (SEC-32).
M.MAX_FILENAME = 260

---@class Lib.Time.ParseCtx
---@field filename? string     log file name; supplies the date to a time-only notation
---@field offset_min? integer  UTC offset in minutes for text without a zone (default 0)

---@alias Lib.Time.Notation
---| "browserstack"  # `2026-9-23 13:30:26:20` - date, milliseconds after a colon (F1, F2)
---| "comma"         # `2026-10-23 09:59:43,122` - decimal comma, no zone (F4)
---| "offset"        # `+00:00`, `+05:30`, `+0200` after the time (F5, F6, F11)
---| "zulu"          # `Z` after the time (F8, F9)
---| "plain"         # date and time, decimal point or no fraction, no zone (F3)
---| "clock12"       # `1:22:40 PM` (F7)
---| "time"          # time of day without date (F10)

---@class Lib.Time.ParseInfo
---@field has_date boolean        a calendar date was known (from the text or the file name)
---@field date_source? "text"|"filename"
---@field offset_min? integer     offset that was applied; nil when there was no date to apply it to
---@field offset_assumed boolean  the text carried no zone, `ctx.offset_min` (or 0) was used
---@field notation Lib.Time.Notation
---@field frac_sep? "."|","|":"   separator of the sub-second part, nil without one
---@field zone? "Z"|"offset"      zone written in the text
---@field bracketed boolean       the text was enclosed in `[...]` (F11)

--- Days in each month of a common year.
local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

---@param y integer
---@return boolean
local function is_leap(y)
  return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0
end

---@param y integer
---@param mo integer
---@return integer
local function days_in_month(y, mo)
  if mo == 2 and is_leap(y) then
    return 29
  end
  return MONTH_DAYS[mo]
end

---@param y integer
---@param mo integer
---@param d integer
---@return boolean
local function valid_date(y, mo, d)
  return mo >= 1 and mo <= 12 and d >= 1 and d <= days_in_month(y, mo)
end

--- Days since 1970-01-01 of a civil date (days-from-civil).
---@param y integer
---@param mo integer
---@param d integer
---@return integer
local function days_from_civil(y, mo, d)
  if mo <= 2 then
    y = y - 1
  end
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = mo > 2 and mo - 3 or mo + 9
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

--- Civil date of a day count since 1970-01-01 (civil-from-days).
---@param z integer
---@return integer y, integer mo, integer d
local function civil_from_days(z)
  z = z + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor(
    (doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365
  )
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local mo = mp < 10 and mp + 3 or mp - 9
  if mo <= 2 then
    y = y + 1
  end
  return y, mo, d
end

M.days_from_civil = days_from_civil
M.civil_from_days = civil_from_days

--- Is `y-mo-d` a day of the calendar (month 1-12, day within the month)?
---@param y integer
---@param mo integer
---@param d integer
---@return boolean
function M.valid_date(y, mo, d)
  return valid_date(y, mo, d)
end

--- UTC calendar day (`YYYY-MM-DD`) of a unix timestamp in seconds, without
--- `os.date` (which raises on dates it cannot print).
---@param epoch integer seconds since 1970
---@return string
function M.utc_date(epoch)
  local y, mo, d = civil_from_days(math.floor(epoch / 86400))
  return ("%04d-%02d-%02d"):format(y, mo, d)
end

--- UTC milliseconds since 1970 of a civil date and time read as UTC. No
--- range checks: `parse` validates before it calls this.
---@param y integer
---@param mo integer
---@param d integer
---@param h? integer
---@param mi? integer
---@param s? integer
---@param ms? integer
---@return integer
function M.civil_ms(y, mo, d, h, mi, s, ms)
  return days_from_civil(y, mo, d) * MS_DAY
    + (h or 0) * MS_HOUR
    + (mi or 0) * MS_MINUTE
    + (s or 0) * MS_SECOND
    + (ms or 0)
end

--- Date patterns in a file name, tried at every position; the earliest
--- valid match wins. The frontiers keep a match from starting or ending in
--- the middle of a longer digit run (`Log_20261028_132240`).
local FILENAME_PATTERNS = {
  "%f[%d](%d%d%d%d)(%d%d)(%d%d)%f[%D]",
  "%f[%d](%d%d%d%d)_(%d%d)_(%d%d)%f[%D]",
  "%f[%d](%d%d%d%d)%-(%d%d)%-(%d%d)%f[%D]",
}

--- Calendar date written in a log file name (`GatewayService_Log_20260920.txt`,
--- `ToscaCommander-2026_10_23-...log`, `x-2026-10-23.log`). Only the basename
--- counts, so a dated folder does not lend its date to the file.
---@param name string
---@return integer? y
---@return integer? mo
---@return integer? d
function M.date_from_filename(name)
  if type(name) ~= "string" then
    return nil
  end
  local base = name:match("[^/\\]*$") or name
  if #base > M.MAX_FILENAME then
    return nil
  end
  local best_pos, by, bmo, bd
  for _, pat in ipairs(FILENAME_PATTERNS) do
    local init = 1
    while true do
      local a, b, sy, smo, sd = base:find(pat, init)
      if not a or (best_pos and a >= best_pos) then
        break
      end
      local y, mo, d = tonumber(sy), tonumber(smo), tonumber(sd)
      ---@cast y integer
      ---@cast mo integer
      ---@cast d integer
      if y >= 1970 and y <= 2199 and valid_date(y, mo, d) then
        best_pos, by, bmo, bd = a, y, mo, d
        break
      end
      init = b + 1
    end
  end
  if not best_pos then
    return nil
  end
  return by, bmo, bd
end

---@param ctx_offset any
---@return integer? offset, string? err
local function ctx_offset_min(ctx_offset)
  if ctx_offset == nil then
    return 0
  end
  if
    type(ctx_offset) ~= "number"
    or ctx_offset ~= math.floor(ctx_offset)
    or math.abs(ctx_offset) >= 24 * 60
  then
    return nil, "ctx.offset_min must be an integer between -1439 and 1439"
  end
  return ctx_offset
end

--- Parse one timestamp text into UTC milliseconds since 1970.
---
--- Without a zone in the text, `ctx.offset_min` (default 0) is assumed and
--- `info.offset_assumed` says so. A time of day without a date takes the
--- date from `ctx.filename`; when that has none either, the result is the
--- milliseconds since midnight of the written clock, no offset applied, and
--- `info.has_date` is false.
---@param raw string
---@param ctx? Lib.Time.ParseCtx
---@return integer? ms
---@return Lib.Time.ParseInfo|string info_or_err
function M.parse(raw, ctx)
  if type(raw) ~= "string" then
    return nil, "timestamp must be a string"
  end
  if #raw > M.MAX_RAW then
    return nil, ("timestamp longer than %d characters"):format(M.MAX_RAW)
  end
  ctx = type(ctx) == "table" and ctx or {}
  local assumed_offset, oerr = ctx_offset_min(ctx.offset_min)
  if not assumed_offset then
    return nil, oerr --[[@as string]]
  end

  local s = raw:match("^%s*(.-)%s*$") or raw
  local bracketed = false
  if s:sub(1, 1) == "[" then
    if s:sub(-1) ~= "]" then
      return nil, "unclosed '['"
    end
    bracketed = true
    s = s:sub(2, -2)
  end

  local pos = 1
  local y, mo, d
  local a, b, sy, smo, sd = s:find("^(%d%d%d%d)%-(%d%d?)%-(%d%d?)", pos)
  if a then
    y, mo, d = tonumber(sy), tonumber(smo), tonumber(sd)
    ---@cast y integer
    ---@cast mo integer
    ---@cast d integer
    if not valid_date(y, mo, d) then
      return nil, ("invalid date %s-%s-%s"):format(sy, smo, sd)
    end
    pos = b + 1
    local sep = s:sub(pos, pos)
    if sep ~= "T" and sep ~= " " then
      return nil, "expected 'T' or a space after the date"
    end
    pos = pos + 1
  end

  local sh, smi, ss
  a, b, sh, smi, ss = s:find("^(%d%d?):(%d%d):(%d%d)", pos)
  if not a then
    return nil, "no time of day (H:MM:SS)"
  end
  local h, mi, sec = tonumber(sh), tonumber(smi), tonumber(ss)
  ---@cast h integer
  ---@cast mi integer
  ---@cast sec integer
  pos = b + 1

  local frac_sep, ms = nil, 0
  local fsep, digits
  a, b, fsep, digits = s:find("^([.,:])(%d+)", pos)
  if a then
    if #digits > 9 then
      return nil, "fraction of a second longer than 9 digits"
    end
    if fsep == ":" then
      -- BrowserStack writes plain milliseconds, unpadded: `:20` is 20 ms.
      if #digits > 3 then
        return nil, "milliseconds after ':' longer than 3 digits"
      end
      ms = tonumber(digits) --[[@as integer]]
    else
      -- A decimal fraction: `.5` is 500 ms, `.1234567` truncates to 123 ms.
      ms = tonumber((digits .. "00"):sub(1, 3)) --[[@as integer]]
    end
    frac_sep = fsep
    pos = b + 1
  end

  local zone, zone_offset
  local zsign, zh, zm
  a, b, zsign, zh, zm = s:find("^ ?([+-])(%d%d):?(%d%d)", pos)
  if a then
    local oh, om = tonumber(zh), tonumber(zm)
    ---@cast oh integer
    ---@cast om integer
    if oh > 23 or om > 59 then
      return nil, ("invalid offset %s%s:%s"):format(zsign, zh, zm)
    end
    zone, zone_offset = "offset", (oh * 60 + om) * (zsign == "-" and -1 or 1)
    pos = b + 1
  elseif s:sub(pos, pos) == "Z" then
    zone, zone_offset = "Z", 0
    pos = pos + 1
  end

  local clock12 = false
  local ampm
  a, b, ampm = s:find("^ ?([AaPp][Mm])", pos)
  if a then
    if h < 1 or h > 12 then
      return nil, ("hour %d is not on a 12-hour clock"):format(h)
    end
    local pm = ampm:sub(1, 1):lower() == "p"
    -- 12 AM is midnight, 12 PM is noon.
    h = (h % 12) + (pm and 12 or 0)
    clock12 = true
    pos = b + 1
  end

  if pos <= #s then
    return nil, ("unexpected text after the time: %q"):format(s:sub(pos))
  end
  if h > 23 or mi > 59 or sec > 59 then
    return nil, ("invalid time %s:%s:%s"):format(sh, smi, ss)
  end

  local date_source
  if y then
    date_source = "text"
  elseif ctx.filename then
    y, mo, d = M.date_from_filename(ctx.filename)
    if y then
      date_source = "filename"
    end
  end

  local notation
  if clock12 then
    notation = "clock12"
  elseif date_source ~= "text" then
    notation = "time"
  elseif frac_sep == ":" then
    notation = "browserstack"
  elseif zone == "Z" then
    notation = "zulu"
  elseif zone == "offset" then
    notation = "offset"
  elseif frac_sep == "," then
    notation = "comma"
  else
    notation = "plain"
  end

  ---@type Lib.Time.ParseInfo
  local info = {
    has_date = y ~= nil,
    date_source = date_source,
    offset_assumed = zone == nil,
    notation = notation,
    frac_sep = frac_sep,
    zone = zone,
    bracketed = bracketed,
  }

  if not y then
    return h * MS_HOUR + mi * MS_MINUTE + sec * MS_SECOND + ms, info
  end
  local offset = zone_offset or assumed_offset
  info.offset_min = offset
  ---@cast mo integer
  ---@cast d integer
  return M.civil_ms(y, mo, d, h, mi, sec, ms) - offset * MS_MINUTE, info
end

---@param offset_min integer
---@return string
local function offset_text(offset_min)
  if offset_min == 0 then
    return "Z"
  end
  local sign = offset_min < 0 and "-" or "+"
  local abs = math.abs(offset_min)
  return ("%s%02d:%02d"):format(sign, math.floor(abs / 60), abs % 60)
end

--- Render UTC milliseconds. `mode`: "time" (`07:59:21.693`), "datetime"
--- (`2026-10-29 07:59:21.693`) or "iso" (`2026-10-29T07:59:21.693Z`).
--- `offset_min` shifts the clock to a local time (the original zone of a
--- log); "iso" then ends in that offset instead of `Z`.
---@param ms integer
---@param mode? "time"|"datetime"|"iso"  default "datetime"
---@param offset_min? integer
---@return string
function M.format(ms, mode, offset_min)
  offset_min = offset_min or 0
  local t = ms + offset_min * MS_MINUTE
  local days = math.floor(t / MS_DAY)
  local rest = t - days * MS_DAY
  local h = math.floor(rest / MS_HOUR)
  local mi = math.floor(rest % MS_HOUR / MS_MINUTE)
  local sec = math.floor(rest % MS_MINUTE / MS_SECOND)
  local frac = rest % MS_SECOND
  local clock = ("%02d:%02d:%02d.%03d"):format(h, mi, sec, frac)
  if mode == "time" then
    return clock
  end
  local y, mo, d = civil_from_days(days)
  local date = ("%04d-%02d-%02d"):format(y, mo, d)
  if mode == "iso" then
    return date .. "T" .. clock .. offset_text(offset_min)
  end
  return date .. " " .. clock
end

--- Distance to the previous entry, short and German-formatted: `+318 ms`,
--- `+2,3 s` (tenths, truncated), `+14 min`, `+3 h 5 min`, `+2 d 4 h`.
--- Negative distances (clock went back) get a `-`.
---@param ms integer
---@return string
function M.delta(ms)
  local sign = ms < 0 and "-" or "+"
  local a = math.abs(ms)
  if a < MS_SECOND then
    return ("%s%d ms"):format(sign, a)
  end
  if a < MS_MINUTE then
    local tenths = math.floor(a / 100)
    return ("%s%d,%d s"):format(sign, math.floor(tenths / 10), tenths % 10)
  end
  if a < MS_HOUR then
    return ("%s%d min"):format(sign, math.floor(a / MS_MINUTE))
  end
  if a < MS_DAY then
    local mins = math.floor(a / MS_MINUTE)
    return ("%s%d h %d min"):format(sign, math.floor(mins / 60), mins % 60)
  end
  local hours = math.floor(a / MS_HOUR)
  return ("%s%d d %d h"):format(sign, math.floor(hours / 24), hours % 24)
end

return M
