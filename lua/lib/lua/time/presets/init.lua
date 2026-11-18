---@module 'lib.lua.time.presets'
--- Date-range presets, pure Lua (`os.time`/`os.date`), no `vim.*`.
---
--- Three layers, one calendar:
---
--- - Named presets (`today`, `this_week`, `last_week`, `previous_month`,
---   `days_ago(n)`, ...) return `{ from, to }` unix timestamps. A current,
---   still-open period ends at `now`; a closed one ends at the local midnight
---   after it (exclusive).
--- - `parse(words)` reads the range words people type (`today`, `last week`,
---   `last 4 weeks`, `month`, `letzte woche`, `gestern`, ...) in English and
---   German and returns `{ from, to, label }` with an exclusive `to` at a
---   local midnight (today included).
--- - `since_utc(value)` reads the `--since=` value of a command line
---   (`2026-11-09` or `7d`) as a UTC calendar day.
---
--- Every function takes an optional `now` (unix timestamp, default
--- `os.time()` at call time), so callers and specs get reproducible ranges.
--- Weeks start on Monday. Every boundary is a local midnight found by
--- calendar arithmetic (`os.time` normalises an out-of-range day), never by
--- subtracting multiples of 86400 seconds: on the two days a year the clock is
--- switched that lands an hour off midnight.
---
--- `last_week` is the last 7 full days ending at the start of today (it does
--- not include today); the previous Monday-Sunday week is `previous_week`.

local M = {}

---@internal
---@param ts integer
---@return osdate
local function to_date_table(ts)
  -- "*t" is exactly the pattern that makes `os.date` return a table; the
  -- annotation covers both shapes at once and cannot narrow on the literal.
  return os.date("*t", ts) --[[@as osdate]]
end

---Local midnight of the day `offset` days from the one `ts` falls on.
---@internal
---@param ts integer
---@param offset? integer default 0
---@return integer
local function day_start(ts, offset)
  local t = to_date_table(ts)
  return os.time({ year = t.year, month = t.month, day = t.day + (offset or 0), hour = 0 })
end

---Local midnight of the Monday of `ts`'s week.
---@internal
---@param ts integer
---@return integer
local function week_start(ts)
  local days_since_monday = (to_date_table(ts).wday + 5) % 7 -- wday: 1 = Sunday
  return day_start(ts, -days_since_monday)
end

---Local midnight of the first of the month, `back` months before `ts`'s.
---@internal
---@param ts integer
---@param back? integer default 0
---@return integer
local function month_start(ts, back)
  local t = to_date_table(ts)
  return os.time({ year = t.year, month = t.month - (back or 0), day = 1, hour = 0 })
end

---Local midnight of the first day of `ts`'s quarter.
---@internal
---@param ts integer
---@return integer
local function quarter_start(ts)
  local t = to_date_table(ts)
  local first_month = (math.floor((t.month - 1) / 3) * 3) + 1
  return os.time({ year = t.year, month = first_month, day = 1, hour = 0 })
end

---Local midnight of the first of January, `back` years before `ts`'s.
---@internal
---@param ts integer
---@param back? integer default 0
---@return integer
local function year_start(ts, back)
  return os.time({ year = to_date_table(ts).year - (back or 0), month = 1, day = 1, hour = 0 })
end

-- ---------------------------------------------------------------- named presets

---@nodiscard
---@param now? integer Defaults to `os.time()`
---@return LibTimeRange
function M.today(now)
  now = now or os.time()
  return { from = day_start(now), to = now }
end

---@nodiscard
---@param now? integer Defaults to `os.time()`
---@return LibTimeRange
function M.yesterday(now)
  now = now or os.time()
  return { from = day_start(now, -1), to = day_start(now) }
end

---Last 7 full days, ending at the start of today (does not include today).
---@nodiscard
---@param now? integer Defaults to `os.time()`
---@return LibTimeRange
function M.last_week(now)
  now = now or os.time()
  return { from = day_start(now, -7), to = day_start(now) }
end

---Monday 00:00 of this week until now.
---@nodiscard
---@param now? integer Defaults to `os.time()`
---@return LibTimeRange
function M.this_week(now)
  now = now or os.time()
  return { from = week_start(now), to = now }
end

---@nodiscard
---@param now? integer Defaults to `os.time()`
---@return LibTimeRange
function M.this_month(now)
  now = now or os.time()
  return { from = month_start(now), to = now }
end

---@nodiscard
---@param now? integer Defaults to `os.time()`
---@return LibTimeRange
function M.this_quarter(now)
  now = now or os.time()
  return { from = quarter_start(now), to = now }
end

---@nodiscard
---@param now? integer Defaults to `os.time()`
---@return LibTimeRange
function M.this_year(now)
  now = now or os.time()
  return { from = year_start(now), to = now }
end

