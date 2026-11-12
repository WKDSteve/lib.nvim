-- TESTS/trash_restore_spec.lua — lib.nvim.fs.trash.restore_blocking
--
-- Windows: a real round trip through the recycle bin (a uniquely named file is trashed and
-- restored at once, so nothing is left in the user's bin). Linux: an XDG trash directory
-- under a temp dir. macOS: only the documented "unsupported" answer.

return function(H)
  local eq, ok = H.eq, H.ok
  local trash = require("lib.nvim.fs.trash")
  local is_windows = require("lib.nvim.cross.platform.is_windows")()
  local is_wsl = require("lib.nvim.cross.platform.is_wsl")()
  local is_macos = require("lib.nvim.cross.platform.is_macos")()

  eq(type(trash.restore_blocking), "function", "restore_blocking exists")
  eq(type(trash.restore), "function", "restore exists")

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function make(name, text)
    local path = dir .. "/" .. name
    vim.fn.writefile({ text }, path)
    return path
  end

  if is_windows and not is_wsl then
    local f = make("lib_trash_restore_" .. vim.fn.getpid() .. "_" .. os.time() .. ".txt", "payload")
    local t_ok, t_err = trash.trash_blocking(f)
    ok(t_ok, "trash_blocking: " .. tostring(t_err))
    eq(vim.uv.fs_stat(f), nil, "trashed: the file is gone")

    local r_ok, r_err = trash.restore_blocking(f)
    ok(r_ok, "restore_blocking: " .. tostring(r_err))
    eq(vim.fn.readfile(f)[1], "payload", "restored with its content")

    local again, err = trash.restore_blocking(f)
    eq(again, false, "restore: an existing destination is refused")
    ok(tostring(err):find("exists"), "restore: the error says why: " .. tostring(err))

    local gone, err2 = trash.restore_blocking(dir .. "/never_trashed_" .. os.time() .. ".txt")
    eq(gone, false, "restore: a file that was never trashed")
    ok(tostring(err2):find("recycle bin"), "restore: the error names the bin: " .. tostring(err2))

    -- async form
    local g =
      make("lib_trash_restore_async_" .. vim.fn.getpid() .. "_" .. os.time() .. ".txt", "async")
    ok(trash.trash_blocking(g), "trash for the async case")
    local done, res_ok
    trash.restore(g, function(o)
      done, res_ok = true, o
    end)
    vim.wait(20000, function()
      return done
    end, 50)
    ok(done and res_ok, "restore (async) calls back with ok")
    eq(vim.fn.readfile(g)[1], "async", "restore (async): content back")

    -- an 8.3 short folder name (what tempname() gives under C:\Users\RUNNER~1):
    -- the bin records the long form, restore must still find the entry
    local long = dir .. "/a_folder_name_longer_than_eight"
    vim.fn.mkdir(long, "p")
    -- Neovim has no `:8` modifier; the short name comes from the file system object.
    -- A volume without 8.3 names (8dot3name disabled, ReFS) has nothing to check.
    local res = vim
      .system({
        "powershell",
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        "(New-Object -ComObject Scripting.FileSystemObject).GetFolder('"
          .. long:gsub("'", "''")
          .. "').ShortPath",
      }, { text = true })
      :wait()
    local short = vim.trim(res and res.stdout or "")
    if res and res.code == 0 and short:find("~", 1, true) then
      local s = short
        .. "/lib_trash_restore_short_"
        .. vim.fn.getpid()
        .. "_"
        .. os.time()
        .. ".txt"
      vim.fn.writefile({ "short" }, s)
      ok(trash.trash_blocking(s), "trash through a short folder name")
      local s_ok, s_err = trash.restore_blocking(s)
      ok(s_ok, "restore_blocking through a short folder name: " .. tostring(s_err))
      eq(vim.fn.readfile(s)[1], "short", "restored through a short folder name")
    end
  elseif is_macos then
    local r, err = trash.restore_blocking(dir .. "/x")
    eq(r, false, "macOS: restore is unsupported")
    eq(err, "unsupported platform", "macOS: the documented answer")
  else
    local base = vim.fn.tempname()
    local saved = vim.env.XDG_DATA_HOME
    vim.env.XDG_DATA_HOME = base
    vim.fn.mkdir(base .. "/Trash/files", "p")
    vim.fn.mkdir(base .. "/Trash/info", "p")
    local f = dir .. "/restore me.txt"
    -- as `gio trash` writes it: payload in files/, percent-encoded Path in info/
    vim.fn.writefile({ "old" }, base .. "/Trash/files/restore me.txt")
    vim.fn.writefile({
      "[Trash Info]",
      "Path=" .. dir .. "/restore%20me.txt",
      "DeletionDate=2026-01-01T10:00:00",
    }, base .. "/Trash/info/restore me.txt.trashinfo")
    vim.fn.writefile({ "new" }, base .. "/Trash/files/restore me.2.txt")
    vim.fn.writefile({
      "[Trash Info]",
      "Path=" .. dir .. "/restore%20me.txt",
      "DeletionDate=2026-02-01T10:00:00",
    }, base .. "/Trash/info/restore me.2.txt.trashinfo")

    local r_ok, r_err = trash.restore_blocking(f)
    vim.env.XDG_DATA_HOME = saved
    ok(r_ok, "xdg restore: " .. tostring(r_err))
    eq(vim.fn.readfile(f)[1], "new", "xdg restore: the newest deletion wins")
    eq(
      vim.uv.fs_stat(base .. "/Trash/info/restore me.2.txt.trashinfo"),
      nil,
      "xdg restore: info removed"
    )
    vim.fn.delete(base, "rf")
  end

  vim.fn.delete(dir, "rf")
end
