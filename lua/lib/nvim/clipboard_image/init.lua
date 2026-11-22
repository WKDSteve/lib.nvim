---@module 'lib.nvim.clipboard_image'
--- Save the image on the system clipboard as a PNG file (`save` waits, `save_async` does not).
---@description
--- Platform tools, detected and never assumed:
--- * Windows -- `powershell.exe -STA` with `System.Windows.Forms.Clipboard` (the
---   single-threaded apartment is mandatory, otherwise the clipboard reads `null`)
--- * macOS   -- `pngpaste`
--- * Linux   -- `wl-paste` (Wayland), else `xclip` (X11)
---
--- Without an image on the clipboard nothing is written and the error says so.
--- The result is checked for the PNG signature, so a text clipboard that a tool
--- printed anyway is never stored as an image.

local M = {}

local PNG_SIGNATURE = "\137PNG\r\n\26\n"

---@class Lib.ClipboardImage.Opts
---@field platform? "windows"|"macos"|"linux"  Override of the detected platform (for specs)
---@field has? fun(exe: string): boolean       Override of the executable check (for specs)
---@field system? fun(cmd: string[], o: table): { code: integer, stdout: string?, stderr: string? } Override of the process runner (for specs)
---@field timeout_ms? integer                   Default 15000

---@param opts? Lib.ClipboardImage.Opts
---@return "windows"|"macos"|"linux"
local function platform(opts)
  if opts and opts.platform then
    return opts.platform
  end
  if require("lib.nvim.cross.platform.is_windows")() then
    return "windows"
  end
  if require("lib.nvim.cross.platform.is_macos")() then
    return "macos"
  end
  return "linux"
end

---@param opts? Lib.ClipboardImage.Opts
---@return fun(exe: string): boolean
local function has_fn(opts)
  if opts and opts.has then
    return opts.has
  end
  return require("lib.nvim.cross.executable").exists
end

---Single-quote a value for a PowerShell string literal.
---@param s string
---@return string
local function ps_quote(s)
  return "'" .. s:gsub("'", "''") .. "'"
end

---The command that reads the clipboard image, or why there is none.
---`stdout = true` means the tool prints the PNG instead of writing the file.
---@param path string
---@param opts? Lib.ClipboardImage.Opts
---@return { cmd: string[], stdout: boolean, tool: string }|nil spec
---@return string|nil err
local function command(path, opts)
  local os_name, has = platform(opts), has_fn(opts)
  if os_name == "windows" then
    local script = table.concat({
      "Add-Type -AssemblyName System.Windows.Forms,System.Drawing;",
      "$img = [System.Windows.Forms.Clipboard]::GetImage();",
      "if ($null -eq $img) { exit 3 };",
      ("$img.Save(%s, [System.Drawing.Imaging.ImageFormat]::Png);"):format(ps_quote(path)),
    }, " ")
    return {
      cmd = { "powershell.exe", "-NoProfile", "-NonInteractive", "-STA", "-Command", script },
      stdout = false,
      tool = "powershell.exe",
    }
  elseif os_name == "macos" then
    if not has("pngpaste") then
      return nil, "`pngpaste` not found (brew install pngpaste)"
    end
    return { cmd = { "pngpaste", path }, stdout = false, tool = "pngpaste" }
  end
  if has("wl-paste") then
    return { cmd = { "wl-paste", "--type", "image/png" }, stdout = true, tool = "wl-paste" }
  end
  if has("xclip") then
    return {
      cmd = { "xclip", "-selection", "clipboard", "-t", "image/png", "-o" },
      stdout = true,
      tool = "xclip",
    }
  end
  return nil, "neither `wl-paste` nor `xclip` found"
end

---The tool this platform would use, or the reason there is none (for `:checkhealth`).
---@param opts? Lib.ClipboardImage.Opts
---@return string|nil tool
---@return string|nil err
function M.tool(opts)
  local spec, err = command("", opts)
  if not spec then
    return nil, err
  end
  return spec.tool, nil
end

