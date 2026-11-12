---@module 'lib.nvim.cross.platform.is_wsl'
--- Single-purpose module that exports exactly one function to detect
--- whether Neovim is running inside Windows Subsystem for Linux (WSL).
--- This module intentionally returns the function itself (not a table),
--- so it can be re-exported cleanly by `lib.init`.

-- Cache across calls, declared outside the returned function so it is a
-- shared upvalue (not reset to nil on every invocation — a `local cached`
-- declared *inside* the function body would never actually persist, and this
-- module's fallback path does real file IO, so that matters more here than
-- in the sibling is_windows/is_macos/is_linux modules).
---@type boolean|nil
local cached

---A WSL kernel alone is not WSL: a container on the podman machine or a distro without interop runs on the
---WSL2 kernel ("microsoft" in the release string) but has no `wslpath`, no `explorer.exe`, no Windows side.
---`wslpath` is injected into every real WSL distro, so its presence is the marker of the interop.
---@return boolean
local function has_wslpath()
  local uv = vim and (vim.uv or vim.loop)
  if not (uv and uv.fs_stat) then
    return true
  end
  return uv.fs_stat("/bin/wslpath") ~= nil or uv.fs_stat("/usr/bin/wslpath") ~= nil
end

---@return boolean
--- Returns true when the current runtime is WSL (either v1 or v2).
--- Detection strategy (in order):
---   1) Use `uv.os_uname().release` (contains "Microsoft"/"WSL" on WSL) -- and `wslpath` must exist
--      (a Linux container on the WSL2 kernel is not WSL).
---   2) Environment variables commonly set by WSL (`WSL_DISTRO_NAME`, `WSL_INTEROP`).
---   3) Fallback: read `/proc/sys/kernel/osrelease` and look for markers.
return function()
  if cached ~= nil then
    return cached
  end

  -- Prefer `vim.uv` (Neovim ≥ 0.10); fall back to `vim.loop` for older versions.
  local uv = (vim and (vim.uv or vim.loop)) or nil

  local is = false
  local uname_answered = false

  -- 1) uname-based detection
  if uv and uv.os_uname then
    local ok, u = pcall(uv.os_uname)
    if ok and type(u) == "table" and type(u.release) == "string" then
      uname_answered = true
      local rel = u.release:lower()
      -- Typical markers: "microsoft-standard-WSL2", "...-microsoft-..." etc.
      if (rel:find("microsoft", 1, true) or rel:find("wsl", 1, true)) and has_wslpath() then
        is = true
      end
    end
  end

  -- 2) Environment variables exposed by WSL
  if not is and vim and vim.env then
    local env = vim.env
    if type(env.WSL_DISTRO_NAME) == "string" and env.WSL_DISTRO_NAME ~= "" then
      is = true
    elseif type(env.WSL_INTEROP) == "string" and env.WSL_INTEROP ~= "" then
      is = true
    end
  end

  -- 3) Fallback: kernel release file, only when uv/os_uname gave no release (it reads the same kernel)
  if not is and not uname_answered then
    local f = io.open("/proc/sys/kernel/osrelease", "r")
    if f then
      local line = f:read("*l") or ""
      f:close()
      local low = line:lower()
      if (low:find("microsoft", 1, true) or low:find("wsl", 1, true)) and has_wslpath() then
        is = true
      end
    end
  end

  cached = is
  return is
end
