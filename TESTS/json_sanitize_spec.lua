-- TESTS/json_sanitize_spec.lua — lib.nvim.json.sanitize
--
-- The contract: a decoded API response is repaired against a description, never crashes on odd
-- data, never changes its input, and reports every repair by path.

return function(H)
  local ok = H.ok
  local sanitize = require("lib.nvim.json.sanitize")

  --- `eq` that compares tables by content.
  local function eq(a, b, msg)
    if type(a) == "table" or type(b) == "table" then
      a, b = vim.inspect(a), vim.inspect(b)
    end
    H.eq(a, b, msg)
  end

  local REPO = {
    type = "table",
    fields = {
      name = { type = "string", required = true, default = "No name" },
      owner = {
        type = "table",
        required = true,
        fields = { login = { type = "string", required = true, default = "Unknown" } },
      },
      description = { type = "string", default = "No description" },
    },
  }
  local RESPONSE = {
    type = "table",
    required = true,
    fields = {
      total_count = { type = "number", default = 0 },
      items = { type = "list", required = true, of = REPO },
    },
  }

  local function codes(ws)
    local out = {}
    for _, w in ipairs(ws) do
      out[#out + 1] = w.path .. ":" .. w.code
    end
    return out
  end

  -- ------------------------------------------------------- a complete response
  do
    local data = {
      total_count = 2,
      items = {
        { name = "a", owner = { login = "x" }, description = "d", stars = 5 },
        { name = "b", owner = { login = "y" }, description = "e" },
      },
    }
    local clean, ws = sanitize.apply(data, RESPONSE)
    eq(ws, {}, "nothing to repair")
    eq(clean, data, "same content")
    eq(clean.items[1].stars, 5, "keys the description does not name are kept")
    ok(clean ~= data and clean.items ~= data.items, "a copy, not the input")
    ok(sanitize.check(data, RESPONSE), "check: nothing to repair")
  end

  -- -------------------------------------- the reposcope case: odd items, no crash
  do
    local data = {
      items = {
        { name = "ok", owner = { login = "x" }, description = "d" },
        { owner = { login = "y" } },
        { name = "no-owner" },
        { name = vim.NIL, owner = vim.NIL, description = 7 },
        "not a table",
      },
    }
    local before = vim.inspect(data)
    local clean, ws = sanitize.apply(data, RESPONSE)
    eq(vim.inspect(data), before, "the input is not changed")
    eq(#clean.items, 5, "every item keeps its place")
    eq(clean.items[2].name, "No name", "missing name -> placeholder")
    eq(clean.items[2].description, "No description", "optional description with default is filled")
    eq(
      clean.items[3].owner.login,
      "Unknown",
      "a missing owner object is built, its required field filled"
    )
    eq(clean.items[4].name, "No name", "null name")
    eq(clean.items[4].owner.login, "Unknown", "null owner")
    eq(clean.items[4].description, "No description", "wrong-typed optional -> its default")
    eq(clean.items[5].name, "No name", "a string where an item was expected -> placeholder item")
    eq(clean.total_count, 0, "optional field with default is filled silently")
    eq(clean.items[1], data.items[1], "a good item is unchanged")
    eq(codes(ws), {
      "$.items[2].name:missing",
      "$.items[3].owner:missing",
      "$.items[4].description:type",
      "$.items[4].name:missing",
      "$.items[4].owner:missing",
      "$.items[5]:type",
    }, "warnings by path, nested placeholders are not reported again")
    ok(not sanitize.check(data, RESPONSE), "check: repairs needed")
  end

  -- ------------------------------------------------ roots that are not what they should be
  do
    for _, bad in ipairs({ vim.NIL, "text", 42, true, {}, { 1, 2 } }) do
      local clean, ws = sanitize.apply(bad, RESPONSE)
      ok(type(clean) == "table", "a placeholder root for " .. vim.inspect(bad))
      eq(clean.items, {}, "required list is there")
      ok(#ws >= 1, "and reported: " .. vim.inspect(bad))
    end
    local nothing = sanitize.apply(nil, { type = "table" })
    eq(nothing, nil, "an optional absent root stays absent")
  end

  -- --------------------------------------------------------------- optional fields
  do
    local f = { type = "table", fields = { a = { type = "string" }, b = { type = "number" } } }
    local clean, ws = sanitize.apply({ a = 1 }, f)
    eq(clean.a, nil, "optional wrong-typed value without default is dropped")
    eq(codes(ws), { "$.a:type" }, "and reported")
    local c2, w2 = sanitize.apply({}, f)
    eq(c2, {}, "optional absent fields stay absent")
    eq(w2, {}, "silently")
  end

  -- ------------------------------------------------- bounds and enum (the shared schema)
  do
    local BOUNDED = {
      type = "table",
      fields = {
        n = { type = "number", min = 0, max = 10, required = true, default = 5 },
        e = { type = "string", enum = { "a", "b" }, required = true, default = "a" },
        opt = { type = "number", min = 0 },
        t = { type = "table" },
      },
    }
    local clean, ws = sanitize.apply({ n = 11, e = "z", opt = -1, t = { 1 } }, BOUNDED)
    eq(clean.n, 5, "out of bounds: the placeholder")
    eq(clean.e, "a", "off the enum: the placeholder")
    eq(clean.opt, nil, "an optional value out of bounds is dropped")
    eq(
      table.concat(codes(ws), " "),
      "$.e:value $.n:value $.opt:value $.t:type",
      "and each says what was wrong"
    )
    ok(ws[1].message:find("value not allowed", 1, true), "a refused value is not a type error")
    ok(
      ws[4].message:find("expected table, got list", 1, true),
      "a list is no table: " .. ws[4].message
    )

    local kept, none = sanitize.apply({ n = 10, e = "b", opt = 0 }, BOUNDED)
    eq(kept.n, 10, "a bound is inclusive")
    eq(kept.e, "b", "an enum value stays")
    eq(#none, 0, "and nothing is said")

    local _, nan = sanitize.apply(
      { n = 0 / 0 },
      { type = "table", fields = { n = { type = "number" } } }
    )
    eq(nan[1] and nan[1].code, "value", "a NaN is not a number")

    local d = sanitize.apply({}, {
      type = "table",
      fields = {
        n = { type = "number", max = 3, required = true, default = 9 },
      },
    })
    eq(d.n, 0, "a default outside the bounds is ignored like one of the wrong type")
  end

  -- ------------------------------------------------------------------ coerce
  do
    local f = {
      type = "table",
      fields = {
        s = { type = "string", coerce = true },
        n = { type = "number", coerce = true },
        b = { type = "boolean", coerce = true },
        x = { type = "number", coerce = true, required = true, default = -1 },
      },
    }
    local clean, ws = sanitize.apply({ s = 5, n = "2.5", b = "true", x = "abc" }, f)
    eq(clean.s, "5", "number -> string")
    eq(clean.n, 2.5, "numeric string -> number")
    eq(clean.b, true, "'true' -> boolean")
    eq(clean.x, -1, "an unparseable string falls back to the default")
    eq(
      codes(ws),
      { "$.b:coerced", "$.n:coerced", "$.s:coerced", "$.x:type" },
      "coercions are reported"
    )
    -- not asked for: no conversion
    local c2 = sanitize.apply(
      { s = 5 },
      { type = "table", fields = { s = { type = "string", required = true } } }
    )
    eq(c2.s, "", "without coerce a number is a wrong type")
  end

  -- -------------------------------------------------------------- lists
  do
    local f = { type = "list", of = { type = "number", required = true, default = 0 } }
    local clean, ws = sanitize.apply({ 1, "x", 3 }, f)
    eq(clean, { 1, 0, 3 }, "a bad element is replaced, positions are kept")
    eq(codes(ws), { "$[2]:type" }, "reported")
    local d = { type = "list", drop_invalid = true, of = { type = "number" } }
    local c2, w2 = sanitize.apply({ 1, "x", 3 }, d)
    eq(c2, { 1, 3 }, "drop_invalid leaves the element out")
    eq(codes(w2), { "$[2]:type" }, "one warning per repair")
    eq(
      sanitize.apply({ a = 1 }, { type = "list", required = true }),
      {},
      "an object where a required list is expected"
    )
    eq(sanitize.apply({ a = 1 }, { type = "list" }), nil, "an optional one is dropped")
    eq(
      sanitize.apply({ 1, 2 }, { type = "list" }),
      { 1, 2 },
      "no element description: kept as they are"
    )
    eq(sanitize.apply({}, { type = "list", required = true }), {}, "an empty table is a list")
    eq(sanitize.apply({}, { type = "table", required = true, fields = {} }), {}, "and an object")
  end

  -- ------------------------------------------------------------ strict, defaults
  do
    local f = { type = "table", strict = true, fields = { a = { type = "string" } } }
    eq(sanitize.apply({ a = "1", z = 2 }, f), { a = "1" }, "strict drops unnamed keys")
    local made = 0
    local g = {
      type = "table",
      required = true,
      fields = {
        l = {
          type = "list",
          required = true,
          default = function()
            made = made + 1
            return { "x" }
          end,
        },
      },
    }
    local c1 = sanitize.apply({}, g)
    local c2 = sanitize.apply({}, g)
    eq(c1.l, { "x" }, "a default function is called")
    ok(c1.l ~= c2.l and made == 2, "a fresh placeholder every time")
    local shared = { "q" }
    local h = { type = "table", fields = { l = { type = "list", default = shared } } }
    local r1 = sanitize.apply({}, h)
    r1.l[1] = "changed"
    eq(shared, { "q" }, "a default value is copied, never shared")
  end

  -- ------------------------------------------------------- warnings: callback, cap, warn=false
  do
    local seen = {}
    local f = {
      type = "list",
      of = { type = "table", fields = { n = { type = "string", required = true } } },
    }
    local data = {}
    for i = 1, 10 do
      data[i] = {}
    end
    local _, ws, dropped = sanitize.apply(data, f, {
      max_warnings = 3,
      on_warning = function(w)
        seen[#seen + 1] = w.path
      end,
    })
    eq(#ws, 3, "recording stops at max_warnings")
    eq(dropped, 7, "the rest is counted")
    eq(#seen, 10, "the callback sees every warning")
    ok(ws[1].message:find("$[1].n", 1, true), "the message names the path")

    local quiet =
      { type = "table", fields = { n = { type = "string", required = true, warn = false } } }
    local c, w2 = sanitize.apply({}, quiet)
    eq(c.n, "", "warn = false still repairs")
    eq(w2, {}, "but does not report")
    -- a throwing callback never breaks the repair
    local c3 = sanitize.apply({}, quiet, {
      on_warning = function()
        error("boom")
      end,
    })
    eq(c3.n, "", "a throwing on_warning is contained")
  end

  -- ------------------------------------------------------- review findings
  do
    -- a null element of an `any` list is left out and says so (no placeholder exists for `any`)
    local c, w = sanitize.apply({ 1, vim.NIL, 3 }, { type = "list", of = {} })
    eq(c, { 1, 3 }, "null element of an any list is left out")
    eq(codes(w), { "$[2]:missing" }, "and reported once")
    -- NaN / infinity are no JSON numbers
    for _, text in ipairs({ "nan", "inf", "-inf", "1e999" }) do
      local n, nw = sanitize.apply(text, { type = "number", coerce = true })
      eq(n, nil, text .. " is not coerced")
      eq(codes(nw), { "$:type" }, text .. " is a wrong type")
    end
    eq(
      sanitize.apply("12", { type = "number", coerce = true }),
      12,
      "an ordinary numeric string is"
    )
    -- a recursive description over required children stops instead of overflowing the stack
    local fields = {}
    local node = { type = "table", required = true, fields = fields }
    fields.child = node
    local ok_rec, res = pcall(sanitize.apply, {}, node)
    ok(ok_rec, "recursive description does not overflow: " .. tostring(res))
    -- a default that raises or has the wrong type falls back to the neutral value
    local bad = {
      type = "table",
      fields = {
        a = {
          type = "string",
          required = true,
          default = function()
            error("boom")
          end,
        },
        n = { type = "number", required = true, default = "x" },
      },
    }
    local cb = sanitize.apply({}, bad)
    eq(cb.a, "", "raising default function")
    eq(cb.n, 0, "default of the wrong type")
  end

  -- --------------------------------------------------------------- programmer errors
  do
    ok(not pcall(sanitize.apply, {}, "nope"), "a description that is no table is an error")
    ok(not pcall(sanitize.apply, {}, { type = "strnig" }), "an unknown type is an error")
  end

  -- ----------------------------------------------------------- linear in the data
  do
    local items = {}
    for i = 1, 50000 do
      items[i] = (i % 3 == 0) and {} or { name = "n" .. i, owner = { login = "l" } }
    end
    local t0 = vim.uv.hrtime()
    local clean, ws, dropped = sanitize.apply({ items = items }, RESPONSE)
    ok((vim.uv.hrtime() - t0) / 1e9 < 5, "50000 items in a few seconds")
    eq(#clean.items, 50000, "all items kept")
    eq(#ws + dropped >= 16666, true, "all repairs counted")
  end
end
