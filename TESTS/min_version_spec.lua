-- TESTS/min_version_spec.lua -- the minimum Neovim version is promised in three places and exercised
-- in one: the extra leg of .github/workflows/ci.yml. A promise no job runs drifts silently (0.10 was
-- promised here while the keymap setup failed under it), so this fails when the floor moves in only
-- some of them.

return function(H)
  local eq, ok = H.eq, H.ok

  ---@param rel string
  ---@return string
  local function read(rel)
    local f = assert(io.open(vim.fn.getcwd() .. "/" .. rel, "rb"), "missing file: " .. rel)
    local text = f:read("*a")
    f:close()
    return text
  end

  local minor = read(".github/workflows/ci.yml"):match("nvim:%s*v0%.(%d+)%.%d+")
  ok(minor ~= nil, "min_version: ci.yml has a leg pinned to the minimum version")

  local floor = "0." .. minor
  local escaped = vim.pesc(floor)
  ok(read("README.md"):find("Neovim%-" .. escaped .. "%%2B") ~= nil, "min_version: README badge")
  ok(
    read("docs/installation.md"):find("| Neovim | **" .. floor .. "+** |", 1, true) ~= nil,
    "min_version: docs/installation.md"
  )
  eq(
    read("lua/lib/health.lua"):match("MIN_NVIM = { 0, (%d+), 0 }"),
    minor,
    "min_version: lua/lib/health.lua"
  )
end
