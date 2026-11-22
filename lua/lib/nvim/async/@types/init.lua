---@meta
---@module 'lib.nvim.async.@types'

---Options for `require("lib.nvim.async").run`.
---@class Lib.Async.RunOpts
---@field tag? string Prefix for the default error notification (default `"lib.nvim.async"`); ignored when `on_error` is set.
---@field on_error? fun(err: any) Called instead of the default `vim.notify` when the coroutine body raises. Not `vim.schedule`-wrapped — it may run in a fast-event context.

---Options for `require("lib.nvim.async").map_limit`.
---@class Lib.Async.MapLimitOpts
---@field on_progress? fun(done_count: integer, total: integer, index: integer, result: any, err: any) Called (`vim.schedule`d) after every finished item, in the order they finished -- not item order.

---Something that can be stopped: the handle `map_limit` returns, and what a worker may
---return so that `stop()` on the run can kill it (`run_async_captured`, `lib.nvim.git`'s
---`*_async` helpers).
---@class Lib.Async.Stoppable
---@field stop fun() Stop the work; harmless to call after it finished.

---The callback-style worker `map_limit` fans out: start the work for `item`, call `done`
---exactly once when finished, optionally return a `Lib.Async.Stoppable`.
---@alias Lib.Async.MapLimitWorker fun(item: any, index: integer, done: fun(result: any, err: any)): Lib.Async.Stoppable|nil

---Options for `require("lib.nvim.async").all`.
---@class Lib.Async.AllOpts
---@field in_flight? Lib.Async.InFlight Counts the run as one piece of work until `on_done` returned.

---@class Lib.Async.InFlightClass
---@field new fun(): Lib.Async.InFlight

---Counter of callbacks still to come (`idle()` for specs). One per consumer.
---@class Lib.Async.InFlight
---@field pending integer Tracked pieces of work that have not called back yet.
---@field track fun(self: Lib.Async.InFlight, cb?: function): function Count one piece of work; the returned wrapper uncounts it once, after `cb` returned.
---@field count fun(self: Lib.Async.InFlight): integer How many tracked pieces have not called back yet.
---@field idle fun(self: Lib.Async.InFlight): boolean Whether nothing tracked is waiting for its callback.

---@class Lib.Async
---@field all fun(tasks: (fun(done: fun(result: any, err: any)): Lib.Async.Stoppable|nil)[], on_done: fun(results: any[], errors: any[], stopped: boolean), opts?: Lib.Async.AllOpts): Lib.Async.Stoppable # Start every task at once, answer once when the last one is back.
---@field InFlight Lib.Async.InFlightClass
---@field in_flight fun(): Lib.Async.InFlight Shorthand for `InFlight.new()`.
---@field await fun(starter: fun(resume: fun(...))): ... Suspend until `starter` calls its `resume`.
---@field map_limit fun(items: any[], limit: integer, worker: Lib.Async.MapLimitWorker, on_done: fun(results: any[], errors: any[], stopped: boolean), opts?: Lib.Async.MapLimitOpts): Lib.Async.Stoppable # Run a callback-style worker over every item with at most `limit` in flight; results in item order, `stop()` kills what is still running.
---@field run fun(body: function, on_done?: function, opts?: Lib.Async.RunOpts) Drive an `await`-using coroutine to completion.
---@field wrap fun(fn: function, argc: integer): fun(...): ... Turn a callback-style function (callback last, at position `argc`) into an awaitable one.
---@field Semaphore Lib.Async.SemaphoreClass
---@field Condvar Lib.Async.CondvarClass
---@field LatestWins Lib.Async.LatestWinsClass
---@field latest_wins fun(): Lib.Async.LatestWins Shorthand for `LatestWins.new()`.

---@class Lib.Async.SemaphoreClass
---@field new fun(permits: integer): Lib.Async.Semaphore

---Counting semaphore instance; `:acquire()` is only valid inside an `async.run` body.
---@class Lib.Async.Semaphore
---@field permits integer Currently free permits.
---@field waiters fun(...)[] Suspended acquirers, longest-waiting first.
---@field acquire fun(self: Lib.Async.Semaphore) Take a permit, suspending until one is free.
---@field release fun(self: Lib.Async.Semaphore) Give a permit back, handing it straight to a waiter if there is one.
---@field with fun(self: Lib.Async.Semaphore, body: function, ...: any): boolean, ... Hold a permit around `body(...)`, released also when `body` throws (`ok, ...` like `lib.lua.error.safe_call`).

---@class Lib.Async.CondvarClass
---@field new fun(): Lib.Async.Condvar

---Condition variable instance; `:wait()` is only valid inside an `async.run` body.
---@class Lib.Async.Condvar
---@field waiters fun(...)[] Suspended waiters, longest-waiting first.
---@field wait fun(self: Lib.Async.Condvar) Suspend until notified.
---@field notify_one fun(self: Lib.Async.Condvar) Wake the longest-waiting coroutine, if any.
---@field notify_all fun(self: Lib.Async.Condvar) Wake every waiting coroutine.

---@class Lib.Async.LatestWinsClass
---@field new fun(): Lib.Async.LatestWins

---"Newest request wins" token gate instance. Not tied to `M.run`; usable
---around any callback-based async call.
---@class Lib.Async.LatestWins
---@field token integer The most recently minted token without a key.
---@field keyed table<any, integer> The most recently minted token per key.
---@field begin fun(self: Lib.Async.LatestWins, key?: any): integer Mint a new token, superseding the previous one (of the same key).
---@field is_current fun(self: Lib.Async.LatestWins, token: integer, key?: any): boolean Whether `token` is still the newest one minted (for `key`).
---@field ticket fun(self: Lib.Async.LatestWins, key?: any): fun(): boolean `begin(key)` as a closure: `valid()` until the next token of the same key.
---@field if_current fun(self: Lib.Async.LatestWins, token: integer, fn: fun(...), ...) Run `fn` only if `token` is still current.

return {}
