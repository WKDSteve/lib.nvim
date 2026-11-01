---@module 'lib.nvim.fs.path_shorten'
--- Shorten a filesystem path for display. Two styles, selected via `opts.style`:
---   "fit"   (default) preserves the path start (drive/root) and the filename
---           at the end, replacing a variable-length middle section with an
---           ellipsis ("…" by default) until the result fits `max_len`.
---   "label" always renders "<root>/<ellipsis>/<parent>/<file>" ("...." by
---           default), ignoring `max_len` — ported from Harpoon's menu-label
---           formatter. Independent algorithm; only dispatch and the ellipsis
---           marker are shared with "fit".

local uv = vim.uv or vim.loop

--------------------------------------------------------------------------------
-- "label" style — <root>/<ellipsis>/<parent>/<file>
--------------------------------------------------------------------------------

---@internal
---@return string
local function label_homedir()
  return (uv.os_homedir and uv.os_homedir()) or vim.fn.expand("~")
end

---@internal
---@param p string
---@return string
local function label_to_display_sep(p)
  return (p:gsub("\\", "/"))
end

---@internal
---@param p string
---@return boolean
local function label_is_unc(p)
  return p:match("^//") ~= nil
end

---@internal
---@param p string
---@return string, string
local function label_split_unc_root(p)
  local s = p:match("^//([^/]+/[^/]+)")
  if not s then
    local rest = (p:gsub("^//+", ""))
    return "//", rest
  end
  local root = "//" .. s
  local rest = p:sub(#root + 2)
  return root, rest
end

---@internal
---@param p string
---@return boolean
local function label_is_windows_drive(p)
  return p:match("^%a:[/\\]") ~= nil
end

---@internal
---@param p string
---@return string, string
local function label_split_drive_root(p)
  local drive = p:sub(1, 2):upper()
  local rest = p:sub(3)
  rest = rest:gsub("^[/\\]+", "")
  return drive, rest
end

---@internal
---@param path string
---@param ellipsis string
---@return string
local function build_label(path, ellipsis)
  if type(path) ~= "string" or path == "" then
    return ""
  end

  local rp = (uv.fs_realpath and uv.fs_realpath(path)) or path
  local p = label_to_display_sep(rp)

  local home = label_to_display_sep(label_homedir())
  local root, rest

  if label_is_unc(p) then
    root, rest = label_split_unc_root(p)
  elseif label_is_windows_drive(p) then
    root, rest = label_split_drive_root(p)
    root = root .. "/"
  elseif p:sub(1, #home + 1) == (home .. "/") then
    root, rest = "~", p:sub(#home + 2)
    root = root .. "/"
  elseif p == home then
    return "~"
  elseif p:sub(1, 1) == "/" then
    root, rest = "/", p:sub(2)
  else
    local cwd = label_to_display_sep((uv.cwd and uv.cwd()) or vim.fn.getcwd())
    if p:sub(1, 1) ~= "/" and not label_is_windows_drive(p) and not label_is_unc(p) then
      p = cwd .. "/" .. p
    end
    return build_label(p, ellipsis)
  end

  local parent = rest:match("(.+)/[^/]+$") or ""
  local file = rest:match("[^/]+$") or rest

  if parent == "" then
    if root == "//" then
      return "//" .. file
    end
    return root .. file
  end

  local parent_name = parent:match("[^/]+$") or parent
  return string.format("%s%s/%s/%s", root, ellipsis, parent_name, file)
end

--------------------------------------------------------------------------------
-- "fit" style — width-budget ellipsis collapsing
--------------------------------------------------------------------------------

---@internal
--- Determine path separator depending on platform.
--- @return string separator ("/" on POSIX, "\" on Windows)
local function get_sep()
  -- package.config:sub(1,1) returns the directory separator for the current Lua build
  return package.config:sub(1, 1)
end

---@internal
--- Split a string by a separator.
--- Keeps a leading empty token to denote a leading separator (root) if present.
--- @param s string
--- @param sep string
--- @return string[] parts
local function split(s, sep)
  ---@type string[]
  local parts = {}
  if sep == "\\" then
    -- escape backslash for pattern
    sep = "\\\\"
  end
  local pattern = "([^" .. sep .. "]+)"
  for part in s:gmatch(pattern) do
    parts[#parts + 1] = part
  end
  -- If original string starts with separator, represent root by inserting empty first element.
  if s:sub(1, 1) == get_sep() then
    table.insert(parts, 1, "")
  end
  return parts
end

---@internal
--- Join parts into a path using separator.
--- If first part is empty string, it denotes a leading separator (root).
--- @param parts string[]
--- @param sep string
--- @return string
local function join(parts, sep)
  if #parts == 0 then
    return ""
  end
  if parts[1] == "" then
    if #parts == 1 then
      return sep
    end
    local unpack = require("lib.lua.functions.varargs").unpack
    return sep .. table.concat({ unpack(parts, 2) }, sep)
  end
  return table.concat(parts, sep)
end

---@internal
--- Length used for the width budget: byte length, not display width — so a
--- multibyte ellipsis or path segment counts as its byte size.
--- @param s string
--- @return integer
local function strlen(s)
  return #s
end

--- Shorten a path for display. Default ("fit") style preserves the first
--- meaningful segment (drive or root marker) and the last segment (filename),
--- collapsing the middle with an ellipsis until the result fits `max_len`.
--- "label" style always shows "<root>/<ellipsis>/<parent>/<file>", ignoring
--- `max_len`.
--- @param path string full path to shorten
--- @param max_len integer|nil maximum allowed length (characters, >=1); ignored for style "label"
--- @param opts? Lib.Fs.PathShortenOpts
--- @return string shortened path
return function(path, max_len, opts)
  if type(path) ~= "string" then
    return path
  end

  opts = opts or {}
  local style = opts.style or "fit"

  if style == "label" then
    return build_label(path, opts.ellipsis or "....")
  end

  if type(max_len) ~= "number" or max_len < 1 then
    return path
  end

  local sep = get_sep()
  local ell = opts.ellipsis or "…"

  -- fast path: already fits
  if strlen(path) <= max_len then
    return path
  end

  local parts = split(path, sep) ---@type string[]
  local n = #parts

  if n == 0 then
    if strlen(path) <= max_len then
      return path
    else
      return ell .. path:sub(-math.max(1, max_len - 1))
    end
  end

  local has_root = parts[1] == ""

  -- Determine first_display (drive or first non-empty part). For Windows absolute like "C:\"
  local first_part = parts[1]
  if has_root then
    if sep == "/" then
      first_part = sep -- always show leading '/' for POSIX absolute paths
    else
      first_part = parts[1] -- for Windows, keep "C:" visible
    end
  end

  local last_part = parts[n]

  -- If even "first + sep + last" does not fit, then show ellipsis + truncated filename (right-aligned)
  local min_needed = strlen(first_part) + strlen(sep) + strlen(last_part)
  if min_needed > max_len then
    local allowed_for_last = math.max(1, max_len - strlen(ell))
    local last_visible = last_part
    if strlen(last_part) > allowed_for_last then
      -- truncate from left to keep the filename end visible (byte-based)
      last_visible = last_part:sub(-allowed_for_last)
    end
    return ell .. last_visible
  end

  -- 1) Try collapsing entire middle to ellipsis: first + sep + ell + sep + last
  ---@internal
  local function build_with_ellipsis()
    local out_parts = {}
    if has_root then
      table.insert(out_parts, "") -- leading '/' will be produced by join
    else
      table.insert(out_parts, parts[1])
    end
    -- only add ellipsis if there are more than 2 segments besides root
    if n > 2 then
      table.insert(out_parts, ell)
    end
    table.insert(out_parts, parts[n])
    return join(out_parts, sep)
  end

  local attempt = build_with_ellipsis()
  if strlen(attempt) <= max_len then
    return attempt
  end

  -- 2) Try keeping increasing number of trailing segments (right-most) with a leading ellipsis
  for k = 1, n - 1 do
    local keep_from = n - k + 1
    local out_parts = {}
    if has_root then
      table.insert(out_parts, "") -- leading '/' always visible
    else
      table.insert(out_parts, parts[1])
    end
    -- only add ellipsis if there are collapsed segments between root/first and last segments
    if keep_from > (has_root and 2 or 1) then
      table.insert(out_parts, ell)
    end
    for i = keep_from, n do
      table.insert(out_parts, parts[i])
    end
    local cand = join(out_parts, sep)
    if strlen(cand) <= max_len then
      return cand
    end
  end

  -- 3) Last resort: show ellipsis + as much of the rightmost characters as fits
  local allowed = max_len - strlen(ell)
  if allowed <= 0 then
    return ell
  end
  local tail = path:sub(-allowed)
  return ell .. tail
end
