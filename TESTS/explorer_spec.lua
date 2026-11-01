-- TESTS/explorer_spec.lua — lib.nvim.explorer: adapter registry for neo-tree / NvimTree / netrw / oil.
-- No real plugin is installed here: the built-ins are exercised through fake modules in `package.loaded`.

return function(H)
  local eq, ok = H.eq, H.ok
  local explorer = require("lib.nvim.explorer")
  explorer.reset()

  local function names()
    local out = {}
    for _, a in ipairs(explorer.adapters()) do
      out[#out + 1] = a.name
    end
    return table.concat(out, ",")
  end

  local made = {}
  local function buf_with(ft, lines)
    local b = vim.api.nvim_create_buf(false, true)
    made[#made + 1] = b
    vim.api.nvim_set_current_buf(b)
    if lines then
      vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
    end
    vim.bo[b].filetype = ft
    return b
  end

  eq(names(), "neo-tree,nvim-tree,netrw,oil", "the four built-ins, in this order")

  -- A plain buffer is no explorer, and asking costs no error.
  local plain = buf_with("lua", { "x" })
  eq(explorer.current(plain), nil, "a lua buffer is not an explorer")
  eq(explorer.current_path(plain), nil, "no path from a plain buffer")
  eq(explorer.detect(99999), nil, "an invalid buffer answers nil")

  -- Missing plugins: recognised by filetype, never an error.
  local oil_buf = buf_with("oil")
  eq(explorer.current(oil_buf), "oil", "filetype oil is recognised without the plugin")
  eq(explorer.current_path(oil_buf), nil, "no oil plugin: no path, no error")
  buf_with("neo-tree")
  eq(explorer.current(), "neo-tree", "default buffer is the current one")
  eq(explorer.current_path(), nil, "no neo-tree plugin: no path, no error")
  eq(#explorer.reload_all(), 0, "no plugin loaded: nothing reloads")

  -- netrw reads b:netrw_curdir plus the file under the cursor.
  local nb = buf_with("netrw", { "foo.txt" })
  vim.b[nb].netrw_curdir = "/x/y"
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  eq(explorer.current_path(nb), "/x/y/foo.txt", "netrw joins directory and entry")
  vim.b[nb].netrw_curdir = "/x/y/"
  eq(explorer.current_path(nb), "/x/y/foo.txt", "no doubled separator")
  vim.b[nb].netrw_curdir = nil
  eq(explorer.current_path(nb), nil, "no curdir, no path")

  -- Asked about a buffer that is not the current one: read the cursor of ITS window.
  vim.b[nb].netrw_curdir = "/x/y"
  vim.cmd("vsplit")
  vim.api.nvim_set_current_buf(plain)
  eq(
    explorer.current_path(nb),
    "/x/y/foo.txt",
    "a buffer shown in another window answers from that window"
  )
  vim.api.nvim_win_set_buf(vim.fn.win_findbuf(nb)[1], plain)
  eq(explorer.current_path(nb), nil, "a buffer shown nowhere has no cursor to read")
  vim.cmd("only")

  -- Built-ins through fake plugin modules.
  local reloads = {}
  package.loaded["oil"] = {
    get_current_dir = function()
      return "/proj/"
    end,
    get_cursor_entry = function()
      return { name = "a.lua" }
    end,
  }
  package.loaded["oil.actions"] = {
    refresh = {
      callback = function()
        reloads[#reloads + 1] = "oil"
      end,
    },
  }
  package.loaded["nvim-tree"] = {}
  package.loaded["nvim-tree.api"] = {
    tree = {
      get_node_under_cursor = function()
        return { absolute_path = "/proj/b.lua" }
      end,
      reload = function()
        reloads[#reloads + 1] = "nvim-tree"
      end,
    },
  }
  vim.api.nvim_set_current_buf(oil_buf)
  eq(explorer.current_path(oil_buf), "/proj/a.lua", "oil: dir plus cursor entry")
  local nt = buf_with("NvimTree")
  eq(explorer.current_path(nt), "/proj/b.lua", "nvim-tree: absolute path of the node")
  eq(
    table.concat(explorer.reload_all(), ","),
    "nvim-tree,oil",
    "loaded explorers reload, in registration order"
  )
  eq(table.concat(reloads, ","), "nvim-tree,oil", "both reloads ran")
  package.loaded["oil"], package.loaded["oil.actions"] = nil, nil
  package.loaded["nvim-tree"], package.loaded["nvim-tree.api"] = nil, nil

  -- Registration from outside.
  local fake_reload = 0
  explorer.register({
    name = "fake",
    filetypes = { "fakeexp" },
    current_path = function()
      return "/fake/path"
    end,
    reload = function()
      fake_reload = fake_reload + 1
    end,
  })
  eq(names(), "neo-tree,nvim-tree,netrw,oil,fake", "a new explorer is appended")
  local fb = buf_with("fakeexp")
  eq(explorer.current(fb), "fake", "recognised by its filetype")
  eq(explorer.current_path(fb), "/fake/path", "path from the registered adapter")
  eq(table.concat(explorer.reload_all(), ","), "fake", "reload_all runs it (no module gate)")

  -- detect() instead of filetypes.
  explorer.register({
    name = "byname",
    detect = function(b)
      return vim.api.nvim_buf_get_name(b):find("byname://", 1, true) ~= nil
    end,
  })
  local bb = buf_with("")
  vim.api.nvim_buf_set_name(bb, "byname://root")
  eq(explorer.current(bb), "byname", "a detect function replaces the filetype test")
  eq(explorer.current_path(bb), nil, "an adapter without current_path answers nil")

  -- Same name replaces and keeps its position.
  explorer.register({
    name = "fake",
    filetypes = { "fakeexp" },
    current_path = function()
      return "/second"
    end,
  })
  eq(names(), "neo-tree,nvim-tree,netrw,oil,fake,byname", "replace keeps the position")
  vim.api.nvim_set_current_buf(fb)
  eq(explorer.current_path(fb), "/second", "the replacement answers")

  -- Failure isolation.
  explorer.register({
    name = "boom",
    filetypes = { "boomexp" },
    current_path = function()
      error("kaput")
    end,
    reload = function()
      error("kaput")
    end,
  })
  eq(explorer.current_path(buf_with("boomexp")), nil, "a raising current_path answers nil")
  explorer.register({
    name = "after",
    filetypes = { "afterexp" },
    reload = function()
      fake_reload = fake_reload + 10
    end,
  })
  local done = table.concat(explorer.reload_all(), ",")
  ok(
    done:find("after", 1, true) and not done:find("boom", 1, true),
    "a failing reload is skipped, later ones run"
  )

  -- Module gate.
  local gated = 0
  explorer.register({
    name = "gated",
    filetypes = { "gatedexp" },
    module = "gated.plugin",
    reload = function()
      gated = gated + 1
    end,
  })
  explorer.reload_all()
  eq(gated, 0, "reload waits for the plugin module to be loaded")
  package.loaded["gated.plugin"] = true
  explorer.reload_all()
  eq(gated, 1, "reload runs once the module is loaded")
  package.loaded["gated.plugin"] = nil

  -- Validation, unregister, reset.
  ok(not pcall(explorer.register, { name = "bad" }), "an adapter needs filetypes or detect")
  ok(not pcall(explorer.register, { filetypes = { "x" } }), "an adapter needs a name")
  ok(explorer.unregister("boom"), "unregister removes")
  ok(not explorer.unregister("boom"), "unregister of a missing name is false")
  explorer.reset()
  eq(names(), "neo-tree,nvim-tree,netrw,oil", "reset returns to the built-ins")

  for _, b in ipairs(made) do
    pcall(vim.api.nvim_buf_delete, b, { force = true })
  end
end
