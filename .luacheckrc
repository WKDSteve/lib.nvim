std = "luajit"
max_line_length = false

globals = {
  "vim",
}

read_globals = {
  -- Neovim's bundled LuaJIT ships 5.2-style table.pack/unpack and math.type
  -- as compat shims; luacheck's stock luajit std predates them.
  table = { fields = { "pack", "unpack" } },
  math = { fields = { "type" } },
}

-- 212: unused argument — colon-syntax methods (`function M:name()`) that
-- close over their data via upvalues rather than `self` are idiomatic here
-- (see doc/lib.nvim-window.txt's `attach` construct).
-- 542: empty if/else branch — used deliberately as a documented no-op
-- (each instance carries an explanatory comment, e.g. a commented-out debug
-- notify call kept for local debugging).
ignore = {
  "212/self",
  "542",
}

exclude_files = {
  -- Pure `---@meta` LuaCATS annotation scaffolding: `local x ---@type T` /
  -- `return {}` patterns luacheck has no way to know are intentional.
  "**/@types/**",
  -- Snippets for the docs, read as text: an argument a reader sees named (`ctx`, `idx`) is the point there. The CI
  -- checks `lua TESTS` only; a pipeline that checks the whole tree (`testing ci`) must agree with it.
  "docs/**",
}
