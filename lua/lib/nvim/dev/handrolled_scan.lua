---@module 'lib.nvim.dev.handrolled_scan'
--- Where do sibling plugin repos hand-roll a debounce, a throttle or an event
--- emitter that `lib.nvim.debounce`, `lib.nvim.patterns.throttle` or
--- `lib.nvim.hooks` already provide? A worklist and a warning, never a gate:
--- `LUA-09` points here, nothing fails because of a finding.
---@description
--- A line scanner with a heuristic, not a parser. Per file of every immediate
--- subdirectory of `root` (`lua/`, `plugin/`):
---
---   * `debounce` -- a timer that lives longer than one call (`local timer`
---     at module level, or a field such as `self.timer`) is created with
---     `new_timer()` and both `:stop()`ped and `:start()`ed in the same file,
---     i.e. restarted on each event. A one-shot timer (`local t = new_timer()`
---     inside a function, started and closed there) is not a finding.
---   * `throttle` -- the file takes a clock reading (`uv.now()`, `hrtime()`,
---     `os.clock()`) and subtracts a `last*` variable from it.
---   * `emitter` -- the file keeps a `listeners`/`subscribers`/`observers`
---     table and defines an `emit`/`fire`/`publish`/`dispatch` function.
---
--- Exceptions, so the output stays a worklist and does not turn into noise:
---
---   * `-- handrolled-ok: <reason>` anywhere in the file silences it (the
---     reason is the point: say why the shared module does not carry the case).
---   * `opts.exceptions`, a map of `"repo"` or `"repo/lua/rel/path.lua"` to a
---     reason, for files that cannot carry a comment.
---
--- Not scanned: `TESTS/`, `tests/`, `.deps/`, `.git/`, `node_modules/` and
--- `lib.nvim` itself (the shared modules are the reference, not a finding).

local M = {}

---@class Lib.Dev.HandrolledScan.Finding
---@field repo string
---@field file string Path relative to the repo
---@field line integer
---@field kind string "debounce"|"throttle"|"emitter"
---@field name string The timer / variable / table the heuristic keyed on
---@field hint string The shared module to use instead

---@class Lib.Dev.HandrolledScan.Opts
---@field exclude? string[] Extra repo directory names to skip
---@field exceptions? table<string, string> `"repo"` or `"repo/rel/path.lua"` -> reason

local ALWAYS_EXCLUDED = { ["lib.nvim"] = true }
local SKIP_DIRS =
  { TESTS = true, tests = true, [".deps"] = true, [".git"] = true, node_modules = true }

local HINTS = {
  debounce = "lib.nvim.debounce",
  throttle = "lib.nvim.patterns.throttle",
  emitter = "lib.nvim.hooks (or lib.lua.patterns.event_bus)",
}

local EMITTER_TABLES = { "listeners", "subscribers", "observers" }
local EMITTER_FUNCTIONS = { "emit", "fire", "publish", "dispatch" }
local OK_MARKER = "handrolled-ok"

