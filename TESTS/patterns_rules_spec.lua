-- TESTS/patterns_rules_spec.lua -- the rules-vault rules (rulesets/lua) applied to the pattern modules, one block per rule family.
-- Each block is a property of the whole collection (every module), so a new module is checked without a new test.
-- Decisions where a rule and the concept disagree are recorded in the vault: tasks-vault/lib.nvim/handovers/pattern-regelabgleich-ergebnis-2026-11-01.md.
return function(H)
  local eq, ok = H.eq, H.ok

  local ROOTS = { "lua/lib/lua/patterns", "lua/lib/nvim/patterns" }

  ---@param path string
  ---@return string|nil
  local function read(path)
    local f = io.open(path, "rb")
    if not f then
      return nil
    end
    local text = f:read("*a")
    f:close()
    return text
  end

  ---All pattern modules: name, require path, init source and @types source.
  local function modules()
    local out = {}
    for _, root in ipairs(ROOTS) do
      local req = root:sub(5):gsub("/", ".")
      for name, kind in vim.fs.dir(root) do
        if kind == "directory" then
          out[#out + 1] = {
            name = name,
            req = req .. "." .. name,
            dir = root .. "/" .. name,
            src = read(root .. "/" .. name .. "/init.lua") or "",
            types = read(root .. "/" .. name .. "/@types/init.lua") or "",
          }
        end
      end
    end
    table.sort(out, function(a, b)
      return a.req < b.req
    end)
    return out
  end

  ---Collect a failure per module instead of stopping at the first, so one run shows every offender.
  local function collect()
    local bad = {}
    return bad, function(msg)
      bad[#bad + 1] = msg
    end
  end

  local function none(bad, what)
    ok(#bad == 0, what .. ": " .. table.concat(bad, "; "))
  end

  local failed = {}
  ---Run one rule block; a failure is recorded and the next block still runs, so one run lists every red rule.
  ---@param block fun()
  local function section(block)
    local pok, err = pcall(block)
    if not pok then
      failed[#failed + 1] = tostring(err)
    end
  end

  local mods = modules()
  ok(#mods >= 34, "the collection was found (" .. #mods .. " modules)")

  -- ------------------------------------------------------------------ LLS-*
  section(function()
    -- `fun(...): any, name: T` in a @field reads `name: T` as a second return value, the parameter is lost and
    -- LuaLS reports `redundant-parameter` on the definition
    local bad, add = collect()
    for _, m in ipairs(mods) do
      for line in (m.types .. "\n"):gmatch("([^\n]*)\n") do
        if
          line:match("^%-%-%-@field") and line:match("%b()%s*:%s*[%w_.|<>%[%]]+,%s*[%w_]+%??%s*:")
        then
          add(m.name .. ": " .. line:gsub("%s+", " "))
        end
      end
    end
    none(bad, "LLS: a function type before another parameter must be parenthesised")

    -- the whole collection is clean under LuaLS (`vim` is not declared in this repo's .luarc.json: noise)
    if vim.fn.executable("lua-language-server") == 1 then
      local out = vim.fn.tempname() .. ".json"
      local logdir = vim.fn.tempname()
      for _, root in ipairs(ROOTS) do
        vim
          .system({
            "lua-language-server",
            "--check",
            root,
            "--checklevel=Hint",
            "--check_format=json",
            "--check_out_path=" .. out,
            "--logpath=" .. logdir,
            "--metapath=" .. logdir .. "/meta",
          }, { text = true })
          :wait(120000)
        local text = read(out)
        if text and text ~= "" then
          local found = vim.json.decode(text)
          local diag = {}
          for file, list in pairs(found) do
            for _, d in ipairs(list) do
              if d.code ~= "undefined-global" then
                diag[#diag + 1] = ("%s:%d %s"):format(
                  file:match("[^/]+/[^/]+$"),
                  d.range.start.line + 1,
                  d.code
                )
              end
            end
          end
          ok(#diag == 0, "LLS: no new diagnostics in " .. root .. ": " .. table.concat(diag, "; "))
        end
      end
    else
      print("n/a  LuaLS check (lua-language-server is not installed)")
    end
  end)

  -- ------------------------------------------------------------------ CMT-02
  section(function()
    -- every `self.<field>` an instance method reads or writes is declared as @field of the class
    local bad, add = collect()
    for _, m in ipairs(mods) do
      -- `state` builds its method set from the spec: its @types file documents that there is no fixed class
      if m.types:find("---@field", 1, true) then
        local declared = {}
        for name in m.types:gmatch("%-%-%-@field%s+([%a_][%w_]*)") do
          declared[name] = true
        end
        local seen = {}
        for name in m.src:gmatch("self%.([%a_][%w_]*)") do
          if not declared[name] and not seen[name] then
            seen[name] = true
            add(m.name .. ".self." .. name)
          end
        end
      end
    end
    none(bad, "CMT-02: a field used on self is declared in @types")

    -- the optional store primitives `repository` probes are part of the Store class
    local repo = nil
    for _, m in ipairs(mods) do
      if m.name == "repository" then
        repo = m
      end
    end
    ok(
      repo and repo.types:find("---@field each", 1, true),
      "CMT-02: Store declares the optional each"
    )
    ok(
      repo and repo.types:find("---@field count", 1, true),
      "CMT-02: Store declares the optional count"
    )
  end)

  -- ------------------------------------------------------------------ ERR-02
  section(function()
    -- a callback that is stored and called later fails far from its cause: it is rejected where it is passed
    local function raises(fn, ...)
      return not pcall(fn, ...)
    end
    local bus = require("lib.lua.patterns.event_bus").new()
    ok(
      raises(bus.on, bus, "t", "not a function"),
      "ERR-02 event_bus.on: listener must be a function"
    )
    ok(raises(bus.on, bus, nil, function() end), "ERR-02 event_bus.on: topic must not be nil")
    ok(raises(bus.once, bus, "t", 42), "ERR-02 event_bus.once: listener must be a function")
    local store = require("lib.lua.patterns.reducer").store(function(s)
      return s
    end, 0)
    ok(raises(store.subscribe, store, "x"), "ERR-02 reducer.subscribe: listener must be a function")
    local sm = require("lib.lua.patterns.state_machine").new({ initial = "a" })
    ok(raises(sm.on_change, sm, {}), "ERR-02 state_machine.on_change: listener must be a function")
    local iterator = require("lib.lua.patterns.iterator")
    ok(raises(iterator.from_fn, "x"), "ERR-02 iterator.from_fn: next_fn must be a function")
    local it = iterator.of({ 1, 2 })
    ok(raises(it.map, it, "x"), "ERR-02 iterator.map: fn must be a function")
    ok(raises(it.filter, it, 1), "ERR-02 iterator.filter: pred must be a function")
    local decorator = require("lib.lua.patterns.decorator")
    ok(raises(decorator.before, 1), "ERR-02 decorator.before: hook must be a function")
    ok(raises(decorator.after, 1), "ERR-02 decorator.after: hook must be a function")
    ok(raises(decorator.guard, "x"), "ERR-02 decorator.guard: predicate must be a function")
    ok(
      raises(decorator.guard, function() end, 5),
      "ERR-02 decorator.guard: otherwise must be a function"
    )
    ok(raises(decorator.wrap, "f"), "ERR-02 decorator.wrap: fn must be a function")
    ok(
      raises(decorator.wrap, function() end, "d"),
      "ERR-02 decorator.wrap: decorators must be functions"
    )
    local composite = require("lib.lua.patterns.composite").new()
    ok(raises(composite.add, composite, "leaf"), "ERR-02 composite.add: child must be a table")
  end)

  -- ------------------------------------------------------------------ PERF / SEC (bounded resources)
  section(function()
    -- state: an arbitrary key is not a method; asking for one neither answers with a function nor grows the
    -- dispatcher cache shared by every object
    local state = require("lib.lua.patterns.state")
    local door = state.new({
      initial = "closed",
      states = {
        closed = {
          open = function(self)
            self:set_state("open")
          end,
        },
        open = {},
      },
    })
    eq(door.no_such_method, nil, "SEC state: an unknown key is nil, not a dispatcher")
    ok(door.open ~= nil, "SEC state: a method some state defines is still dispatched")
    for i = 1, 100 do
      local _ = door["probe" .. i]
    end
    eq(door.probe1, nil, "SEC state: probing many keys leaves them unknown")
    ok(
      not pcall(state.new, { initial = "a", states = { a = {} }, fields = { _methods = {} } }),
      "state: _methods is reserved"
    )
  end)

  -- ------------------------------------------------------------------ ERR-02 (second pass: values checked before use)
  section(function()
    local function raises(fn, ...)
      return not pcall(fn, ...)
    end
    ok(
      raises(require("lib.nvim.patterns.throttle").new, "f", 10),
      "ERR-02 throttle.new: fn must be a function"
    )
    local retry = require("lib.nvim.patterns.retry_backoff")
    ok(raises(retry.run, "task"), "ERR-02 retry_backoff.run: task must be a function")
    ok(raises(retry.run, function() end, { sleep = "x" }), "ERR-02 retry_backoff.run: opts.sleep")
    ok(raises(retry.run, function() end, { on_done = 1 }), "ERR-02 retry_backoff.run: opts.on_done")
    ok(
      raises(retry.run, function() end, { should_retry = {} }),
      "ERR-02 retry_backoff.run: opts.should_retry"
    )
    local mediator = require("lib.lua.patterns.mediator").new()
    ok(
      raises(mediator.register, mediator, nil, { handle = function() end }),
      "ERR-02 mediator.register: name"
    )
    local history = require("lib.lua.patterns.command").history()
    ok(raises(history.run, history, "cmd"), "ERR-02 command.run: cmd needs a run function")
    ok(raises(history.run, history, {}), "ERR-02 command.run: cmd.run is required")
    local store = require("lib.lua.patterns.repository").memory()
    local uow = require("lib.lua.patterns.unit_of_work").new(store)
    ok(raises(uow.add, uow, nil, 1), "ERR-02 unit_of_work.add: id must not be nil")
    ok(raises(uow.add, uow, "id", nil), "ERR-02 unit_of_work.add: value must not be nil")
    ok(raises(uow.remove, uow, nil), "ERR-02 unit_of_work.remove: id must not be nil")
    local builder = require("lib.lua.patterns.builder")
    ok(raises(builder.new, "schema"), "ERR-02 builder.new: schema must be a table")
    ok(raises(builder.new, { _values = {} }), "ERR-02 builder.new: _values is reserved")
    ok(raises(builder.new, { _schema = {} }), "ERR-02 builder.new: _schema is reserved")
    local factory = require("lib.lua.patterns.factory_method")
    ok(raises(factory.new, {}, { default = "x" }), "ERR-02 factory_method.new: opts.default")
    ok(
      raises(require("lib.lua.patterns.facade").new, "spec"),
      "ERR-02 facade.new: spec must be a table"
    )
    local breaker = require("lib.lua.patterns.circuit_breaker")
    ok(raises(breaker.new, { now = "clock" }), "ERR-02 circuit_breaker.new: opts.now")
    ok(raises(breaker.new, { on_change = 1 }), "ERR-02 circuit_breaker.new: opts.on_change")
    local di = require("lib.lua.patterns.dependency_injection").new()
    ok(raises(di.provide, di, nil, function() end), "ERR-02 dependency_injection.provide: name")
    ok(raises(di.value, di, nil, 1), "ERR-02 dependency_injection.value: name")

    -- saga: a malformed step is rejected before any step ran (ERR-30: validate before the first side effect)
    local saga = require("lib.lua.patterns.saga")
    local ran = 0
    ok(
      raises(saga.run, {
        {
          name = "a",
          run = function()
            ran = ran + 1
          end,
        },
        { name = "b" },
      }),
      "ERR-02 saga.run: a step without run is rejected"
    )
    eq(
      ran,
      0,
      "ERR-02 saga.run: no step ran before the malformed one was found (validated before the first side effect)"
    )
    ok(raises(saga.run, "steps"), "ERR-02 saga.run: steps must be a list")

    -- ERR-05: a validator that raises is a rejected value, build() keeps its `nil, err` contract
    local make = builder.new({
      n = {
        validate = function(v)
          return v.x > 0
        end,
      },
    })
    local product, err = make():set("n", 1):build()
    eq(product, nil, "ERR-05 builder: a raising validator gives no product")
    ok(
      type(err) == "string" and err:find("n", 1, true),
      "ERR-05 builder: the error names the field"
    )
  end)

  -- ------------------------------------------------------------------ ERR-63 (nil inside a vararg list)
  section(function()
    local decorator = require("lib.lua.patterns.decorator")
    local function id(f)
      return f
    end
    local pok, err = pcall(decorator.wrap, function() end, id, nil, id)
    ok(not pok, "ERR-63 decorator.wrap: a nil decorator is rejected")
    ok(
      tostring(err):find("decorator 2", 1, true),
      "ERR-63 decorator.wrap: the error names the position of the nil (" .. tostring(err) .. ")"
    )
    -- the decorators still compose in order: wrap(fn, d1, d2) == d1(d2(fn))
    local log = {}
    local function tag(name)
      return function(fn)
        return function(...)
          log[#log + 1] = name
          return fn(...)
        end
      end
    end
    decorator.wrap(function() end, tag("d1"), tag("d2"))()
    eq(table.concat(log, ","), "d1,d2", "ERR-63 decorator.wrap: order d1(d2(fn)) is kept")
  end)

  -- ------------------------------------------------------------------ decisions D6/D7 (task pattern-eigenheiten-entscheiden)
  section(function()
    -- result: map_err catches a throw like map does
    local result = require("lib.lua.patterns.result")
    local mapped = result.err("e"):map_err(function()
      error("boom", 0)
    end)
    ok(
      not mapped.ok and mapped.err == "boom",
      "result.map_err: a throw becomes the error of the result"
    )
    eq(result.err("e"):map_err(string.upper).err, "E", "result.map_err still maps the error")

    -- ERR-51: abstract_factory and builder keep their own copy of what they were given
    local abstract_factory = require("lib.lua.patterns.abstract_factory")
    local families = {
      a = {
        box = function()
          return "a"
        end,
      },
      b = {
        box = function()
          return "b"
        end,
      },
    }
    local factory = abstract_factory.new(families)
    families.a.box = nil
    families.c = { other = function() end }
    eq(factory:create("a", "box"), "a", "abstract_factory: a later change to the table is not seen")
    eq(#factory:names(), 2, "abstract_factory: a family added later is not seen")

    local builder = require("lib.lua.patterns.builder")
    local schema = { name = { required = true } }
    local make = builder.new(schema)
    schema.name.required = false
    schema.extra = {}
    local product, err = make():build()
    eq(product, nil, "builder: a later change to the schema does not drop the required check")
    ok(
      type(err) == "string" and err:find("name", 1, true),
      "builder: the required field is reported"
    )
    ok(
      not pcall(make().set, make(), "extra", 1),
      "builder: a field added to the schema later is unknown"
    )
  end)

  -- ------------------------------------------------------------------ CMT-01 (counts and enumerations)
  section(function()
    local text = read("docs/patterns.md") or ""
    local rows = { reuse = 0, impl = 0, idea = 0 }
    local listed = {}
    for stage, rest in text:gmatch("| `(%a+)` | ([^\n]*)") do
      -- the stage legend at the top has the same first column but only two cells
      local cells = select(2, rest:gsub("|", ""))
      if rows[stage] ~= nil and cells >= 3 then
        rows[stage] = rows[stage] + 1
        local mod = rest:match("`lib%.[%a_.]*patterns%.([%a_]+)`")
        if mod then
          listed[mod] = stage
        end
      end
    end
    local total = rows.reuse + rows.impl + rows.idea
    local a, b, c, d = text:match("(%d+) patterns: (%d+) `reuse`, (%d+) `impl`, (%d+) `idea`")
    ok(a ~= nil, "CMT-01: the catalogue states its counts")
    ok(
      vim.deep_equal(
        { tonumber(a), tonumber(b), tonumber(c), tonumber(d) },
        { total, rows.reuse, rows.impl, rows.idea }
      ),
      ("CMT-01: the stated counts equal the rows of the tables (%s)"):format(
        vim.inspect({ a, b, c, d, total, rows })
      )
    )

    local bad, add = collect()
    for _, m in ipairs(mods) do
      local stage = listed[m.name]
      if not stage then
        add(m.name .. " is not in the catalogue")
      elseif stage == "reuse" then
        add(m.name .. " is a module but listed as reuse")
      else
        local readme = read(m.dir .. "/README.md") or ""
        local pool = (m.src .. readme):find("Status: idea pool", 1, true) ~= nil
        if (stage == "idea") ~= pool then
          add(
            m.name
              .. ": catalogue says "
              .. stage
              .. ", module says "
              .. (pool and "idea pool" or "no idea pool")
          )
        end
      end
    end
    none(bad, "CMT-01: modules and catalogue agree")
    -- every `impl`/`idea` row names a module that exists
    local have = {}
    for _, m in ipairs(mods) do
      have[m.name] = true
    end
    local ghosts, gadd = collect()
    for mod, stage in pairs(listed) do
      if stage ~= "reuse" and not have[mod] then
        gadd(mod)
      end
    end
    none(ghosts, "CMT-01: every catalogued module exists")
  end)

  if #failed > 0 then
    error(#failed .. " rule block(s) failed:\n" .. table.concat(failed, "\n"), 0)
  end
  return true
end
