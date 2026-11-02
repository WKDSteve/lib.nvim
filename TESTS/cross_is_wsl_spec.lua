-- TESTS/cross_is_wsl_spec.lua -- cross.platform.is_wsl: a WSL kernel counts only together with `wslpath`; the
-- environment markers of WSL count on their own. A Linux container on the WSL2 kernel ("microsoft" in the release
-- string, no wslpath, no WSL variables) is not WSL: nothing there can reach the Windows side.
---@diagnostic disable: missing-fields, duplicate-set-field

return function(H)
  local uv = vim.uv or vim.loop
  local real_uname, real_stat = uv.os_uname, uv.fs_stat
  local env_keys = { "WSL_DISTRO_NAME", "WSL_INTEROP" }
  local saved_env = {}
  for _, k in ipairs(env_keys) do
    saved_env[k] = vim.env[k]
  end
  local saved_module = package.loaded["lib.nvim.cross.platform.is_wsl"]

  ---@param release string
  ---@param wslpath boolean
  ---@param env? table<string, string>
  ---@return boolean
  local function detect(release, wslpath, env)
    uv.os_uname = function()
      return { release = release }
    end
    uv.fs_stat = function(path)
      if path:find("wslpath", 1, true) then
        return wslpath and {} or nil
      end
      return real_stat(path)
    end
    for _, k in ipairs(env_keys) do
      vim.env[k] = env and env[k] or nil
    end
    package.loaded["lib.nvim.cross.platform.is_wsl"] = nil
    return require("lib.nvim.cross.platform.is_wsl")()
  end

  local ok, err = pcall(function()
    H.eq(detect("5.15.153.1-microsoft-standard-WSL2", true), true, "WSL kernel with wslpath is WSL")
    H.eq(
      detect("5.15.153.1-microsoft-standard-WSL2", false),
      false,
      "WSL kernel without wslpath (container) is not WSL"
    )
    H.eq(
      detect("6.8.0-generic", false, { WSL_DISTRO_NAME = "Arch" }),
      true,
      "the WSL_DISTRO_NAME marker counts alone"
    )
    H.eq(
      detect("6.8.0-generic", false, { WSL_INTEROP = "/run/WSL/1_interop" }),
      true,
      "the WSL_INTEROP marker counts alone"
    )
    H.eq(
      detect("6.8.0-generic", true),
      false,
      "a plain Linux kernel is not WSL even if wslpath exists"
    )
  end)

  uv.os_uname, uv.fs_stat = real_uname, real_stat
  for _, k in ipairs(env_keys) do
    vim.env[k] = saved_env[k]
  end
  package.loaded["lib.nvim.cross.platform.is_wsl"] = saved_module
  if not ok then
    error(err, 0)
  end
end
