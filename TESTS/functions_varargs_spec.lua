-- TESTS/functions_varargs_spec.lua -- lib.lua.functions.varargs: the one pack/unpack shim for LuaJIT.
return function(H)
  local eq, ok = H.eq, H.ok
  local varargs = require("lib.lua.functions.varargs")

  -- ------------------------------------------------------------------ behaviour
  local packed = varargs.pack(1, nil, 3, nil)
  eq(packed.n, 4, "pack counts trailing and embedded nils")
  eq(packed[1], 1, "pack keeps the first value")
  eq(packed[3], 3, "pack keeps a value behind a nil")

  local a, b, c, d = varargs.unpack(packed, 1, packed.n)
  ok(
    a == 1 and b == nil and c == 3 and d == nil,
    "unpack(t, 1, t.n) returns every value, nils included"
  )
  eq(select("#", varargs.unpack(packed, 1, packed.n)), 4, "unpack returns exactly n values")
  eq(varargs.pack().n, 0, "pack of nothing has n == 0")

  -- ------------------------------------------------------------------ aggregator
  local functions = require("lib.lua.functions")
  ok(functions.pack == varargs.pack, "lib.lua.functions.pack is the shared helper")
  ok(functions.unpack == varargs.unpack, "lib.lua.functions.unpack is the shared helper")

  -- ------------------------------------------------------------------ no second copy of the shim
  -- (rules-vault LUA-07/LUA-08: reuse before reimplementing; five copies existed before this module)
  local function scan(dir, hits)
    for name, kind in vim.fs.dir(dir) do
      local path = dir .. "/" .. name
      if kind == "directory" then
        scan(path, hits)
      elseif name:match("%.lua$") then
        local f = io.open(path, "rb")
        local text = f and f:read("*a") or ""
        if f then
          f:close()
        end
        if text:find("table.unpack or unpack", 1, true) then
          hits[#hits + 1] = path
        end
      end
    end
    return hits
  end
  local hits = scan("lua/lib", {})
  ok(
    #hits == 1 and hits[1]:match("functions/varargs%.lua$") ~= nil,
    "the `table.unpack or unpack` shim lives only in functions/varargs.lua, found: "
      .. table.concat(hits, ", ")
  )
end
