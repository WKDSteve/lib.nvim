---@module 'lib.nvim.patterns.retry_backoff'
--- Retry with exponential backoff, callback style (non-blocking).
---
--- `run(task, opts)` calls `task(attempt, done)`; the task reports with `done(ok, value_or_err)`. On
--- failure it waits `delay(attempt)` ms and tries again until `max_attempts` is used up or
--- `should_retry(err, attempt)` says no. `opts.on_done(ok, value_or_err, attempts)` gets the end result.
---
--- ```lua
--- local retry = require("lib.nvim.patterns.retry_backoff")
--- retry.run(function(attempt, done)
---   fetch(url, function(err, body) done(err == nil, err or body) end)
--- end, { max_attempts = 4, base_ms = 200, on_done = function(ok, res) ... end })
--- ```
---
--- Delay: `base_ms * factor^(attempt-1)`, capped at `max_ms`; with `jitter` a random 50-100 % of it.
--- `opts.sleep(ms, cb)` is injectable (tests), the default is `vim.defer_fn`.

require("lib.nvim.patterns.retry_backoff.@types")

local M = {}

---Delay in ms before the retry that follows failed attempt number `attempt` (1-based).
---@param attempt integer
---@param opts Lib.Patterns.RetryBackoff.Opts|nil
---@return number
function M.delay(attempt, opts)
  opts = opts or {}
  local d = (opts.base_ms or 100) * (opts.factor or 2) ^ (attempt - 1)
  if d ~= d then
    d = 0 -- math.min(NaN, cap) would return the cap
  end
  d = math.min(d, opts.max_ms or 10000)
  if opts.jitter then
    d = d * (0.5 + math.random() * 0.5)
  end
  -- a negative or NaN delay would never fire; a retry must always be scheduled
  if d ~= d or d < 0 then
    d = 0
  end
  return d
end

local function check_number(opts, key, min)
  local v = opts[key]
  if v ~= nil and (type(v) ~= "number" or v ~= v or v < min) then
    error(("retry_backoff.run: opts.%s must be a number >= %s"):format(key, min), 3)
  end
end

---@param task fun(attempt: integer, done: fun(ok: boolean, value_or_err: any))
---@param opts Lib.Patterns.RetryBackoff.Opts|nil
function M.run(task, opts)
  if type(task) ~= "function" then
    error("retry_backoff.run: task must be a function", 2)
  end
  opts = opts or {}
  if opts.sleep ~= nil and type(opts.sleep) ~= "function" then
    error("retry_backoff.run: opts.sleep must be a function or nil", 2)
  end
  if opts.on_done ~= nil and type(opts.on_done) ~= "function" then
    error("retry_backoff.run: opts.on_done must be a function or nil", 2)
  end
  if opts.should_retry ~= nil and type(opts.should_retry) ~= "function" then
    error("retry_backoff.run: opts.should_retry must be a function or nil", 2)
  end
  check_number(opts, "max_attempts", 1)
  check_number(opts, "base_ms", 0)
  check_number(opts, "factor", 0)
  check_number(opts, "max_ms", 0)
  local max = opts.max_attempts or 5
  local sleep = opts.sleep or function(ms, cb)
    vim.defer_fn(cb, ms)
  end

  local function finish(ok, res, attempts)
    if opts.on_done then
      opts.on_done(ok, res, attempts)
    end
  end

  local function attempt_n(n)
    local settled = false
    local in_task = true
    local deferred_err
    local function complete(ok, res)
      if ok then
        return finish(true, res, n)
      end
      local retry_ok = n < max
      if retry_ok and opts.should_retry then
        -- a raising should_retry means "do not retry", never "wait forever"
        local rok, verdict = pcall(opts.should_retry, res, n)
        retry_ok = rok and verdict and true or false
      end
      if not retry_ok then
        return finish(false, res, n)
      end
      -- a sleep that cannot be scheduled ends the retry with that error instead of stalling
      local sok, serr = pcall(sleep, M.delay(n, opts), function()
        attempt_n(n + 1)
      end)
      if not sok then
        return finish(false, serr, n)
      end
    end
    local function done(ok, res)
      if settled then
        return
      end
      settled = true
      local cok, cerr = pcall(complete, ok, res)
      if not cok then
        -- an error of the completion path (on_done, sleep) is not a task failure: while the task is
        -- still on the stack it is re-raised after the task returned, otherwise to whoever called done()
        if in_task then
          deferred_err = cerr
        else
          error(cerr, 0)
        end
      end
    end
    local ok, err = pcall(task, n, done)
    in_task = false
    if deferred_err ~= nil then
      error(deferred_err, 0)
    end
    if not ok then
      done(false, err)
    end
  end

  attempt_n(1)
end

return M
