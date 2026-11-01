---@module 'lib.nvim.async'
--- Minimal coroutine async/await over libuv, plus the two control
--- primitives that need it (`Semaphore`, `Condvar`), plus `LatestWins`, a
--- "newest request wins" token gate for overlapping async work.
---
--- The whole thing rests on one protocol: `await(starter)` yields the
--- `starter` function, and the driver in `run()` calls `starter(resume)`.
--- Whatever `resume` receives becomes `await`'s return values. A libuv
--- callback is passed straight through as `resume`; a semaphore waiter is
--- just a stored `resume` called later. No promise/future objects, no
--- scheduler beyond `step()`.
---
--- Written against real duplication rather than speculatively: this is
--- the extraction of the private `await`/`run_async` helper that
--- `fs.collect_recursive` and `fs.write.async` each carried their own
--- (already diverging) copy of.
---
--- Neovim-side by design, not `lib.lua`: `run`'s completion and error
--- paths must hop through `vim.schedule`, because every resume after the
--- first happens inside a raw libuv callback (fast-event context) where
--- `vim.fn`/`vim.api` are off limits. `Semaphore`/`Condvar` are pure
--- coroutine mechanics, but only mean anything under this runner, so they
--- live here too.
---
---```lua
--- local async = require("lib.nvim.async")
---
--- local uv = vim.uv or vim.loop
--- local fs_open = async.wrap(uv.fs_open, 4) -- (path, flags, mode, cb)
---
--- async.run(function()
---   local err, fd = fs_open("/tmp/x", "r", 438)
---   if err then
---     return nil, err
---   end
---   return fd
--- end, function(fd, err)
---   -- vim.schedule-dispatched: safe to touch vim.api here
--- end, { tag = "my.module" })
---```

require("lib.nvim.async.@types")

local class = require("lib.lua.class")
local error_mod = require("lib.lua.error")

local varargs = require("lib.lua.functions.varargs")
local pack, unpack = varargs.pack, varargs.unpack

local M = {}

-- =========================================================
-- Core
-- =========================================================

--- Suspend the running coroutine until `starter` settles. `starter(resume)`
--- must arrange for `resume(...)` to be called — typically by passing it
--- straight through as a libuv callback. Whatever `resume` receives becomes
--- this call's return values. Only valid inside a coroutine driven by
--- `M.run`.
---@param starter fun(resume: fun(...))
---@return ... # whatever `resume` was called with
function M.await(starter)
  return coroutine.yield(starter)
end

--- Drive a coroutine written against `M.await` to completion.
---
--- `on_done` receives `body`'s return values (all of them, embedded `nil`s
--- included) and is `vim.schedule`-dispatched — every resume past the
--- first happens inside a raw libuv callback, so nothing after the last
--- `await()` may safely touch `vim.fn`/`vim.api` without that hop.
---
--- An error thrown inside `body` does not propagate to the original
--- caller (its stack is long gone by then); it goes to `opts.on_error`,
--- which defaults to a `vim.notify` prefixed with `opts.tag` so it lands
--- in `:messages` instead of vanishing into the event loop.
---@param body fun(): ...
---@param on_done? fun(...)
---@param opts? Lib.Async.RunOpts
function M.run(body, on_done, opts)
  opts = opts or {}
  local co = coroutine.create(body)

  local function step(...)
    local results = pack(coroutine.resume(co, ...))
    if not results[1] then
      local err = results[2]
      if opts.on_error then
        opts.on_error(err)
      else
        local tag = opts.tag or "lib.nvim.async"
        vim.schedule(function()
          vim.notify("[" .. tag .. "] " .. tostring(err), vim.log.levels.ERROR)
        end)
      end
      return
    end
    if coroutine.status(co) == "dead" then
      if on_done then
        vim.schedule(function()
          on_done(unpack(results, 2, results.n))
        end)
      end
      return
    end
    -- results[2] is the starter function `body` handed to `await()`,
    -- expecting `step` itself as its `resume` callback.
    results[2](step)
  end

  step()
end

--- Turn a callback-style function into an awaitable one. `argc` is the
--- total argument count of `fn` *including* its callback, which must be
--- the last parameter — `uv.fs_open(path, flags, mode, cb)` is `argc = 4`.
---
--- The returned function is only callable inside an `M.run` body; it
--- returns whatever `fn` passes to its callback.
---@param fn function
---@param argc integer
---@return fun(...): ...
function M.wrap(fn, argc)
  return function(...)
    local args = pack(...)
    return M.await(function(resume)
      args[argc] = resume
      -- Callers may legitimately pass fewer than argc-1 arguments (a uv
      -- function with optional parameters); the callback still has to land
      -- in slot argc, so the arg count grows to match rather than
      -- truncating it back to what was actually passed.
      args.n = math.max(args.n, argc)
      fn(unpack(args, 1, args.n))
    end)
  end
end

-- =========================================================
-- Control primitives
-- =========================================================