---@param path string
---@return string[]
local function read_lines(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or {}
end

---Removes a trailing `-- comment` when it is not inside a string (approximate:
---a `--` after an odd number of quotes is kept).
---@param line string
---@return string
local function strip_comment(line)
  local pos = line:find("%-%-")
  while pos do
    local before = line:sub(1, pos - 1)
    local _, dq = before:gsub('"', "")
    local _, sq = before:gsub("'", "")
    if dq % 2 == 0 and sq % 2 == 0 then
      return before
    end
    pos = line:find("%-%-", pos + 2)
  end
  return line
end

---@param s string
---@return string
local function escape(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

---@param code string[]
---@return Lib.Dev.HandrolledScan.Finding[] findings Without repo/file
local function analyse(code)
  local out = {}

  -- debounce: a timer is created, started one-shot (repeat 0) and a *long-lived*
  -- handle (a field such as `st.timer`, or a `local pending` at column 0) is
  -- stopped, i.e. the previous run is cancelled when a new event comes in.
  -- `start(every, every, ...)` is a periodic poll or heartbeat, not a debounce.
  local one_shot, timer_line = false, nil
  for i, l in ipairs(code) do
    if l:find("new_timer%s*%(") and not timer_line then
      timer_line = i
    end
    if l:match(":start%(%s*[^,]+,%s*0%s*,") then
      one_shot = true
    elseif l:match(":start%(%s*$") then
      -- multi-line call: the repeat is the second argument, two lines further down
      local args = (code[i + 1] or "") .. (code[i + 2] or "")
      if args:match("^%s*[^,]+,%s*0%s*,") then
        one_shot = true
      end
    end
  end
  if timer_line and one_shot then
    for _, l in ipairs(code) do
      local name = l:match("([%a_][%w_%.]*):stop%s*%(")
      if name then
        local persistent = name:find(".", 1, true) ~= nil
        if not persistent then
          for _, c in ipairs(code) do
            if
              c:match("^local%s+" .. escape(name) .. "%s*$")
              or c:match("^local%s+" .. escape(name) .. "%s*=%s*nil")
            then
              persistent = true
              break
            end
          end
        end
        if persistent then
          out[#out + 1] =
            { line = timer_line, kind = "debounce", name = name, hint = HINTS.debounce }
          break
        end
      end
    end
  end

  -- throttle: a clock reading minus a `last*` variable.
  local has_clock = false
  for _, l in ipairs(code) do
    if l:find("%.now%s*%(") or l:find("hrtime%s*%(") or l:find("os%.clock%s*%(") then
      has_clock = true
      break
    end
  end
  if has_clock then
    for i, l in ipairs(code) do
      local name
      for operand in l:gmatch("%-%s*([%a_][%w_%.]*)") do
        if operand:find("last", 1, true) then
          name = operand
          break
        end
      end
      if name then
        out[#out + 1] = { line = i, kind = "throttle", name = name, hint = HINTS.throttle }
        break
      end
    end
  end

  -- emitter: a listeners table plus an emit-like function in one file.
  local table_line, table_name
  for i, l in ipairs(code) do
    for _, n in ipairs(EMITTER_TABLES) do
      if l:match("[%s%.]" .. n .. "%s*=%s*{%s*}") or l:match("^" .. n .. "%s*=%s*{%s*}") then
        table_line, table_name = i, n
        break
      end
    end
    if table_line then
      break
    end
  end
  if table_line then
    for _, l in ipairs(code) do
      for _, f in ipairs(EMITTER_FUNCTIONS) do
        if l:match("function%s+[%w_%.:]*" .. f .. "%s*%(") or l:match(f .. "%s*=%s*function") then
          out[#out + 1] =
            { line = table_line, kind = "emitter", name = table_name, hint = HINTS.emitter }
          return out
        end
      end
    end
  end

  return out
end

---@param repo_dir string
---@param repo string
---@param exceptions table<string, string>
---@return Lib.Dev.HandrolledScan.Finding[]
local function scan_repo(repo_dir, repo, exceptions)
  local out = {}
  local files = {}
  for _, sub in ipairs({ "lua", "plugin" }) do
    local base = repo_dir .. "/" .. sub
    if vim.fn.isdirectory(base) == 1 then
      for name, kind in
        vim.fs.dir(base, {
          depth = 20,
          skip = function(dir)
            return not SKIP_DIRS[dir]
          end,
        })
      do
        if kind == "file" and name:sub(-4) == ".lua" then
          files[#files + 1] = sub .. "/" .. name
        end
      end
    end
  end
  table.sort(files)

  for _, rel in ipairs(files) do
    if not exceptions[repo .. "/" .. rel] then
      local lines = read_lines(repo_dir .. "/" .. rel)
      local excused = false
      local code = {}
      for i, raw in ipairs(lines) do
        if raw:find(OK_MARKER, 1, true) then
          excused = true
        end
        code[i] = raw:match("^%s*%-%-") and "" or strip_comment(raw)
      end
      if not excused then
        for _, f in ipairs(analyse(code)) do
          f.repo, f.file = repo, rel
          out[#out + 1] = f
        end
      end
    end
  end
  return out
end

---Scans every sibling repo under `root`.
---@param root? string Directory holding the repos (default: cwd)
---@param opts? Lib.Dev.HandrolledScan.Opts
---@return Lib.Dev.HandrolledScan.Finding[]
function M.scan(root, opts)
  root = root or vim.fn.getcwd()
  local skip = vim.tbl_extend("force", {}, ALWAYS_EXCLUDED)
  for _, name in ipairs(opts and opts.exclude or {}) do
    skip[name] = true
  end
  local exceptions = opts and opts.exceptions or {}

  local all = {}
  for _, name in ipairs(vim.fn.readdir(root) or {}) do
    local dir = root .. "/" .. name
    if not skip[name] and not exceptions[name] and vim.fn.isdirectory(dir .. "/lua") == 1 then
      vim.list_extend(all, scan_repo(dir, name, exceptions))
    end
  end
  return all
end

---Per-repo totals, most findings first.
---@param findings Lib.Dev.HandrolledScan.Finding[]
---@return { repo: string, total: integer, by_kind: table<string, integer> }[]
function M.summarize(findings)
  local by_repo = {}
  for _, f in ipairs(findings) do
    local r = by_repo[f.repo] or { repo = f.repo, total = 0, by_kind = {} }
    by_repo[f.repo] = r
    r.total = r.total + 1
    r.by_kind[f.kind] = (r.by_kind[f.kind] or 0) + 1
  end
  local list = vim.tbl_values(by_repo)
  table.sort(list, function(a, b)
    if a.total ~= b.total then
      return a.total > b.total
    end
    return a.repo < b.repo
  end)
  return list
end

---Markdown report; every finding is a warning (`WARN`), none is an error.
---@param root? string
---@param opts? Lib.Dev.HandrolledScan.Opts
---@return string[]
function M.lines(root, opts)
  local findings = M.scan(root, opts)
  local lines = { "| Repo | Warnings | Kinds |", "|---|---|---|" }
  for _, r in ipairs(M.summarize(findings)) do
    local kinds = {}
    for kind, n in pairs(r.by_kind) do
      kinds[#kinds + 1] = kind .. "=" .. n
    end
    table.sort(kinds)
    lines[#lines + 1] = ("| %s | %d | %s |"):format(r.repo, r.total, table.concat(kinds, " "))
  end
  if #findings == 0 then
    lines[#lines + 1] = "| (none) | 0 | |"
  end

  local current
  for _, f in ipairs(findings) do
    if f.repo ~= current then
      current = f.repo
      lines[#lines + 1] = ""
      lines[#lines + 1] = "### " .. f.repo
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = ("- WARN `%s:%d` %s `%s` -> use %s"):format(
      f.file,
      f.line,
      f.kind,
      f.name,
      f.hint
    )
  end
  return lines
end

---Expose `:<name> [path]` for the calling config. Put this call in **your own
---config**, not in a library, like every other `create_usercmd` in lib.nvim.
---@param name? string Default `LibHandrolledScan`
---@return nil
function M.create_usercmd(name)
  local base = name or "LibHandrolledScan"
  require("lib.nvim.bindings.usercmd").create(base, function(cmd_opts)
    local root = cmd_opts.args ~= "" and vim.fn.fnamemodify(cmd_opts.args, ":p"):gsub("[/\\]$", "")
      or nil
    local lines = M.lines(root)
    local ok, kit = pcall(require, "lib.nvim.ui.kit")
    if ok then
      kit.viewer({
        lines = lines,
        title = " " .. base .. " ",
        width = math.min(140, vim.o.columns - 8),
      })
    else
      print(table.concat(lines, "\n"))
    end
  end, {
    nargs = "?",
    complete = "dir",
    desc = "Hand-rolled debounce / throttle / event emitters that lib.nvim already provides (warnings, LUA-09)",
  })
end

return M
