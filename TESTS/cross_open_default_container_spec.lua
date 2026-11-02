-- TESTS/cross_open_default_container_spec.lua -- cross.open_default on real Linux: `xdg-open` gets the target
-- as one untouched argument (a stub records it) and a missing xdg-open is reported. The checks run in
-- TESTS/container/open_default_linux.lua inside the Linux container of testing.nvim (testing.container);
-- n/a where no container engine or image exists, or testing.nvim cannot be found.
---@diagnostic disable: missing-fields

return function(H)
  local this = debug.getinfo(1, "S").source:sub(2)
  local root = vim.fn.fnamemodify(this, ":p:h:h")
  local repos = vim.fn.fnamemodify(root, ":h")

  local candidates =
    { vim.env.TESTING_NVIM_DIR or "", repos .. "/testing.nvim", root .. "/.deps/testing.nvim" }
  local ok_mod, container = pcall(require, "testing.container")
  if not ok_mod then
    for _, dir in ipairs(candidates) do
      if dir ~= "" and vim.fn.isdirectory(dir .. "/lua/testing") == 1 then
        vim.opt.rtp:append(dir)
        ok_mod, container = pcall(require, "testing.container")
        break
      end
    end
  end
  if not ok_mod then
    print("n/a  testing.nvim is not available (testing.container)")
    return
  end
  local available, reason = container.available()
  if not available then
    print("n/a  " .. reason)
    return
  end

  local res = container.run(
    {
      "nvim",
      "--headless",
      "--clean",
      "-u",
      "NONE",
      "-l",
      "/repos/lib.nvim/TESTS/container/open_default_linux.lua",
      "/repos",
    },
    { mounts = { [repos] = "/repos" } }
  )
  local out = res.stdout .. res.stderr
  H.ok(res.code == 0, "the container run succeeds: " .. out)
  H.ok(out:find("OPEN_OK", 1, true) ~= nil, "and reports OPEN_OK: " .. out)
end
