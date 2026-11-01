-- TESTS/progress_resolve_style_spec.lua -- lib.nvim.progress.resolve_style: style name -> implementation, with the fidget fallback.
return function(H)
  local eq = H.eq
  local resolve = require("lib.nvim.progress.resolve_style")

  local function impl(name)
    return require("lib.nvim.progress.styles." .. name)
  end

  -- fidget is a soft dependency: make sure the first half of the spec runs without it, the second with a stub
  local saved_loaded, saved_preload = package.loaded.fidget, package.preload.fidget
  package.loaded.fidget, package.preload.fidget = nil, nil
  local have_fidget = pcall(require, "fidget")
  if have_fidget then
    -- a real fidget is installed on this machine: nothing to prove about the fallback here
    print("n/a  resolve_style without fidget (fidget is installed)")
  else
    eq(resolve("fidget"), impl("notify"), "fidget requested but missing falls back to notify")
    eq(resolve(nil), impl("notify"), "auto without fidget is notify")
    eq(resolve("auto"), impl("notify"), "explicit auto without fidget is notify")
    eq(resolve("no-such-style"), impl("notify"), "an unknown name is treated as auto")
  end

  -- named styles resolve to their own module, whether or not fidget exists
  for _, name in ipairs({ "statusline", "echo", "notify", "float", "kit" }) do
    eq(resolve(name), impl(name), name .. " resolves to its own module")
  end

  -- with a (stub) fidget present, auto, unknown and fidget itself pick the fidget style
  package.loaded.fidget = {}
  eq(resolve("fidget"), impl("fidget"), "fidget requested and present is fidget")
  eq(resolve(nil), impl("fidget"), "auto with fidget is fidget")
  eq(resolve("no-such-style"), impl("fidget"), "unknown with fidget is fidget")
  -- opt-in styles are never picked automatically
  assert(
    resolve(nil) ~= impl("float") and resolve(nil) ~= impl("kit"),
    "float and kit are opt-in only"
  )

  package.loaded.fidget, package.preload.fidget = saved_loaded, saved_preload
end
