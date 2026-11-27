-- TESTS/require_installed_spec.lua -- lib.nvim.require.installed: "is the plugin installed?"
-- answered without loading it under lazy.nvim (a stand-in registry and a stand-in lazy loader),
-- and the two catalogues (contextmenu.catalog.available, crossfeature.installed) asking it.

return function(H)
  local ok, eq = H.ok, H.eq
  local req = require("lib.nvim.require")

  local root = vim.fn.tempname():gsub("\\", "/")
  ---Write a plugin checkout `<root>/<repo>/lua/<mod path>/init.lua` that counts its loads.
  ---@param repo string
  ---@param mod string
  ---@return string dir
  local function plugin(repo, mod)
    local dir = root .. "/" .. repo
    local mdir = dir .. "/lua/" .. mod:gsub("%.", "/")
    vim.fn.mkdir(mdir, "p")
    vim.fn.writefile({
      "_G.LIB_SPEC_INSTALLED_LOADS = (_G.LIB_SPEC_INSTALLED_LOADS or 0) + 1",
      "return {}",
    }, mdir .. "/init.lua")
    return dir
  end

  local dir_a = plugin("lazydemo_a.nvim", "lazydemo_a")
  local dir_b = plugin("lazydemo_b.nvim", "lazydemo_b.sub")
  local dir_off = plugin("lazydemo_off.nvim", "lazydemo_off")

  -- A stand-in for lazy.nvim: its registry (`lazy.core.config.plugins`, keyed by repo name,
  -- none on runtimepath) and a loader that loads an unloaded plugin on `require`, as lazy does.
  local saved_cfg = package.loaded["lazy.core.config"]
  package.loaded["lazy.core.config"] = {
    plugins = {
      ["lazydemo_a.nvim"] = { name = "lazydemo_a.nvim", dir = dir_a },
      ["lazydemo_b.nvim"] = { name = "lazydemo_b.nvim", dir = dir_b },
      ["lazydemo_gone.nvim"] = { name = "lazydemo_gone.nvim", dir = root .. "/not-there" },
      ["lazydemo_off.nvim"] = { name = "lazydemo_off.nvim", dir = dir_off, _ = { cond = false } },
    },
  }
  local loaders = package.loaders -- LuaJIT (Lua 5.1)
  local function lazy_loader(name)
    for _, dir in ipairs({ dir_a, dir_b }) do
      local file = dir .. "/lua/" .. name:gsub("%.", "/") .. "/init.lua"
      if vim.fn.filereadable(file) == 1 then
        return loadfile(file)
      end
    end
    return nil
  end
  table.insert(loaders, 2, lazy_loader)

  local function forget()
    for _, m in ipairs({ "lazydemo_a", "lazydemo_b.sub", "lazydemo_gone" }) do
      package.loaded[m] = nil
    end
    _G.LIB_SPEC_INSTALLED_LOADS = nil
  end

  local function done()
    for i, l in ipairs(loaders) do
      if l == lazy_loader then
        table.remove(loaders, i)
        break
      end
    end
    package.loaded["lazy.core.config"] = saved_cfg
    forget()
    require("lib.nvim.contextmenu.catalog").reset()
    require("lib.nvim.crossfeature").reset()
    vim.fn.delete(root, "rf")
  end

  local passed, err = pcall(function()
    forget()

    -- ---------- lib.nvim.require.installed ----------

    ok(req.installed("lazydemo_a", { repo = "lazydemo_a.nvim" }), "listed by repo: installed")
    eq(package.loaded.lazydemo_a, nil, "listed by repo: not loaded")
    eq(_G.LIB_SPEC_INSTALLED_LOADS, nil, "listed by repo: the plugin's code never ran")

    ok(req.installed("lazydemo_b.sub"), "no repo given: found in a listed plugin's lua/")
    eq(package.loaded["lazydemo_b.sub"], nil, "no repo given: not loaded")

    ok(
      not req.installed("lazydemo_gone", { repo = "lazydemo_gone.nvim" }),
      "listed without a directory: not installed"
    )
    ok(
      not req.installed("lazydemo_off", { repo = "lazydemo_off.nvim" }),
      "listed with cond = false (by repo): not installed"
    )
    ok(not req.installed("lazydemo_off"), "listed with cond = false (scan): not installed")
    ok(not req.installed("lazydemo_nowhere"), "unknown module: not installed")
    ok(not req.installed(""), "empty name: not installed")

    package.loaded.lazydemo_a = {}
    ok(req.installed("lazydemo_a"), "already loaded: installed")
    forget()

    ok(req.installed("lib.nvim.require"), "on runtimepath: installed")

    package.preload.lazydemo_preloaded = function()
      return {}
    end
    ok(req.installed("lazydemo_preloaded"), "only a loader knows it: require last")
    package.preload.lazydemo_preloaded = nil
    package.loaded.lazydemo_preloaded = nil

    -- ---------- the catalogues ----------

    local catalog = require("lib.nvim.contextmenu.catalog")
    catalog.reset()
    catalog.register({
      id = "lazydemo_a.open",
      plugin = "lazydemo_a",
      label = "Open the demo",
      group = "open",
      context = { "file" },
      effect = "open",
      requires = { plugins = { "lazydemo_a", "lazydemo_b.sub" } },
    })
    ok((catalog.available("lazydemo_a.open")), "contextmenu.catalog.available: installed")
    eq(_G.LIB_SPEC_INSTALLED_LOADS, nil, "contextmenu.catalog.available: nothing loaded")

    local cf = require("lib.nvim.crossfeature")
    ok(cf.installed("lazydemo_a"), "crossfeature.installed: installed")
    eq(_G.LIB_SPEC_INSTALLED_LOADS, nil, "crossfeature.installed: nothing loaded")
  end)
  done()
  if not passed then
    error(err, 0)
  end
end
