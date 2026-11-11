-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read, a uv handle -- this file must crash and name it. The nil
-- guards LuaLS asks for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
---@diagnostic disable: missing-fields
-- The command-callback tables built here carry only the fields the composer
-- actually reads; a full Lib.UserCommand.Args per case would be noise.
-- TESTS/composer_spec.lua — lib.nvim.bindings.usercmd.composer
--
-- Covers the whole pipeline headlessly: tree build/walk, argument coercion,
-- the completion engine, dispatch (happy + error paths via an injected
-- synchronous notifier), custom types, and docgen (render + file round-trip).

return function(H)
  local eq, ok = H.eq, H.ok

  local composer = require("lib.nvim.bindings.usercmd.composer")
  local tree = require("lib.nvim.bindings.usercmd.composer.tree")
  local parse = require("lib.nvim.bindings.usercmd.composer.parse")
  local complete = require("lib.nvim.bindings.usercmd.composer.complete")
  local argtypes = require("lib.nvim.bindings.usercmd.composer.argtypes")
  local docgen = require("lib.nvim.bindings.usercmd.composer.docgen")
  local format = require("lib.nvim.bindings.usercmd.composer.format")

  -- Every internal + the aggregator path loads.
  for _, mod in ipairs({
    "lib.nvim.bindings.usercmd.composer",
    "lib.nvim.bindings.usercmd.composer.tree",
    "lib.nvim.bindings.usercmd.composer.parse",
    "lib.nvim.bindings.usercmd.composer.complete",
    "lib.nvim.bindings.usercmd.composer.argtypes",
    "lib.nvim.bindings.usercmd.composer.docgen",
    "lib.nvim.bindings.usercmd.composer.registry",
    "lib.nvim.bindings.usercmd.composer.format",
    "lib.nvim.bindings.usercmd.composer.flags",
    "lib.nvim.bindings.usercmd.composer.kv",
  }) do
    ok(require(mod) ~= nil, "loads: " .. mod)
  end
  -- A backtick in a path lead is a command substitution to Vim's wildcard
  -- expansion (a directory named "x`touch m`" would run it on the next <Tab>):
  -- PATH/DIR/FILE completion must not hand such a lead to getcompletion().
  do
    local asked = {}
    H.with_patched(vim.fn, "getcompletion", function(lead, kind)
      asked[#asked + 1] = lead .. "|" .. kind
      return { "from-getcompletion" }
    end, function()
      for _, type_name in ipairs({ "PATH", "DIR", "FILE" }) do
        local def = argtypes.get(type_name)
        eq(
          vim.deep_equal(def.complete("./x`touch marker`/s"), {}),
          true,
          type_name .. " completion: a lead with a backtick completes to nothing"
        )
        eq(
          vim.deep_equal(def.complete("./plain"), { "from-getcompletion" }),
          true,
          type_name .. " completion: a normal lead still completes"
        )
      end
    end)
    eq(#asked, 3, "path completion: getcompletion ran for the three normal leads only")
  end

  eq(type(require("lib").composer.verb), "function", "aggregator: lib.composer.verb wired")
  eq(
    type(require("lib").usercmd.composer.verb),
    "function",
    "aggregator: lib.usercmd.composer wired"
  )

  -- ---------------------------------------------------------------- spec fixture
  ---@type Lib.UserCmd.Composer.Spec
  local spec = {
    desc = "Demo verb",
    default = function()
      return "DEFAULT"
    end,
    routes = {
      {
        path = { "buffer" },
        desc = "on buffer",
        run = function()
          return "BUFFER"
        end,
      },
      {
        path = { "count" },
        args = { { name = "n", type = "INT" } },
        run = function(ctx)
          return ctx.args.n
        end,
      },
      {
        path = { "cwd" },
        args = { { name = "root", type = "STRING", optional = true, default = "HERE" } },
        run = function(ctx)
          return ctx.args.root
        end,
      },
      {
        path = { "surround" },
        args = {
          { name = "kind", type = "STRING", enum = { "quote", "paren", "brace" } },
          { name = "target", type = "STRING" },
        },
        run = function(ctx)
          return ctx.args.kind .. "/" .. ctx.args.target
        end,
      },
    },
  }
  local root = tree.build(spec.routes)

  -- ------------------------------------------------------------------ tree walk
  do
    local node, consumed = tree.walk(root, { "surround", "quote", "x" })
    eq(consumed, 1, "walk: consumes only the literal 'surround'")
    ok(node.route ~= nil, "walk: lands on the surround route")
    local n2, c2 = tree.walk(root, { "nope" })
    eq(c2, 0, "walk: unknown token consumes nothing")
    ok(n2.route == nil, "walk: unknown token stays at root (no route)")
  end

  -- ---------------------------------------------------------------- arg coercion
  do
    local okc, v = argtypes.validate("42", { name = "n", type = "INT" })
    ok(okc, "INT: '42' validates")
    eq(v, 42, "INT: coerces to number 42")
    eq(type(v), "number", "INT: result is a number, not a string")
    local bad = argtypes.validate("nope", { name = "n", type = "INT" })
    ok(not bad, "INT: 'nope' rejected")
    local eok, ev = argtypes.validate("Quote", { name = "k", enum = { "quote", "paren" } })
    ok(eok and ev == "quote", "enum: case-insensitive match normalizes to canonical value")
    ok(
      not (argtypes.validate("zzz", { name = "k", enum = { "quote" } })),
      "enum: non-member rejected"
    )
    ok(argtypes.validate("anything", { name = "p", type = "STRING" }), "STRING: accepts any token")

    -- WINDOW: ids are opaque, so validation is the only guard against a typo'd
    -- one reaching a handler that would then raise deep inside nvim_win_*.
    local spec_win = vim.api.nvim_get_current_win()
    local wok, wv = argtypes.validate(tostring(spec_win), { name = "w", type = "WINDOW" })
    ok(wok, "WINDOW: a live window id validates")
    eq(wv, spec_win, "WINDOW: coerces to the numeric id")
    ok(
      not (argtypes.validate("999999", { name = "w", type = "WINDOW" })),
      "WINDOW: a non-existent id is rejected"
    )
    ok(
      not (argtypes.validate("nope", { name = "w", type = "WINDOW" })),
      "WINDOW: a non-numeric token is rejected"
    )
    ok(
      vim.tbl_contains(argtypes.complete("", { name = "w", type = "WINDOW" }), tostring(spec_win)),
      "WINDOW: completion offers the live window ids"
    )
  end

  -- ----------------------------------------------------------------- completion
  local function join(t)
    return table.concat(t, ",")
  end
  do
    local function comp(lead, line)
      return join(complete.candidates(root, lead, line))
    end
    eq(
      comp("", "Demo "),
      "buffer,count,cwd,surround",
      "complete: root lists all subcommands, sorted"
    )
    eq(comp("s", "Demo s"), "surround", "complete: prefix filter")
    eq(comp("", "Demo surround "), "quote,paren,brace", "complete: enum arg of surround")
    eq(comp("q", "Demo surround q"), "quote", "complete: enum arg prefix-filtered")
    eq(comp("", "Demo count "), "", "complete: INT arg has no candidates")
    eq(comp("", "Demo buffer "), "", "complete: no args past a leaf with no schema")
  end

  -- A route.check gates its own literal out of the offered subcommands, the
  -- same check checkhealth already surfaces -- so `<Tab>` never advertises a
  -- subcommand that would immediately fail with "not installed".
  do
    local checked_root = tree.build({
      {
        path = { "ui", "lazygit" },
        check = function()
          return true
        end,
        run = function() end,
      },
      {
        path = { "ui", "neogit" },
        check = function()
          return false, "neogit is not installed"
        end,
        run = function() end,
      },
      {
        path = { "ui", "diffview" },
        check = function()
          error("boom")
        end,
        run = function() end,
      },
      { path = { "ui", "status" }, run = function() end },
    })
    eq(
      join(complete.candidates(checked_root, "", "Demo ui ")),
      "diffview,lazygit,status",
      "complete: a route.check returning false drops its literal; a throwing check fails open; a route with no check always stays"
    )
  end

  -- route.available gates completion exactly like route.check does, but --
  -- unlike route.check -- must NEVER be read by check.results/checkhealth:
  -- it exists precisely for a route whose backend is one of several
  -- interchangeable optional ones, where one being absent was already
  -- designed to be informational rather than an error (gitsuite.nvim's
  -- `:Git ui neogit`/`:Git ui lazygit` is the motivating case -- see its own
  -- usrcmds.lua). A route.check that fails here would wrongly surface as a
  -- checkhealth error for something the caller never meant to be a hard
  -- requirement; route.available must not repeat that mistake.
  do
    local available_root = tree.build({
      {
        path = { "ui", "neogit" },
        available = function()
          return false
        end,
        run = function() end,
      },
      { path = { "ui", "diffview" }, run = function() end },
    })
    eq(
      join(complete.candidates(available_root, "", "Demo ui ")),
      "diffview",
      "complete: route.available returning false drops its literal, same as route.check"
    )

    -- Required locally: the `check` local further below in this file is
    -- declared later in this same function body, not in scope yet here.
    local results = require("lib.nvim.bindings.usercmd.composer.check").results(available_root)
    ok(
      #results == 2 and results[1].ok and results[2].ok,
      "check.results: route.available is never consulted -- both routes report ok regardless of it"
    )
  end

  -- Root route (`path = {}`) coexisting with literal children: the first slot
  -- must offer BOTH, or every value the root route accepts is invisible.
  -- This is open.nvim's `:Open [target] [scope]` next to `:Open viewer …`,
  -- where completing only "viewer" hid all handler names.
  do
    local mixed = tree.build({
      {
        path = {},
        args = {
          {
            name = "target",
            type = "STRING",
            enum = { "browser", "filemanager" },
          },
        },
        run = function() end,
      },
      { path = { "viewer" }, run = function() end },
    })
    local got = join(complete.candidates(mixed, "", "Demo "))
    eq(got, "viewer,browser,filemanager", "complete: literals first, then the root route's own arg")
    eq(
      join(complete.candidates(mixed, "f", "Demo f")),
      "filemanager",
      "complete: root-route arg is prefix-filtered alongside the literals"
    )
    eq(
      join(complete.candidates(mixed, "v", "Demo v")),
      "viewer",
      "complete: a literal still wins its own prefix"
    )
  end

  -- A variadic last arg keeps completing past the declared slots; without it
  -- the completion ends where the schema does (the unchanged default).
  do
    local fields = { "title", "number", "path" }
    argtypes.register("VARIADIC_DEMO_FIELD", {
      validate = function(raw)
        return true, raw, nil
      end,
      complete = function(lead)
        return argtypes.prefix(fields, lead)
      end,
    })
    local function root_with(variadic)
      return tree.build({
        {
          path = { "copy" },
          args = {
            { name = "what", type = "VARIADIC_DEMO_FIELD", optional = true },
            { name = "more", type = "VARIADIC_DEMO_FIELD", optional = true, variadic = variadic },
          },
          flags = { { name = "sep", type = "STRING" } },
          run = function() end,
        },
      })
    end
    local plain, var = root_with(nil), root_with(true)
    eq(
      join(complete.candidates(var, "", "Demo copy title number ")),
      "title,number,path",
      "complete: a variadic last arg is offered for the third token"
    )
    eq(
      join(complete.candidates(var, "p", "Demo copy title number --sep=x p")),
      "path",
      "complete: the variadic arg stays prefix-filtered, flags do not occupy a slot"
    )
    eq(
      join(complete.candidates(var, "", "Demo copy a b c d ")),
      "title,number,path",
      "complete: and for every token after that"
    )
    eq(
      join(complete.candidates(plain, "", "Demo copy title number ")),
      "",
      "complete: without variadic the third token has no candidates"
    )
    eq(
      join(complete.candidates(var, "", "Demo copy ")),
      "title,number,path",
      "complete: the declared slots are unchanged"
    )
    eq(
      format.arg_token({ name = "more", optional = true, variadic = true }),
      "[{more} ...]",
      "format: a variadic arg is shown with a trailing ..."
    )
    eq(
      format.arg_token({ name = "more", optional = true }),
      "[{more}]",
      "format: a plain arg is unchanged"
    )
  end

  -- committed-token extraction (bang + trailing lead handling)
  do
    eq(
      join(complete.committed("Demo! surround ", "")),
      "surround",
      "committed: strips the command word incl. bang"
    )
    eq(
      join(complete.committed("Demo surround qu", "qu")),
      "surround",
      "committed: drops the in-progress lead"
    )
  end

  -- ------------------------------------------------------------------- dispatch
  -- Synchronous capture notifier so error paths are assertable inline.
  local msgs
  local cap = {
    error = function(m)
      msgs.error = m
    end,
    info = function(m)
      msgs.info = m
    end,
  }
  local function dispatch(fargs, extra)
    msgs = {}
    local opts = vim.tbl_extend("force", { fargs = fargs }, extra or {})
    return parse.dispatch("Demo", spec, root, opts, cap)
  end

  eq(dispatch({}), "DEFAULT", "dispatch: bare verb → default handler")
  eq(dispatch({ "buffer" }), "BUFFER", "dispatch: leaf route")
  eq(dispatch({ "count", "7" }), 7, "dispatch: INT arg coerced and passed")
  eq(dispatch({ "cwd" }), "HERE", "dispatch: omitted optional arg uses its default")
  eq(dispatch({ "cwd", "X" }), "X", "dispatch: provided optional arg wins")
  eq(dispatch({ "surround", "paren", "word" }), "paren/word", "dispatch: two positional args")

  dispatch({ "count" })
  ok(
    msgs.error and msgs.error:find("missing required argument"),
    "dispatch: missing required arg → error"
  )
  dispatch({ "count", "nope" })
  ok(msgs.error and msgs.error:find("is not an integer"), "dispatch: bad INT → error with reason")
  dispatch({ "bogus" })
  ok(
    msgs.error and msgs.error:find("unknown subcommand 'bogus'"),
    "dispatch: unknown subcommand → error"
  )

  -- ctx carries bang/range
  spec.routes[1].run = function(ctx)
    return ctx.bang
  end
  local rroot = tree.build(spec.routes)
  msgs = {}
  eq(
    parse.dispatch("Demo", spec, rroot, { fargs = { "buffer" }, bang = true }, cap),
    true,
    "dispatch: ctx.bang reflects the ! form"
  )
  ok(not msgs.error, "dispatch: ctx.bang path produces no error")
  spec.routes[1].run = function()
    return "BUFFER"
  end -- restore

  -- ------------------------------------------------------------------- run resolution
  eq(
    parse.resolve_run(function()
      return 99
    end)(),
    99,
    "resolve_run: passes a function through"
  )
  ok(parse.resolve_run("definitely.not.a.module") == nil, "resolve_run: bad module path → nil")
  do
    local fn, err = parse.resolve_run("definitely.not.a.module")
    ok(fn == nil, "resolve_run: bad module path → nil fn (two-value form)")
    ok(
      type(err) == "string" and err:match("definitely%.not%.a%.module"),
      "resolve_run: bad module path → real require error, not swallowed"
    )
  end
  do
    local fn, err = parse.resolve_run(function() end)
    ok(type(fn) == "function" and err == nil, "resolve_run: a function passes through with nil err")
  end

  -- ---------------------------------------------------------------- custom type
  composer.register_type("SHOUT", {
    validate = function(raw)
      return true, raw:upper(), nil
    end,
    complete = function()
      return { "loud", "louder" }
    end,
  })
  do
    local okc, v = argtypes.validate("hey", { name = "x", type = "SHOUT" })
    ok(okc and v == "HEY", "custom type: validate transforms the value")
    eq(
      join(argtypes.complete("", { name = "x", type = "SHOUT" })),
      "loud,louder",
      "custom type: completion"
    )
  end

  -- ----------------------------------------------------------------------- docgen
  do
    local body = docgen.render({ { name = "Demo", spec = spec, root = root } })
    ok(body:find(":Demo surround {kind} {target}", 1, true), "docgen: renders full invocation")
    ok(body:find("`{kind}` ∈ `quote | paren | brace`", 1, true), "docgen: enum note")
    ok(body:find(":Demo cwd %[{root}%]"), "docgen: optional arg wrapped in [ ]")
    ok(
      body:find("\n> Demo verb\n", 1, true),
      "docgen: the verb description is a quote above the table"
    )

    -- a multi-line description stays one quote
    local multi = vim.deepcopy(spec)
    multi.desc = "first line\nsecond line"
    local mbody = docgen.render({ { name = "Demo", spec = multi, root = root } })
    ok(
      mbody:find("\n> first line\n> second line\n", 1, true),
      "docgen: every line of a multi-line description is quoted"
    )

    -- write round-trip
    local path = H.tmpfile(".md")
    local wok = docgen.write({ { name = "Demo", spec = spec, root = root } }, path, "replace")
    ok(wok, "docgen: write returns ok")
    local content = table.concat(H.read_lines(path), "\n")
    ok(content:find("## :Demo", 1, true), "docgen: file contains the verb section")

    -- section mode preserves surrounding prose
    local spath = H.tmpfile(".md")
    local f = io.open(spath, "w")
    f:write("# Manual\n\nkeep me\n")
    f:close()
    docgen.write({ { name = "Demo", spec = spec, root = root } }, spath, "section")
    local scontent = table.concat(H.read_lines(spath), "\n")
    ok(scontent:find("keep me", 1, true), "docgen section: preserves hand-written prose")
    ok(scontent:find("lib.nvim:composer", 1, true), "docgen section: inserts the delimited block")
  end

  -- --------------------------------------------------------------- flags (Phase 6)
  local flags = require("lib.nvim.bindings.usercmd.composer.flags")

  -- A route WITHOUT declared flags: "--" tokens must NOT be treated specially
  -- (backward-compat guarantee — every pre-Phase-6 route keeps working as-is).
  local no_flags_route = { path = { "x" }, args = { { name = "a", type = "STRING" } } }
  do
    local p, f, err = flags.split(no_flags_route, { "--looks-like-a-flag" })
    eq(err, nil, "flags.split: no declared flags -> no error, ever")
    -- `split` returns the parsed halves or an error, never both and never
    -- neither; asserting that here is what lets the rest read them plainly.
    assert(p and f)
    eq(#p, 1, "flags.split: no declared flags -> tokens pass through untouched")
    eq(p[1], "--looks-like-a-flag", "flags.split: '--' token treated as an ordinary positional")
    eq(next(f), nil, "flags.split: no declared flags -> empty flags table")
  end

  local flag_route = {
    path = {},
    args = { { name = "old", type = "STRING" }, { name = "new", type = "STRING" } },
    flags = {
      { name = "dry", bool = true },
      { name = "type", type = "STRING", repeatable = true },
      { name = "engine", type = "STRING", enum = { "fzf", "telescope" } },
    },
  }

  do
    -- bool flag, inline =value, space-separated value, repeatable collection
    local p, f = flags.split(
      flag_route,
      { "foo", "bar", "--dry", "--type=lua", "--type", "go", "--engine=fzf" }
    )
    assert(p and f)
    eq(
      table.concat(p, ","),
      "foo,bar",
      "flags.split: positionals extracted in order, flags removed"
    )
    eq(f.dry, true, "flags.split: bool flag present -> true")
    eq(
      table.concat(f.type, ","),
      "lua,go",
      "flags.split: repeatable flag collects every occurrence, mixing =value and space-separated forms"
    )
    eq(f.engine, "fzf", "flags.split: enum-valued flag coerced")
  end

  do
    -- flags may appear anywhere, including before positionals
    local p, f = flags.split(flag_route, { "--dry", "foo", "bar" })
    assert(p and f)
    eq(
      table.concat(p, ","),
      "foo,bar",
      "flags.split: flag before positionals doesn't disturb positional order"
    )
    eq(f.dry, true, "flags.split: flag-first form works")
  end

  do
    -- literal "--" stops flag parsing; everything after is positional even if flag-shaped
    local p, f = flags.split(flag_route, { "foo", "--", "--dry", "bar" })
    assert(p and f)
    eq(
      table.concat(p, ","),
      "foo,--dry,bar",
      "flags.split: bare -- stops flag parsing (replacer.nvim's flags_done sentinel)"
    )
    eq(f.dry, nil, "flags.split: --dry after the -- sentinel is NOT parsed as a flag")
  end

  do
    local _, _, err = flags.split(flag_route, { "foo", "bar", "--bogus" })
    ok(
      err and err:find("unknown flag"),
      "flags.split: undeclared flag -> error, not silently positional"
    )
    local _, _, err2 = flags.split(flag_route, { "foo", "bar", "--type" }) -- value-flag with nothing after it
    ok(
      err2 and err2:find("requires a value"),
      "flags.split: value flag with no following token -> error"
    )
    local bool_route = { path = {}, flags = { { name = "dry", bool = true } } }
    local _, _, err3 = flags.split(bool_route, { "--dry=yes" })
    ok(err3 and err3:find("takes no value"), "flags.split: bool flag given =value -> error")
  end

  do
    -- default applied only when the flag was never passed
    local defaulted = { path = {}, flags = { { name = "context", type = "INT", default = 3 } } }
    local _, f = flags.split(defaulted, {})
    eq(f.context, 3, "flags.split: unpassed flag with a default gets it")
    local _, f2 = flags.split(defaulted, { "--context=7" })
    eq(f2.context, 7, "flags.split: passed value overrides the default")
  end

  -- ctx.flags reaches the handler through full dispatch
  do
    local seen
    local spec_with_flags = {
      routes = {
        vim.tbl_extend("force", flag_route, {
          run = function(ctx)
            seen = ctx.flags
          end,
        }),
      },
    }
    local flags_ctx_root = tree.build(spec_with_flags.routes)
    parse.dispatch(
      "FlagsCtx",
      spec_with_flags,
      flags_ctx_root,
      { fargs = { "a", "b", "--dry" } },
      cap
    )
    ok(seen and seen.dry == true, "dispatch: ctx.flags is populated end-to-end")
  end

  -- flags.strip: lenient, used by completion to not miscount positional slots
  do
    eq(
      join(flags.strip(flag_route, { "--dry", "foo" })),
      "foo",
      "flags.strip: bool flag stripped, no value token consumed"
    )
    eq(
      join(flags.strip(flag_route, { "--type", "lua", "foo" })),
      "foo",
      "flags.strip: value flag AND its value token both stripped"
    )
    eq(
      join(flags.strip(no_flags_route, { "--x" })),
      "--x",
      "flags.strip: no declared flags -> passthrough (matches split's backward-compat)"
    )
  end

  -- flags.candidates / completion integration
  do
    local names = flags.candidates(flag_route, "--")
    table.sort(names)
    eq(
      table.concat(names, ","),
      "--dry,--engine,--type",
      "flags.candidates: full --name form, sorted"
    )
    eq(join(flags.candidates(flag_route, "--e")), "--engine", "flags.candidates: prefix filter")
    local vals = flags.candidates(flag_route, "--engine=")
    table.sort(vals)
    eq(
      table.concat(vals, ","),
      "--engine=fzf,--engine=telescope",
      "flags.candidates: enum value completion, full replacement strings"
    )
    eq(
      join(flags.candidates(flag_route, "--dry=")),
      "",
      "flags.candidates: bool flag has no value completion"
    )
    eq(
      join(flags.candidates(no_flags_route, "--")),
      "",
      "flags.candidates: no declared flags -> no candidates"
    )
  end

  -- optional_value: `--name` alone is legal, `--name=v` specifies a value,
  -- and the bare form never eats the next token.
  do
    local opt_route = {
      path = {},
      args = { { name = "old", type = "STRING" }, { name = "scope", type = "STRING" } },
      flags = {
        { name = "changed", type = "STRING", optional_value = true },
        { name = "dry", bool = true },
      },
    }

    local p, f, err = flags.split(opt_route, { "foo", "--changed", "cwd" })
    eq(err, nil, "optional_value: a bare flag is not an error")
    assert(p and f)
    eq(f.changed, true, "optional_value: bare form binds true, not a string")
    eq(
      table.concat(p, ","),
      "foo,cwd",
      "optional_value: the bare form leaves the following token a positional"
    )

    local p2, f2 = flags.split(opt_route, { "foo", "--changed=staged,modified", "cwd" })
    assert(p2 and f2)
    eq(f2.changed, "staged,modified", "optional_value: inline =value binds the value")
    eq(table.concat(p2, ","), "foo,cwd", "optional_value: inline form leaves positionals alone")

    -- The contrast that motivates the flavor: a plain value flag IS greedy,
    -- so the same command line would swallow the scope.
    local plain_route = vim.deepcopy(opt_route)
    plain_route.flags[1].optional_value = nil
    local p3, f3, err3 = flags.split(plain_route, { "foo", "--changed", "cwd" })
    eq(err3, nil, "control: a plain value flag accepts a space-separated value")
    assert(p3 and f3)
    eq(f3.changed, "cwd", "control: ... by consuming the next token")
    eq(table.concat(p3, ","), "foo", "control: ... which is why the positional is gone")

    -- bare_value: the bare form binds a declared value instead of `true`; the inline form still wins.
    local bv_route = {
      path = {},
      args = {},
      flags = {
        { name = "file", type = "STRING", optional_value = true, bare_value = "%" },
        {
          name = "many",
          type = "STRING",
          optional_value = true,
          bare_value = "cur",
          repeatable = true,
        },
      },
    }
    local _, bf, berr = flags.split(bv_route, { "--file" })
    eq(berr, nil, "bare_value: a bare flag is not an error")
    assert(bf)
    eq(bf.file, "%", "bare_value: the bare form binds the declared value")
    local _, bf2 = flags.split(bv_route, { "--file=a,b" })
    assert(bf2)
    eq(bf2.file, "a,b", "bare_value: the inline form binds the typed value")
    local _, bf3 = flags.split(bv_route, { "--many", "--many=x" })
    assert(bf3)
    eq(table.concat(bf3.many, ","), "cur,x", "bare_value: repeatable mixes bare and inline forms")
    local _, bf4 = flags.split(bv_route, {})
    assert(bf4)
    eq(bf4.file, nil, "bare_value: a flag never passed stays unset")

    eq(
      format.flag_token({ name = "changed", type = "STRING", optional_value = true }),
      "[--changed[=<value>]]",
      "optional_value: docgen nests the brackets, not documenting the bare form as an error"
    )
  end

  -- end-to-end completion: flag-name and enum-value slots on a real route tree
  do
    local flags_comp_root =
      tree.build({ vim.tbl_extend("force", flag_route, { run = function() end }) })
    local function comp(lead, line)
      return complete.candidates(flags_comp_root, lead, line)
    end
    local top = comp("--e", "FlagsComp --e")
    eq(join(top), "--engine", "complete.candidates: flag-name completion routed through the engine")
    -- A bare "--" must list every flag, not nothing: it is the keystroke at
    -- which a user asks what the route accepts. (A committed "--" is still
    -- the end-of-options separator -- that is flags.split's business, and it
    -- is reached by typing a space, never by completing.)
    local bare = comp("--", "FlagsComp --")
    table.sort(bare)
    eq(
      table.concat(bare, ","),
      "--dry,--engine,--type",
      "complete.candidates: a bare '--' lists every declared flag"
    )
    local vals = comp("--engine=", "FlagsComp --engine=")
    table.sort(vals)
    eq(
      table.concat(vals, ","),
      "--engine=fzf,--engine=telescope",
      "complete.candidates: flag-value completion routed through the engine"
    )
  end

  -- docgen renders flags in the invocation + enum notes
  do
    local flags_doc_root =
      tree.build({ vim.tbl_extend("force", flag_route, { run = function() end }) })
    local body = docgen.render({
      { name = "FlagsDoc", spec = { routes = { flag_route } }, root = flags_doc_root },
    })
    ok(body:find("[--dry]", 1, true), "docgen: bool flag rendered as [--dry]")
    ok(
      body:find("[--type=<value> ...]", 1, true),
      "docgen: repeatable value flag rendered with trailing ..."
    )
    -- Escaped, because this string lands in a table CELL. GitHub splits a row
    -- on its pipes before it parses inline code, so an unescaped member list
    -- would end the invocation cell mid-word and push the description past the
    -- header's column count, where it is dropped. This assertion used to
    -- expect the unescaped form and so protected the bug.
    ok(
      body:find("[--engine=<fzf\\|telescope>]", 1, true),
      "docgen: enum flag renders its member list inline, pipes escaped for the table"
    )
    -- The note line sits BELOW the table, not in a cell, so it keeps the
    -- readable spelling.
    ok(
      body:find("`--engine` ∈ `fzf | telescope`", 1, true),
      "docgen: enum flag gets its own note line"
    )
  end

  -- ------------------------------------------------------- end-to-end registration
  do
    local fired
    composer.verb("ComposerSpecE2E", {
      routes = {
        {
          path = { "go" },
          args = { { name = "n", type = "INT" } },
          run = function(ctx)
            fired = ctx.args.n
          end,
        },
      },
    })
    vim.cmd("ComposerSpecE2E go 5")
    eq(fired, 5, "e2e: real :command registration dispatches and coerces")
    -- completion callback is wired on the real command
    local cc = vim.fn.getcompletion("ComposerSpecE2E ", "cmdline")
    ok(vim.tbl_contains(cc, "go"), "e2e: cmdline completion offers the subcommand")
    pcall(vim.api.nvim_del_user_command, "ComposerSpecE2E")
  end

  -- ------------------------------------------- bare invocation of a root route
  -- Real regression, found migrating markdown.nvim's buffer-local TableView*
  -- commands (all invoked bare in the common case, e.g. plain :TableViewClose):
  -- M.dispatch's `#fargs == 0` branch unconditionally treated bare invocation
  -- as "use spec.default or show usage", completely bypassing a registered
  -- `path = {}` root route even though tree.walk(root, {}) resolves to it
  -- just fine -- a root route with all-optional (or zero) args silently never
  -- fired on the single most common way to call it. diff.nvim's :DiffClear/
  -- :DiffOrig/:DiffExit (already shipped) hit this same gap.
  do
    local fired = "unset"
    composer.verb("ComposerSpecBareRoot", {
      routes = {
        {
          path = {},
          args = { { name = "scope", type = "STRING", optional = true } },
          run = function(ctx)
            fired = ctx.args.scope
          end,
        },
      },
    })
    vim.cmd("ComposerSpecBareRoot")
    eq(
      fired,
      nil,
      "bare invocation of a path={} root route with only optional args dispatches (not the usage fallback)"
    )
    vim.cmd("ComposerSpecBareRoot foo")
    eq(fired, "foo", "the same root route still binds a provided arg normally")
    pcall(vim.api.nvim_del_user_command, "ComposerSpecBareRoot")
  end

  do
    -- Zero declared args at all (e.g. :DiffClear's shape) -- bare invocation
    -- must still reach run(), not just routes with an optional arg slot.
    local fired = false
    composer.verb("ComposerSpecBareRootNoArgs", {
      routes = {
        {
          path = {},
          run = function()
            fired = true
          end,
        },
      },
    })
    vim.cmd("ComposerSpecBareRootNoArgs")
    ok(fired, "bare invocation of a path={} root route with NO declared args still dispatches")
    pcall(vim.api.nvim_del_user_command, "ComposerSpecBareRootNoArgs")
  end

  do
    -- spec.default still takes priority over an also-registered root route
    -- (an unusual combination, but default must win if both exist).
    local which
    composer.verb("ComposerSpecDefaultWins", {
      default = function()
        which = "default"
      end,
      routes = {
        {
          path = {},
          run = function()
            which = "root"
          end,
        },
      },
    })
    vim.cmd("ComposerSpecDefaultWins")
    eq(which, "default", "spec.default still wins over a root route on bare invocation")
    pcall(vim.api.nvim_del_user_command, "ComposerSpecDefaultWins")
  end

  -- route.range must reach the real :command registration (wants_range),
  -- not just spec.range -- a route declaring `range = true` with no
  -- verb-level spec.range previously registered a range-less command.
  -- (Invoking a live range like `:1,2Cmd` from vim.cmd is a separate,
  -- pre-existing Neovim quirk unrelated to composer -- reproduces even for
  -- a bare `:command -range Foo` + `:1,2Foo`, so range plumbing is checked
  -- via the registered command's metadata + a direct dispatch call instead,
  -- the same approach the bang test above already uses.)
  do
    composer.verb("ComposerSpecRange", {
      routes = {
        { path = { "go" }, range = true, run = function() end },
      },
    })
    local def = vim.api.nvim_get_commands({})["ComposerSpecRange"]
    ok(
      def and def.range and def.range ~= "" and def.range ~= false,
      "route.range=true propagates to the real user command (wants_range)"
    )
    pcall(vim.api.nvim_del_user_command, "ComposerSpecRange")
  end

  do
    local captured
    local spec_range = {
      routes = {
        {
          path = { "go" },
          range = true,
          run = function(ctx)
            captured = ctx.range
          end,
        },
      },
    }
    local root2 = tree.build(spec_range.routes)
    parse.dispatch(
      "ComposerSpecRange2",
      spec_range,
      root2,
      { fargs = { "go" }, range = 2, line1 = 5, line2 = 9 },
      cap
    )
    eq(captured.range, 2, "ctx.range.range reaches the handler")
    eq(captured.line1, 5, "ctx.range.line1 reaches the handler")
    eq(captured.line2, 9, "ctx.range.line2 reaches the handler")
  end

  -- ------------------------------------------- ctx.range: visual mode + columns
  -- Best-effort: populated from vim.fn.visualmode()/getpos("'<"/"'>") whenever
  -- opts.range > 0, regardless of whether this exact invocation came from
  -- Visual mode (that distinction is not knowable — see parse.lua's
  -- visual_info() doc comment). A real charwise Visual selection is set up
  -- here so mode/col1/col2 have real, non-nil values to assert against.
  do
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "hello world", "second line" })
    vim.api.nvim_win_set_cursor(0, { 1, 1 }) -- col 2 (1-based)
    vim.cmd("normal! v")
    vim.api.nvim_win_set_cursor(0, { 1, 6 }) -- col 7
    vim.cmd("normal! \27") -- <Esc>, sets '< '> without leaving a pending op

    local captured
    local spec_visual = {
      routes = {
        {
          path = { "go" },
          range = true,
          run = function(ctx)
            captured = ctx.range
          end,
        },
      },
    }
    local root3 = tree.build(spec_visual.routes)
    parse.dispatch(
      "ComposerSpecVisual",
      spec_visual,
      root3,
      { fargs = { "go" }, range = 2, line1 = 1, line2 = 1 },
      cap
    )
    eq(captured.mode, "v", "ctx.range.mode: charwise visual reports 'v'")
    eq(captured.col1, 2, "ctx.range.col1: '< mark's column reaches the handler")
    eq(captured.col2, 7, "ctx.range.col2: '> mark's column reaches the handler")
  end

  do
    -- Linewise reports MAXCOL as col2 (Vim's "to end of line" sentinel), not a
    -- real column -- verified against a live selection, and documented on
    -- RangeInfo, since a caller slicing with it would otherwise be surprised.
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd("normal! Vj\27")

    local captured
    local spec_lw = {
      routes = {
        {
          path = { "go" },
          range = true,
          run = function(ctx)
            captured = ctx.range
          end,
        },
      },
    }
    parse.dispatch(
      "ComposerSpecLinewise",
      spec_lw,
      tree.build(spec_lw.routes),
      { fargs = { "go" }, range = 2, line1 = 1, line2 = 2 },
      cap
    )
    eq(captured.mode, "V", "ctx.range.mode: linewise visual reports 'V'")
    ok(captured.col2 >= 2147483647, "ctx.range.col2: linewise reports Vim's MAXCOL sentinel")
  end

  do
    -- Blockwise (CTRL-V) is the third submode and must be distinguishable.
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    vim.cmd("normal! \22jll\27")

    local captured
    local spec_bw = {
      routes = {
        {
          path = { "go" },
          range = true,
          run = function(ctx)
            captured = ctx.range
          end,
        },
      },
    }
    parse.dispatch(
      "ComposerSpecBlockwise",
      spec_bw,
      tree.build(spec_bw.routes),
      { fargs = { "go" }, range = 2, line1 = 1, line2 = 2 },
      cap
    )
    eq(captured.mode, "\22", "ctx.range.mode: blockwise visual reports CTRL-V")
  end

  do
    -- opts.range == 0 (no range given) must NOT populate mode/col1/col2, even
    -- though the marks above are still set from the previous block -- this is
    -- exactly the "stale marks" case the doc comment warns about, and the
    -- guard (opts.range > 0) is what keeps a plain `:Verb` call from
    -- reporting misleading Visual info it never asked for.
    local captured
    local spec_no_range = {
      routes = {
        {
          path = { "go" },
          run = function(ctx)
            captured = ctx.range
          end,
        },
      },
    }
    local root4 = tree.build(spec_no_range.routes)
    parse.dispatch(
      "ComposerSpecNoRange",
      spec_no_range,
      root4,
      { fargs = { "go" }, range = 0 },
      cap
    )
    eq(
      captured.mode,
      nil,
      "ctx.range.mode: nil when no range was given, even with stale marks present"
    )
    eq(captured.col1, nil, "ctx.range.col1: nil when no range was given")
    eq(captured.col2, nil, "ctx.range.col2: nil when no range was given")
  end

  -- ------------------------------------------------------- count prefix (:N Verb)
  -- Same "route-level opt-in must reach the real registration" shape as
  -- range/bang above (Phase 8, added for fileops.nvim's `:N File next`).
  do
    local captured_count
    composer.verb("ComposerSpecCount", {
      count = 0,
      routes = {
        {
          path = { "go" },
          run = function(ctx)
            captured_count = ctx.range.count
          end,
        },
      },
    })
    vim.cmd("5ComposerSpecCount go")
    eq(captured_count, 5, "count=0 registers a :N Verb prefix that reaches ctx.range.count")
    vim.cmd("ComposerSpecCount go")
    eq(captured_count, 0, "omitted count prefix falls back to spec.count's default")
    pcall(vim.api.nvim_del_user_command, "ComposerSpecCount")
  end

  do
    composer.verb("ComposerSpecRouteCount", {
      routes = { { path = { "go" }, count = 3, run = function() end } },
    })
    local ok_call = pcall(function()
      vim.cmd("7ComposerSpecRouteCount go")
    end)
    ok(
      ok_call,
      "route.count=3 (no spec.count) still propagates to the real user command (wants_count)"
    )
    pcall(vim.api.nvim_del_user_command, "ComposerSpecRouteCount")
  end

  -- ------------------------------------------------------- buffer-local commands
  do
    local buf1 = vim.api.nvim_create_buf(false, true)
    local buf2 = vim.api.nvim_create_buf(false, true)
    local fired_in

    vim.api.nvim_set_current_buf(buf1)
    composer.verb("ComposerSpecBufLocal", {
      buffer = true,
      routes = {
        {
          path = { "go" },
          run = function()
            fired_in = vim.api.nvim_get_current_buf()
          end,
        },
      },
    })

    vim.api.nvim_set_current_buf(buf1)
    ok(
      vim.fn.exists(":ComposerSpecBufLocal") == 2,
      "buffer-local: registered in the buffer it was created in"
    )
    vim.cmd("ComposerSpecBufLocal go")
    eq(fired_in, buf1, "buffer-local: dispatch runs correctly")

    vim.api.nvim_set_current_buf(buf2)
    ok(
      vim.fn.exists(":ComposerSpecBufLocal") == 0,
      "buffer-local: NOT registered in a different buffer"
    )

    vim.api.nvim_set_current_buf(buf1)
    pcall(vim.api.nvim_buf_del_user_command, buf1, "ComposerSpecBufLocal")
    pcall(vim.api.nvim_buf_delete, buf1, { force = true })
    pcall(vim.api.nvim_buf_delete, buf2, { force = true })
  end

  -- --------------------------------------------------------------- short flags
  local short_route = {
    path = {},
    args = { { name = "query", type = "STRING" } },
    flags = {
      { name = "replace", short = "r", bool = true },
      { name = "output", short = "o", type = "STRING" },
    },
  }

  do
    local p, f = flags.split(short_route, { "foo", "-r" })
    eq(join(p), "foo", "short flag: bool -r extracted, positional untouched")
    eq(f.replace, true, "short flag: -r resolves to the long name (replace)")
  end
  do
    local p, f = flags.split(short_route, { "foo", "-o", "out.txt" })
    eq(join(p), "foo", "short flag: value -o consumes the next token")
    eq(f.output, "out.txt", "short flag: -o resolves to the long name (output)")
  end
  do
    local p, f = flags.split(short_route, { "-r", "foo", "--output=out2.txt" })
    eq(join(p), "foo", "short flag: mixes with long --flag=value in the same call")
    eq(f.replace, true, "short + long mix: short flag value")
    eq(f.output, "out2.txt", "short + long mix: long flag value")
  end
  do
    -- Lenient: an unrecognized short-shaped token (no matching FlagSpec.short)
    -- is left as an ordinary positional, not an error (e.g. a negative number).
    local p, _, err = flags.split(short_route, { "-5", "foo" })
    eq(err, nil, "short flag: unrecognized -x is not an error")
    eq(join(p), "-5,foo", "short flag: unrecognized -x stays positional")
  end
  do
    local names = flags.candidates(short_route, "-")
    table.sort(names)
    eq(table.concat(names, ","), "-o,-r", "short flag: bare '-' completes every declared short")
  end
  do
    local short_doc_root =
      tree.build({ vim.tbl_extend("force", short_route, { run = function() end }) })
    local body = docgen.render({
      { name = "ShortFlagDoc", spec = { routes = { short_route } }, root = short_doc_root },
    })
    -- `\|`, not `|`: this is the exact shape that cost sandbox.nvim sixteen
    -- command descriptions -- present in the file, dropped by the renderer.
    ok(
      body:find("[--replace\\|-r]", 1, true),
      "docgen: short flag rendered alongside the long name, pipe escaped"
    )
  end

  -- --------------------------------------------------------------- kv (key=value)
  local kv = require("lib.nvim.bindings.usercmd.composer.kv")
  local kv_route = {
    path = {},
    kv = {
      { key = "target", type = "STRING" },
      { key = "view", type = "STRING", enum = { "vsplit", "split" }, default = "vsplit" },
    },
  }

  do
    local p, v = kv.split(kv_route, { "foo", "target=bar.txt", "view=split" })
    eq(join(p), "foo", "kv: declared key=value pairs extracted, positional untouched")
    eq(v.target, "bar.txt", "kv: target value coerced")
    eq(v.view, "split", "kv: enum-constrained value coerced")
  end
  do
    -- Lenient: an undeclared key=value-shaped token is left as an ordinary
    -- positional, not an error -- "=" is common in real positional values.
    local p, _, err = kv.split(kv_route, { "foo=bar", "baz" })
    eq(err, nil, "kv: undeclared key=value is not an error")
    eq(join(p), "foo=bar,baz", "kv: undeclared key=value stays positional")
  end
  do
    local _, _, err = kv.split(kv_route, { "view=floating" })
    ok(err and err:find("expected one of"), "kv: bad enum value -> error")
  end
  do
    local _, v = kv.split(kv_route, {})
    eq(v.view, "vsplit", "kv: default applied when the key is never passed")
  end
  do
    local names = kv.candidates(kv_route, "")
    table.sort(names)
    eq(table.concat(names, ","), "target=,view=", "kv: empty prefix offers every declared key")
    eq(join(kv.candidates(kv_route, "vi")), "view=", "kv: prefix filter on the key name")
    local vals = kv.candidates(kv_route, "view=")
    table.sort(vals)
    eq(table.concat(vals, ","), "view=split,view=vsplit", "kv: value completion for a declared key")
  end

  -- kv + flags + positionals together, through real dispatch and a real
  -- :command (proves the flags.split -> kv.split -> bind_args chain in parse.lua).
  do
    local seen
    composer.verb("ComposerSpecKvFlags", {
      routes = {
        {
          path = {},
          args = { { name = "name", type = "STRING" } },
          kv = { { key = "view", type = "STRING", enum = { "vsplit", "split" } } },
          flags = { { name = "verbose", short = "v", bool = true } },
          run = function(ctx)
            seen = { name = ctx.args.name, view = ctx.kv.view, verbose = ctx.flags.verbose }
          end,
        },
      },
    })
    vim.cmd("ComposerSpecKvFlags myfile view=split -v")
    eq(seen.name, "myfile", "kv+flags+positional: positional arg reaches the handler")
    eq(seen.view, "split", "kv+flags+positional: kv value reaches the handler")
    eq(seen.verbose, true, "kv+flags+positional: short flag reaches the handler")

    local cc = vim.fn.getcompletion("ComposerSpecKvFlags ", "cmdline")
    table.sort(cc)
    ok(vim.tbl_contains(cc, "view="), "kv+flags+positional: cmdline completion offers the kv key")
    pcall(vim.api.nvim_del_user_command, "ComposerSpecKvFlags")
  end

  -- ------------------------------------------------------- route.visual allowlist
  do
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "hello world", "second line" })

    ---Select lines l1..l2 with `keys`, then dispatch a route declaring `allow`.
    ---@return string|nil err  nil when the invocation was let through
    local function try(keys, allow, l1, l2)
      vim.api.nvim_win_set_cursor(0, { 1, 1 })
      vim.cmd("normal! " .. keys)
      local ran = false
      local spec_v = {
        routes = {
          {
            path = { "go" },
            range = true,
            visual = allow,
            run = function()
              ran = true
            end,
          },
        },
      }
      local visual_msgs = {}
      parse.dispatch(
        "ComposerSpecVisualGuard",
        spec_v,
        tree.build(spec_v.routes),
        { fargs = { "go" }, range = 2, line1 = l1, line2 = l2 },
        {
          error = function(m)
            visual_msgs[#visual_msgs + 1] = m
          end,
          info = function() end,
        }
      )
      return (not ran) and (visual_msgs[1] or "rejected") or nil
    end

    -- Marks span exactly the invoked range -> the allowlist is enforced.
    eq(try("vlll\27", { "charwise" }, 1, 1), nil, "route.visual: matching charwise passes")
    ok(
      try("vlll\27", { "linewise" }, 1, 1) ~= nil,
      "route.visual: charwise selection is rejected by a linewise-only route"
    )
    eq(try("Vj\27", { "linewise" }, 1, 2), nil, "route.visual: matching linewise passes")
    eq(
      try("\22jll\27", { "charwise", "blockwise" }, 1, 2),
      nil,
      "route.visual: blockwise passes a list naming it"
    )
    ok(
      try("\22jll\27", { "linewise" }, 1, 2) ~= nil,
      "route.visual: blockwise is rejected by a linewise-only route"
    )
    -- Vim's own spellings are accepted interchangeably with the friendly names.
    eq(try("vlll\27", { "v" }, 1, 1), nil, "route.visual: raw 'v' spelling is accepted")

    do
      local err = try("vlll\27", { "linewise", "blockwise" }, 1, 1)
      ok(
        err and err:match("blockwise or linewise") and err:match("got charwise"),
        "route.visual: the rejection names both what was wanted and what arrived"
      )
    end

    -- The conservative half: marks that do NOT span the invoked range are
    -- stale evidence, so the guard stays out of the way rather than refusing.
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    vim.cmd("normal! vlll\27") -- charwise marks on line 1
    do
      local ran = false
      local spec_v = {
        routes = {
          {
            path = { "go" },
            range = true,
            visual = { "linewise" },
            run = function()
              ran = true
            end,
          },
        },
      }
      parse.dispatch(
        "ComposerSpecVisualStale",
        spec_v,
        tree.build(spec_v.routes),
        { fargs = { "go" }, range = 2, line1 = 1, line2 = 2 }, -- != the marks
        cap
      )
      ok(ran, "route.visual: a typed range that the marks don't describe is let through")
    end

    -- A route with no allowlist is unaffected, and an allowlist of nothing
    -- recognizable is treated as a spec bug rather than refusing every call.
    eq(try("vlll\27", nil, 1, 1), nil, "route.visual: absent allowlist never rejects")
    eq(try("vlll\27", { "nonsense" }, 1, 1), nil, "route.visual: unrecognized entries never reject")
  end

  do
    -- spec.visual is the verb-level default for routes declaring none.
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    vim.cmd("normal! vlll\27")
    local ran = false
    local spec_v = {
      visual = { "linewise" },
      routes = {
        {
          path = { "go" },
          range = true,
          run = function()
            ran = true
          end,
        },
      },
    }
    local visual_msgs = {}
    parse.dispatch(
      "ComposerSpecVisualSpec",
      spec_v,
      tree.build(spec_v.routes),
      { fargs = { "go" }, range = 2, line1 = 1, line2 = 1 },
      {
        error = function(m)
          visual_msgs[#visual_msgs + 1] = m
        end,
        info = function() end,
      }
    )
    ok(not ran and visual_msgs[1], "spec.visual: applies to a route that declares none of its own")
  end

  -- ------------------------------------------------------------------ check()
  local check = require("lib.nvim.bindings.usercmd.composer.check")

  do
    -- A route whose run is a function always resolves; a route whose run is a
    -- broken module path is exactly the case that used to surface only as
    -- "no runnable handler" on first dispatch.
    local root_c = tree.build({
      { path = { "good" }, run = function() end },
      { path = { "broken" }, run = "definitely.not.a.module" },
    })
    local results = check.results(root_c)
    eq(#results, 2, "check.results: one entry per route")

    local by_path = {}
    for _, r in ipairs(results) do
      by_path[table.concat(r.path, " ")] = r
    end
    eq(by_path.good.ok, true, "check.results: a function run resolves")
    eq(by_path.good.err, nil, "check.results: a passing route carries no err")
    eq(by_path.broken.ok, false, "check.results: an unloadable module path fails")
    ok(
      type(by_path.broken.err) == "string"
        and by_path.broken.err:match("definitely%.not%.a%.module"),
      "check.results: reports the REAL require error, not a generic message"
    )
  end

  do
    -- route.check: passing, failing, and throwing.
    local root_c = tree.build({
      {
        path = { "pass" },
        run = function() end,
        check = function()
          return true
        end,
      },
      {
        path = { "fail" },
        run = function() end,
        check = function()
          return false, "docker not on PATH"
        end,
      },
      {
        path = { "throws" },
        run = function() end,
        check = function()
          error("boom")
        end,
      },
      {
        path = { "bare-false" },
        run = function() end,
        check = function()
          return false
        end, -- no message supplied
      },
    })
    local by_path = {}
    for _, r in ipairs(check.results(root_c)) do
      by_path[table.concat(r.path, " ")] = r
    end

    eq(by_path.pass.ok, true, "route.check: returning true passes")
    eq(by_path.fail.ok, false, "route.check: returning false fails")
    eq(by_path.fail.err, "docker not on PATH", "route.check: its own message is surfaced verbatim")
    eq(by_path.throws.ok, false, "route.check: a throwing check fails instead of propagating")
    ok(
      by_path.throws.err:match("^check%(%) errored: "),
      "route.check: a thrown error is labeled distinctly from an honest false return"
    )
    eq(by_path["bare-false"].ok, false, "route.check: bare false (no message) still fails")
    ok(
      type(by_path["bare-false"].err) == "string",
      "route.check: bare false gets a fallback message rather than a nil err"
    )
  end

  do
    -- A broken `run` short-circuits: route.check is not consulted, since the
    -- handler is unreachable regardless of what its dependency check says.
    local called = false
    local root_c = tree.build({
      {
        path = { "x" },
        run = "definitely.not.a.module",
        check = function()
          called = true
          return true
        end,
      },
    })
    local r = check.results(root_c)[1]
    eq(r.ok, false, "check.results: unresolvable run fails regardless of route.check")
    eq(called, false, "check.results: route.check is skipped when run cannot resolve")
  end

  do
    eq(#check.results(tree.build({})), 0, "check.results: a verb with no routes yields no entries")
  end

  do
    -- handle:check() and composer.check_all() go through the same results().
    local handle = composer.verb("ComposerSpecCheck", {
      routes = {
        { path = { "ok" }, run = function() end },
        { path = { "bad" }, run = "definitely.not.a.module" },
      },
    })
    local hres = handle:check()
    eq(#hres, 2, "handle:check(): returns this verb's route results")

    local all = composer.check_all()
    ok(all.ComposerSpecCheck ~= nil, "composer.check_all(): includes a registered verb by name")
    eq(#all.ComposerSpecCheck, 2, "composer.check_all(): carries the same per-route entries")
    pcall(vim.api.nvim_del_user_command, "ComposerSpecCheck")
  end

  do
    -- checkhealth must not throw for an unregistered verb name — it reports.
    -- vim.health's functions are only valid inside a real :checkhealth run, so
    -- they're stubbed here to capture calls instead.
    local real = vim.health
    local calls = {}
    ---@diagnostic disable-next-line: inject-field
    vim.health = {
      start = function(s)
        calls[#calls + 1] = { "start", s }
      end,
      ok = function(s)
        calls[#calls + 1] = { "ok", s }
      end,
      error = function(s)
        calls[#calls + 1] = { "error", s }
      end,
      info = function(s)
        calls[#calls + 1] = { "info", s }
      end,
      warn = function(s)
        calls[#calls + 1] = { "warn", s }
      end,
    }
    -- check.lua caches the shim at require time, so re-require it fresh.
    package.loaded["lib.nvim.bindings.usercmd.composer.check"] = nil
    local check_stubbed = require("lib.nvim.bindings.usercmd.composer.check")

    check_stubbed.checkhealth("NoSuchVerbRegisteredAnywhere")
    local kinds = {}
    for _, c in ipairs(calls) do
      kinds[#kinds + 1] = c[1]
    end
    ok(vim.tbl_contains(kinds, "start"), "checkhealth: opens a section even for an unknown verb")
    ok(
      vim.tbl_contains(kinds, "error"),
      "checkhealth: unregistered verb reports an error, not a crash"
    )

    calls = {}
    composer.verb("ComposerSpecHealthEmpty", { routes = {} })
    check_stubbed.checkhealth("ComposerSpecHealthEmpty")
    local kinds2 = {}
    for _, c in ipairs(calls) do
      kinds2[#kinds2 + 1] = c[1]
    end
    ok(
      vim.tbl_contains(kinds2, "info"),
      "checkhealth: a route-less verb reports info, not an empty (placeholder) section"
    )
    pcall(vim.api.nvim_del_user_command, "ComposerSpecHealthEmpty")

    vim.health = real
    package.loaded["lib.nvim.bindings.usercmd.composer.check"] = nil
  end

  -- ------------------------------------------------- registry attribution
  --
  -- A verb is created BY the composer FOR its caller, so `usercmd.create`'s
  -- default call site records this library rather than the owner. Everything
  -- that asks "who registers :Foo?" -- checkhealth, generated docs, the
  -- nvim-config's `:Bindings check` -- reads that field, and got the answer
  -- "lib.nvim" for every verb in the process until `register` passed `src`.
  do
    local usercmd = require("lib.nvim.bindings.usercmd")

    ---@param name string
    ---@return string
    local function src_of(name)
      local r = usercmd.registered({ name = name })[1]
      ok(r ~= nil, "registry has a record for :" .. name)
      return ((r.src or ""):gsub("\\", "/"))
    end

    composer.verb("ComposerSpecSrcDirect", { routes = {} })
    local direct = src_of("ComposerSpecSrcDirect")
    ok(
      direct:find("composer_spec") ~= nil,
      "verb(): the record names the declaring file, not the composer -- got " .. direct
    )
    ok(
      direct:find("composer/init%.lua") == nil,
      "verb(): the record does not name lib.nvim's own composer"
    )

    -- The builder reaches `register` one frame deeper than `verb(name, spec)`
    -- does. A counted stack level would be right for exactly one of the two;
    -- this is why the site is walked.
    composer.verb("ComposerSpecSrcBuilder"):build()
    local built = src_of("ComposerSpecSrcBuilder")
    ok(
      built:find("composer_spec") ~= nil,
      "builder:build(): same answer through the longer path -- got " .. built
    )

    -- An explicit `src` still wins: a consumer's own wrapper has the same
    -- problem one layer further out, and this is its way out.
    composer.verb("ComposerSpecSrcExplicit", { routes = {}, src = "owner.lua:1" })
    eq(src_of("ComposerSpecSrcExplicit"), "owner.lua:1", "an explicit spec.src is not overridden")

    for _, n in ipairs({
      "ComposerSpecSrcDirect",
      "ComposerSpecSrcBuilder",
      "ComposerSpecSrcExplicit",
    }) do
      usercmd.delete(n)
    end
  end

  -- ------------------------------------------- docs configuration starts fresh
  do
    local registry = require("lib.nvim.bindings.usercmd.composer.registry")
    local given = { path = "docs/OTHER.md", mode = "append" }
    registry.configure(given)
    eq(registry.docs.path, "docs/OTHER.md", "configure: an option is applied")
    eq(registry.docs.mode, "append", "configure: ...each one")
    eq(given.path, "docs/OTHER.md", "configure: the caller's table is not changed")

    registry.configure({ mode = "replace" })
    eq(
      registry.docs.path,
      "docs/BINDINGS/Usercmds.md",
      "configure: a path left out is back at its default"
    )
    eq(registry.docs.mode, "replace", "configure: the new option applies")

    registry.configure({ path = "docs/OTHER.md" })
    registry.configure(nil)
    eq(registry.docs.path, "docs/BINDINGS/Usercmds.md", "configure(nil): the defaults")
    registry.docs.path = "written"
    registry.configure(nil)
    eq(
      registry.docs.path,
      "docs/BINDINGS/Usercmds.md",
      "configure: writing into docs does not change the defaults"
    )
  end
end
