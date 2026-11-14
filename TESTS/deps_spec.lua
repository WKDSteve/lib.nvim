-- Test code: when something here comes back nil -- a `pcall(require, ...)`,
-- a fixture read, a uv handle -- this file must crash and name it. The nil
-- guards LuaLS asks for below would hide the very failure it exists to report.
---@diagnostic disable: need-check-nil
-- TESTS/deps_spec.lua — lib.nvim.deps.{spec,pm,install,view,health}
--
-- Covers docs/INSTALL.md (fenced-YAML) and docs/install.json parsing,
-- validation (bin/why/pkg required, required defaults false), load()'s
-- extension dispatch, find()/plugins()' runtimepath lookup, package-manager
-- command composition, install-plan computation, the report renderer, and
-- health.report / health.from_tools not erroring.
--
-- `bin_alternatives` (one tool, several spellings -- `gs` / `gswin64c`) is
-- covered on both sides: the parser accepting and rejecting it, and
-- `deps.detect` resolving through it. `nvim` is the stand-in for "installed"
-- throughout, since it is the one binary a headless spec run can be certain
-- of.
--
-- Package-manager assertions pass an explicit manager rather than using
-- whatever this host has installed, so the suite behaves identically on a
-- CI container and a dev machine. `install.run` is only exercised on its
-- refusal paths — the success path opens a terminal, which a headless run
-- has no business doing.

