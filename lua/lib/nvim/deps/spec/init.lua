---@module 'lib.nvim.deps.spec'
--- Parse + validate a plugin's declared external-tool requirements from
--- either `docs/INSTALL.md` (```install-tool fenced blocks, YAML-ish body —
--- see `lib.lua.yaml`) or `docs/install.json` (`{"tools": [...]}`), and
--- locate either file for a named plugin on `runtimepath`.
---
--- `why` is validated as a required, non-empty field, not just documented as
--- a convention. The reasoning: a manifest entry that doesn't say why a tool
--- matters is treated the same as one with a malformed `pkg` map, both fail
--- validation rather than silently produce a nameless "tool missing" report.
---
--- Parsing only. Nothing here touches the filesystem beyond reading the one
--- spec file handed to it, and nothing here executes a command.

local yaml = require("lib.lua.yaml")
local strings = require("lib.lua.strings.core")

local M = {}

---@internal
---True when `line` (already trimmed) opens an `install-tool` fenced block.
---@param line string
---@return boolean
local function is_block_open(line)
  return line == "```install-tool"
end

---@internal
---True when `line` (already trimmed) closes any fenced block.
---@param line string
---@return boolean
local function is_block_close(line)
  return line == "```"
end

---Extract the raw body text of every ```install-tool fenced block in `text`,
---in document order. Line-based on purpose — a fence delimiter is just a
---line matching exactly, no CommonMark parser needed for this narrow a job.
---@internal
---@param text string
---@return string[]
local function extract_blocks(text)
  local blocks = {}
  local capturing = false
  local buf = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local trimmed = strings.trim(line)
    if not capturing then
      if is_block_open(trimmed) then
        capturing = true
        buf = {}
      end
    else
      if is_block_close(trimmed) then
        capturing = false
        blocks[#blocks + 1] = table.concat(buf, "\n")
      else
        buf[#buf + 1] = line
      end
    end
  end
  return blocks
end

---Validate one decoded entry (from either the YAML block body or a JSON
---`tools[]` element) into a `Lib.Deps.Tool`, or a list of field errors.
---`bin`, non-empty `why`, and a non-empty `pkg` map are all required;
---`required` defaults to `false`; `see`, `bin_alternatives` and `paths` are
---optional.
---@internal
---@param data table
---@param index integer
---@return Lib.Deps.Tool|nil tool
---@return Lib.Deps.Error[] errors empty on success
local function validate_entry(data, index)
  if type(data) ~= "table" then
    return nil, { { index = index, field = nil, message = "entry is not an object" } }
  end

  local errors = {} ---@type Lib.Deps.Error[]

  if type(data.bin) ~= "string" or data.bin == "" then
    errors[#errors + 1] = { index = index, field = "bin", message = "missing or empty 'bin'" }
  end

  if type(data.why) ~= "string" or data.why == "" then
    errors[#errors + 1] = {
      index = index,
      field = "why",
      message = "missing or empty 'why' — every tool must say why it matters",
    }
  end

  if type(data.pkg) ~= "table" or next(data.pkg) == nil then
    errors[#errors + 1] = {
      index = index,
      field = "pkg",
      message = "missing 'pkg' — at least one package-manager entry is required",
    }
  end

  if data.required ~= nil and type(data.required) ~= "boolean" then
    errors[#errors + 1] =
      { index = index, field = "required", message = "'required' must be true/false" }
  end

  -- A bare string here is the obvious way to get it wrong, and the one that
  -- would otherwise pass silently: `bin_alternatives = "gswin64c"` iterates as
  -- an empty list, so the alternative would simply never be probed and the
  -- tool would keep reporting missing on the platform it was added for.
  if data.bin_alternatives ~= nil then
    if not vim.islist(data.bin_alternatives) then
      errors[#errors + 1] = {
        index = index,
        field = "bin_alternatives",
        message = "'bin_alternatives' must be a list of executable names",
      }
    else
      for _, alt in ipairs(data.bin_alternatives) do
        if type(alt) ~= "string" or alt == "" then
          errors[#errors + 1] = {
            index = index,
            field = "bin_alternatives",
            message = "'bin_alternatives' entries must be non-empty strings",
          }
          break
        end
      end
    end
  end

  -- Same shape of mistake as `bin_alternatives` above, one level deeper: a
  -- `paths` value that isn't a per-platform list of strings would otherwise
  -- iterate as empty and the tool would keep reporting missing on exactly
  -- the platform `paths` was added to rescue.
  if data.paths ~= nil then
    if type(data.paths) ~= "table" then
      errors[#errors + 1] =
        { index = index, field = "paths", message = "'paths' must be an object keyed by platform" }
    else
      for _, platform in ipairs({ "win", "mac", "linux" }) do
        local list = data.paths[platform]
        if list ~= nil then
          if not vim.islist(list) then
            errors[#errors + 1] = {
              index = index,
              field = "paths",
              message = ("'paths.%s' must be a list of install-location strings"):format(platform),
            }
          else
            for _, path in ipairs(list) do
              if type(path) ~= "string" or path == "" then
                errors[#errors + 1] = {
                  index = index,
                  field = "paths",
                  message = ("'paths.%s' entries must be non-empty strings"):format(platform),
                }
                break
              end
            end
          end
        end
      end
    end
  end

  -- `files`: every one must exist; `probe`: an argv that must exit 0. Both
  -- are lists of non-empty strings; anything else would silently never match.
  for _, field in ipairs({ "files", "probe" }) do
    local v = data[field]
    if v ~= nil then
      local good = vim.islist(v) and #v > 0
      if good then
        for _, item in ipairs(v) do
          if type(item) ~= "string" or item == "" then
            good = false
            break
          end
        end
      end
      if not good then
        errors[#errors + 1] = {
          index = index,
          field = field,
          message = ("'%s' must be a non-empty list of non-empty strings"):format(field),
        }
      end
    end
  end

  if #errors > 0 then
    return nil, errors
  end

  return {
    bin = data.bin,
    files = data.files,
    probe = data.probe,
    bin_alternatives = data.bin_alternatives,
    paths = data.paths,
    required = data.required == true,
    why = data.why,
    see = (type(data.see) == "string" and data.see ~= "") and data.see or nil,
    pkg = data.pkg,
  }, {}
end

---Parse a `docs/INSTALL.md`-shaped string: prose plus zero or more
---```install-tool fenced blocks, each block's body decoded as
---`lib.lua.yaml`'s minimal YAML subset.
---@param text string
---@return Lib.Deps.ParseResult
function M.parse_markdown(text)
  local tools, errors = {}, {} ---@type Lib.Deps.Tool[], Lib.Deps.Error[]

  for i, block in ipairs(extract_blocks(text)) do
    local data, yerr = yaml.simple_parse(block)
    if not data then
      errors[#errors + 1] =
        { index = i, field = nil, message = "malformed install-tool block: " .. tostring(yerr) }
    else
      local tool, verrs = validate_entry(data, i)
      if tool then
        tools[#tools + 1] = tool
      end
      for _, e in ipairs(verrs) do
        errors[#errors + 1] = e
      end
    end
  end

  return { tools = tools, errors = errors }
end

---Parse a `docs/install.json`-shaped string: `{"tools": [ {...}, ... ]}`,
---decoded via Neovim's native `vim.json.decode` (the "maximum information,
---most performant to parse" variant — no custom parser, no line-oriented
---subset limits, so multi-line `why`/arbitrary extra metadata are fine here
---even though the Markdown+YAML variant can't carry them).
---@param text string
---@return Lib.Deps.ParseResult
function M.parse_json(text)
  local ok, data = pcall(vim.json.decode, text)
  if not ok then
    return {
      tools = {},
      errors = { { index = 0, field = nil, message = "malformed JSON: " .. tostring(data) } },
    }
  end

  if type(data) ~= "table" or type(data.tools) ~= "table" then
    return {
      tools = {},
      errors = {
        { index = 0, field = "tools", message = 'expected a top-level {"tools": [...]} object' },
      },
    }
  end

  local tools, errors = {}, {} ---@type Lib.Deps.Tool[], Lib.Deps.Error[]
  for i, entry in ipairs(data.tools) do
    local tool, verrs = validate_entry(entry, i)
    if tool then
      tools[#tools + 1] = tool
    end
    for _, e in ipairs(verrs) do
      errors[#errors + 1] = e
    end
  end

  return { tools = tools, errors = errors }
end

---Read and parse a spec file, dispatching on its extension
---(`.json` -> `parse_json`, anything else -> `parse_markdown`).
---@param path string
---@return Lib.Deps.ParseResult|nil result
---@return string|nil err set only when the file itself couldn't be read
function M.load(path)
  local f, open_err = io.open(path, "r")
  if not f then
    return nil, "cannot open " .. path .. ": " .. tostring(open_err)
  end
  local text = f:read("*a")
  f:close()

  if path:match("%.json$") then
    return M.parse_json(text), nil
  end
  return M.parse_markdown(text), nil
end

--- Spec filenames, in resolution order. JSON first: it has no
--- parsing-subset limitations, so it is the canonical file when a plugin
--- author ships both.
local SPEC_FILES = { "docs/install.json", "docs/INSTALL.md" }

---@internal
---@param path string
---@return boolean
local function file_exists(path)
  local uv = vim.uv or vim.loop
  local ok, stat = pcall(uv.fs_stat, path)
  return ok and stat ~= nil and stat.type == "file"
end

---@internal
--- Install directory of every plugin lazy.nvim *knows about*, keyed by name
--- — loaded or not.
---
--- This exists because `runtimepath` alone is not enough, which is worth
--- stating plainly: lazy.nvim only puts a plugin on `runtimepath` once it
--- actually loads. Measured against a real config while building this:
--- 120 plugins configured, 44 loaded at startup, **76 pending**. Resolving
--- through `nvim_get_runtime_file` alone would therefore silently fail for
--- the majority of a lazy-loading user's plugins — and "silently" is the
--- problem, since a missing spec is indistinguishable from a plugin that
--- ships none.
---
--- Kept strictly opportunistic: `pcall`'d, no hard dependency, and only
--- consulted *after* the runtimepath scan. Other managers (packer,
--- vim-plug, mini.deps) put plugins on `runtimepath` eagerly, so the
--- primary path already covers them; this is a lazy.nvim-shaped hole, and
--- lazy.nvim's own registry is the only thing that can fill it.
---@return table<string, string> dirs plugin name -> install dir
local function lazy_dirs()
  local ok, cfg = pcall(require, "lazy.core.config")
  if not ok or type(cfg) ~= "table" or type(cfg.plugins) ~= "table" then
    return {}
  end
  local dirs = {}
  for name, plugin in pairs(cfg.plugins) do
    if type(plugin) == "table" and type(plugin.dir) == "string" then
      dirs[name] = plugin.dir
    end
  end
  return dirs
end

---Locate `docs/install.json` or `docs/INSTALL.md` for `plugin_name`.
---
---Resolution order:
---  1. `runtimepath` — manager-agnostic; covers packer, vim-plug, mini.deps,
---     a symlinked dev checkout, and every *loaded* lazy.nvim plugin.
---     `plugin_name` must match a whole path segment, not a substring, so
---     `pdfport.nvim` doesn't match a directory like `my-pdfport.nvim-fork`.
---  2. lazy.nvim's plugin registry, if lazy.nvim is present — covers
---     plugins that are installed but not yet loaded, which `runtimepath`
---     cannot see at all (see `lazy_dirs`).
---
---JSON is preferred over Markdown at both steps.
---@param plugin_name string
---@return string|nil path
function M.find(plugin_name)
  ---@internal
  ---@param matches string[]
  ---@return string|nil
  local function pick(matches)
    for _, path in ipairs(matches) do
      local normalized = path:gsub("\\", "/")
      for segment in normalized:gmatch("[^/]+") do
        if segment == plugin_name then
          return path
        end
      end
    end
    return nil
  end

  for _, file in ipairs(SPEC_FILES) do
    -- No `**` prefix: each `runtimepath` entry already IS a plugin root, so
    -- `file` alone checks exactly `<rtp-entry>/docs/install.json` per
    -- entry — no recursion needed. `**` would recurse into every
    -- subdirectory of every plugin looking for a nested `docs/`, which is
    -- both unnecessary and genuinely dangerous: measured against a real
    -- plugin repo carrying a 17k-file `node_modules/` (mdview.nvim), the
    -- recursive form did not return within a minute. Non-recursive stats
    -- one path per `runtimepath` entry and is effectively instant.
    local found = pick(vim.api.nvim_get_runtime_file(file, true))
    if found then
      return found
    end
  end

  local dir = lazy_dirs()[plugin_name]
  if dir then
    for _, file in ipairs(SPEC_FILES) do
      local path = dir .. "/" .. file
      if file_exists(path) then
        return path
      end
    end
  end

  return nil
end

---Every plugin that ships a deps spec, by directory name, sorted and
---de-duplicated (a plugin shipping both formats appears once). Covers both
---resolution sources `find` uses — `runtimepath` and, when lazy.nvim is
---present, its not-yet-loaded plugins. Drives `<Tab>` completion for
---`:Lib deps show|install`.
---@return string[]
function M.plugins()
  local seen, names = {}, {}

  ---@param name string|nil
  local function add(name)
    if name and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end

  for _, file in ipairs(SPEC_FILES) do
    -- Non-recursive for the same reason `find` is — see the comment there.
    for _, path in ipairs(vim.api.nvim_get_runtime_file(file, true)) do
      -- ".../<plugin-dir>/docs/<file>" — the plugin name is two segments up.
      add(path:gsub("\\", "/"):match("([^/]+)/docs/[^/]+$"))
    end
  end

  for name, dir in pairs(lazy_dirs()) do
    for _, file in ipairs(SPEC_FILES) do
      if file_exists(dir .. "/" .. file) then
        add(name)
        break
      end
    end
  end

  table.sort(names)
  return names
end

---@type Lib.Deps.Spec
return M
