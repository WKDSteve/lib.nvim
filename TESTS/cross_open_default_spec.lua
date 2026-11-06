-- TESTS/cross_open_default_spec.lua -- cross.open_default: which launcher a URL and a path get on
-- Windows. A URL must go to rundll32 url.dll,FileProtocolHandler (ShellExecute in-process): given
-- a URL with `?`, `&` or a `%xx` escape, explorer.exe opens the Documents folder in a hidden
-- window instead of the browser and exits 1 as on success (measured 2026-10-14).
---@diagnostic disable: missing-fields

return function(H)
  local eq, ok = H.eq, H.ok

  local run = require("lib.nvim.cross.run")
  local real_detached = run.run_detached
  local saved = {}
  local platform_modules = { "is_windows", "is_wsl", "is_macos" }
  for _, name in ipairs(platform_modules) do
    saved[name] = package.loaded["lib.nvim.cross.platform." .. name]
  end
  package.loaded["lib.nvim.cross.platform.is_windows"] = function()
    return true
  end
  package.loaded["lib.nvim.cross.platform.is_wsl"] = function()
    return false
  end
  package.loaded["lib.nvim.cross.platform.is_macos"] = function()
    return false
  end

  local captured
  run.run_detached = function(argv)
    captured = argv
    return true
  end

  local okrun, err = pcall(function()
    local open_default = require("lib.nvim.cross.open_default")
    local URL = "https://example.com/a?b=1&c=%3F"

    ok(open_default(URL), "a URL is dispatched")
    eq(captured[1], "rundll32.exe", "windows: a URL goes to rundll32")
    eq(captured[2], "url.dll,FileProtocolHandler", "through the ShellExecute entry point")
    eq(captured[3], URL, "with the URL untouched: ?, & and %xx survive")
    eq(#captured, 3, "and nothing else")

    ok(open_default("www.example.com/x?y=1"), "a www. target is a URL too")
    eq(captured[1], "rundll32.exe", "and also goes to rundll32")

    -- Non-http schemes are handed over untouched, not mangled into a path.
    for _, uri in ipairs({
      "ssh://host/x",
      "mailto:a@b.de",
      "file:///C:/x.txt",
      "magnet:?xt=urn:btih:abc",
    }) do
      ok(open_default(uri), uri .. " is dispatched")
      eq(captured[1], "rundll32.exe", uri .. " goes to rundll32")
      eq(captured[3], uri, uri .. " arrives unchanged")
    end
    -- A drive letter or a relative path is still a path.
    for _, path in ipairs({ "C:\\x", "C:/x/y.txt", "./rel.txt", "rel.txt" }) do
      ok(open_default(path), path .. " is dispatched")
      eq(captured[1], "explorer.exe", path .. " stays a path")
    end

    ok(open_default("C:/tmp/some file.pdf"), "a path is dispatched")
    eq(captured[1], "explorer.exe", "windows: a file path keeps explorer.exe")
    ok(not captured[2]:find("/", 1, true), "absolute and backslashed")
    eq(#captured, 2, "two elements")

    -- opts.schemes: an allowlist per call; without it everything above stays as it was.
    local allow = { schemes = { "HTTPS", "mailto" } }
    captured = nil
    ok(open_default("https://example.com/x", allow), "an allowed scheme opens")
    eq(captured[3], "https://example.com/x", "and reaches the opener")
    ok(open_default("MAILTO:a@b.de", allow), "the scheme matches in any case")
    ok(open_default("www.example.com", allow), "a www. target counts as https")
    captured = nil
    local opened, why = open_default("ms-msdt:/id x", allow)
    eq(opened, false, "a scheme off the list is refused")
    eq(why, "URI scheme not allowed: ms-msdt", "and named")
    eq(captured, nil, "and nothing is started")
    opened = open_default("www.example.com", { schemes = { "mailto" } })
    eq(opened, false, "a www. target is refused without https on the list")
    opened = open_default("https://example.com", { schemes = {} })
    eq(opened, false, "an empty list allows no URL")
    ok(open_default("C:/x/y.txt", allow), "a path is not judged")
    eq(captured[1], "explorer.exe", "and stays a path")
    captured = nil
    for _, bad in ipairs({ { "https", 1 }, { https = true }, "https", false }) do
      opened, why = open_default("https://example.com", { schemes = bad })
      eq(opened, false, "a value that is not a list fails closed: " .. vim.inspect(bad))
      eq(why, "opts.schemes must be a list of strings", "and says so")
    end
    eq(captured, nil, "a malformed list starts nothing")

    -- WSL: a URL still goes to rundll32
    package.loaded["lib.nvim.cross.platform.is_wsl"] = function()
      return true
    end
    ok(open_default(URL), "wsl: a URL is dispatched")
    eq(captured[1], "rundll32.exe", "wsl: a URL goes to rundll32")
    eq(captured[3], URL, "untouched")
  end)

  run.run_detached = real_detached
  -- Iterate the names, not `pairs(saved)`: a module that was not loaded before has no entry in
  -- `saved`, so `pairs` skipped it and the mock (is_windows/is_wsl = true) leaked into every
  -- later spec of the run.
  for _, name in ipairs(platform_modules) do
    package.loaded["lib.nvim.cross.platform." .. name] = saved[name]
  end
  if not okrun then
    error(err, 0)
  end
  for _, name in ipairs(platform_modules) do
    eq(
      package.loaded["lib.nvim.cross.platform." .. name],
      saved[name],
      name .. " is restored, not left mocked for later specs"
    )
  end
end