return function(H)
  local eq, ok = H.eq, H.ok

  local spec = require("lib.nvim.deps.spec")
  local health = require("lib.nvim.deps.health")
  local detect = require("lib.nvim.deps.detect")

  -- ------------------------------------------------------------- parse_markdown
  do
    local text = [[
# Optional tools

Some prose here that isn't a fenced block at all.

```install-tool
bin: pdftotext
required: false
why: "Enables the fast plain-text extraction backend."
pkg:
  apt: poppler-utils
  brew: poppler
```

More prose in between blocks.

```install-tool
bin: tesseract
required: true
why: "Enables OCR extraction for scanned PDFs."
pkg:
  apt: tesseract-ocr
```
]]
    local result = spec.parse_markdown(text)
    eq(#result.tools, 2, "parse_markdown: two install-tool blocks -> two tools")
    eq(#result.errors, 0, "parse_markdown: well-formed blocks -> no errors")

    eq(result.tools[1].bin, "pdftotext", "parse_markdown: tool 1 bin")
    eq(result.tools[1].required, false, "parse_markdown: tool 1 required (explicit false)")
    eq(
      result.tools[1].why,
      "Enables the fast plain-text extraction backend.",
      "parse_markdown: tool 1 why"
    )
    eq(result.tools[1].pkg.apt, "poppler-utils", "parse_markdown: tool 1 pkg.apt")
    eq(result.tools[1].pkg.brew, "poppler", "parse_markdown: tool 1 pkg.brew")

    eq(result.tools[2].bin, "tesseract", "parse_markdown: tool 2 bin")
    eq(result.tools[2].required, true, "parse_markdown: tool 2 required")
  end

  do
    local text = [[
```install-tool
bin: ffmpeg
pkg:
  apt: ffmpeg
```
]]
    local result = spec.parse_markdown(text)
    eq(#result.tools, 0, "parse_markdown: missing why -> no tool produced")
    eq(#result.errors, 1, "parse_markdown: missing why -> exactly one error")
    eq(result.errors[1].field, "why", "parse_markdown: error field is 'why'")

    -- required omitted entirely (as opposed to explicit false above) still
    -- defaults correctly once why/pkg are fixed:
    local text2 =
      text:gsub("bin: ffmpeg", 'bin: ffmpeg\nwhy: "Transcodes audio for the voice-note backend."')
    local result2 = spec.parse_markdown(text2)
    eq(#result2.tools, 1, "parse_markdown: fixed entry now produces a tool")
    eq(result2.tools[1].required, false, "parse_markdown: omitted 'required' defaults to false")
  end

  do
    local text = [[
```install-tool
required: false
why: "No bin given, should fail."
pkg:
  apt: something
```
]]
    local result = spec.parse_markdown(text)
    eq(#result.tools, 0, "parse_markdown: missing bin -> no tool produced")
    ok(#result.errors >= 1, "parse_markdown: missing bin -> at least one error")
  end

  do
    local text = [[
```install-tool
bin: something
why: "No pkg given, should fail."
```
]]
    local result = spec.parse_markdown(text)
    eq(#result.tools, 0, "parse_markdown: missing pkg -> no tool produced")
    local has_pkg_error = false
    for _, e in ipairs(result.errors) do
      if e.field == "pkg" then
        has_pkg_error = true
      end
    end
    ok(has_pkg_error, "parse_markdown: missing pkg -> reports field 'pkg'")
  end

  eq(
    #spec.parse_markdown("just prose, no fenced blocks at all").tools,
    0,
    "parse_markdown: no blocks -> empty tools"
  )

  -- ----------------------------------------------------------------- parse_json
  do
    local text = vim.json.encode({
      tools = {
        {
          bin = "magick",
          required = false,
          why = "Converts SVGs to PNG for terminals that can't decode SVG themselves.",
          pkg = { apt = "imagemagick", brew = "imagemagick" },
        },
      },
    })
    local result = spec.parse_json(text)
    eq(#result.tools, 1, "parse_json: one entry -> one tool")
    eq(#result.errors, 0, "parse_json: well-formed -> no errors")
    eq(result.tools[1].bin, "magick", "parse_json: bin")
    eq(result.tools[1].pkg.brew, "imagemagick", "parse_json: nested pkg map")
  end

  -- bin_alternatives: accepted as a list, and rejected as anything else.
  do
    local result = spec.parse_json(vim.json.encode({
      tools = {
        {
          bin = "gs",
          bin_alternatives = { "gswin64c", "gswin32c" },
          why = "Ghostscript is spelled differently on Windows.",
          pkg = { apt = "ghostscript" },
        },
      },
    }))
    eq(#result.errors, 0, "parse_json: bin_alternatives list -> no errors")
    eq(#result.tools, 1, "parse_json: bin_alternatives list -> tool produced")
    eq(
      table.concat(result.tools[1].bin_alternatives, ","),
      "gswin64c,gswin32c",
      "parse_json: bin_alternatives carried through in order"
    )
  end

  -- A bare string is the way this gets written by mistake, and the one that
  -- would otherwise pass: it iterates as an empty list, so the alternative
  -- would silently never be probed and the tool would keep reporting missing
  -- on the exact platform the field was added for.
  do
    local result = spec.parse_json(vim.json.encode({
      tools = {
        {
          bin = "gs",
          bin_alternatives = "gswin64c",
          why = "Written as a string by mistake.",
          pkg = { apt = "ghostscript" },
        },
      },
    }))
    eq(#result.tools, 0, "parse_json: bin_alternatives as a string -> no tool produced")
    eq(#result.errors, 1, "parse_json: bin_alternatives as a string -> one error")
    eq(
      result.errors[1].field,
      "bin_alternatives",
      "parse_json: the error names the offending field"
    )
  end

  eq(#spec.parse_json(vim.json.encode({
    tools = {
      {
        bin = "gs",
        bin_alternatives = { "gswin64c", "" },
        why = "One alternative is empty.",
        pkg = { apt = "ghostscript" },
      },
    },
  })).tools, 0, "parse_json: an empty string among the alternatives -> rejected")

  -- The Markdown variant carries it too: the YAML subset does block lists,
  -- so this is not a JSON-only field.
  do
    local result = spec.parse_markdown([[
```install-tool
bin: gs
bin_alternatives:
  - gswin64c
  - gswin32c
why: Ghostscript is spelled differently on Windows.
pkg:
  apt: ghostscript
```
]])
    eq(#result.errors, 0, "parse_markdown: bin_alternatives block list -> no errors")
    eq(
      table.concat(result.tools[1].bin_alternatives, ","),
      "gswin64c,gswin32c",
      "parse_markdown: bin_alternatives carried through in order"
    )
  end

  -- paths: a per-platform map of install-location strings, for tools whose
  -- installer never extends PATH (Chrome, LibreOffice, ...).
  do
    local result = spec.parse_json(vim.json.encode({
      tools = {
        {
          bin = "chrome",
          paths = {
            win = { "$PROGRAMFILES\\Google\\Chrome\\Application\\chrome.exe" },
            mac = { "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" },
          },
          why = "Chrome's installer never extends PATH.",
          pkg = { winget = "Google.Chrome" },
        },
      },
    }))
    eq(#result.errors, 0, "parse_json: paths per-platform map -> no errors")
    eq(#result.tools, 1, "parse_json: paths per-platform map -> tool produced")
    eq(
      result.tools[1].paths.win[1],
      "$PROGRAMFILES\\Google\\Chrome\\Application\\chrome.exe",
      "parse_json: paths.win carried through unexpanded"
    )
    eq(
      result.tools[1].paths.mac[1],
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      "parse_json: paths.mac carried through"
    )
  end

  -- Same failure shape as bin_alternatives, one level deeper: a bare string
  -- for one platform's value would otherwise iterate as an empty list and
  -- the tool would keep reporting missing on exactly the platform it was
  -- added to rescue.
  do
    local result = spec.parse_json(vim.json.encode({
      tools = {
        {
          bin = "chrome",
          paths = { win = "not-a-list" },
          why = "Written as a string by mistake.",
          pkg = { winget = "Google.Chrome" },
        },
      },
    }))
    eq(#result.tools, 0, "parse_json: paths.win as a string -> no tool produced")
    eq(#result.errors, 1, "parse_json: paths.win as a string -> one error")
    eq(result.errors[1].field, "paths", "parse_json: the error names the offending field")
  end

  eq(#spec.parse_json(vim.json.encode({
    tools = {
      {
        bin = "chrome",
        paths = { win = { "" } },
        why = "One path entry is empty.",
        pkg = { winget = "Google.Chrome" },
      },
    },
  })).tools, 0, "parse_json: an empty string among paths.win -> rejected")

  eq(
    #spec.parse_json("{not valid json").errors,
    1,
    "parse_json: malformed JSON -> one file-level error"
  )
  eq(
    #spec.parse_json('{"nope": []}').errors,
    1,
    "parse_json: missing 'tools' key -> one file-level error"
  )

  -- ---------------------------------------------------------------------- load
  do
    local md_path = H.tmpfile(".md")
    local f = io.open(md_path, "w")
    f:write('```install-tool\nbin: rg\nwhy: "Fast search backend."\npkg:\n  apt: ripgrep\n```\n')
    f:close()
    local result = spec.load(md_path)
    eq(#result.tools, 1, "load: .md path dispatches to parse_markdown")
    eq(result.tools[1].bin, "rg", "load: .md parsed tool bin")
    os.remove(md_path)

    local json_path = H.tmpfile(".json")
    local jf = io.open(json_path, "w")
    jf:write(vim.json.encode({
      tools = { { bin = "fzf", why = "Fuzzy picker backend.", pkg = { apt = "fzf" } } },
    }))
    jf:close()
    local jresult = spec.load(json_path)
    eq(#jresult.tools, 1, "load: .json path dispatches to parse_json")
    eq(jresult.tools[1].bin, "fzf", "load: .json parsed tool bin")
    os.remove(json_path)

    local missing_result, err = spec.load(H.tmpfile(".md"))
    eq(missing_result, nil, "load: nonexistent file -> nil result")
    ok(err ~= nil, "load: nonexistent file -> error message")
  end

  -- ---------------------------------------------------------------------- find
  do
    eq(
      spec.find("a-plugin-name-that-definitely-does-not-exist.nvim"),
      nil,
      "find: unknown plugin -> nil"
    )

    local base = vim.fn.tempname()
    vim.fn.mkdir(base, "p")
    local plugin_dir = base .. "/some-fixture-plugin.nvim"
    vim.fn.mkdir(plugin_dir .. "/docs", "p")
    local install_path = plugin_dir .. "/docs/install.json"
    local f = io.open(install_path, "w")
    f:write(vim.json.encode({ tools = {} }))
    f:close()

    vim.opt.rtp:prepend(plugin_dir)
    local found = spec.find("some-fixture-plugin.nvim")
    ok(found ~= nil, "find: locates docs/install.json once the plugin dir is on runtimepath")
    if found then
      ok(
        found:gsub("\\", "/"):match("some%-fixture%-plugin%.nvim/docs/install%.json$") ~= nil,
        "find: resolved path shape"
      )
    end
    vim.opt.rtp:remove(plugin_dir)
  end

  -- `find`/`plugins` must NOT recurse into a plugin's subdirectories — see
  -- the "Runtime lookup" correction:
  -- nvim_get_runtime_file("**/docs/install.json", true) did not return
  -- within a minute against a real plugin (mdview.nvim) carrying a
  -- 17k-file node_modules/. Proven here without timing: a spec file nested
  -- one level deeper than a plugin root must NOT be found — a recursive
  -- glob would find it too, so this fails if `**` is ever reintroduced.
  do
    local base = vim.fn.tempname()
    local plugin_dir = base .. "/no-recursion-fixture.nvim"
    vim.fn.mkdir(plugin_dir .. "/some-subdir/docs", "p")
    local f = io.open(plugin_dir .. "/some-subdir/docs/install.json", "w")
    f:write(vim.json.encode({ tools = {} }))
    f:close()

    vim.opt.rtp:prepend(plugin_dir)
    eq(
      spec.find("no-recursion-fixture.nvim"),
      nil,
      "find: a docs/install.json nested below the plugin root is NOT found (non-recursive lookup)"
    )
    local found_it = false
    for _, n in ipairs(spec.plugins()) do
      if n == "no-recursion-fixture.nvim" then
        found_it = true
      end
    end
    ok(not found_it, "plugins: same non-recursive guarantee")
    vim.opt.rtp:remove(plugin_dir)
  end

  -- ------------------------------------------------------------------ plugins
  do
    local base = vim.fn.tempname()
    local plugin_dir = base .. "/plugins-fixture.nvim"
    vim.fn.mkdir(plugin_dir .. "/docs", "p")
    local f = io.open(plugin_dir .. "/docs/install.json", "w")
    f:write(vim.json.encode({ tools = {} }))
    f:close()

    vim.opt.rtp:prepend(plugin_dir)
    local names = spec.plugins()
    local found = false
    for _, n in ipairs(names) do
      if n == "plugins-fixture.nvim" then
        found = true
      end
    end
    ok(found, "plugins: lists a plugin shipping docs/install.json")
    vim.opt.rtp:remove(plugin_dir)
  end

  -- ------------------------------------------------- lazy.nvim (not-yet-loaded)
  -- lazy.nvim only puts a plugin on runtimepath once it actually loads, so a
  -- runtimepath-only lookup misses every pending plugin (measured on a real
  -- config: 120 configured, 44 loaded, 76 pending). These two assertions pin
  -- the fallback that covers them: the fixture below is deliberately NOT on
  -- runtimepath, so it is only findable via lazy's registry.
  do
    local base = vim.fn.tempname()
    local plugin_dir = base .. "/lazy-only-fixture.nvim"
    vim.fn.mkdir(plugin_dir .. "/docs", "p")
    local f = io.open(plugin_dir .. "/docs/install.json", "w")
    f:write(vim.json.encode({
      tools = {
        {
          bin = "ghostbin",
          why = "Only reachable through lazy's registry.",
          pkg = { apt = "ghost" },
        },
      },
    }))
    f:close()

    eq(spec.find("lazy-only-fixture.nvim"), nil, "find: not on runtimepath and no lazy -> nil")

    local had = package.loaded["lazy.core.config"]
    package.loaded["lazy.core.config"] = {
      plugins = { ["lazy-only-fixture.nvim"] = { dir = plugin_dir } },
    }

    local found = spec.find("lazy-only-fixture.nvim")
    ok(found ~= nil, "find: falls back to lazy.nvim's registry for a not-yet-loaded plugin")

    local listed = false
    for _, n in ipairs(spec.plugins()) do
      if n == "lazy-only-fixture.nvim" then
        listed = true
      end
    end
    ok(listed, "plugins: includes not-yet-loaded lazy.nvim plugins")

    -- A registry entry pointing at a plugin with no spec file must not be
    -- listed just because lazy knows about it.
    package.loaded["lazy.core.config"] = { plugins = { ["no-spec.nvim"] = { dir = base } } }
    local spurious = false
    for _, n in ipairs(spec.plugins()) do
      if n == "no-spec.nvim" then
        spurious = true
      end
    end
    ok(not spurious, "plugins: a lazy plugin without a spec file is not listed")

    package.loaded["lazy.core.config"] = had
  end

  -- ------------------------------------------------------------------------ pm
  do
    local pm = require("lib.nvim.deps.pm")

    ok(pm.get("apt") ~= nil, "pm.get: known manager id resolves")
    eq(pm.get("not-a-package-manager"), nil, "pm.get: unknown id -> nil")
    ok(#pm.ids() >= 9, "pm.ids: every known manager is listed")

    -- Composition is asserted against explicit manager definitions rather
    -- than whatever this machine happens to have installed, so the spec
    -- behaves the same on a CI container and a dev laptop.
    local brew = assert(pm.get("brew"), "brew is a known manager id")
    local cmds = pm.commands(brew, { "poppler", "tesseract" })
    eq(#cmds, 1, "pm.commands: multi-capable manager -> one combined command")
    eq(pm.render(cmds[1]), "brew install poppler tesseract", "pm.commands: brew argv")

    local winget = assert(pm.get("winget"), "winget is a known manager id")
    local wcmds = pm.commands(winget, { "A.One", "B.Two" })
    eq(#wcmds, 2, "pm.commands: winget cannot batch -> one command per package")
    eq(pm.render(wcmds[1]), "winget install A.One", "pm.commands: winget first argv")

    eq(#pm.commands(brew, {}), 0, "pm.commands: no packages -> no commands")

    local pac = pm.commands(assert(pm.get("pacman")), { "poppler" })[1]
    ok(
      table.concat(pac, " "):match("pacman %-S %-%-needed poppler$") ~= nil,
      "pm.commands: pacman keeps its own confirmation prompt (no --noconfirm)"
    )

    eq(pm.render({ "a b", "c" }), '"a b" c', "pm.render: quotes only tokens that need it")

    eq(type(pm.is_root()), "boolean", "pm.is_root: always returns a boolean")
    eq(
      pm.needs_terminal(brew),
      false,
      "pm.needs_terminal: brew never needs root -> false regardless of is_root()"
    )
    if not pm.is_root() then
      eq(
        pm.needs_terminal(assert(pm.get("apt"))),
        true,
        "pm.needs_terminal: a root-requiring manager needs a terminal when not already root"
      )
    end
  end

  -- ------------------------------------------------------------------- install
  do
    local deps_install = require("lib.nvim.deps.install")
    local brew = require("lib.nvim.deps.pm").get("brew")

    local tools = {
      -- `nvim` is guaranteed present: this suite runs inside it.
      {
        bin = "nvim",
        required = true,
        why = "The editor this all runs in.",
        pkg = { brew = "neovim" },
      },
      {
        bin = "a-binary-that-does-not-exist-anywhere",
        required = false,
        why = "Enables the hypothetical backend under test.",
        pkg = { brew = "ghost-package" },
      },
      {
        bin = "another-binary-that-does-not-exist",
        required = false,
        why = "Has no brew package declared, so it cannot be installed here.",
        pkg = { apt = "apt-only-package" },
      },
    }

    local plan = deps_install.plan(tools, { manager = brew })
    eq(#plan.present, 1, "plan: one tool already on PATH")
    eq(plan.present[1].bin, "nvim", "plan: present tool is the one that exists")
    eq(#plan.missing, 2, "plan: two tools missing")
    eq(#plan.installable, 1, "plan: only the missing tool with a brew package is installable")
    eq(#plan.unsupported, 1, "plan: the apt-only tool is unsupported under brew")
    eq(plan.packages[1], "ghost-package", "plan: package name comes from the manager's pkg key")
    eq(#plan.commands, 1, "plan: one combined brew command")
    eq(
      require("lib.nvim.deps.pm").render(plan.commands[1]),
      "brew install ghost-package",
      "plan: composed command installs only what's missing and supported"
    )

    -- Two tools, one package (pdftotext + pdftoppm are both poppler-utils).
    -- The command must name the package once; both tools still count as
    -- installable, since the report lists tools rather than packages.
    local shared = deps_install.plan({
      {
        bin = "a-missing-bin-one",
        required = false,
        why = "First half of one package.",
        pkg = { brew = "shared-pkg" },
      },
      {
        bin = "a-missing-bin-two",
        required = false,
        why = "Second half of one package.",
        pkg = { brew = "shared-pkg" },
      },
    }, { manager = brew })
    eq(#shared.installable, 2, "plan: both tools of a shared package are installable")
    eq(#shared.packages, 1, "plan: a package shared by two tools is listed once")
    eq(
      require("lib.nvim.deps.pm").render(shared.commands[1]),
      "brew install shared-pkg",
      "plan: shared package appears once in the composed command"
    )

    local all_present = deps_install.plan({ tools[1] }, { manager = brew })
    eq(#all_present.missing, 0, "plan: nothing missing -> empty missing list")
    eq(#all_present.commands, 0, "plan: nothing missing -> no commands")
    eq(
      deps_install.run(all_present, { confirm = false }),
      false,
      "install.run: nothing to do -> returns false without opening anything"
    )

    -- The no-package-manager plan is built by hand rather than via
    -- `plan(tools, { manager = nil })`: a nil override falls back to
    -- `pm.detect()`, so on any machine that *has* a package manager (this
    -- one included) that call would quietly test the opposite path.
    eq(
      deps_install.run({
        manager = nil,
        present = {},
        missing = { tools[2] },
        installable = {},
        unsupported = { tools[2] },
        packages = {},
        commands = {},
      }, { confirm = false }),
      false,
      "install.run: no package manager -> returns false without opening anything"
    )

    -- A plan whose manager has no package for any missing tool: `run` must
    -- refuse rather than open a terminal with a package-less command.
    local unsupported_only = deps_install.plan({ tools[3] }, { manager = brew })
    eq(#unsupported_only.commands, 0, "plan: only apt-declared tool under brew -> no commands")
    eq(
      deps_install.run(unsupported_only, { confirm = false }),
      false,
      "install.run: nothing installable under this manager -> returns false"
    )

    -- The question is the shared dialog: the terminal opens only after a yes, the return value is
    -- nil while the question is open and on_done says how it ended.
    do
      local dialog = require("lib.nvim.ui.dialog")
      local terminal = require("lib.nvim.terminal")
      local orig_yesno, orig_spawn = dialog.yesno, terminal.spawn
      local answer, asked, spawned = nil, nil, 0
      dialog.yesno = function(question, label, cb)
        asked = { question = question, label = label }
        answer = cb
      end
      terminal.spawn = function()
        spawned = spawned + 1
        return { bufnr = 1 }
      end
      local installable = deps_install.plan({
        { bin = "a-missing-bin-three", required = false, why = "x", pkg = { brew = "pkg-three" } },
      }, { manager = brew })

      local ended = {}
      local function on_done(started)
        ended[#ended + 1] = started
      end
      eq(deps_install.run(installable, { on_done = on_done }), nil, "install.run: nil while asking")
      eq(spawned, 0, "install.run: nothing is opened before the answer")
      eq(asked.label, "open terminal", "install.run: the yes answer names the action")
      answer(false)
      eq(spawned, 0, "install.run: no opens nothing")
      eq(ended[1], false, "install.run: on_done(false) after a no")

      deps_install.run(installable, { on_done = on_done })
      answer(true)
      eq(spawned, 1, "install.run: yes opens the terminal once")
      eq(ended[2], true, "install.run: on_done(true) after a yes")

      eq(
        deps_install.run(installable, { confirm = false, on_done = on_done }),
        true,
        "install.run: without a question the result is the return value"
      )
      eq(ended[3], true, "install.run: ...and on_done ran before it returned")
      dialog.yesno, terminal.spawn = orig_yesno, orig_spawn
    end
  end

  -- ---------------------------------------------------------------------- view
  do
    local view = require("lib.nvim.deps.view")
    local brew = require("lib.nvim.deps.pm").get("brew")

    local result = {
      tools = {
        {
          bin = "a-missing-required-tool",
          required = true,
          why = "Without this the whole feature is unavailable.",
          pkg = { brew = "ghost" },
        },
        {
          bin = "a-missing-optional-tool",
          required = false,
          why = "short",
          pkg = { brew = "ghost2" },
        },
        {
          bin = "nvim",
          required = false,
          why = "The editor this all runs in.",
          pkg = { brew = "neovim" },
        },
      },
      errors = { { index = 2, field = "why", message = "example problem" } },
    }

    local lines = view.lines("fixture.nvim", result, { manager = brew })
    local text = table.concat(lines, "\n")

    ok(text:match("# fixture%.nvim"), "view.lines: titled with the plugin name")
    ok(
      text:match("%[MISSING, required%] a%-missing%-required%-tool"),
      "view.lines: flags a missing required tool"
    )
    ok(text:match("%[ok%] nvim"), "view.lines: marks a present tool as ok")
    ok(
      text:match("Without this the whole feature is unavailable%."),
      "view.lines: shows each tool's why"
    )
    ok(text:match("this 'why' is very short"), "view.lines: nudges on a low-effort why")
    ok(text:match("brew install ghost"), "view.lines: shows the per-tool install command")
    ok(text:match("## Spec problems"), "view.lines: surfaces spec validation errors")

    -- Missing-and-required must be rendered before the merely-missing one,
    -- which must in turn come before anything already installed: the whole
    -- point of the view is finding what isn't there.
    local required_at = text:find("a%-missing%-required%-tool")
    local optional_at = text:find("a%-missing%-optional%-tool")
    local present_at = text:find("%[ok%] nvim")
    ok(required_at < optional_at, "view.lines: required-missing sorts before optional-missing")
    ok(optional_at < present_at, "view.lines: missing sorts before present")

    local empty = view.lines("empty.nvim", { tools = {}, errors = {} }, { manager = brew })
    ok(
      table.concat(empty, "\n"):match("declares no external tools"),
      "view.lines: empty spec says so rather than rendering a bare header"
    )
  end

  -- ---------------------------------------------------- view.render (ui state)
  do
    local view = require("lib.nvim.deps.view")
    local brew = require("lib.nvim.deps.pm").get("brew")
    local result = {
      tools = {
        {
          bin = "ghostbin",
          required = true,
          why = "Testing streamed output.",
          pkg = { brew = "ghost" },
        },
      },
      errors = {},
    }

    -- render(..., {}) must equal lines() exactly: the interactive overlay
    -- must not change anything when nothing is running.
    eq(
      table.concat(view.render("fixture", result, { manager = brew }, {}).lines, "\n"),
      table.concat(view.lines("fixture", result, { manager = brew }), "\n"),
      "view.render: empty ui table renders identically to lines()"
    )

    local ui = { ghostbin = { lines = {}, running = true, done = false, collapsed = false } }
    local running = view.render("fixture", result, { manager = brew }, ui)
    local running_text = table.concat(running.lines, "\n")
    ok(running_text:match("installing…"), "view.render: running state shows an installing marker")
    ok(running_text:match("<CR> to collapse"), "view.render: running+expanded offers to collapse")

    -- line_tools must point back at the right tool for a line inside the
    -- header block, so a keymap can resolve "which tool is the cursor on".
    local header_idx
    for i, l in ipairs(running.lines) do
      if l:match("^%[MISSING") then
        header_idx = i
      end
    end
    ok(header_idx ~= nil, "view.render: found the tool's header line")
    eq(
      running.line_tools[header_idx] and running.line_tools[header_idx].bin,
      "ghostbin",
      "view.render: line_tools maps the header line back to its tool"
    )
    eq(running.line_tools[1], nil, "view.render: line_tools is nil for non-tool lines (the title)")

    ui.ghostbin.lines = { "Downloading...", "Installing..." }
    local with_output =
      table.concat(view.render("fixture", result, { manager = brew }, ui).lines, "\n")
    ok(with_output:match("| Downloading%.%.%."), "view.render: streamed lines appear, expanded")

    ui.ghostbin.collapsed = true
    local collapsed =
      table.concat(view.render("fixture", result, { manager = brew }, ui).lines, "\n")
    ok(not collapsed:match("Downloading"), "view.render: collapsed hides the streamed output")
    ok(collapsed:match("<CR> to expand"), "view.render: collapsed offers to expand")

    ui.ghostbin.running = false
    ui.ghostbin.done = true
    ui.ghostbin.exit_code = 0
    ui.ghostbin.collapsed = false
    local done_text =
      table.concat(view.render("fixture", result, { manager = brew }, ui).lines, "\n")
    ok(done_text:match("exit 0"), "view.render: done state shows the exit code")
    ok(not done_text:match("installing…"), "view.render: done state no longer shows 'installing'")
  end

  -- --------------------------------------------------------------- forget_exec
  -- End-to-end, not just "doesn't error": a binary that genuinely appears on
  -- PATH mid-session must still read as missing until forget_exec clears the
  -- cached miss — this is exactly the gap that made view.lua's inline
  -- install leave a just-installed tool's line stuck on `[missing]`.
  do
    local core = require("lib.nvim.core")
    local is_windows = require("lib.nvim.cross.platform.is_windows")()

    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local name = "fx-forget-exec-probe"
    local bin_path = dir .. "/" .. name .. (is_windows and ".cmd" or "")

    ok(core.has_exec(name) == false, "forget_exec: not yet on PATH -> miss")

    local f = io.open(bin_path, "w")
    f:write(is_windows and "@echo off\r\n" or "#!/bin/sh\nexit 0\n")
    f:close()
    if not is_windows then
      os.execute("chmod +x " .. bin_path)
    end

    local had_path = vim.env.PATH
    vim.env.PATH = dir .. (is_windows and ";" or ":") .. had_path

    ok(
      core.has_exec(name) == false,
      "forget_exec: cached miss survives PATH actually gaining the binary"
    )
    core.forget_exec(name)
    ok(core.has_exec(name) == true, "forget_exec: cleared -> re-probes and finds it")

    vim.env.PATH = had_path
    os.remove(bin_path)
  end

  -- ----------------------------------------------------------------- first_run
  -- The three blocks below test the popup itself, so they need the opt-out
  -- unset. A runner may have set it for every editor it starts (testing.nvim
  -- does, `disable_first_run`); put it back once they are done.
  local ambient_first_run_optout = vim.g.lib_nvim_deps_disable_first_run
  vim.g.lib_nvim_deps_disable_first_run = nil
  do
    local first_run = require("lib.nvim.deps.first_run")
    local cache_dir = vim.fn.tempname()
    local cache = { dir = cache_dir }

    eq(first_run.seen("fx.nvim", cache), false, "first_run.seen: nothing recorded yet -> false")

    -- No spec anywhere on runtimepath: show_once must still mark it seen
    -- (so a plugin with no spec isn't re-resolved via spec.find on every
    -- single startup) and must not open anything (returns false).
    eq(
      first_run.show_once("a-plugin-with-no-spec-fx", { cache = cache }),
      false,
      "show_once: no spec found -> false"
    )
    eq(
      first_run.seen("a-plugin-with-no-spec-fx", cache),
      true,
      "show_once: still marks seen even with nothing to show"
    )

    -- A real fixture plugin dir on rtp, with one MISSING tool -> show_once
    -- must report true (a popup would have opened) exactly once.
    local base = vim.fn.tempname()
    local plugin_dir = base .. "/first-run-fixture.nvim"
    vim.fn.mkdir(plugin_dir .. "/docs", "p")
    local f = io.open(plugin_dir .. "/docs/install.json", "w")
    f:write(vim.json.encode({
      tools = {
        {
          bin = "a-binary-that-should-not-exist-anywhere-fr",
          required = true,
          why = "Fixture for first_run.show_once.",
          pkg = { apt = "ghost" },
        },
      },
    }))
    f:close()
    vim.opt.rtp:prepend(plugin_dir)

    eq(
      first_run.show_once("first-run-fixture.nvim", { cache = cache }),
      true,
      "show_once: a genuinely missing declared tool -> true (would show)"
    )
    eq(first_run.seen("first-run-fixture.nvim", cache), true, "show_once: marks seen after showing")
    eq(
      first_run.show_once("first-run-fixture.nvim", { cache = cache }),
      false,
      "show_once: second call is a no-op"
    )

    first_run.reset("first-run-fixture.nvim", cache)
    eq(first_run.seen("first-run-fixture.nvim", cache), false, "reset: un-marks a single plugin")

    first_run.mark_seen("another-fx.nvim", cache)
    first_run.reset(nil, cache)
    eq(
      first_run.seen("another-fx.nvim", cache),
      false,
      "reset: with no argument clears every plugin"
    )

    vim.opt.rtp:remove(plugin_dir)

    -- ------------------------------------------ corrupt store vs. no store yet
    -- "No file yet" and "the file exists but could not be decoded" must not
    -- collapse into the same silent empty table: the second one still holds
    -- the only copy of which plugins were already dismissed, and the very
    -- next mark_seen/reset would otherwise overwrite it with a near-empty
    -- table -- resetting every plugin's "seen" flag with no trace of why.
    local warnings = {}
    local real_notify = vim.notify
    vim.notify = function(msg, level)
      warnings[#warnings + 1] = { msg = msg, level = level }
    end

    local corrupt_cache_dir = vim.fn.tempname()
    local corrupt_cache = { dir = corrupt_cache_dir }
    vim.fn.mkdir(corrupt_cache_dir, "p")
    local corrupt_path = corrupt_cache_dir .. "/lib.nvim.deps.first_run.json"
    vim.fn.writefile({ "{not valid json" }, corrupt_path)

    eq(
      first_run.seen("whatever.nvim", corrupt_cache),
      false,
      "first_run.seen: a corrupt store still answers false, not an error"
    )
    eq(#warnings, 1, "first_run: a corrupt store is reported once on load")
    eq(
      vim.fn.filereadable(corrupt_path .. ".corrupt"),
      1,
      "first_run: the original bytes survive next to the store"
    )

    -- mark_seen must proceed (not refuse forever behind one broken file);
    -- it overwrites the source with a fresh, well-formed table, which is
    -- safe only because the bytes above were already preserved as .corrupt.
    first_run.mark_seen("after-corruption.nvim", corrupt_cache)
    eq(
      first_run.seen("after-corruption.nvim", corrupt_cache),
      true,
      "first_run: mark_seen recovers cleanly once the store is rewritten"
    )

    -- show_once() must load a corrupt store exactly once per call and reuse
    -- that table for both the "already seen" check and the mark-seen write,
    -- not go through the M.seen()/M.mark_seen() wrappers (each of which
    -- independently calls load_seen) -- otherwise one logical show_once
    -- call would warn twice for a single corrupt-store event.
    warnings = {}
    local show_once_corrupt_dir = vim.fn.tempname()
    local show_once_corrupt_cache = { dir = show_once_corrupt_dir }
    vim.fn.mkdir(show_once_corrupt_dir, "p")
    local show_once_corrupt_path = show_once_corrupt_dir .. "/lib.nvim.deps.first_run.json"
    vim.fn.writefile({ "{not valid json" }, show_once_corrupt_path)

    eq(
      first_run.show_once("a-plugin-with-no-spec-fx", { cache = show_once_corrupt_cache }),
      false,
      "show_once: a corrupt store still resolves cleanly (no spec -> not shown)"
    )
    eq(
      #warnings,
      1,
      "show_once: a corrupt store is reported exactly once per call, not once per internal load"
    )

    vim.notify = real_notify
  end

  -- vim.g opt-out: neither disable path should mark anything seen (so
  -- removing the opt-out later picks up exactly where it left off, not
  -- silently consumed while disabled).
  do
    local first_run = require("lib.nvim.deps.first_run")
    local base = vim.fn.tempname()
    local plugin_dir = base .. "/optout-fixture.nvim"
    vim.fn.mkdir(plugin_dir .. "/docs", "p")
    local f = io.open(plugin_dir .. "/docs/install.json", "w")
    f:write(vim.json.encode({
      tools = {
        {
          bin = "a-binary-that-should-not-exist-anywhere-oo",
          required = true,
          why = "Fixture for the vim.g opt-out.",
          pkg = { apt = "ghost" },
        },
      },
    }))
    f:close()
    vim.opt.rtp:prepend(plugin_dir)

    local cache = { dir = vim.fn.tempname() }

    vim.g.lib_nvim_deps_disable_first_run = true
    eq(
      first_run.show_once("optout-fixture.nvim", { cache = cache }),
      false,
      "show_once: global vim.g opt-out -> false"
    )
    eq(
      first_run.seen("optout-fixture.nvim", cache),
      false,
      "show_once: global opt-out does not mark seen"
    )
    vim.g.lib_nvim_deps_disable_first_run = nil

    vim.g.lib_nvim_deps_disabled_plugins = { "optout-fixture.nvim" }
    eq(
      first_run.show_once("optout-fixture.nvim", { cache = cache }),
      false,
      "show_once: per-plugin vim.g opt-out -> false"
    )
    eq(
      first_run.seen("optout-fixture.nvim", cache),
      false,
      "show_once: per-plugin opt-out does not mark seen"
    )
    -- A different plugin name is unaffected by the per-plugin list.
    eq(
      first_run.show_once("not-in-the-list.nvim", { cache = cache }),
      false,
      "show_once: per-plugin opt-out list does not affect other plugins (no spec -> false anyway)"
    )
    vim.g.lib_nvim_deps_disabled_plugins = nil

    -- Opt-out lifted: show_once now behaves normally again.
    eq(
      first_run.show_once("optout-fixture.nvim", { cache = cache }),
      true,
      "show_once: opt-out removed -> behaves normally again"
    )

    vim.opt.rtp:remove(plugin_dir)
  end

  -- A plugin whose only declared tool is already present -> nothing
  -- actionable, show_once must not report true even though a spec exists.
  do
    local first_run = require("lib.nvim.deps.first_run")
    local cache = { dir = vim.fn.tempname() }

    local base = vim.fn.tempname()
    local plugin_dir = base .. "/all-present-fixture.nvim"
    vim.fn.mkdir(plugin_dir .. "/docs", "p")
    local f = io.open(plugin_dir .. "/docs/install.json", "w")
    -- `nvim` is guaranteed present: this suite runs inside it.
    f:write(vim.json.encode({
      tools = { { bin = "nvim", why = "Always present in this suite.", pkg = { apt = "neovim" } } },
    }))
    f:close()
    vim.opt.rtp:prepend(plugin_dir)

    eq(
      first_run.show_once("all-present-fixture.nvim", { cache = cache }),
      false,
      "show_once: nothing missing -> false even though a spec exists"
    )

    vim.opt.rtp:remove(plugin_dir)
  end
  vim.g.lib_nvim_deps_disable_first_run = ambient_first_run_optout

  -- -------------------------------------------------------------------- detect
  do
    -- Names, canonical first: the order decides which spelling a report
    -- names on a host that happens to have both.
    eq(
      table.concat(detect.names({ bin = "gs", bin_alternatives = { "gswin64c", "gswin32c" } }), ","),
      "gs,gswin64c,gswin32c",
      "detect.names: canonical bin first, then the alternatives in order"
    )
    eq(
      table.concat(detect.names({ bin = "gs" }), ","),
      "gs",
      "detect.names: no alternatives declared -> just the canonical name"
    )
    eq(
      table.concat(detect.names({ bin = "gs", bin_alternatives = { "", "gswin64c" } }), ","),
      "gs,gswin64c",
      "detect.names: an empty alternative is dropped rather than probed"
    )

    -- The case the field exists for: the canonical name is absent and an
    -- alternative is present. Reported as found, and found *as* the name
    -- that actually answered.
    eq(
      detect.found_as({
        bin = "a-binary-name-that-should-not-exist-anywhere",
        bin_alternatives = { "nvim" },
      }),
      "nvim",
      "detect.found_as: falls through to the alternative that exists"
    )
    ok(
      detect.found({
        bin = "a-binary-name-that-should-not-exist-anywhere",
        bin_alternatives = { "nvim" },
      }),
      "detect.found: true when only an alternative is on PATH"
    )
    eq(
      detect.found_as({ bin = "nvim", bin_alternatives = { "also-not-a-real-binary-xyz" } }),
      "nvim",
      "detect.found_as: the canonical name wins when it is there"
    )
    ok(not detect.found({
      bin = "a-binary-name-that-should-not-exist-anywhere",
      bin_alternatives = { "also-not-a-real-binary-xyz" },
    }), "detect.found: false when neither the canonical name nor an alternative exists")
    ok(
      not detect.found({ bin = "a-binary-name-that-should-not-exist-anywhere" }),
      "detect.found: still false with no alternatives declared"
    )

    -- `forget` has to clear every name, not just the canonical one: after an
    -- install it is the alternative that may have appeared.
    detect.forget({ bin = "nvim", bin_alternatives = { "also-not-a-real-binary-xyz" } })
    ok(
      detect.found({ bin = "nvim", bin_alternatives = { "also-not-a-real-binary-xyz" } }),
      "detect.forget: re-probing after a forget still finds the tool"
    )
  end

  -- ------------------------------------------------------------- detect: paths
  --
  -- The Chrome/LibreOffice case: not on PATH under any name, but genuinely
  -- installed at a known location. `vim.v.progpath` stands in for that
  -- location -- this Neovim's own executable, guaranteed to exist on every
  -- platform the suite runs on, so the fixture needs no real Chrome install.
  do
    local this_platform = (vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1) and "win"
      or (vim.fn.has("mac") == 1 and "mac")
      or "linux"
    local other_platform = this_platform == "win" and "mac" or "win"
    local real_exe = vim.v.progpath
    local nonexistent = vim.fn.expand("$LIB_DEPS_SPEC_NOPE") .. "/definitely-does-not-exist"

    eq(
      table.concat(
        detect.candidate_paths({
          bin = "definitely-not-a-real-binary-xyz",
          paths = { [this_platform] = { nonexistent, real_exe } },
        }),
        "\1"
      ),
      table.concat({ vim.fn.expand(nonexistent), vim.fn.expand(real_exe) }, "\1"),
      "detect.candidate_paths: this platform's list, $ENVVAR-expanded, in order"
    )
    eq(#detect.candidate_paths({
      bin = "definitely-not-a-real-binary-xyz",
      paths = { [other_platform] = { real_exe } },
    }), 0, "detect.candidate_paths: another platform's list is not this host's")
    eq(
      #detect.candidate_paths({ bin = "definitely-not-a-real-binary-xyz" }),
      0,
      "detect.candidate_paths: no paths declared -> empty"
    )

    local tool = {
      bin = "definitely-not-a-real-binary-xyz",
      paths = { [this_platform] = { nonexistent, real_exe } },
    }
    eq(
      detect.found_as(tool),
      real_exe,
      "detect.found_as: PATH misses, falls through a non-existent path, lands on the real one"
    )
    ok(detect.found(tool), "detect.found: true via the paths fallback")
    ok(not detect.found({
      bin = "definitely-not-a-real-binary-xyz",
      paths = { [other_platform] = { real_exe } },
    }), "detect.found: a paths entry for a different platform is never tried")

    -- `bin`/`bin_alternatives` still win over `paths` when both would answer
    -- — PATH is tried first, `paths` is a fallback, not an alternate route.
    eq(
      detect.found_as({ bin = "nvim", paths = { [this_platform] = { real_exe } } }),
      "nvim",
      "detect.found_as: PATH still wins over a paths entry, even one that also resolves"
    )

    detect.forget(tool)
  end

  -- An install plan has to route through the same detection, or a tool
  -- present under its Windows spelling would be planned for installation.
  do
    local plan = require("lib.nvim.deps.install").plan({
      {
        bin = "a-binary-name-that-should-not-exist-anywhere",
        bin_alternatives = { "nvim" },
        required = false,
        why = "Present under its alternative name.",
        pkg = { brew = "irrelevant" },
      },
    }, { manager = require("lib.nvim.deps.pm").get("brew") })
    eq(#plan.present, 1, "plan: a tool found under an alternative name counts as present")
    eq(#plan.missing, 0, "plan: and is therefore not planned for installation")
  end

  -- -------------------------------------------------------------------- health
  -- No dedicated assertions on :checkhealth output (no other module in this
  -- suite unit-tests health.lua rendering either) — just confirm neither
  -- entry point errors, including the mixed bin/python_module/missing-both
  -- shapes and the tools-list bridge.
  health.report({
    { bin = "a-binary-name-that-should-not-exist-anywhere", required = false, hint = "n/a" },
    { bin = "a-binary-name-that-should-not-exist-anywhere", required = true, hint = "n/a" },
    { python_module = "a_module_that_should_not_exist", hint = "n/a" },
  })
  -- report_for: no spec anywhere -> must not error (and, being health.lua
  -- output, nothing to assert on beyond that — same posture as report/
  -- from_tools above).
  health.report_for("a-plugin-with-absolutely-no-spec-fx")

  do
    local base = vim.fn.tempname()
    local plugin_dir = base .. "/report-for-fixture.nvim"
    vim.fn.mkdir(plugin_dir .. "/docs", "p")
    local f = io.open(plugin_dir .. "/docs/install.json", "w")
    f:write(vim.json.encode({
      tools = { { bin = "nvim", why = "Always present.", pkg = { apt = "neovim" } } },
    }))
    f:close()
    vim.opt.rtp:prepend(plugin_dir)
    health.report_for("report-for-fixture.nvim")
    vim.opt.rtp:remove(plugin_dir)
  end

  health.from_tools({
    {
      bin = "a-binary-name-that-should-not-exist-anywhere",
      required = false,
      why = "test",
      pkg = { apt = "x" },
    },
    -- Same shape pdfport's ghostscript entry has: reported as found, under
    -- the name that answered.
    {
      bin = "a-binary-name-that-should-not-exist-anywhere",
      bin_alternatives = { "nvim" },
      required = false,
      why = "test alternative",
      pkg = { apt = "x" },
    },
  })

  -- -------------------------------------------------------------------- status
  -- The aggregate view. Two fixture plugins on rtp declare one tool each
  -- plus one they share, which is the case the merge exists for.
  do
    local status = require("lib.nvim.deps.status")
    local base = vim.fn.tempname()

    local function fixture(name, tools)
      local dir = base .. "/" .. name
      vim.fn.mkdir(dir .. "/docs", "p")
      local fh = io.open(dir .. "/docs/install.json", "w")
      fh:write(vim.json.encode({ tools = tools }))
      fh:close()
      vim.opt.rtp:prepend(dir)
      return dir
    end

    local dir_a = fixture("status-fixture-a.nvim", {
      { bin = "shared-tool-fx", why = "A's reason for it.", pkg = { apt = "shared-pkg" } },
      { bin = "only-a-fx", why = "Only A wants this one.", pkg = { apt = "a-pkg" } },
    })
    local dir_b = fixture("status-fixture-b.nvim", {
      {
        bin = "shared-tool-fx",
        required = true,
        why = "B's reason for it.",
        bin_alternatives = { "shared-tool-fx2" },
        pkg = { apt = "shared-pkg", brew = "shared-brew" },
      },
    })

    local collected = status.collect()

    ---@param bin string
    local function tool_named(bin)
      for _, t in ipairs(collected.tools) do
        if t.bin == bin then
          return t
        end
      end
    end

    local shared = tool_named("shared-tool-fx")
    ok(shared, "collect: a tool declared by two plugins is present")
    eq(
      #collected.sources["shared-tool-fx"],
      2,
      "collect: and remembers both declarers rather than the last one"
    )
    -- One line per tool, not per (tool, plugin) pair: a report listing curl
    -- three times buries what else is missing.
    local occurrences = 0
    for _, t in ipairs(collected.tools) do
      if t.bin == "shared-tool-fx" then
        occurrences = occurrences + 1
      end
    end
    eq(occurrences, 1, "collect: merged into a single entry")
    eq(shared.required, true, "collect: required is the strictest claim of any declarer")
    eq(shared.why, "A's reason for it.", "collect: why keeps the first declarer's sentence")
    eq(shared.pkg.brew, "shared-brew", "collect: pkg maps are unioned across declarers")
    eq(shared.pkg.apt, "shared-pkg", "collect: a key declared twice keeps the first")
    ok(
      shared.bin_alternatives and #shared.bin_alternatives == 1,
      "collect: alternatives are unioned — the same program, whoever asked for it"
    )
    ok(shared.see:find("status-fixture-a.nvim", 1, true), "collect: see names the declarers")
    ok(shared.see:find("status-fixture-b.nvim", 1, true), "collect: ... all of them")
    ok(tool_named("only-a-fx"), "collect: a tool only one plugin wants still appears")

    -- The report renders through deps.view unchanged, so this asserts the
    -- wiring rather than the layout.
    local lines = status.lines({ manager = require("lib.nvim.deps.pm").get("apt") })
    local joined = table.concat(lines, "\n")
    ok(joined:find("shared-tool-fx", 1, true), "lines: the merged tool reaches the report")
    ok(joined:find("apt install", 1, true), "lines: with an install command for the given manager")

    vim.opt.rtp:remove(dir_a)
    vim.opt.rtp:remove(dir_b)
  end

  -- -------------------------------------------------------------- require_tool
  -- The failure-moment check. `message` is pure, so the wording is asserted
  -- directly rather than through a notification; `check` runs against a
  -- fixture spec on rtp, with `nvim` again standing in for "installed".
  local require_tool = require("lib.nvim.deps.require_tool")

  do
    local brew = require("lib.nvim.deps.pm").get("brew")

    local lines = require_tool.message("fx.nvim", {
      bin = "some-missing-tool",
      required = false,
      why = "Enables the fast path.",
      pkg = { brew = "some-pkg" },
    }, { manager = brew })
    ok(lines[1]:find("Enables the fast path.", 1, true), "message: leads with the spec's own why")
    ok(
      lines[2]:find("brew install some-pkg", 1, true),
      "message: names the command composed for this host"
    )
    ok(
      lines[3]:find(":Lib deps install fx.nvim", 1, true),
      "message: points at the confirmed install route"
    )

    -- A tool the plugin never declared: still a better line than the
    -- hand-written strings this replaces, just with no reason to give.
    local bare =
      require_tool.message("fx.nvim", { bin = "x", required = false, why = "", pkg = {} })
    eq(#bare, 1, "message: nothing to add when there is no spec entry")
    ok(bare[1]:find("x not found on PATH", 1, true), "message: falls back to a plain line")

    -- Declared, but not for this host's manager. An absent install line
    -- would read as "cannot be installed"; the truth is narrower.
    local elsewhere = require_tool.message("fx.nvim", {
      bin = "y",
      required = false,
      why = "Reason.",
      pkg = { apt = "y-pkg" },
    }, { manager = brew })
    ok(
      elsewhere[2]:find("no package known", 1, true),
      "message: 'no package here' is not 'no package anywhere'"
    )
  end

  do
    local plugin_dir = vim.fn.tempname() .. "/require-tool-fixture.nvim"
    vim.fn.mkdir(plugin_dir .. "/docs", "p")
    local f = io.open(plugin_dir .. "/docs/install.json", "w")
    f:write(vim.json.encode({
      tools = {
        { bin = "nvim", why = "Always present.", pkg = { apt = "neovim" } },
        {
          bin = "a-binary-name-that-should-not-exist-anywhere",
          bin_alternatives = { "nvim" },
          why = "Present under its alternative name.",
          pkg = { apt = "irrelevant" },
        },
        {
          bin = "another-missing-tool-fx",
          why = "Missing everywhere.",
          pkg = { apt = "some-pkg" },
        },
      },
    }))
    f:close()
    vim.opt.rtp:prepend(plugin_dir)
    require_tool.reset()

    eq(
      require_tool.check("require-tool-fixture.nvim", "nvim"),
      "nvim",
      "check: a present tool answers with the name it was found under"
    )
    -- The reason this returns a name rather than a boolean: the caller has
    -- to know which spelling to spawn.
    eq(
      require_tool.check(
        "require-tool-fixture.nvim",
        "a-binary-name-that-should-not-exist-anywhere"
      ),
      "nvim",
      "check: bin_alternatives decide the name handed back"
    )
    eq(
      require_tool.check("require-tool-fixture.nvim", "another-missing-tool-fx", { silent = true }),
      nil,
      "check: a missing tool answers nil"
    )

    -- The throttle is a burst guard, not a mute: a second check inside the
    -- window still answers, it just doesn't report twice.
    local notified = 0
    local real_notify = vim.notify
    vim.notify = function()
      notified = notified + 1
    end
    require_tool.reset()
    require_tool.check("require-tool-fixture.nvim", "another-missing-tool-fx")
    require_tool.check("require-tool-fixture.nvim", "another-missing-tool-fx")
    eq(notified, 1, "check: a burst of identical failures reports once")
    require_tool.reset("require-tool-fixture.nvim")
    require_tool.check("require-tool-fixture.nvim", "another-missing-tool-fx")
    eq(notified, 2, "check: reset makes the pair reportable again")
    require_tool.check("require-tool-fixture.nvim", "another-missing-tool-fx", { throttle_ms = 0 })
    eq(notified, 3, "check: throttle_ms = 0 disables the guard")
    vim.notify = real_notify

    -- `lines` is the same wording by binary name and without notifying, for
    -- the failure paths that hand their error upwards instead of showing it.
    local by_name = require_tool.lines("require-tool-fixture.nvim", "another-missing-tool-fx")
    ok(
      by_name[1]:find("Missing everywhere.", 1, true),
      "lines: resolves the spec entry from a bare bin name"
    )

    -- Before a plugin ships a spec at all: still answers, still no error —
    -- so a call site can move over first and declare its tools afterwards.
    eq(
      require_tool.check("a-plugin-with-absolutely-no-spec-fx", "nvim", { silent = true }),
      "nvim",
      "check: works without any spec"
    )

    vim.opt.rtp:remove(plugin_dir)
    require_tool.reset()
  end
end
