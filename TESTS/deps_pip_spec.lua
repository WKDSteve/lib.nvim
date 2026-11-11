-- TESTS/deps_pip_spec.lua — a tool only pipx/pip can install (lib.nvim.deps.pm.resolve + install.plan)

return function(H)
  local eq, ok = H.eq, H.ok
  local pm = require("lib.nvim.deps.pm")
  local install = require("lib.nvim.deps.install")
  local spec = require("lib.nvim.deps.spec")
  local core = require("lib.nvim.core")

  local brew = pm.get("brew")
  local tool = {
    bin = "a-pip-only-tool-that-does-not-exist",
    required = false,
    why = "Only exists as a Python package.",
    pkg = { pipx = "pip-only-tool", pip = "pip-only-tool" },
  }

  -- ids and definitions
  eq(pm.get("pipx").bin, "pipx", "pm.get: pipx is a known manager")
  eq(pm.get("pip").install[2], "--user", "pm.get: pip installs into the user site")
  ok(
    vim.tbl_contains(pm.ids(), "pipx") and vim.tbl_contains(pm.ids(), "pip"),
    "pm.ids lists pipx and pip"
  )
  ok(pm.detect() == nil or pm.detect().id ~= "pipx", "pm.detect never answers a language manager")

  -- a spec that only declares pipx validates
  local parsed = spec.parse_json(vim.json.encode({
    tools = {
      {
        bin = "whisper-ctranslate2",
        why = "Transcribes audio locally.",
        pkg = { pipx = "whisper-ctranslate2" },
      },
    },
  }))
  eq(#parsed.errors, 0, "spec: a pipx-only pkg map is valid")

  local function with_on_path(names, fn)
    local set = {}
    for _, n in ipairs(names) do
      set[n] = true
    end
    H.with_patched(core, "has_exec", function(name)
      return set[name] == true
    end, fn)
  end

  -- resolve: pipx before pip, both need to be on PATH
  with_on_path({ "pipx", "pip" }, function()
    local m, p = pm.resolve(tool, brew)
    eq(m and m.id, "pipx", "resolve: pipx wins over pip")
    eq(p, "pip-only-tool", "resolve: package name")
  end)
  with_on_path({ "pip" }, function()
    local m = pm.resolve(tool, brew)
    eq(m and m.id, "pip", "resolve: pip when pipx is absent")
  end)
  with_on_path({}, function()
    local m = pm.resolve(tool, brew)
    eq(m, nil, "resolve: nothing on PATH, nothing to run")
  end)

  -- the OS manager wins when the tool declares it
  with_on_path({ "pipx" }, function()
    local both = vim.tbl_extend("force", tool, { pkg = { brew = "brew-name", pipx = "pip-name" } })
    local m, p = pm.resolve(both, brew)
    eq(m and m.id, "brew", "resolve: the OS manager first")
    eq(p, "brew-name", "resolve: the OS package name")
  end)

  -- plan: the pip command is appended, the tool counts as installable
  with_on_path({ "pipx" }, function()
    local plan = install.plan({ tool }, { manager = brew })
    eq(#plan.installable, 1, "plan: a pipx-only tool is installable")
    eq(#plan.unsupported, 0, "plan: ... and not unsupported")
    eq(#plan.commands, 1, "plan: one command")
    eq(pm.render(plan.commands[1]), "pipx install pip-only-tool", "plan: the pipx command")
    eq(#plan.packages, 0, "plan: packages stays the OS manager's list")
  end)
  -- two tools in one pipx package: one command, the package once
  with_on_path({ "pipx" }, function()
    local twin =
      vim.tbl_extend("force", tool, { bin = "another-pip-only-tool-that-does-not-exist" })
    local plan = install.plan({ tool, twin }, { manager = brew })
    eq(#plan.commands, 1, "plan: two tools of one pipx package give one command")
    eq(pm.render(plan.commands[1]), "pipx install pip-only-tool", "plan: the package is named once")
  end)
  with_on_path({}, function()
    local plan = install.plan({ tool }, { manager = brew })
    eq(#plan.unsupported, 1, "plan: without pipx/pip the tool is unsupported")
  end)
end
