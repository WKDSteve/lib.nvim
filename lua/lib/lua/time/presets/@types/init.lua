---@meta
---@module 'lib.lua.time.presets.@types'

---@class LibTimeRange
---@field from integer
---@field to integer

---@class LibTimeWordRange: LibTimeRange
---@field label string `what (first day .. last day)`, e.g. `last 4 weeks (2026-09-17 .. 2026-10-14)`

---@class LibTimePresets
---@field today fun(now?: integer): LibTimeRange
---@field yesterday fun(now?: integer): LibTimeRange
---@field last_week fun(now?: integer): LibTimeRange
---@field this_week fun(now?: integer): LibTimeRange
---@field this_month fun(now?: integer): LibTimeRange
---@field this_quarter fun(now?: integer): LibTimeRange
---@field this_year fun(now?: integer): LibTimeRange
---@field previous_week fun(now?: integer): LibTimeRange
---@field previous_month fun(now?: integer): LibTimeRange
---@field previous_year fun(now?: integer): LibTimeRange
---@field days_ago fun(n: integer, now?: integer): LibTimeRange|nil, string|nil
---@field MAX_DAYS_AGO integer
---@field custom fun(from: integer, to: integer): LibTimeRange|nil, string|nil
---@field dates fun(range: LibTimeRange): string, string
---@field ALIASES table<string, string>
---@field KEYWORDS string[]
---@field parse fun(tokens: string|string[]|nil, now?: integer): LibTimeWordRange|nil, string|nil
---@field candidates fun(typed: string|string[]|nil): string[]
---@field since_utc fun(value: string, now?: integer): string|nil, string|nil
