-- TESTS/deps_files_probe_spec.lua — `files` and `probe` in a deps tool spec (detect + validation)

return function(H)
  local eq = H.eq
  local detect = require("lib.nvim.deps.detect")
  local spec = require("lib.nvim.deps.spec")

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local a, b = dir .. "/a.txt", dir .. "/b.txt"
  vim.fn.writefile({ "x" }, a)

  local nvim = vim.v.progpath

  -- files: all must exist, and they replace the PATH check
  local t = { bin = "no-such-binary-xyz", files = { a } }
  eq(detect.found(t), true, "files: one existing file is enough when it is the only one")
  t.files = { a, b }
  eq(detect.found(t), false, "files: a missing file makes the tool missing")
  vim.fn.writefile({ "x" }, b)
  eq(detect.found(t), true, "files: all present")
  eq(
    vim.fs.normalize(detect.found_as(t)),
    vim.fs.normalize(a),
    "files: the first file is what a hit reports"
  )

  -- probe: exit 0 required, on top of the PATH check
  local ok_tool = { bin = nvim, probe = { nvim, "--version" } }
  eq(detect.found(ok_tool), true, "probe: exit 0 passes")
  local bad = { bin = nvim, probe = { nvim, "--headless", "-u", "NONE", "+cquit 3" } }
  eq(detect.found(bad), false, "probe: a non-zero exit fails")
  local ghost = { bin = nvim, probe = { "no-such-binary-xyz", "--version" } }
  eq(detect.found(ghost), false, "probe: a command that cannot start fails")
  local without_path = { bin = "no-such-binary-xyz", probe = { nvim, "--version" } }
  eq(detect.found(without_path), false, "probe: does not rescue a tool missing on PATH")

  -- spec validation
  local function parse(extra)
    local tool = vim.tbl_extend(
      "force",
      { bin = "x", why = "Because it matters here.", pkg = { apt = "x" } },
      extra
    )
    return spec.parse_json(vim.json.encode({ tools = { tool } }))
  end
  local good = parse({ files = { "/a" }, probe = { "x", "--v" } })
  eq(#good.errors, 0, "spec: files and probe parse")
  eq(good.tools[1].files[1], "/a", "spec: files is kept on the tool")
  eq(good.tools[1].probe[2], "--v", "spec: probe is kept on the tool")
  eq(#parse({ files = "/a" }).errors, 1, "spec: files as a bare string is rejected")
  eq(#parse({ probe = {} }).errors, 1, "spec: an empty probe is rejected")
  eq(#parse({ probe = { "x", 1 } }).errors, 1, "spec: a non-string probe entry is rejected")

  vim.fn.delete(dir, "rf")
end
