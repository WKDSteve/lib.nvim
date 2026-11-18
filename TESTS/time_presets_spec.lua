-- TESTS/time_presets_spec.lua — lib.lua.time.presets (named ranges, the range words of
-- casedesk's `:Cases week` in English and German, `--since=` days) and the styles of
-- lib.lua.time.format that buffer-ctx.nvim's `:Timestamp` uses. The range-word cases are
-- ported from casedesk.nvim's daterange_spec and keep their text.
---@diagnostic disable: need-check-nil
-- The invalid-input cases pass wrong types on purpose.
---@diagnostic disable: param-type-mismatch

return function(H)
  local describe, it, assert = dofile(
    vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/support/busted_lite.lua"
  )(H)
  local presets = require("lib.lua.time.presets")
  local tfmt = require("lib.lua.time.format")

  -- Wednesday 2026-10-14, midday: a fixed "now" so no spec depends on the clock.
  local NOW = os.time({ year = 2026, month = 10, day = 14, hour = 12 })

  ---@param y integer
  ---@param m integer
  ---@param d integer
  ---@return integer
  local function day(y, m, d)
    return os.time({ year = y, month = m, day = d, hour = 0 })
  end

  ---@param words string
  ---@return LibTimeWordRange
  local function parse(words)
    local r, err = presets.parse(vim.split(words, " ", { trimempty = true }), NOW)
    assert(r, err)
    return r
  end

  describe("named presets", function()
    it("today, yesterday and the open periods end now", function()
      assert.are.same({ from = day(2026, 10, 14), to = NOW }, presets.today(NOW))
      assert.are.same({ from = day(2026, 10, 13), to = day(2026, 10, 14) }, presets.yesterday(NOW))
      assert.are.same({ from = day(2026, 10, 12), to = NOW }, presets.this_week(NOW))
      assert.are.same({ from = day(2026, 10, 1), to = NOW }, presets.this_month(NOW))
      assert.are.same({ from = day(2026, 10, 1), to = NOW }, presets.this_quarter(NOW))
      assert.are.same({ from = day(2026, 1, 1), to = NOW }, presets.this_year(NOW))
    end)

    it("last_week is the 7 full days before today", function()
      assert.are.same({ from = day(2026, 10, 7), to = day(2026, 10, 14) }, presets.last_week(NOW))
    end)

    it("previous week, month and year are whole calendar units", function()
      assert.are.same(
        { from = day(2026, 10, 5), to = day(2026, 10, 12) },
        presets.previous_week(NOW)
      )
      assert.are.same(
        { from = day(2026, 9, 1), to = day(2026, 10, 1) },
        presets.previous_month(NOW)
      )
      assert.are.same({ from = day(2025, 1, 1), to = day(2026, 1, 1) }, presets.previous_year(NOW))
      -- January: the previous month is last year's December.
      local jan = os.time({ year = 2026, month = 1, day = 10, hour = 9 })
      assert.are.same(
        { from = day(2025, 12, 1), to = day(2026, 1, 1) },
        presets.previous_month(jan)
      )
    end)

    it("this_week on a Sunday and on a Monday", function()
      local sunday = os.time({ year = 2026, month = 10, day = 18, hour = 23 })
      assert.are.equal(day(2026, 10, 12), presets.this_week(sunday).from)
      local monday = os.time({ year = 2026, month = 10, day = 19, hour = 0, min = 30 })
      assert.are.equal(day(2026, 10, 19), presets.this_week(monday).from)
    end)

    it("days_ago starts at the local midnight n days back and refuses nonsense", function()
      assert.are.same({ from = day(2026, 10, 7), to = NOW }, presets.days_ago(7, NOW))
      assert.are.same({ from = day(2026, 9, 14), to = NOW }, presets.days_ago(30, NOW))
      assert.are.same({ from = day(2026, 10, 14), to = NOW }, presets.days_ago(0, NOW))
      for _, bad in ipairs({ -1, 1.5, "7", presets.MAX_DAYS_AGO + 1, math.huge }) do
        local r, err = presets.days_ago(bad, NOW)
        assert.is_nil(r, tostring(bad))
        assert.is_string(err)
      end
    end)

    it("custom validates", function()
      assert.are.same({ from = 1, to = 2 }, presets.custom(1, 2))
      assert.is_nil((presets.custom(2, 1)))
      assert.is_nil((presets.custom("a", 1)))
    end)

    it("dates names the first and last day a range covers", function()
      local first, last = presets.dates(presets.yesterday(NOW))
      assert.are.same({ "2026-10-13", "2026-10-13" }, { first, last })
      first, last = presets.dates(presets.days_ago(7, NOW))
      assert.are.same({ "2026-10-07", "2026-10-14" }, { first, last })
      first, last = presets.dates(presets.today(NOW))
      assert.are.same({ "2026-10-14", "2026-10-14" }, { first, last })
      -- An empty range at a midnight still covers its own day.
      first, last = presets.dates({ from = day(2026, 10, 14), to = day(2026, 10, 14) })
      assert.are.same({ "2026-10-14", "2026-10-14" }, { first, last })
    end)
  end)

  describe("range words (parse)", function()
    it("defaults to this week, Monday until the end of today", function()
      local r = presets.parse({}, NOW)
      assert.are.equal(day(2026, 10, 12), r.from)
      assert.are.equal(day(2026, 10, 15), r.to)
      assert.are.equal(day(2026, 10, 12), presets.parse(nil, NOW).from)
    end)

    it("`last` and `last week` are the previous Monday-Sunday", function()
      for _, words in ipairs({ "last", "last week", "letzte woche" }) do
        local r = parse(words)
        assert.are.equal(day(2026, 10, 5), r.from, words)
        assert.are.equal(day(2026, 10, 12), r.to, words)
      end
    end)

    it("today and yesterday", function()
      assert.are.equal(day(2026, 10, 14), parse("today").from)
      assert.are.equal(day(2026, 10, 13), parse("yesterday").from)
      assert.are.equal(day(2026, 10, 14), parse("yesterday").to)
      assert.are.equal(day(2026, 10, 13), parse("gestern").from)
      assert.are.equal(day(2026, 10, 14), parse("heute").from)
    end)

    it("`last N weeks` / `last N days` roll back from today, today included", function()
      local w = parse("last 4 weeks")
      assert.are.equal(day(2026, 10, 15), w.to)
      assert.are.equal(day(2026, 9, 17), w.from)
      assert.are.equal(day(2026, 10, 5), parse("last 10 days").from)
      assert.are.equal(day(2026, 9, 17), parse("letzte 4 wochen").from)
      assert.is_truthy(parse("last 1 day").label:find("last 1 day (", 1, true))
    end)

    it("month and year, this and last", function()
      assert.are.equal(day(2026, 10, 1), parse("month").from)
      assert.are.equal(day(2026, 10, 1), parse("diesen monat").from)
      assert.are.equal(day(2026, 9, 1), parse("last month").from)
      assert.are.equal(day(2026, 10, 1), parse("last month").to)
      assert.are.equal(day(2025, 1, 1), parse("last year").from)
      assert.are.equal(day(2026, 1, 1), parse("letztes jahr").to)
      assert.are.equal(day(2026, 8, 1), parse("last 3 months").from)
    end)

    it("one string of words reads like the words", function()
      assert.are.same(parse("last 4 weeks"), presets.parse("last 4 weeks", NOW))
      assert.are.same(parse("last 4 weeks"), presets.parse({ "last 4", "weeks" }, NOW))
    end)

    it("labels show the last day the range includes", function()
      assert.are.equal("last 4 weeks (2026-09-17 .. 2026-10-14)", parse("last 4 weeks").label)
      assert.are.equal("this week (2026-10-12 .. 2026-10-14)", parse("week").label)
    end)

    it("every boundary is a local midnight, on any day of the year", function()
      -- A boundary found by subtracting 86400-second days is an hour off on the two days a year
      -- the clock is switched, in a time zone that has them (the invariant holds in every zone).
      local words = {
        "today",
        "yesterday",
        "week",
        "last",
        "month",
        "last month",
        "year",
        "last year",
        "last 4 weeks",
        "last 10 days",
        "last 3 months",
      }
      for d = 1, 366 do
        local now = os.time({ year = 2026, month = 1, day = d, hour = 12 })
        local edges = {}
        for _, w in ipairs(words) do
          local r = assert(presets.parse(vim.split(w, " "), now))
          edges[#edges + 1] = r.from
          edges[#edges + 1] = r.to
        end
        for _, name in ipairs({ "yesterday", "last_week", "previous_week", "previous_month" }) do
          local r = presets[name](now)
          edges[#edges + 1] = r.from
          edges[#edges + 1] = r.to
        end
        edges[#edges + 1] = presets.days_ago(30, now).from
        edges[#edges + 1] = presets.this_week(now).from
        for _, edge in ipairs(edges) do
          local t = os.date("*t", edge)
          assert.are.same(
            { 0, 0, 0 },
            { t.hour, t.min, t.sec },
            ("day %d: %s"):format(d, os.date("%c", edge))
          )
        end
      end
    end)

    it("rejects nonsense with the list of keywords", function()
      local r, err = presets.parse({ "soon" }, NOW)
      assert.is_nil(r)
      assert.is_truthy(err:find("unknown date range 'soon'", 1, true))
      assert.is_truthy(err:find("last 4 weeks", 1, true))
      assert.is_nil((presets.parse({ "last", "0", "weeks" }, NOW)))
      assert.is_nil((presets.parse({ "last", "-3", "days" }, NOW)))
      assert.is_nil((presets.parse({ "last", "2.5", "weeks" }, NOW)))
      assert.is_nil((presets.parse({ "this", "decade" }, NOW)))
      assert.is_nil((presets.parse({ "next", "week" }, NOW)))
    end)

    it("refuses a count no date can be printed for instead of raising", function()
      for _, count in ipairs({ "99999999999", "1e999", "521" }) do
        local ok, r = pcall(presets.parse, { "last", count, "weeks" }, NOW)
        assert.is_true(ok, count)
        assert.is_nil(r, count)
      end
      assert.is_truthy((presets.parse({ "last", "520", "weeks" }, NOW)))
      assert.is_truthy((presets.parse({ "last", "3650", "days" }, NOW)))
      assert.is_truthy((presets.parse({ "last", "120", "months" }, NOW)))
    end)

    it("offers the next word of the range", function()
      assert.is_true(vim.tbl_contains(presets.candidates({}), "last"))
      assert.is_true(vim.tbl_contains(presets.candidates({ "last" }), "week"))
      assert.is_true(vim.tbl_contains(presets.candidates({ "letzte" }), "4"))
      assert.are.same({ "week", "month", "year" }, presets.candidates({ "diese" }))
      assert.are.same({ "days", "weeks", "months" }, presets.candidates({ "last", "4" }))
      assert.are.same({}, presets.candidates({ "last", "week" }))
    end)
  end)

  describe("since_utc", function()
    -- 2026-11-18 00:30 UTC: the UTC day differs from the local one in many zones.
    local now = 1794960000 + 1800

    it("reads a day, checked against the calendar", function()
      assert.are.equal("2026-11-09", presets.since_utc("2026-11-09", now))
      assert.are.equal("2028-02-29", presets.since_utc("2028-02-29", now))
      for _, bad in ipairs({ "2026-02-29", "2026-13-01", "2026-11-9", "yesterday", "-7d", "7", "" }) do
        local d, err = presets.since_utc(bad, now)
        assert.is_nil(d, bad)
        assert.is_truthy(err:find("7d", 1, true), bad)
      end
      assert.is_nil((presets.since_utc(nil, now)))
    end)

    it("reads n days back as the UTC day", function()
      assert.are.equal("2026-11-18", presets.since_utc("0d", now))
      assert.are.equal("2026-11-11", presets.since_utc("7d", now))
      assert.are.equal("2026-10-19", presets.since_utc("30d", now))
      assert.is_nil((presets.since_utc("9999999d", now)))
    end)
  end)

  describe("format styles", function()
    -- Tuesday 2026-07-14 14:32:05
    local ts = os.time({ year = 2026, month = 7, day = 14, hour = 14, min = 32, sec = 5 })
    local night = os.time({ year = 2026, month = 7, day = 14, hour = 0, min = 5, sec = 9 })

    it("hand-built styles use fixed English names", function()
      assert.are.equal("02:32:05 PM", tfmt.format_timestamp(ts, "12h"))
      assert.are.equal("12:05:09 AM", tfmt.format_timestamp(night, "12h"))
      assert.are.equal("Tuesday", tfmt.format_timestamp(ts, "weekday"))
      assert.are.equal("Tuesday, July 14, 2026", tfmt.format_timestamp(ts, "long"))
      assert.are.equal("Tue, 14 Jul 2026 14:32:05", tfmt.format_timestamp(ts, "rfc2822"))
    end)

    it("pattern styles and caller patterns", function()
      assert.are.equal("2026-07-14", tfmt.format_timestamp(ts, "iso-date"))
      assert.are.equal("14:32:05", tfmt.format_timestamp(ts, "iso-time"))
      assert.are.equal("14:32:05", tfmt.format_timestamp(ts, "time"))
      assert.are.equal(
        "14.07.2026",
        tfmt.format_timestamp(ts, "short", { patterns = { short = "%d.%m.%Y" } })
      )
      assert.are.equal("2026", tfmt.format_timestamp(ts, "mine", { patterns = { mine = "%Y" } }))
      -- A caller pattern never replaces a hand-built style.
      assert.are.equal(
        "Tuesday",
        tfmt.format_timestamp(ts, "weekday", { patterns = { weekday = "%a" } })
      )
    end)

    it("utc applies to hand-built styles too", function()
      local utc_t = os.date("!*t", ts)
      local h = utc_t.hour % 12
      assert.are.equal(
        ("%02d:32:05 %s"):format(h == 0 and 12 or h, utc_t.hour < 12 and "AM" or "PM"),
        tfmt.format_timestamp(ts, "12h", { utc = true })
      )
    end)

    it("STYLES lists every style", function()
      for _, s in ipairs({ "unix", "iso", "12h", "rfc2822", "iso-date", "time" }) do
        assert.is_true(vim.tbl_contains(tfmt.STYLES, s), s)
      end
    end)
  end)
end
