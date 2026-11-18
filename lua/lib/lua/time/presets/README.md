# `lib.lua.time.presets`

Date-range presets, pure Lua (`os.time`/`os.date`), no `vim.*`. One calendar
for every plugin that asks "which period?": casedesk.nvim's `:Cases week`,
github_stats.nvim's date presets and testing.nvim's `--since=` use it.

Every function takes an optional `now` (unix timestamp, default `os.time()`)
so callers and specs get reproducible ranges. Weeks start on Monday. Every
boundary is a local midnight found by calendar arithmetic, never by
subtracting multiples of 86400 seconds (an hour off on the two days a year
the clock is switched).

## Named presets

Each returns `{ from, to }` unix timestamps. A current, still-open period
ends at `now`; a closed one ends at the local midnight after it (exclusive).

```lua
local presets = require("lib.lua.time.presets")

-- Wednesday 2026-10-14 12:00 local time
local now = os.time({ year = 2026, month = 10, day = 14, hour = 12 })

presets.today(now)          -- { 10-14 00:00, now }
presets.yesterday(now)      -- { 10-13 00:00, 10-14 00:00 }
presets.last_week(now)      -- { 10-07 00:00, 10-14 00:00 }  the 7 full days before today
presets.this_week(now)      -- { 10-12 00:00 (Monday), now }
presets.this_month(now)     -- { 10-01 00:00, now }
presets.this_quarter(now)   -- { 10-01 00:00, now }
presets.this_year(now)      -- { 01-01 00:00, now }
presets.previous_week(now)  -- { 10-05 00:00, 10-12 00:00 }  Monday to Monday
presets.previous_month(now) -- { 09-01 00:00, 10-01 00:00 }
presets.previous_year(now)  -- { 2025-01-01, 2026-01-01 }
presets.days_ago(30, now)   -- { 09-14 00:00, now }; nil, err outside 0..MAX_DAYS_AGO
presets.custom(a, b)        -- { a, b }, or nil, "from must be <= to"

presets.dates(presets.days_ago(7, now)) -- "2026-10-07", "2026-10-14"
```

`dates(range, open?)` gives the first and the last local calendar day a range
covers (`YYYY-MM-DD`): a `to` at a local midnight is exclusive, any other `to`
covers its own day. `open = true` for a range that ends at `now` (`today`,
`this_*`, `days_ago`), so one built at 00:00:00 sharp still ends today.

## Range words

`parse(words, now?)` reads what people type, English and German, and returns
`{ from, to, label }` with `to` exclusive at a local midnight (a range that
reaches today ends at tomorrow 00:00), or `nil, err` naming the keywords.

| Words | Range |
| --- | --- |
| *(nothing)*, `week`, `this week`, `diese woche` | Monday until the end of today |
| `today` / `heute`, `yesterday` / `gestern`, `last day` | the day |
| `last`, `last week`, `letzte woche` | the previous Monday-Sunday |
| `month`, `year` (`monat`, `jahr`, `this ...`) | this one, until the end of today |
| `last month`, `last year` (`letzter monat`, `letztes jahr`) | the previous calendar unit |
| `last N days`, `last N weeks`, `last N months` (`letzte 4 wochen`) | rolling window, today included |

```lua
presets.parse({ "last", "4", "weeks" }, now)
-- { from = 09-17 00:00, to = 10-15 00:00, label = "last 4 weeks (2026-09-17 .. 2026-10-14)" }
presets.parse("letzte woche", now)  -- one string of words works too
presets.parse({ "soon" }, now)      -- nil, "unknown date range 'soon' (try: today, ...)"
presets.candidates({ "last" })      -- { "week", "month", "year", "day", "2", ... }
```

`KEYWORDS` (the examples of the error message) and `ALIASES` (German and
plural words to their English spelling) are exported for completion.

## `--since=`

`since_utc(value, now?)` reads a command-line day as a **UTC** calendar day:
`2026-11-09` (checked against the calendar) or `7d` (the UTC day 7 x 24 h
before `now`). Returns `YYYY-MM-DD` or `nil, err`.

```lua
presets.since_utc("7d")          -- e.g. "2026-11-11"
presets.since_utc("2026-02-29")  -- nil, "expected a day (2026-11-09) or a number of days (7d)"
```