--- Counting semaphore: at most `permits` coroutines hold it at once.
--- `:acquire()` is awaitable and suspends when none are free.
---
--- Note that `:release()` resumes a waiting coroutine *synchronously*,
--- so it does not return until that coroutine yields again or finishes.
--- That keeps the handover ordering obvious (no scheduler round-trip
--- between a release and the acquire it unblocks) at the cost of nesting
--- the resumed coroutine's stack under the releasing one.
local Semaphore = class.new("Semaphore")

---@param permits integer
function Semaphore:init(permits)
  self.permits = permits
  self.waiters = {}
end

--- Take a permit, suspending until one is free. Awaitable.
function Semaphore:acquire()
  if self.permits > 0 then
    self.permits = self.permits - 1
    return
  end
  M.await(function(resume)
    self.waiters[#self.waiters + 1] = resume
  end)
end

--- Give a permit back. Hands it straight to the longest-waiting acquirer
--- if there is one — the permit count only grows when nobody is waiting,
--- otherwise a waiter could be starved by a later `acquire()` racing in.
function Semaphore:release()
  local waiter = table.remove(self.waiters, 1)
  if waiter then
    waiter()
  else
    self.permits = self.permits + 1
  end
end

--- Run `body(...)` while holding a permit, releasing it on every path: a
--- normal return and an error in `body` alike. Awaitable (`body` may itself
--- `await`; the yield crosses the guarding `xpcall` on LuaJIT).
---
--- `acquire` + `release` by hand leak the permit when `body` throws, which
--- starves every later acquirer; this is the leak-proof form.
---@param body fun(...): ...
---@param ... any Forwarded to `body`
---@return boolean ok
---@return any ... `body`'s return values, or a structured `LibErrorValue` (`lib.lua.error.safe_call`) when it threw
function Semaphore:with(body, ...)
  self:acquire()
  local outcome = pack(error_mod.safe_call(body, ...))
  self:release()
  return unpack(outcome, 1, outcome.n)
end

M.Semaphore = Semaphore

--- Condition variable: `:wait()` suspends until someone notifies.
--- Like `Semaphore:release`, notifying resumes waiters synchronously.
local Condvar = class.new("Condvar")

function Condvar:init()
  self.waiters = {}
end

--- Suspend until a `notify_one`/`notify_all` reaches this waiter. Awaitable.
function Condvar:wait()
  M.await(function(resume)
    self.waiters[#self.waiters + 1] = resume
  end)
end

--- Wake the longest-waiting coroutine, if any.
function Condvar:notify_one()
  local waiter = table.remove(self.waiters, 1)
  if waiter then
    waiter()
  end
end

--- Wake every waiting coroutine. The waiter list is swapped out first, so
--- a coroutine that re-`wait()`s while being woken queues up for the next
--- notify instead of being woken again by this one.
function Condvar:notify_all()
  local waiters = self.waiters
  self.waiters = {}
  for _, waiter in ipairs(waiters) do
    waiter()
  end
end

M.Condvar = Condvar

-- =========================================================
-- Bounded fan-out
-- =========================================================

--- Run a callback-style `worker` over every item with **at most `limit` of
--- them in flight**, collect the results in item order, and tell the caller
--- when the last one finished (or when it stopped the run).
---
--- The shape every "do this for each of N repositories/files/servers" feature
--- hand-builds: start `limit` jobs, start the next one whenever one finishes,
--- count down, call back. It exists once here because the hand-built copies
--- each get a different corner wrong -- re-entrancy (a worker that finishes
--- synchronously), a throwing worker that stalls the run, a late result after
--- the caller gave up.
---
--- `worker(item, index, done)` starts the work for one item and must call
--- `done(result, err)` **exactly once** when it is finished (a second call is
--- ignored). It may return a handle with a `stop()` method -- what
--- `run_async_captured` and the `*_async` helpers of `lib.nvim.git` return --
--- so `stop` on the run can kill whatever is still in flight. A worker that
--- *throws* counts as finished with that error; it neither stalls the run nor
--- escapes into the caller. A worker that never calls `done` stalls the run,
--- as it would any hand-built pool.
---
--- `on_progress` (after every finished item) and `on_done` are
--- `vim.schedule`d, in the order the events happened, so they are always safe
--- to use `vim.api` in. `worker` is not: it is called synchronously -- for the
--- first `limit` items from inside this function, for the rest from whichever
--- call of `done` freed a slot, i.e. in the context `done` was called from.
--- That is the main loop for `run_async_captured` and every `*_async` helper
--- (they all `vim.schedule` their callback); a worker driven by a raw libuv
--- callback must not touch `vim.api` itself.
---
--- `on_done(results, errors, stopped)`: `results[i]` and `errors[i]` belong to
--- `items[i]` (both sparse: a successful item has no error, a failed one
--- usually no result). After `stop()` they hold what had finished by then,
--- `stopped` is `true`, and anything finishing later is discarded.
---@generic T
---@param items T[]
---@param limit integer Maximum in-flight workers; clamped to at least 1.
---@param worker fun(item: T, index: integer, done: fun(result: any, err: any)): { stop: fun() }|nil
---@param on_done fun(results: any[], errors: any[], stopped: boolean)
---@param opts? Lib.Async.MapLimitOpts
---@return { stop: fun() } handle `stop()` kills in-flight workers that returned a handle, starts no further ones and calls `on_done(..., true)` once; a no-op after the run finished.
function M.map_limit(items, limit, worker, on_done, opts)
  if type(items) ~= "table" then
    error("lib.nvim.async.map_limit: `items` must be a list", 2)
  end
  if type(worker) ~= "function" or type(on_done) ~= "function" then
    error("lib.nvim.async.map_limit: `worker` and `on_done` must be functions", 2)
  end
  opts = opts or {}
  limit = tonumber(limit) or 1
  if limit ~= limit then -- NaN: `math.max(1, nan)` would stay NaN and start nothing
    limit = 1
  end
  limit = math.max(1, math.floor(limit))

  local total = #items
  local results, errors = {}, {}
  local in_flight = {} ---@type table<integer, { stop?: fun() }>
  local next_index, running, completed = 1, 0, 0
  local finished, pumping = false, false

  local function finish(stopped)
    if finished then
      return
    end
    finished = true
    vim.schedule(function()
      on_done(results, errors, stopped)
    end)
  end

  local pump

  local function start(index)
    local called = false

    local function done(result, err)
      if called then
        return
      end
      called = true
      in_flight[index] = nil
      if finished then
        return -- the run was stopped; a late result has nowhere to go
      end
      running = running - 1
      completed = completed + 1
      results[index] = result
      errors[index] = err
      if opts.on_progress then
        local count = completed
        vim.schedule(function()
          opts.on_progress(count, total, index, result, err)
        end)
      end
      if completed == total then
        finish(false)
      else
        pump()
      end
    end

    local ok, handle = pcall(worker, items[index], index, done)
    if not ok then
      -- `handle` is the error here, whatever was thrown. `error(nil)` and
      -- `error(false)` throw a falsy value: it must still read as an error, or
      -- the item would look like a success without a result.
      done(nil, (handle ~= nil and handle ~= false) and handle or "worker raised an error")
    elseif type(handle) == "table" and not called then
      if finished then
        -- The worker stopped the run while it was starting: nobody will ever
        -- stop this one, so it is stopped here.
        if type(handle.stop) == "function" then
          pcall(handle.stop)
        end
      else
        in_flight[index] = handle
      end
    end
  end

  -- A worker that finishes synchronously calls `done` -> `pump` from inside
  -- `start`; without the guard that recursion is as deep as the item list.
  pump = function()
    if pumping then
      return
    end
    pumping = true
    while not finished and running < limit and next_index <= total do
      local index = next_index
      next_index = next_index + 1
      running = running + 1
      start(index)
    end
    pumping = false
  end

  if total == 0 then
    finish(false)
  else
    pump()
  end

  return {
    stop = function()
      if finished then
        return
      end
      -- Mark the run finished BEFORE stopping anything: a worker handle whose
      -- stop() reports back through `done` (a timer, a cancelled request)
      -- would otherwise count as a normal completion and start the next item.
      local handles = in_flight
      in_flight = {}
      finish(true)
      for _, handle in pairs(handles) do
        if type(handle.stop) == "function" then
          pcall(handle.stop)
        end
      end
    end,
  }
end

-- =========================================================
-- Supersession
-- =========================================================

--- "Newest request wins" token gate. Recurs everywhere a caller kicks off
--- overlapping async work (picker preview, LSP request, search-as-you-type)
--- and only the most recent one's result should land — a stale callback
--- firing after a newer request started must not overwrite it.
---
--- Not tied to `M.run`/coroutines: `:begin()`/`:is_current()` are plain
--- synchronous calls, usable around any callback-based async call, not just
--- `await`-driven ones.
local LatestWins = class.new("LatestWins")

function LatestWins:init()
  self.token = 0
end

--- Mint a new token, superseding whichever one was handed out before it.
---@return integer token
function LatestWins:begin()
  self.token = self.token + 1
  return self.token
end

--- Whether `token` is still the newest one `begin()` handed out — i.e.
--- nothing has superseded it since.
---@param token integer
---@return boolean
function LatestWins:is_current(token)
  return token == self.token
end

--- Run `fn` only if `token` is still current; a no-op otherwise. Convenience
--- for the common "apply the result, but only if not superseded" shape.
---@param token integer
---@param fn fun(...)
---@param ... any Forwarded to `fn`
function LatestWins:if_current(token, fn, ...)
  if self:is_current(token) then
    fn(...)
  end
end

M.LatestWins = LatestWins

--- Shorthand for `LatestWins.new()`.
---@return Lib.Async.LatestWins
function M.latest_wins()
  return LatestWins.new()
end

---@type Lib.Async
return M
