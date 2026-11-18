-- TESTS/support/busted_lite.lua -- the part of busted/luassert that specs ported from
-- plugin suites use, over lib.nvim's own harness: `describe`/`it` run at once (a failing `it`
-- fails the spec, the runner reports it), and `assert.are.equal`, `assert.same`, ... map
-- onto `H.eq`/`H.ok`. Usage inside a spec:
--
--   local describe, it, assert = dofile(<this file>)(H)

---@param H table the harness
---@return fun(name: string, fn: fun()) describe
---@return fun(name: string, fn: fun()) it
---@return table assert
return function(H)
  local path = {}

  local function describe(name, fn)
    path[#path + 1] = name
    local ok, err = pcall(fn)
    path[#path] = nil
    if not ok then
      error(err, 0)
    end
  end

  local function it(name, fn)
    local ok, err = pcall(fn)
    if not ok then
      error(("%s > %s: %s"):format(table.concat(path, " > "), name, tostring(err)), 0)
    end
  end

  local function same(expected, actual, msg)
    H.ok(
      vim.deep_equal(expected, actual),
      ("%s: expected %s, got %s"):format(msg or "same", vim.inspect(expected), vim.inspect(actual))
    )
  end

  local function equal(expected, actual, msg)
    H.eq(actual, expected, msg)
  end

  local plain_assert = _G.assert
  local assert = setmetatable({
    equals = equal,
    same = same,
    are = { equal = equal, same = same },
    is_true = function(v, msg)
      H.eq(v, true, msg)
    end,
    is_false = function(v, msg)
      H.eq(v, false, msg)
    end,
    is_nil = function(v, msg)
      H.eq(v, nil, msg)
    end,
    is_not_nil = function(v, msg)
      H.ok(v ~= nil, msg or "expected a value")
    end,
    is_truthy = function(v, msg)
      H.ok(v, msg)
    end,
    is_string = function(v, msg)
      H.eq(type(v), "string", msg)
    end,
    matches = function(pattern, s, msg)
      H.ok(type(s) == "string" and s:match(pattern), (msg or "matches") .. ": " .. tostring(s))
    end,
  }, {
    __call = function(_, ...)
      return plain_assert(...)
    end,
  })

  return describe, it, assert
end
