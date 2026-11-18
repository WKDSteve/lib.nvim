---@meta
---@module 'lib.lua.time.format.@types'

---@alias LibTimeFormatStyle "iso"|"human"|"short"|"log"|"filename"|"unix"|"iso-date"|"iso-time"|"time"|"12h"|"weekday"|"long"|"rfc2822"

---@class LibTimeFormatOpts
---@field utc boolean? When true, format in UTC instead of local time.
---@field patterns table<string, string>? `os.date` patterns by style name, added to or overriding the built-in ones (not the hand-built styles).

---@class LibTimeFormat
---@field format_timestamp fun(ts?: integer, fmt?: LibTimeFormatStyle|string, opts?: LibTimeFormatOpts): string
---@field STYLES string[]
---@field WEEKDAYS string[]
---@field MONTHS string[]
