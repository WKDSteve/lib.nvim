---@module 'lib.nvim.system.lines'
--- Turning a subprocess's output chunks into whole lines.
---
--- Nothing that reads a process hands over lines. `vim.system`'s `stdout` /
--- `stderr` function handlers pass whatever libuv read, so a chunk can end
--- mid-line and the rest arrive in the next one. `jobstart` has the same
--- property in list form (`:h channel-lines`): the first element of a callback
--- continues the last element of the previous one. Code that splits each chunk
--- on its own therefore cuts those lines in two -- measured on 4000 lines of
--- output: 4026 entries, 26 of them malformed.
---
--- The trailing CR goes too, and that is not optional either. `vim.system`'s
--- `text = true` normalizes CRLF only for the stdout it captures *itself* --
--- it does not cover a function handler, so passing it alongside one reads
--- like a guarantee that never applied. On Windows every line would otherwise
--- carry a CR.
---
--- The trailing partial is held in memory until its newline arrives, with no
--- bound: output that never emits one accumulates in full. That is inherent to
--- line buffering rather than a choice made here, but it is worth knowing
--- before streaming something whose shape you do not control -- a caller that
--- needs a ceiling has to impose it on the process, not on this.
---
--- Both shapes are here because callers genuinely need both: `M.collector()`
--- when you want to pull lines out of chunks you already have, `M.buffered()`
--- when you want a ready-made `vim.system` handler that calls you per line.
--- The second is built on the first.
---
--- >lua
---   local lines = require("lib.nvim.system.lines")
---
---   -- pull: hand it chunks, get whole lines back
---   local c = lines.collector()
---   for _, line in ipairs(c.feed(chunk)) do ... end
---   local last = c.flush()   -- output that never got its newline
---
---   -- push: a vim.system stdout/stderr handler
---   vim.system(cmd, { stdout = lines.buffered(function(_, line) ... end) })
--- <

require("lib.nvim.system.@types")

local M = {}

---@internal
---Strip the one trailing CR a CRLF line ending leaves behind. A CR *inside*
---the line is the process's own output and stays.
---@param line string
---@return string
local function strip_cr(line)
  if line:sub(-1) == "\r" then
    return line:sub(1, -2)
  end
  return line
end

---A line collector: feed it output chunks, get whole lines back.
---
---The trailing partial is held back until more of the same stream completes
---it, so give each stream its own collector. A shared one would let a stdout
---chunk that has not seen its newline yet be completed by whatever stderr
---delivers first, producing a line that existed in neither.
---
---Blank lines are returned as `""` rather than dropped: whether an empty line
---means anything is the caller's question, not this module's.
---@return Lib.System.Lines.Collector
function M.collector()
  -- The unterminated tail, kept as the chunks it arrived in and joined only
  -- once its newline shows up. Concatenating it with every chunk and
  -- splitting the whole buffer again made a stream that never sends a
  -- newline (a `\r` progress bar, minified JSON) cost O(n^2) in its length.
  local pending = {}

  return {
    feed = function(data)
      if not data:find("\n", 1, true) then
        if data ~= "" then
          pending[#pending + 1] = data
        end
        return {}
      end
      -- Only the new chunk is split. Its first part continues the pending
      -- tail; its last part is either a partial line or "" (the chunk ended
      -- on a newline) and becomes the new tail. A CRLF torn across two chunks
      -- still strips because the CR is only examined once the joined line is
      -- complete.
      local parts = vim.split(data, "\n", { plain = true })
      if #pending > 0 then
        pending[#pending + 1] = parts[1]
        parts[1] = table.concat(pending)
      end
      local tail = table.remove(parts)
      pending = tail ~= "" and { tail } or {}
      for i = 1, #parts do
        parts[i] = strip_cr(parts[i])
      end
      return parts
    end,

    flush = function()
      -- Strip before deciding, not after: a remainder of exactly "\r" is a
      -- line ending whose newline never arrived, not a line. Testing
      -- emptiness first returned it as "", which is truthy in Lua, so a
      -- caller writing `if last then ...` emitted a blank line at the end of
      -- every such stream.
      local last = strip_cr(table.concat(pending))
      pending = {}
      if last == "" then
        return nil
      end
      return last
    end,
  }
end

---Call `fn(line)` for every line, in order. A `fn` that throws must not take the
---rest of its batch down with it: every line is delivered first and the first
---error is raised afterwards, where `vim.schedule` still reports it. Meant to
---run inside ONE scheduled callback per chunk (a chunk of thousands of short
---lines would otherwise queue thousands of closures).
---@param batch string[]
---@param fn fun(line: string)
---@return nil
function M.deliver(batch, fn)
  local first_err
  for _, line in ipairs(batch) do
    local ok, err = xpcall(fn, debug.traceback, line)
    if not ok and first_err == nil then
      first_err = err
    end
  end
  if first_err ~= nil then
    error(first_err, 0)
  end
end

---A `vim.system` `stdout`/`stderr` handler that calls `cb` once per whole
---line, on the main loop.
---
---Returns nil for a nil `cb`, so it can wrap an optional handler without the
---caller branching. The `err` argument libuv reports is not forwarded: this
---exists to deliver lines, and every caller so far treats a read error as the
---process failing, which the exit callback already reports.
---@param cb fun(err: nil, line: string)|nil
---@return fun(err: string|nil, data: string|nil)|nil
function M.buffered(cb)
  if not cb then
    return nil
  end

  local collector = M.collector()

  return function(_, data)
    if not data then
      -- EOF. A trailing fragment with no newline after it is still a line, and
      -- plenty of real output ends that way -- a file whose last line has no
      -- terminator, `printf` without a trailing \n, a program killed mid-line.
      -- Returning here without flushing drops it silently.
      local last = collector.flush()
      if last then
        vim.schedule(function()
          cb(nil, last)
        end)
      end
      return
    end

    -- One scheduled callback per chunk, not per line; the caller still sees
    -- one call per line, in order (see `M.deliver`).
    local got = collector.feed(data)
    if #got > 0 then
      vim.schedule(function()
        M.deliver(got, function(line)
          cb(nil, line)
        end)
      end)
    end
  end
end

return M
