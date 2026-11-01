-- TESTS/ordered_map_spec.lua — lib.lua.ordered_map, the core under lib.nvim.registry and
-- lib.lua.patterns.repository. Basics, then a differential run against a naive array model (every
-- put / delete / get / keys / each / count must agree, including deletes made inside an `each`).

return function(H)
  local eq, ok = H.eq, H.ok
  local ordered_map = require("lib.lua.ordered_map")

  local function join(list)
    return table.concat(list, ",")
  end

  -- ---------------------------------------------------------------- basics
  local m = ordered_map.new()
  m:put("b", 1)
  m:put("a", 2)
  m:put("b", 3)
  eq(join(m:keys()), "b,a", "a repeated put keeps the position")
  eq(m:get("b"), 3, "and replaces the value")
  eq(m:count(), 2)
  ok(m:has("a") and not m:has("z"))
  ok(m:delete("b"), "delete reports a hit")
  ok(not m:delete("b"), "and a miss")
  m:put("b", 9)
  eq(join(m:keys()), "a,b", "a deleted key comes back at the end")
  ok(not pcall(m.put, m, nil, 1), "nil key is refused")
  ok(not pcall(m.put, m, 0 / 0, 1), "NaN key is refused")
  ok(not pcall(m.put, m, "k", nil), "nil value is refused")
  ok(not m:delete(nil), "deleting nil is a miss")

  -- an each: stop on a truthy return, skip what is deleted meanwhile, ignore what is put meanwhile
  local walk = ordered_map.new()
  for _, k in ipairs({ "1", "2", "3", "4" }) do
    walk:put(k, k)
  end
  local seen = {}
  walk:each(function(k)
    seen[#seen + 1] = k
    if k == "1" then
      walk:delete("2")
      walk:put("5", "5")
    end
    return k == "3"
  end)
  eq(join(seen), "1,3", "deleted skipped, stop honoured, late put not visited")
  eq(join(walk:keys()), "1,3,4,5")

  -- a raising callback releases the walk
  local boom = ordered_map.new()
  boom:put("x", 1)
  ok(not pcall(boom.each, boom, function()
    error("boom")
  end))
  eq(boom.walking, 0)

  m:clear()
  eq(m:count(), 0)
  eq(join(m:keys()), "")
  m:put("z", 1)
  eq(join(m:keys()), "z", "usable after clear")

  -- ---------------------------------------------------------------- differential
  for seed = 1, 40 do
    local rng = seed * 7919
    local function rand(n)
      rng = (rng * 1103515245 + 12345) % 2147483648
      return rng % n + 1
    end
    local real, model = ordered_map.new(), {}
    local function model_index(key)
      for i, e in ipairs(model) do
        if e.key == key then
          return i
        end
      end
    end
    for step = 1, 300 do
      local key = "k" .. rand(12)
      local op = rand(8)
      if op <= 3 then
        local value = step
        real:put(key, value)
        local i = model_index(key)
        if i then
          model[i].value = value
        else
          model[#model + 1] = { key = key, value = value }
        end
      elseif op <= 5 then
        local i = model_index(key)
        local want = i ~= nil
        if i then
          table.remove(model, i)
        end
        eq(real:delete(key), want, ("seed %d step %d delete"):format(seed, step))
      elseif op == 6 then
        local i = model_index(key)
        eq(real:get(key), i and model[i].value or nil, ("seed %d step %d get"):format(seed, step))
      elseif op == 7 then
        -- delete the visited entry and the next one from inside the walk
        local visited, want = {}, {}
        local snapshot = vim.deepcopy(model)
        local stop_at = rand(6)
        real:each(function(k)
          visited[#visited + 1] = k
          local i = model_index(k)
          if i then
            table.remove(model, i)
          end
          real:delete(k)
          return #visited == stop_at
        end)
        for n, e in ipairs(snapshot) do
          want[#want + 1] = e.key
          if n == stop_at then
            break
          end
        end
        eq(join(visited), join(want), ("seed %d step %d each"):format(seed, step))
      else
        local want = {}
        for _, e in ipairs(model) do
          want[#want + 1] = e.key
        end
        eq(join(real:keys()), join(want), ("seed %d step %d keys"):format(seed, step))
      end
      eq(real:count(), #model, ("seed %d step %d count"):format(seed, step))
    end
  end
end
