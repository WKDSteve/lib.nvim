# `lib.lua.time.format`

Format a unix timestamp using a small set of named style presets, pure Lua
(`os.date`), no `vim.*`. Unknown/`nil` `fmt` falls back to `"iso"`.

`12h`, `weekday`, `long` and `rfc2822` are built by hand with fixed English
names: `%p` (AM/PM) vanishes on Windows' C runtime, and `%A`/`%B` follow the
C locale (a German locale writes `Di` for Tuesday).

## Usage

```lua
local format = require("lib.lua.time.format")

-- ts = Tuesday 2026-07-14 14:32:05 UTC
local ts = os.time({ year = 2026, month = 7, day = 14, hour = 14, min = 32, sec = 5 })

format.format_timestamp(ts, "iso", { utc = true })      -- "2026-07-14T14:32:05"
format.format_timestamp(ts, "human", { utc = true })    -- "Jul 14, 2026 14:32"
format.format_timestamp(ts, "short", { utc = true })    -- "2026-07-14"
format.format_timestamp(ts, "log", { utc = true })      -- "[2026-07-14 14:32:05]"
format.format_timestamp(ts, "filename", { utc = true }) -- "20260714_143205"
format.format_timestamp(ts, "iso-date", { utc = true }) -- "2026-07-14"
format.format_timestamp(ts, "iso-time", { utc = true }) -- "14:32:05" (also "time")
format.format_timestamp(ts, "12h", { utc = true })      -- "02:32:05 PM"
format.format_timestamp(ts, "weekday", { utc = true })  -- "Tuesday"
format.format_timestamp(ts, "long", { utc = true })     -- "Tuesday, July 14, 2026"
format.format_timestamp(ts, "rfc2822", { utc = true })  -- "Tue, 14 Jul 2026 14:32:05"
format.format_timestamp(ts, "unix")                     -- "1783514725" (example value)
format.format_timestamp(ts, "bogus", { utc = true })    -- falls back to "iso"

-- a plugin's own spelling of a pattern style (hand-built styles always win)
format.format_timestamp(ts, "short", { patterns = { short = "%d.%m.%Y" } }) -- "14.07.2026"
```

## Returns

| Function / field | Returns |
| --- | --- |
| `format_timestamp(ts, fmt, opts)` | `string`; `opts = { utc?, patterns? }` |
| `STYLES` | every style name, sorted |
| `WEEKDAYS`, `MONTHS` | the English names (`WEEKDAYS[1]` is Sunday, as `os.date("*t").wday`) |