---The previous Monday-Sunday week, `to` exclusive (this week's Monday).
---@nodiscard
---@param now? integer Defaults to `os.time()`
---@return LibTimeRange
function M.previous_week(now)
  local this = week_start(now or os.time())
  return { from = day_start(this, -7), to = this }
end

---The previous calendar month, `to` exclusive (the first of this month).
---@nodiscard
---@param now? integer Defaults to `os.time()`
---@return LibTimeRange
function M.previous_month(now)
  now = now or os.time()
  return { from = month_start(now, 1), to = month_start(now) }
end

---The previous calendar year, `to` exclusive (the first of January).
---@nodiscard
---@param now? integer Defaults to `os.time()`
---@return LibTimeRange
function M.previous_year(now)
  now = now or os.time()
  return { from = year_start(now, 1), to = year_start(now) }
end

---Largest `n` of `days_ago`: one hundred years, small enough that every
---boundary stays a date `os.date` can print.
M.MAX_DAYS_AGO = 36600

---From the local midnight `n` days ago until now (`days_ago(7)` on a Tuesday
---starts on last Tuesday).
---@nodiscard
---@param n integer 0..MAX_DAYS_AGO
---@param now? integer Defaults to `os.time()`
---@return LibTimeRange|nil range
---@return string|nil err
function M.days_ago(n, now)
  if type(n) ~= "number" or n ~= math.floor(n) or n < 0 or n > M.MAX_DAYS_AGO then
    return nil, ("days must be an integer between 0 and %d"):format(M.MAX_DAYS_AGO)
  end
  now = now or os.time()
  return { from = day_start(now, -n), to = now }
end

---Trivial passthrough/validation helper for symmetry with the presets.
---@nodiscard
---@param from integer
---@param to integer
---@return LibTimeRange|nil range
---@return string|nil err
function M.custom(from, to)
  if type(from) ~= "number" or type(to) ~= "number" then
    return nil, "from/to must be numbers"
  end
  if from > to then
    return nil, "from must be <= to"
  end
  return { from = from, to = to }
end

---The first and the last local calendar day a range covers, `YYYY-MM-DD`.
---A `to` at a local midnight is exclusive (that day is not covered); any
---other `to` covers its own day. `open = true` says the range ends at `now`
---(today, this_week, days_ago, ...): its `to` then always covers its own day,
---also at 00:00:00 sharp, where it would otherwise read as an exclusive
---midnight. Which ranges are open the caller knows; `to == now` cannot tell
---(`yesterday` built at midnight ends at `now` too, exclusively).
---@nodiscard
---@param range LibTimeRange
---@param open? boolean the range ends at `now` (default false)
---@return string first
---@return string last
function M.dates(range, open)
  local first = os.date("%Y-%m-%d", range.from) --[[@as string]]
  local to = range.to
  if not open and to > range.from and to == day_start(to) then
    to = to - 1
  end
  return first, os.date("%Y-%m-%d", math.max(to, range.from)) --[[@as string]]
end

-- ------------------------------------------------------------------- range words

---Largest `N` of `last N <unit>`: far more than any history, and small enough
---that every boundary stays a date `os.date` can print (a huge or infinite
---count would raise there).
---@type table<string, integer>
local MAX_COUNT = { day = 3650, week = 520, month = 120 }

---Words that mean the same (German, plural), mapped to the one spelling the
---grammar reasons in.
---@type table<string, string>
M.ALIASES = {
  heute = "today",
  gestern = "yesterday",
  woche = "week",
  weeks = "week",
  wochen = "week",
  monat = "month",
  months = "month",
  monate = "month",
  monaten = "month",
  jahr = "year",
  years = "year",
  jahre = "year",
  days = "day",
  tag = "day",
  tage = "day",
  tagen = "day",
  letzte = "last",
  letzten = "last",
  letztes = "last",
  letzter = "last",
  diese = "this",
  dieses = "this",
  diesen = "this",
}

---The range words, for completion and for the error message.
---@type string[]
M.KEYWORDS = {
  "today",
  "yesterday",
  "week",
  "last week",
  "last 4 weeks",
  "month",
  "last month",
  "last 3 months",
  "last 10 days",
  "year",
  "last year",
}

---@param ts integer
---@return string
local function fmt(ts)
  return os.date("%Y-%m-%d", ts) --[[@as string]]
end

---`to` is exclusive; the label shows the last day the range includes.
---@param from integer
---@param to integer
---@param what string
---@return LibTimeWordRange
local function labelled(from, to, what)
  return { from = from, to = to, label = ("%s (%s .. %s)"):format(what, fmt(from), fmt(to - 1)) }
end

---Lower-cased words of `tokens`, aliases folded into one spelling.
---@param tokens string|string[]|nil
---@return string[]
local function words_of(tokens)
  if type(tokens) == "string" then
    tokens = { tokens }
  end
  local words = {}
  for _, tok in ipairs(tokens or {}) do
    for w in tostring(tok):lower():gmatch("[^%s,]+") do
      words[#words + 1] = M.ALIASES[w] or w
    end
  end
  return words
end

---Read range words. Nothing given is this week. `to` is exclusive and always
---a local midnight: a range that reaches today ends at tomorrow 00:00.
---
---`today`, `yesterday`; `week`/`this week`, `month`, `year` (this one, until
---the end of today); `last`/`last week`, `last month`, `last year`, `last day`
---(the previous calendar unit); `last N days|weeks|months` (a rolling window,
---today included). German: `heute`, `gestern`, `woche`, `monat`, `jahr`,
---`letzte`, `diese`, plurals.
---@nodiscard
---@param tokens string|string[]|nil words, or one string of words
---@param now? integer Defaults to `os.time()`
---@return LibTimeWordRange|nil range
---@return string|nil err
function M.parse(tokens, now)
  now = now or os.time()
  local words = words_of(tokens)

  if #words == 0 then
    words = { "week" }
  end

  local today = day_start(now, 0)
  local tomorrow = day_start(now, 1)

  local function unknown()
    return nil,
      ("unknown date range '%s' (try: %s)"):format(
        table.concat(words, " "),
        table.concat(M.KEYWORDS, ", ")
      )
  end

  local first = words[1]

  if #words == 1 then
    if first == "today" then
      return labelled(today, tomorrow, "today")
    end
    if first == "yesterday" then
      return labelled(day_start(now, -1), today, "yesterday")
    end
    if first == "week" or first == "this" then
      return labelled(week_start(now), tomorrow, "this week")
    end
    -- Bare `last`: the previous calendar week, as the German "letzte Woche".
    if first == "last" then
      local r = M.previous_week(now)
      return labelled(r.from, r.to, "last week")
    end
    if first == "month" then
      return labelled(month_start(now), tomorrow, "this month")
    end
    if first == "year" then
      return labelled(year_start(now), tomorrow, "this year")
    end
    return unknown()
  end

  if first == "this" and #words == 2 then
    return M.parse({ words[2] }, now)
  end

  if first ~= "last" then
    return unknown()
  end

  if #words == 2 then
    local unit = words[2]
    if unit == "week" then
      return M.parse({ "last" }, now)
    end
    if unit == "month" then
      return labelled(month_start(now, 1), month_start(now), "last month")
    end
    if unit == "year" then
      return labelled(year_start(now, 1), year_start(now), "last year")
    end
    if unit == "day" then
      return labelled(day_start(now, -1), today, "yesterday")
    end
    return unknown()
  end

  local n = tonumber(words[2])
  local unit = words[3]
  local max = MAX_COUNT[unit]
  if #words == 3 and max and n and n >= 1 and n <= max and n == math.floor(n) then
    local what = ("last %d %s%s"):format(n, unit, n == 1 and "" or "s")
    if unit == "day" then
      return labelled(day_start(now, -(n - 1)), tomorrow, what)
    end
    if unit == "week" then
      return labelled(day_start(now, -(n * 7 - 1)), tomorrow, what)
    end
    return labelled(month_start(now, n - 1), tomorrow, what)
  end
  return unknown()
end

---Completion candidates for the next range word, given the words already typed.
---@nodiscard
---@param typed string|string[]|nil
---@return string[]
function M.candidates(typed)
  local words = words_of(typed)
  if #words == 0 then
    return { "today", "yesterday", "week", "last", "this", "month", "year" }
  end
  if #words == 1 and words[1] == "last" then
    return { "week", "month", "year", "day", "2", "3", "4", "6", "8", "12" }
  end
  if #words == 1 and words[1] == "this" then
    return { "week", "month", "year" }
  end
  if #words == 2 and words[1] == "last" and tonumber(words[2]) then
    return { "days", "weeks", "months" }
  end
  return {}
end

-- ------------------------------------------------------------------ --since=

---Read a `--since=` value as a UTC calendar day: `YYYY-MM-DD` (a real date)
---or `<n>d` (the UTC day `n` times 24 hours before `now`).
---@nodiscard
---@param value string
---@param now? integer Defaults to `os.time()`
---@return string|nil day `YYYY-MM-DD`
---@return string|nil err
function M.since_utc(value, now)
  local parse = require("lib.lua.time.parse")
  if type(value) ~= "string" then
    return nil, "expected a day (2026-11-09) or a number of days (7d)"
  end
  local n = value:match("^(%d+)d$")
  if n and #n <= 6 then
    return parse.utc_date((now or os.time()) - tonumber(n) * 86400)
  end
  local y, mo, d = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if
    y
    and parse.valid_date(
      tonumber(y) --[[@as integer]],
      tonumber(mo) --[[@as integer]],
      tonumber(d) --[[@as integer]]
    )
  then
    return value
  end
  return nil, "expected a day (2026-11-09) or a number of days (7d)"
end

---@type LibTimePresets
return M
