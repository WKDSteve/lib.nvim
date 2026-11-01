-- TESTS/hooks_equivalence_spec.lua — lib.nvim.hooks against a reference copy of its original
-- implementation (plain arrays, `table.remove`, sort on every registration). The same pseudo-random
-- sequence of on / unregister / off / clear / count / run is driven through both and every observable
-- result must match: which hooks ran in which order, proceed, error count, the reported errors, counts
-- and the return value of `off`. Keeps the listener-core rewrite of `hooks` honest across veto,
-- `short_circuit`, priorities, duplicates and changes made by a hook while a run is in progress.

return function(H)
  local eq = H.eq
  local hooks = require("lib.nvim.hooks")

  -- ---------------------------------------------------------------- reference (the old code)
  local function reference_new(opts)
    local vetoable, list = {}, {}
    for _, name in ipairs(opts.events) do
      list[name] = {}
      vetoable[name] = name:sub(1, 7) == "before_"
    end
    if opts.vetoable then
      for name in pairs(vetoable) do
        vetoable[name] = false
      end
      for _, name in ipairs(opts.vetoable) do
        vetoable[name] = true
      end
    end
    local on_error = opts.on_error
    local seq = 0
    local reg = {}

    function reg.on(event, fn, hook_opts)
      local priority = hook_opts and hook_opts.priority
      seq = seq + 1
      local entry = { fn = fn, priority = priority or 0, seq = seq }
      local entries = list[event]
      entries[#entries + 1] = entry
      table.sort(entries, function(a, b)
        if a.priority ~= b.priority then
          return a.priority < b.priority
        end
        return a.seq < b.seq
      end)
      return function()
        for i, e in ipairs(list[event]) do
          if e == entry then
            table.remove(list[event], i)
            return
          end
        end
      end
    end

    function reg.off(event, fn)
      for i, e in ipairs(list[event]) do
        if e.fn == fn then
          table.remove(list[event], i)
          return true
        end
      end
      return false
    end

    function reg.clear(event)
      if event == nil then
        for name in pairs(list) do
          list[name] = {}
        end
        return
      end
      list[event] = {}
    end

    function reg.count(event)
      return #list[event]
    end

    function reg.run(event, ctx, extra)
      local fns = {}
      if type(extra) == "table" then
        for _, fn in ipairs(extra) do
          fns[#fns + 1] = fn
        end
      elseif extra ~= nil then
        fns[1] = extra
      end
      for _, e in ipairs(list[event]) do
        fns[#fns + 1] = e.fn
      end
      local proceed, errors = true, 0
      for _, fn in ipairs(fns) do
        local ok, result = pcall(fn, ctx)
        if not ok then
          errors = errors + 1
          pcall(on_error, event, result, fn)
        elseif result == false and vetoable[event] then
          proceed = false
          if opts.short_circuit then
            break
          end
        end
      end
      return proceed, errors
    end

    return reg
  end

  -- ---------------------------------------------------------------- the driver
  local EVENTS = { "before_apply", "after_apply", "before_write", "after_write" }

  -- A hook behaves by kind: stay quiet, veto, throw, or change the registry while it runs.
  local function make_hook(id, kind, state)
    return function()
      state.log[#state.log + 1] = "ran:" .. id
      if kind == "veto" then
        return false
      elseif kind == "true" then
        return true
      elseif kind == "throw" then
        error("boom" .. id, 0)
      elseif kind == "self_off" then
        state.reg.off(state.event, state.fns[id])
      elseif kind == "add_during" then
        state.reg.on(state.event, function()
          state.log[#state.log + 1] = "late"
        end)
      elseif kind == "clear_during" then
        state.reg.clear(state.event)
      end
      return nil
    end
  end

  local KINDS = { "quiet", "veto", "true", "throw", "self_off", "add_during", "clear_during" }

  -- Both registries log into one shared table, so hook runs and reported errors are compared together.
  local function run_pair(opts, seed)
    local shared = {}
    local function with_log(make)
      return function(o)
        o.on_error = function(event, err)
          shared[#shared + 1] = ("error:%s:%s"):format(event, tostring(err))
        end
        return make(o)
      end
    end
    local function trace(make)
      shared = {}
      local reg = with_log(make)(vim.tbl_extend("force", opts, { events = EVENTS }))
      local fns, handles, out = {}, {}, {}
      local rng = seed
      local function rand(n)
        rng = (rng * 1103515245 + 12345) % 2147483648
        return rng % n + 1
      end
      local state = { reg = reg, fns = fns, event = EVENTS[1], log = shared }
      for step = 1, 160 do
        local op = rand(10)
        local event = EVENTS[rand(#EVENTS)]
        state.event = event
        if op <= 4 then
          local id = #fns + 1
          fns[id] = make_hook(id, KINDS[rand(#KINDS)], state)
          local priority = ({ 0, 0, 1, -1, 5, 0.5 })[rand(6)]
          handles[#handles + 1] =
            reg.on(event, fns[id], priority ~= 0 and { priority = priority } or nil)
          out[#out + 1] = ("on:%s:%d:%s"):format(event, id, tostring(priority))
        elseif op == 5 and #handles > 0 then
          handles[rand(#handles)]()
          out[#out + 1] = "unregister"
        elseif op == 6 and #fns > 0 then
          out[#out + 1] = "off:" .. tostring(reg.off(event, fns[rand(#fns)]))
        elseif op == 7 then
          if rand(2) == 1 then
            reg.clear()
            out[#out + 1] = "clear-all"
          else
            reg.clear(event)
            out[#out + 1] = "clear:" .. event
          end
        elseif op == 8 then
          out[#out + 1] = ("count:%s:%d"):format(event, reg.count(event))
        else
          local extra
          local pick = rand(4)
          if pick == 2 then
            extra = function()
              shared[#shared + 1] = "extra"
            end
          elseif pick == 3 then
            extra = {
              function()
                shared[#shared + 1] = "extra1"
              end,
              function()
                shared[#shared + 1] = "extra2"
                return false
              end,
            }
          elseif pick == 4 then
            extra = "not callable"
          end
          local proceed, errors = reg.run(event, { step = step }, extra)
          out[#out + 1] = ("run:%s:%s:%d"):format(event, tostring(proceed), errors)
        end
        out[#out + 1] = "log=" .. table.concat(shared, ",")
        shared = {}
        state.log = shared
      end
      return out
    end
    return trace(reference_new), trace(hooks.new)
  end

  local variants = {
    {},
    { short_circuit = true },
    { vetoable = { "after_write" } },
    { vetoable = { "before_apply", "after_apply" }, short_circuit = true },
  }
  local compared = 0
  for vi, opts in ipairs(variants) do
    for seed = 1, 60 do
      local want, got = run_pair(opts, seed * 7919 + vi)
      eq(#got, #want, ("variant %d seed %d: same number of steps"):format(vi, seed))
      for i = 1, #want do
        if want[i] ~= got[i] then
          eq(got[i], want[i], ("variant %d seed %d step %d"):format(vi, seed, i))
          break
        end
      end
      compared = compared + #want
    end
  end
  eq(compared > 10000, true, "a few thousand operations were compared")
end
