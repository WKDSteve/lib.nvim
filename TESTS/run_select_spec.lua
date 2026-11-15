-- TESTS/run_select_spec.lua — TESTS/run.lua runs the spec files named on its command line alone:
-- with or without folder and ending, in the order of its list, with the result line and the exit
-- code of a whole run; a name that is no spec ends it with exit code 2 before anything ran.

return function(H)
  local ok, eq = H.ok, H.eq
  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

  ---@param names string[]
  ---@return integer code
  ---@return string out
  local function run(names)
    local cmd =
      { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", "TESTS/run.lua" }
    vim.list_extend(cmd, names)
    local done = vim.system(cmd, { cwd = root, text = true }):wait(120000)
    return done.code, (done.stdout or "") .. (done.stderr or "")
  end
  ---@param out string
  ---@return string[]
  local function ran(out)
    local names = {}
    for name in out:gmatch("ok%s+(%S+%.lua)") do
      names[#names + 1] = name
    end
    return names
  end

  local code, out = run({ "harness_spec.lua" })
  eq(code, 0, "one spec by its file name: exit code 0")
  eq(table.concat(ran(out), ","), "harness_spec.lua", "... only that spec ran")
  ok(out:find("LIB_TESTS_OK", 1, true) ~= nil, "... with the result line of a whole run")
  ok(out:find("1 of %d+ specs ran") ~= nil, "... and a line that says it was not the whole suite")

  -- every spelling of a name, and the order of the list whatever the order asked for
  code, out = run({ "TESTS/shell_quote_spec.lua", "harness", "TESTS\\min_version_spec" })
  eq(code, 0, "three specs, each spelled another way: exit code 0")
  eq(
    table.concat(ran(out), ","),
    "harness_spec.lua,min_version_spec.lua,shell_quote_spec.lua",
    "... the three ran, in the order of the list"
  )

  code, out = run({ "harness_spec.lua", "no_such_thing" })
  eq(code, 2, "a name that is no spec: exit code 2")
  ok(out:find("no spec of TESTS/run.lua: no_such_thing", 1, true) ~= nil, "... it is named")
  eq(#ran(out), 0, "... and nothing ran")
end