---Read the tool's result: the file is written (or was by the tool) and is a PNG, or why not.
---@param spec { cmd: string[], stdout: boolean, tool: string }
---@param path string
---@param res table  # { code, stdout?, stderr? } of the tool
---@return boolean ok
---@return string|nil err
local function finish(spec, path, res)
  if spec.stdout then
    local data = res.stdout
    if res.code ~= 0 or type(data) ~= "string" or data == "" then
      return false, "no image in the clipboard"
    end
    if data:sub(1, #PNG_SIGNATURE) ~= PNG_SIGNATURE then
      return false, "the clipboard holds no PNG image"
    end
    local fh, ferr = io.open(path, "wb")
    if not fh then
      return false, ("cannot write %s: %s"):format(path, tostring(ferr))
    end
    fh:write(data)
    fh:close()
    return true, nil
  end

  if res.code == 3 then
    return false, "no image in the clipboard"
  end
  if res.code ~= 0 then
    local msg = tostring(res.stderr or ""):gsub("%s+$", "")
    return false,
      ("%s failed (exit %d)%s"):format(spec.tool, res.code, msg ~= "" and (": " .. msg) or "")
  end
  local st = vim.uv.fs_stat(path)
  if not st or st.size == 0 then
    pcall(vim.uv.fs_unlink, path)
    return false, "no image in the clipboard"
  end
  return true, nil
end

---The command for `path`, or why there is none (also for a missing path).
---@param path any
---@param opts? Lib.ClipboardImage.Opts
---@return { cmd: string[], stdout: boolean, tool: string }|nil spec
---@return string|nil err
local function prepare(path, opts)
  if type(path) ~= "string" or path == "" then
    return nil, "clipboard_image.save needs a target path"
  end
  return command(path, opts)
end

---@param opts? Lib.ClipboardImage.Opts
---@return table
local function system_opts(opts)
  return { text = false, timeout = (opts and opts.timeout_ms) or 15000 }
end

---Write the clipboard image to `path` as a PNG. Nothing is left behind on failure.
---Waits for the tool (on Windows a PowerShell start); from a keypress use `save_async`.
---@param path string
---@param opts? Lib.ClipboardImage.Opts
---@return boolean ok
---@return string|nil err
function M.save(path, opts)
  local spec, err = prepare(path, opts)
  if not spec then
    return false, err
  end

  local run = opts and opts.system
    or function(cmd, o)
      return vim.system(cmd, o):wait(o.timeout)
    end
  local ran, res = pcall(run, spec.cmd, system_opts(opts))
  if not ran or type(res) ~= "table" then
    return false, ("cannot run %s: %s"):format(spec.tool, tostring(res))
  end
  return finish(spec, path, res)
end

---`save` without waiting: the tool runs in the background and `on_done(ok, err)` is called later on the main
---loop, always on a later tick (also when there is no tool or no path). The answer is the one `save` gives.
---`opts.system` (specs) is called at once, as in `save`, and its result is read as the tool's exit.
---@param path string
---@param opts? Lib.ClipboardImage.Opts
---@param on_done fun(ok: boolean, err: string|nil)
function M.save_async(path, opts, on_done)
  assert(type(on_done) == "function", "clipboard_image.save_async needs a callback")
  local function answer(ok, err)
    vim.schedule(function()
      on_done(ok, err)
    end)
  end
  local spec, err = prepare(path, opts)
  if not spec then
    answer(false, err)
    return
  end
  local function exited(res)
    if type(res) ~= "table" then
      answer(false, ("cannot run %s: %s"):format(spec.tool, tostring(res)))
      return
    end
    -- On the main loop: `finish` writes the file, and the caller's callback may touch buffers.
    vim.schedule(function()
      on_done(finish(spec, path, res))
    end)
  end
  if opts and opts.system then
    local ran, res = pcall(opts.system, spec.cmd, system_opts(opts))
    exited(ran and res or tostring(res))
    return
  end
  -- The exit callback of vim.system runs in a fast event; `exited` only schedules from there.
  local ran, serr = pcall(vim.system, spec.cmd, system_opts(opts), exited)
  if not ran then
    answer(false, ("cannot run %s: %s"):format(spec.tool, tostring(serr)))
  end
end

return M
