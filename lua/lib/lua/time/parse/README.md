# `lib.lua.time.parse`

Timestamp parser for the notations logs write, mapped onto **UTC
milliseconds since 1970**, so entries of several services can be merged by
time and gaps measured. Pure Lua: no `vim.*`, and no `os.time`/`os.date`
either (both read the host's time zone; a log written in Vienna must give the
same millisecond on a CI runner in UTC). The calendar arithmetic is Hinnant's
days-from-civil algorithm.

It came from casedesk.nvim's log reading copy (`logview/core/time.lua`,
formats F1-F11), which now uses this module.

## Notations

| Text | `info.notation` |
| --- | --- |
| `2026-10-29 7:59:21:693` (milliseconds after `:`, unpadded) | `browserstack` |
| `2026-10-23 09:59:43,122` | `comma` |
| `2026-09-20 09:19:51.215 +05:30`, `...-0200` | `offset` |
| `2026-10-29T07:59:21.693Z` | `zulu` |
| `2026-10-29 07:59:21.693`, no fraction | `plain` |
| `1:22:40 PM` | `clock12` |
| `07:59:21` (date from `ctx.filename`, or none) | `time` |

Any of them may be enclosed in `[...]` (`info.bracketed`). Fractions longer
than 3 digits are truncated; at most 9 digits. Texts longer than `MAX_RAW`
(64) characters are refused.

## Usage

```lua
local tparse = require("lib.lua.time.parse")

local ms, info = tparse.parse("2026-09-20 09:19:51.215 +05:30")
-- ms = 1789876191215, info.offset_min = 330, info.notation = "offset"

-- no zone in the text: ctx.offset_min (default 0) is assumed
tparse.parse("2026-10-23 09:59:43,122", { offset_min = 120 })

-- a time alone takes the date from the file name
tparse.parse("07:59:21", { filename = "GatewayService_Log_20261029.txt" })

local ms2, err = tparse.parse("yesterday") -- nil, "no time of day (H:MM:SS)"

tparse.format(ms, "iso")          -- "2026-09-20T03:49:51.215Z"
tparse.format(ms, "iso", 330)     -- "2026-09-20T09:19:51.215+05:30"
tparse.format(ms, "time")         -- "03:49:51.215"
tparse.delta(2300)                -- "+2,3 s"
tparse.date_from_filename("ToscaCommander-2026_10_23-x.log") -- 2026, 10, 23
tparse.civil_ms(2026, 10, 29, 7, 59, 21, 693)               -- UTC ms
tparse.utc_date(os.time())        -- today's UTC day, "YYYY-MM-DD"
```

## API

| Function | Returns |
| --- | --- |
| `parse(raw, ctx?)` | `ms, info` or `nil, err`; `ctx = { filename?, offset_min? }` |
| `format(ms, mode?, offset_min?)` | `"time"`, `"datetime"` (default) or `"iso"` text |
| `delta(ms)` | short German distance: `+318 ms`, `+2,3 s`, `+14 min`, `+3 h 5 min`, `+2 d 4 h` |
| `date_from_filename(name)` | `y, mo, d` of the earliest date in the basename, or `nil` |
| `civil_ms(y, mo, d, h?, mi?, s?, ms?)` | UTC milliseconds of a civil date and time |
| `days_from_civil(y, mo, d)` / `civil_from_days(z)` | day count since 1970 and back |
| `valid_date(y, mo, d)` | is it a calendar day |
| `utc_date(epoch_s)` | `YYYY-MM-DD` UTC day of a unix timestamp |

`info` (`Lib.Time.ParseInfo`): `has_date`, `date_source` (`"text"` /
`"filename"`), `offset_min`, `offset_assumed`, `notation`, `frac_sep`,
`zone` (`"Z"` / `"offset"`), `bracketed`.
