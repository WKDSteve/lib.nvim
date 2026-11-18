-- TESTS/time_parse_spec.lua — lib.lua.time.parse: every log notation onto one UTC millisecond,
-- file-name dates, rendering and deltas. Ported from casedesk.nvim's logview_time_spec (the parser
-- came from its log reading copy); the cases keep their text.
--
-- The expected epochs are literals computed outside Lua (`date -u -d ... +%s`),
-- so the spec does not check the days-from-civil arithmetic against itself.
-- All timestamps and file names are invented in the shape of the formats.
---@diagnostic disable: need-check-nil
-- The invalid-input cases pass wrong types on purpose (a number, nil, an error string read as a time).
---@diagnostic disable: param-type-mismatch, assign-type-mismatch

return function(H)
  local describe, it, assert = dofile(
    vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/support/busted_lite.lua"
  )(H)
  local time = require("lib.lua.time.parse")

  --- Epoch seconds (from `date -u`) plus milliseconds.
  ---@param epoch_s integer
  ---@param ms? integer
  ---@return integer
  local function at(epoch_s, ms)
    return epoch_s * 1000 + (ms or 0)
  end

  -- 2026-10-29 07:59:21 UTC
  local T_1029 = 1793260761

  describe("logview.core.time", function()
    describe("civil_ms", function()
      it("is 0 at the epoch and negative before it", function()
        assert.are.equal(0, time.civil_ms(1970, 1, 1, 0, 0, 0, 0))
        assert.are.equal(-1000, time.civil_ms(1969, 12, 31, 23, 59, 59, 0))
      end)

      it("handles leap years, century rules and default parts", function()
        assert.are.equal(at(1835438400), time.civil_ms(2028, 2, 29, 12, 0, 0))
        assert.are.equal(at(951868800), time.civil_ms(2000, 3, 1))
        assert.are.equal(at(4107456000), time.civil_ms(2100, 2, 28))
      end)
    end)

    describe("parse: notations", function()
      it("BrowserStack: no leading zeros, milliseconds after a colon", function()
        local ms, info = time.parse("2026-10-29 7:59:21:693")
        assert.are.equal(at(T_1029, 693), ms)
        assert.are.equal("browserstack", info.notation)
        assert.are.equal(":", info.frac_sep)
        assert.is_true(info.has_date)
        assert.are.equal("text", info.date_source)
      end)

      it("BrowserStack: unpadded milliseconds are milliseconds (`:20` is 20 ms)", function()
        local ms = time.parse("2026-9-23 13:30:26:20")
        assert.are.equal(at(1790170226, 20), ms)
        assert.are.equal(at(1790170226, 5), time.parse("2026-9-23 13:30:26:5"))
      end)

      it("decimal comma", function()
        local ms, info = time.parse("2026-10-23 09:59:43,122")
        assert.are.equal(at(1792749583, 122), ms)
        assert.are.equal("comma", info.notation)
        assert.is_true(info.offset_assumed)
        assert.are.equal(0, info.offset_min)
      end)

      it("explicit offset +00:00 and +05:30", function()
        local ms, info = time.parse("2026-09-20 09:19:51.215 +00:00")
        assert.are.equal(at(1789895991, 215), ms)
        assert.are.equal("offset", info.notation)
        assert.is_false(info.offset_assumed)
        assert.are.equal(0, info.offset_min)

        -- 09:19:51 at +05:30 is 03:49:51 UTC.
        ms, info = time.parse("2026-09-20 09:19:51.215 +05:30")
        assert.are.equal(at(1789876191, 215), ms)
        assert.are.equal(330, info.offset_min)
      end)

      it("negative offset and offset without colon", function()
        -- 2026-10-29 07:59:21 UTC written at -02:00 is 05:59:21 local.
        assert.are.equal(at(T_1029), time.parse("2026-10-29 05:59:21-02:00"))
        assert.are.equal(at(T_1029), time.parse("2026-10-29 05:59:21 -0200"))
      end)

      it("Z without fraction", function()
        local ms, info = time.parse("2026-10-05 10:12:29Z")
        assert.are.equal(at(1791195149), ms)
        assert.are.equal("zulu", info.notation)
        assert.are.equal("Z", info.zone)
      end)

      it("ISO with T, decimal comma and Z", function()
        local ms, info = time.parse("2026-10-07T03:25:07,117Z")
        assert.are.equal(at(1791343507, 117), ms)
        assert.are.equal("zulu", info.notation)
        assert.are.equal(",", info.frac_sep)
      end)

      it("bracketed with offset (+02:00 the day before in UTC)", function()
        local ms, info = time.parse("[2026-08-29 01:11:00.510+02:00]")
        assert.are.equal(at(1787958660, 510), ms)
        assert.is_true(info.bracketed)
        assert.are.equal(120, info.offset_min)
      end)

      it("Serilog JSON timestamp", function()
        local ms = time.parse("2026-10-06T06:16:06.857+00:00")
        assert.are.equal(at(1791267366, 857), ms)
      end)

      it("plain date and time with a decimal point and no zone", function()
        local ms, info = time.parse("2026-10-29 07:59:21.693")
        assert.are.equal(at(T_1029, 693), ms)
        assert.are.equal("plain", info.notation)
      end)

      it("all notations of the same instant give the same millisecond", function()
        local want = at(T_1029, 693)
        for _, raw in ipairs({
          "2026-10-29 7:59:21:693",
          "2026-10-29 07:59:21,693",
          "2026-10-29 07:59:21.693 +00:00",
          "2026-10-29 13:29:21.693 +05:30",
          "2026-10-29T07:59:21,693Z",
          "[2026-10-29 09:59:21.693+02:00]",
          "2026-10-29T07:59:21.693+00:00",
          "2026-10-29T07:59:21.6930000Z",
        }) do
          assert.are.equal(want, (time.parse(raw)), raw)
        end
      end)

      it("decimal fractions scale by position", function()
        assert.are.equal(at(T_1029, 500), time.parse("2026-10-29 07:59:21.5"))
        assert.are.equal(at(T_1029, 50), time.parse("2026-10-29 07:59:21.05"))
        assert.are.equal(at(T_1029, 123), time.parse("2026-10-29 07:59:21.1239999Z"))
      end)

      it("leading and trailing blanks are ignored", function()
        assert.are.equal(at(T_1029), time.parse("  2026-10-29 07:59:21  "))
      end)
    end)

    describe("parse: assumed offset", function()
      it("applies ctx.offset_min to text without a zone", function()
        local ms, info = time.parse("2026-10-29 09:59:21,000", { offset_min = 120 })
        assert.are.equal(at(T_1029), ms)
        assert.is_true(info.offset_assumed)
        assert.are.equal(120, info.offset_min)
      end)

      it("ignores ctx.offset_min when the text has a zone", function()
        local ms, info = time.parse("2026-10-29 07:59:21Z", { offset_min = 120 })
        assert.are.equal(at(T_1029), ms)
        assert.is_false(info.offset_assumed)
        assert.are.equal(0, info.offset_min)
      end)

      it("rejects a non-integer or out-of-range ctx.offset_min", function()
        assert.is_nil((time.parse("2026-10-29 07:59:21", { offset_min = 1.5 })))
        assert.is_nil((time.parse("2026-10-29 07:59:21", { offset_min = 1440 })))
        local ms, err = time.parse("2026-10-29 07:59:21", { offset_min = "60" })
        assert.is_nil(ms)
        assert.is_string(err)
      end)
    end)

    describe("parse: 12-hour clock and time-only", function()
      local ctx = { filename = "Log_20261028_132240.txt" }

      it("takes the date from the file name", function()
        local ms, info = time.parse("1:22:40 PM", ctx)
        assert.are.equal(at(1793193760), ms)
        assert.are.equal("clock12", info.notation)
        assert.are.equal("filename", info.date_source)
        assert.is_true(info.has_date)
        assert.is_true(info.offset_assumed)
      end)

      it("12 AM is midnight, 12 PM is noon", function()
        assert.are.equal(at(1793146960), time.parse("12:22:40 AM", ctx))
        assert.are.equal(at(1793189100), time.parse("12:05:00 PM", ctx))
        assert.are.equal(at(1793189100), time.parse("12:05:00pm", ctx))
        assert.are.equal(at(1793146960 + 11 * 3600), time.parse("11:22:40 AM", ctx))
      end)

      it("rejects hours outside 1-12 on a 12-hour clock", function()
        assert.is_nil((time.parse("0:22:40 AM", ctx)))
        assert.is_nil((time.parse("13:22:40 PM", ctx)))
      end)

      it("time-only with a dated file name", function()
        local ms, info =
          time.parse("6:42:39.978", { filename = "x/2026-10-28/Module_2026_10_28.txt" })
        assert.are.equal(at(1793146960 - 22 * 60 - 40 + 6 * 3600 + 42 * 60 + 39, 978), ms)
        assert.are.equal("time", info.notation)
        assert.are.equal("filename", info.date_source)
      end)

      it("time-only without any date: ms since midnight, no offset applied", function()
        local ms, info =
          time.parse("6:42:39.978", { filename = "ToscaModuleLogs.txt", offset_min = 120 })
        assert.are.equal(((6 * 60 + 42) * 60 + 39) * 1000 + 978, ms)
        assert.is_false(info.has_date)
        assert.is_nil(info.date_source)
        assert.is_nil(info.offset_min)
        assert.are.equal("time", info.notation)

        local pm = time.parse("1:22:40 PM")
        assert.are.equal(((13 * 60 + 22) * 60 + 40) * 1000, pm)
      end)
    end)

    describe("parse: leap years and dates without leading zeros", function()
      it("accepts 29 February in a leap year only", function()
        assert.are.equal(at(1835438400), time.parse("2028-2-29 12:00:00"))
        assert.is_nil((time.parse("2026-2-29 12:00:00")))
        assert.is_nil((time.parse("2100-02-29 12:00:00")))
        assert.is_not_nil((time.parse("2000-02-29 12:00:00")))
      end)

      it("reads single-digit month, day and hour", function()
        assert.are.equal(time.parse("2026-09-03 07:05:09"), time.parse("2026-9-3 7:05:09"))
      end)
    end)

    describe("parse: invalid input", function()
      local bad = {
        "",
        "   ",
        "not a time",
        "2026-10-29",
        "2026-13-01 07:59:21",
        "2026-10-32 07:59:21",
        "2026-10-29 24:00:00",
        "2026-10-29 07:60:21",
        "2026-10-29 07:59:60",
        "2026-10-29 07:59:21:1234",
        "2026-10-29 07:59:21.1234567890",
        "2026-10-29 07:59:21 +24:00",
        "2026-10-29 07:59:21 +01:60",
        "2026-10-29 07:59:21 INFO",
        "2026-10-29_07:59:21",
        "[2026-10-29 07:59:21",
        "7:59",
      }
      for _, raw in ipairs(bad) do
        it(("returns nil and a message for %q"):format(raw), function()
          local ok, ms, err = pcall(time.parse, raw)
          assert.is_true(ok)
          assert.is_nil(ms)
          assert.is_string(err)
        end)
      end

      it("returns nil for non-strings and over-long text", function()
        assert.is_nil((time.parse(nil)))
        assert.is_nil((time.parse(42)))
        local ms, err = time.parse(("2026-10-29 07:59:21 "):rep(10))
        assert.is_nil(ms)
        assert.matches("longer than", err)
      end)

      it("stays fast on a long blank run inside the length cap", function()
        local raw = (" "):rep(time.MAX_RAW - 1) .. "x"
        local ok, ms = pcall(time.parse, raw)
        assert.is_true(ok)
        assert.is_nil(ms)
      end)
    end)

    describe("date_from_filename", function()
      it("finds YYYYMMDD, YYYY_MM_DD and YYYY-MM-DD", function()
        assert.are.same(
          { 2026, 9, 20 },
          { time.date_from_filename("GatewayService_Log_20260920.txt") }
        )
        assert.are.same(
          { 2026, 10, 23 },
          { time.date_from_filename("ToscaCommander-2026_10_23-1.log") }
        )
        assert.are.same({ 2026, 10, 7 }, { time.date_from_filename("licserver.2026-10-07.0.log") })
      end)

      it("does not start or end inside a longer digit run", function()
        assert.are.same({ 2026, 10, 28 }, { time.date_from_filename("Log_20261028_132240.txt") })
        assert.are.same({ 2026, 10, 5 }, { time.date_from_filename("log_18380_20261005.txt") })
        assert.is_nil(time.date_from_filename("build_1202610281.txt"))
      end)

      it("takes the earliest valid date and skips invalid ones", function()
        assert.are.same({ 2026, 1, 2 }, { time.date_from_filename("x_20260102_to_2026-03-04.log") })
        assert.are.same({ 2026, 3, 4 }, { time.date_from_filename("x_20261340_to_2026-03-04.log") })
      end)

      it("reads only the basename", function()
        assert.is_nil(time.date_from_filename("C:\\cases\\2026-10-13\\ToscaModuleLogs.txt"))
        assert.are.same(
          { 2026, 10, 6 },
          { time.date_from_filename("a/2026-10-13/Auth_Log_20261006.txt") }
        )
      end)

      it("returns nil for no date, non-strings and over-long names", function()
        assert.is_nil(time.date_from_filename("logs.txt"))
        assert.is_nil(time.date_from_filename(nil))
        assert.is_nil(time.date_from_filename(("a"):rep(time.MAX_FILENAME) .. "_20261028.txt"))
      end)
    end)

    describe("format", function()
      local ms = at(T_1029, 693)

      it("renders time, datetime and iso in UTC", function()
        assert.are.equal("07:59:21.693", time.format(ms, "time"))
        assert.are.equal("2026-10-29 07:59:21.693", time.format(ms, "datetime"))
        assert.are.equal("2026-10-29 07:59:21.693", time.format(ms))
        assert.are.equal("2026-10-29T07:59:21.693Z", time.format(ms, "iso"))
      end)

      it("shifts to an original offset", function()
        assert.are.equal("13:29:21.693", time.format(ms, "time", 330))
        assert.are.equal("2026-10-29T13:29:21.693+05:30", time.format(ms, "iso", 330))
        assert.are.equal("2026-10-28T23:59:21.693-08:00", time.format(ms, "iso", -480))
      end)

      it("round-trips through parse, also across a leap day and before 1970", function()
        for _, raw in ipairs({
          "2028-02-29T23:59:59.999Z",
          "1969-12-31T23:59:59.000Z",
          "2000-03-01T00:00:00.000Z",
        }) do
          assert.are.equal(raw, time.format(time.parse(raw), "iso"))
        end
      end)
    end)

    describe("delta", function()
      it("uses ms, tenths of seconds, minutes, hours and days", function()
        assert.are.equal("+0 ms", time.delta(0))
        assert.are.equal("+318 ms", time.delta(318))
        assert.are.equal("+2,3 s", time.delta(2349))
        assert.are.equal("+1,0 s", time.delta(1000))
        assert.are.equal("+59,9 s", time.delta(59999))
        assert.are.equal("+14 min", time.delta(14 * 60000 + 59000))
        assert.are.equal("+3 h 5 min", time.delta((3 * 60 + 5) * 60000))
        assert.are.equal("+2 d 4 h", time.delta((2 * 24 + 4) * 3600000))
      end)

      it("marks negative distances", function()
        assert.are.equal("-318 ms", time.delta(-318))
        assert.are.equal("-2,3 s", time.delta(-2349))
      end)
    end)
  end)

  describe("lib additions", function()
    it("utc_date renders the UTC day of a timestamp, before 1970 too", function()
      assert.are.equal("1970-01-01", time.utc_date(0))
      assert.are.equal("1969-12-31", time.utc_date(-1))
      assert.are.equal("2026-10-29", time.utc_date(T_1029))
      assert.are.equal("2028-02-29", time.utc_date(1835438400))
    end)

    it("days_from_civil and civil_from_days are inverse", function()
      for _, ymd in ipairs({ { 1970, 1, 1 }, { 2000, 2, 29 }, { 2100, 3, 1 }, { 1900, 12, 31 } }) do
        local y, mo, d = time.civil_from_days(time.days_from_civil(ymd[1], ymd[2], ymd[3]))
        assert.are.same(ymd, { y, mo, d })
      end
    end)

    it("valid_date knows month lengths and leap years", function()
      assert.is_true(time.valid_date(2028, 2, 29))
      assert.is_false(time.valid_date(2026, 2, 29))
      assert.is_false(time.valid_date(2100, 2, 29))
      assert.is_true(time.valid_date(2000, 2, 29))
      assert.is_false(time.valid_date(2026, 13, 1))
      assert.is_false(time.valid_date(2026, 4, 31))
    end)
  end)
end
