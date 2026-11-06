-- TESTS/contract_host_spec.lua -- lib.nvim.contract.host: the persistent engine over a line protocol, in process and
-- as a real child Neovim started from templates/contract_host.lua.
--
-- The rule it holds: a question through the host gets the document `api.call` gives, byte for byte.

return function(H)
  local ok = H.ok
  local doc = require("lib.nvim.contract.doc")
  local capi = require("lib.nvim.contract.api")
  local chost = require("lib.nvim.contract.host")
  local uv = vim.uv or vim.loop

  ---Deep comparison (the shared `H.eq` compares references).
  local function eq(a, b, msg)
    if not vim.deep_equal(a, b) then
      error(("FAIL %s: expected %s, got %s"):format(msg or "", vim.inspect(b), vim.inspect(a)), 2)
    end
  end

  local function has(text, part, msg)
    ok(type(text) == "string" and text:find(part, 1, true), msg or ("expected " .. part))
  end

  local ROOT = "C:/Users/me/vault"

  local d = doc.new({ plugin = "tasks.nvim", schema = 1 })
  d.clock = function()
    return "2026-01-01T00:00:00Z"
  end
  d.engine_info = function()
    return { version = "0.1.0", git = "abc1234", nvim = "v0.11.0" }
  end

  local last_opts
  local api = capi.make({
    doc = d,
    methods = {
      hello = {
        params = {},
        run = function(_, opts)
          last_opts = opts
          return d.head(d.kind("hello"), opts.root)
        end,
      },
      echo = {
        params = { text = "string" },
        run = function(p)
          return { kind = "tasks.echo", text = p.text }
        end,
      },
      flatty = {
        flat = true,
        keep_null = true,
        params = { a = "integer", b = "string" },
        run = function(p)
          return { kind = "tasks.flat", a = p.a, b = p.b }
        end,
      },
    },
  })

  -- ── make: a wrong config is refused where it is made, with the position of the caller ──
  local function refused_make(cfg, part, label)
    local good, err = pcall(chost.make, cfg)
    ok(not good, "expected make to refuse " .. (label or vim.inspect(cfg)))
    has(tostring(err), part)
  end
  refused_make(nil, "needs a table")
  refused_make({}, "api must be")
  refused_make({ api = {} }, "api must be")
  refused_make({ api = { call = function() end } }, "api must be")
  refused_make(
    { api = { call = function() end, METHODS = {} } },
    "api must be",
    "an api without minimal_error"
  )
  refused_make({ api = api, protocol = 0 }, "protocol must be")
  refused_make({ api = api, protocol = 1.5 }, "protocol must be")
  refused_make({ api = api, protocol = "1" }, "protocol must be")
  refused_make({ api = api, call_opts = 5 }, "call_opts must be")

  local host = chost.make({ api = api, call_opts = { root = ROOT } })
  eq(host.PROTOCOL, 1)
  eq(chost.make({ api = api, protocol = 3 }).PROTOCOL, 3)
  eq(host.max_line_bytes(), 256 * 1024 + 256, "a request plus the id and the method")

  -- the binary mode is for the process's own stdin only: a stream that is not it is left alone (the real thing is
  -- tried in the child Neovim below)
  eq(chost.binary_stdin({}), false, "a table is no stdin")
  eq(chost.binary_stdin(nil), false, "nothing is no stdin")

  -- ── handle: one line in, one line out, the bytes of api.call ──
  for _, case in ipairs({
    { id = "1", method = "hello", params = "" },
    { id = "2", method = "echo", params = '{"text":"hi"}' },
    { id = "3", method = "echo", params = '{"text":"ü日本"}' },
  }) do
    local want = api.call(
      case.method,
      case.params ~= "" and ('{"params":' .. case.params .. "}") or nil,
      { root = ROOT }
    )
    local reply = host.handle(case.id .. "\t" .. case.method .. "\t" .. case.params)
    eq(reply, case.id .. "\t" .. want, case.method .. ": same bytes as api.call")
    ok(not reply:sub(#case.id + 2):find("\n"), case.method .. ": one line")
  end
  eq(last_opts, { root = ROOT }, "the options of the plugin reach the call")

  -- a flat method carries its fields at the top of the request, as on the command line
  local flat = '{"a":1,"b":"x"}'
  eq(host.handle("7\tflatty\t" .. flat), "7\t" .. api.call("flatty", flat, { root = ROOT }))
  eq(vim.json.decode(host.handle("7\tflatty\t" .. flat):sub(3)).a, 1)

  -- a method without a tab after it, and without params
  eq(host.handle("4\thello"), "4\t" .. api.call("hello", nil, { root = ROOT }), "no second tab")

  -- a request the dispatcher refuses is its own error document, with the id of the question
  local refused = host.handle("8\tbogus\t")
  ok(refused ~= nil and refused:sub(1, 2) == "8\t", "an unknown method is answered with its id")
  eq(vim.json.decode(refused:sub(3)).code, "not_found")
  eq(vim.json.decode(host.handle("9\techo\t{not json"):sub(3)).code, "invalid_argument")
  -- a method name that cannot be shown on a terminal is refused without being echoed back
  for _, name in ipairs({ "\27]52;c;ZXZpbA==\7", "a\0b", "bad\194\133name", string.rep("m", 65) }) do
    local reply = host.handle("5\t" .. name .. "\t{}")
    ok(reply ~= nil and reply:sub(1, 2) == "5\t", "a hostile method name is answered with its id")
    eq(vim.json.decode(reply:sub(3)).code, "not_found")
    ok(
      not reply:find("52;c", 1, true) and not reply:find("mmmm", 1, true),
      "the name is not echoed"
    )
  end
  eq(vim.json.decode(host.handle("5\t" .. string.rep("m", 64) .. "\t{}"):sub(3)).code, "not_found")
  -- (documented) the params text is spliced into the request, not parsed: it can carry a top-level field of its own.
  -- That is the same client that writes the whole line, so it is no way to anything it could not ask for anyway.
  eq(
    vim.json.decode(host.handle('9\techo\t1,"schema":9'):sub(3)).code,
    "unsupported_schema",
    "the spliced field is judged by the dispatcher like any other"
  )
  eq(
    vim.json.decode(host.handle('9\techo\t{"text":"x"},"extra":1'):sub(3)).code,
    "invalid_argument",
    "and an unknown one is refused"
  )

  -- a Windows line ending is not part of the request
  eq(host.handle("10\thello\t\r"), "10\t" .. api.call("hello", nil, { root = ROOT }))
  eq(host.handle("10\thello\r"), "10\t" .. api.call("hello", nil, { root = ROOT }))

  -- what is no request is skipped (nil), never answered with a guess
  eq(host.handle("hello"), nil)
  eq(host.handle(""), nil)
  eq(host.handle("x\thello\t"), nil)
  eq(host.handle("1234567890123456\thello\t"), nil, "an id of 16 digits")
  eq(host.handle("123456789012345\thello\t") ~= nil, true, "15 digits are fine")
  eq(host.handle("1\t\t"), nil, "no method")
  local bad = vim.json.decode(host.handle("1\tbad-name\t"):sub(3))
  eq(bad.code, "not_found", "the dispatcher refuses a method it does not have")
  has(bad.message, "unknown method 'bad-name'")
  eq(host.handle(5), nil, "not even a text")
  eq(host.handle(nil), nil)

  -- a method name runs to the next tab and is judged whole, never cut at a dash or a dot: `list-all` is not `list`
  local named = capi.make({
    doc = d,
    methods = {
      list = {
        params = {},
        run = function()
          return { kind = "tasks.list" }
        end,
      },
      ["list-all"] = {
        params = { n = "integer" },
        run = function(p)
          return { kind = "tasks.list_all", n = p.n }
        end,
      },
      ["a.b"] = {
        params = {},
        run = function()
          return { kind = "tasks.dot" }
        end,
      },
    },
  })
  local named_host = chost.make({ api = named, call_opts = { root = ROOT } })
  eq(
    named_host.handle('1\tlist-all\t{"n":3}'),
    "1\t" .. named.call("list-all", '{"params":{"n":3}}', { root = ROOT }),
    "a dashed method with params: the bytes of api.call"
  )
  local dashed = vim.json.decode(named_host.handle('1\tlist-all\t{"n":3}'):sub(3))
  eq(
    { dashed.kind, dashed.n },
    { "tasks.list_all", 3 },
    "'list-all' ran, not 'list' with a spliced '-all'"
  )
  eq(
    vim.json.decode(named_host.handle("2\tlist\t"):sub(3)).kind,
    "tasks.list",
    "and 'list' is still itself"
  )
  eq(vim.json.decode(named_host.handle("3\ta.b\t"):sub(3)).kind, "tasks.dot", "a dotted method")
  eq(
    vim.json.decode(named_host.handle("4\ta.b"):sub(3)).kind,
    "tasks.dot",
    "a dotted method without the second tab"
  )
  local unknown = vim.json.decode(named_host.handle("5\ta.c\t"):sub(3))
  eq(unknown.code, "not_found")
  has(unknown.message, "unknown method 'a.c'")
  ok(
    not unknown.message:find("unknown method 'a'", 1, true),
    "the host names the method the client sent"
  )

  -- call_opts: a function is asked per request
  local asked = 0
  local per_request = chost.make({
    api = api,
    call_opts = function()
      asked = asked + 1
      return { root = "/r" .. asked }
    end,
  })
  per_request.handle("1\thello\t")
  per_request.handle("2\thello\t")
  eq(last_opts, { root = "/r2" })
  eq(asked, 2)
  chost.make({ api = api, call_opts = function() end }).handle("1\thello\t")
  eq(last_opts, {}, "a function that answers nothing: no options")
  chost.make({ api = api }).handle("1\thello\t")
  eq(last_opts, {}, "no call_opts: no options")

  -- the options reach the dispatcher as a table whatever the plugin hands in
  local seen_opts = {}
  local spy_api = {
    METHODS = {},
    MAX_REQUEST_BYTES = 100,
    minimal_error = api.minimal_error,
    call = function(_, _, opts)
      seen_opts[#seen_opts + 1] = opts
      return "{}"
    end,
  }
  chost.make({ api = spy_api }).handle("1\thello\t")
  chost.make({ api = spy_api, call_opts = function() end }).handle("1\thello\t")
  chost
    .make({
      api = spy_api,
      call_opts = function()
        return "text"
      end,
    })
    .handle("1\thello\t")
  eq(seen_opts, { {}, {}, {} }, "always a table")

  -- a dispatcher that raises or answers no text is a document of its own, never a dead host
  local broken = {
    METHODS = {},
    MAX_REQUEST_BYTES = 100,
    minimal_error = api.minimal_error,
    call = function()
      error("boom")
    end,
  }
  local fallback = chost.make({ api = broken }).handle("5\thello\t")
  eq(fallback:sub(1, 2), "5\t")
  eq(vim.json.decode(fallback:sub(3)).message, "the host failed on this request")
  broken.call = function()
    return nil
  end
  eq(
    chost.make({ api = broken }).handle("6\thello\t"):sub(1, 2),
    "6\t",
    "no text from the dispatcher"
  )
  broken.call = function()
    return "a\nb\r\nc"
  end
  eq(chost.make({ api = broken }).handle("6\thello\t"), "6\ta b  c", "a line break is whitespace")

  -- ── serve: in process, with streams that are tables ──
  ---@param lines string[]
  ---@param opts? { fail_after?: integer }
  local function streams(lines, opts)
    opts = opts or {}
    local input = { pos = 0, lines = lines }
    function input:read(fmt)
      assert(fmt == "l", "the host reads lines")
      self.pos = self.pos + 1
      return self.lines[self.pos]
    end
    local output = { out = {}, flushed = 0 }
    function output:write(text)
      if opts.fail_after and #self.out >= opts.fail_after then
        return nil, "EPIPE"
      end
      self.out[#self.out + 1] = text
      return self
    end
    function output:flush()
      self.flushed = self.flushed + 1
    end
    return input, output
  end

  local warnings = {}
  local function warn(text)
    warnings[#warnings + 1] = text
  end

  local input, output = streams({
    "1\thello\t",
    "garbage",
    "",
    "\r",
    "2\techo\t" .. '{"text":"x"}',
  })
  host.serve(input, output, warn)
  eq(output.out[1], "ready\t1\n", "ready, first")
  eq(output.out[2], "1\t" .. api.call("hello", nil, { root = ROOT }) .. "\n")
  eq(output.out[3], "2\t" .. api.call("echo", '{"params":{"text":"x"}}', { root = ROOT }) .. "\n")
  eq(#output.out, 3, "nothing for a line that is no request")
  eq(
    warnings,
    { "host: a line that is not a request is skipped" },
    "told once; an empty line, and the empty line of a Windows client (a bare CR), are not worth a word"
  )
  eq(output.flushed, 3, "flushed after every line")
  eq(input.pos, 6, "read until the input ended")

  -- more than a bare CR is no blank line: it is told
  warnings = {}
  local in_cr, out_cr = streams({ "\r\r", " " })
  host.serve(in_cr, out_cr, warn)
  eq(#warnings, 2, "only an empty line and a lone CR are silent")
  eq(#out_cr.out, 1, "only ready")

  -- the protocol number
  local _, out3 = streams({})
  chost.make({ api = api, protocol = 3 }).serve(streams({}), out3, warn)
  eq(out3.out, { "ready\t3\n" })

  -- a line that is too long: skipped, told, and when it starts with an id the client gets an answer
  warnings = {}
  local small = capi.make({
    doc = d,
    max_request_bytes = 20,
    methods = { hello = api.METHODS.hello },
  })
  local small_host = chost.make({ api = small, call_opts = { root = ROOT } })
  eq(small_host.max_line_bytes(), 20 + 256)
  local long = "5\thello\t" .. string.rep("x", 400)
  local in2, out2 = streams({ long, "6\thello\t", string.rep("y", 400) })
  small_host.serve(in2, out2, warn)
  eq(out2.out[1], "ready\t1\n")
  local answered = out2.out[2]
  eq(answered:sub(1, 2), "5\t", "the answer carries the id of the long line")
  local over = vim.json.decode(answered:sub(3))
  eq({ over.code, over.kind }, { "payload_too_large", "tasks.error" })
  has(over.message, "a request is at most 20 bytes")
  eq(out2.out[3]:sub(1, 2), "6\t", "and the next question is answered as usual")
  eq(#out2.out, 3, "a long line without an id gets no answer")
  eq(#warnings, 2)
  has(warnings[1], "a line of ")
  has(warnings[1], " bytes is skipped")
  -- the limit is read at call time
  small.MAX_REQUEST_BYTES = 1000
  eq(small_host.max_line_bytes(), 1256)

  -- an id of 16 digits on a long line gets no answer (it is no id)
  small.MAX_REQUEST_BYTES = 20
  local in4, out4 = streams({ "1234567890123456\t" .. string.rep("x", 400) })
  small_host.serve(in4, out4, warn)
  eq(#out4.out, 1, "only ready: a 16-digit id is no id")

  -- the longest id there is (15 digits) on a long line is answered, with that id
  local in8, out8 = streams({ "123456789012345\thello\t" .. string.rep("x", 400) })
  small_host.serve(in8, out8, warn)
  eq(#out8.out, 2, "ready and an answer for the 15-digit id")
  eq(out8.out[2]:sub(1, 16), "123456789012345\t", "a 15-digit id on a long line is answered")
  eq(
    vim.json.decode(out8.out[2]:sub(17)).code,
    "payload_too_large",
    "and the answer is the one for a long line"
  )

  -- the limit itself: exactly max_line_bytes() goes to api.call, one byte more is refused by the host
  local pad = "7\thello\t"
  local at = pad .. string.rep(" ", small_host.max_line_bytes() - #pad)
  eq(#at, small_host.max_line_bytes(), "a line of exactly the limit")
  local in9, out9 = streams({ at, at .. " " })
  small_host.serve(in9, out9, warn)
  eq(out9.out[2], small_host.handle(at) .. "\n", "at the limit: api.call answers")
  eq(
    out9.out[3],
    "7\t" .. small.minimal_error("payload_too_large", "a request is at most 20 bytes") .. "\n",
    "one over: the host refuses"
  )
  ok(out9.out[2] ~= out9.out[3], "the two are told apart")

  -- the output goes away: the host ends and does not read on
  local in5, out5 = streams({ "1\thello\t", "2\thello\t", "3\thello\t" }, { fail_after = 2 })
  host.serve(in5, out5, warn)
  eq(#out5.out, 2, "ready and the first answer, then the write failed")
  eq(in5.pos, 2, "the host stopped reading when it could not answer")
  local in6, out6 = streams({ "1\thello\t" }, { fail_after = 0 })
  host.serve(in6, out6, warn)
  eq(in6.pos, 0, "not even ready could be written: nothing is read")

  -- the default warn goes to stderr
  local captured = {}
  local in7, out7 = streams({ "garbage" })
  H.with_patched(io, "stderr", {
    write = function(_, text)
      captured[#captured + 1] = text
    end,
  }, function()
    host.serve(in7, out7)
  end)
  eq(captured, { "host: a line that is not a request is skipped\n" })

  -- ── a real child Neovim, started from the template ──
  local dir = vim.fn.tempname()
  local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
  end

  -- the module that the template starts: a plugin's host, with a method that tells which process answered
  local HOST_MODULE = [=[
local doc = require("lib.nvim.contract.doc")
local capi = require("lib.nvim.contract.api")
local d = doc.new({ plugin = "spec.nvim", schema = 1 })
d.clock = function()
  return "2026-01-01T00:00:00Z"
end
local api = capi.make({
  doc = d,
  methods = {
    hello = {
      params = {},
      run = function(_, opts)
        return d.head(d.kind("hello"), opts.root)
      end,
    },
    echo = {
      params = { text = "string" },
      run = function(p)
        return { kind = "spec.echo", text = p.text, pid = vim.uv.os_getpid() }
      end,
    },
  },
})
return require("lib.nvim.contract.host").make({
  api = api,
  call_opts = function()
    return { root = vim.env.SPEC_ROOT }
  end,
})
]=]

  -- a module that does not serve but tells which fake lib.nvim (see `fake_lib`) the template put on the runtimepath
  local PROBE_MODULE = [=[
local M = {}
function M.serve(_, out)
  local found = {}
  for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
    local f = io.open(path .. "/lua/lib/nvim/MARKER", "rb")
    if f then
      found[#found + 1] = f:read("*a")
      f:close()
    end
  end
  out:write(table.concat(found, ",") .. "\n")
end
return M
]=]

  local template =
    assert(io.open(vim.fn.getcwd() .. "/templates/contract_host.lua", "rb"):read("*a"))

  ---Install the template as `<root>/plugin/scripts/host.lua` of a plugin whose `module` is `source`.
  ---@param root string
  ---@param module string
  ---@param source string
  ---@return string script
  local function install(root, module, source)
    local text = template
      :gsub('local MODULE = "your_plugin.host"', ('local MODULE = "%s"'):format(module))
      :gsub('local PLUGIN = "your%-plugin.nvim"', 'local PLUGIN = "spec.nvim"')
    ok(
      text:find('local MODULE = "' .. module .. '"', 1, true),
      "the template names its module in the place the spec replaces"
    )
    write(root .. "/plugin/lua/" .. (module:gsub("%.", "/")) .. ".lua", source)
    write(root .. "/plugin/scripts/host.lua", text)
    return root .. "/plugin/scripts/host.lua"
  end

  ---A folder that passes the template's check for a lib.nvim checkout, and says who it is.
  ---@param path string
  ---@param name string
  local function fake_lib(path, name)
    write(path .. "/lua/lib/nvim/MARKER", name)
  end

  local script = install(dir, "spec_host_plugin.host", HOST_MODULE)
  write(dir .. "/data-dir.lua", 'io.stdout:write(vim.fn.stdpath("data"))')

  local lib_dir = vim.fn.getcwd()
  ok(
    vim.fn.isdirectory(lib_dir .. "/lua/lib/nvim") == 1,
    "the spec runs from the lib.nvim checkout"
  )

  ---Run a script in a child Neovim. The places the template looks in are blank unless the case sets them, so what the
  ---machine has in its environment (`$REPOS_DIR` on a developer's) never finds lib.nvim for a case.
  ---@param stdin string
  ---@param env table
  ---@param which? string   # The script, default the host of `HOST_MODULE`.
  local function run_child(stdin, env, which)
    local base = {
      NVIM = "",
      NVIM_LISTEN_ADDRESS = "",
      REPOS_DIR = "",
      LIB_NVIM_DIR = "",
      LIB_NVIM_PATH = "",
    }
    return vim
      .system(
        { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", which or script },
        { text = true, stdin = stdin, env = vim.tbl_extend("force", base, env) }
      )
      :wait(60000)
  end

  ---The non-empty lines of a child's output, without the carriage returns of a Windows console.
  ---@param text string
  ---@return string[]
  local function lines_of(text)
    local out = {}
    for l in (text:gsub("\r", "")):gmatch("[^\n]+") do
      out[#out + 1] = l
    end
    return out
  end

  local child = run_child(
    table.concat(
      { "1\thello\t", '2\techo\t{"text":"x"}', "garbage", '3\techo\t{"nope":1}', "" },
      "\n"
    ),
    { LIB_NVIM_DIR = lib_dir, SPEC_ROOT = "/spec/root" }
  )
  eq(child.code, 0, "the host ends cleanly when its input ends; stderr: " .. tostring(child.stderr))
  local lines = lines_of(child.stdout)
  eq(lines[1], "ready\t1")
  local hello = vim.json.decode(lines[2]:match("^1\t(.*)$"))
  eq({ hello.kind, hello.plugin, hello.vault.id }, { "spec.hello", "spec.nvim", "root" })
  local echo = vim.json.decode(lines[3]:match("^2\t(.*)$"))
  eq({ echo.kind, echo.text }, { "spec.echo", "x" })
  ok(echo.pid ~= uv.os_getpid(), "answered by the child, not by this process")
  eq(vim.json.decode(lines[4]:match("^3\t(.*)$")).code, "invalid_argument")
  eq(#lines, 4, "nothing else on stdout")
  has(child.stderr, "not a request")

  -- two questions to one process: the same process answers (the modules are loaded once)
  local twice =
    run_child('1\techo\t{"text":"a"}\n2\techo\t{"text":"b"}\n', { LIB_NVIM_DIR = lib_dir })
  local pids = {}
  for id, body in (twice.stdout:gsub("\r", "")):gmatch("(%d)\t([^\n]+)") do
    pids[id] = vim.json.decode(body).pid
  end
  ok(pids["1"] ~= nil and pids["1"] == pids["2"], "one process for both questions")

  -- the input ends at once: ready, then a clean exit
  local quiet = run_child("", { LIB_NVIM_DIR = lib_dir })
  eq(quiet.code, 0)
  eq((quiet.stdout:gsub("\r", "")), "ready\t1\n")

  -- a raw 0x1A byte in a line is a byte like any other and not the end of the input (Windows reads a text mode stdin
  -- up to it and no further): the line is answered, and so is the one after it
  local ctrl_z =
    run_child('4\techo\t{"text":"a\26b"}\n5\techo\t{"text":"z"}\n', { LIB_NVIM_DIR = lib_dir })
  eq(ctrl_z.code, 0, "a 0x1A in a line: " .. tostring(ctrl_z.stderr))
  local zl = lines_of(ctrl_z.stdout)
  eq(#zl, 3, "ready and one answer for each of the two lines; stdout " .. ctrl_z.stdout)
  eq(zl[2]:sub(1, 2), "4\t", "the line with the 0x1A is answered with its id")
  eq(vim.json.decode(zl[3]:match("^5\t(.*)$")).text, "z", "and the line after it is not lost")

  -- a client that ends its lines with CR LF: the request is the line without the CR, and its blank line is no word on
  -- stderr
  local crlf = run_child(
    "1\thello\t\r\n\r\n2\thello\r\n",
    { LIB_NVIM_DIR = lib_dir, SPEC_ROOT = "/spec/root" }
  )
  eq(crlf.code, 0, "CRLF: " .. tostring(crlf.stderr))
  local cl = lines_of(crlf.stdout)
  eq(#cl, 3, "ready and two answers; stdout " .. crlf.stdout)
  eq({ cl[2]:sub(1, 2), cl[3]:sub(1, 2) }, { "1\t", "2\t" })
  ok(
    not crlf.stderr:find("not a request", 1, true),
    "the blank line of a CRLF client is skipped silently: " .. crlf.stderr
  )

  -- the end-to-end way in by $LIB_NVIM_PATH (the other places are told apart below, with stand-ins for lib.nvim)
  local via_path = run_child("", { LIB_NVIM_PATH = lib_dir })
  eq(via_path.code, 0, "LIB_NVIM_PATH: " .. tostring(via_path.stderr))

  -- where the template looks for lib.nvim, and in which order. Every place holds a stand-in that names itself; the
  -- probe says which one the template put on the runtimepath. The winner is removed after each run, so each place is
  -- shown to be looked in, at its own rank. The environment of the machine does not matter: all variables are set here.
  local order_root = dir .. "/order"
  local order_data = order_root .. "/data"
  vim.fn.mkdir(order_data, "p")
  local order_env = { XDG_DATA_HOME = order_data, LOCALAPPDATA = order_data }
  local data_home = vim.trim(run_child("", order_env, dir .. "/data-dir.lua").stdout)
  ok(
    vim.startswith(vim.fs.normalize(data_home), vim.fs.normalize(order_data)),
    "the data folder of the editor is moved under the spec's: " .. data_home
  )
  local probe = install(order_root, "spec_host_plugin.probe", PROBE_MODULE)
  local places = {
    LIB_NVIM_DIR = order_root .. "/by-dir",
    LIB_NVIM_PATH = order_root .. "/by-path",
    REPOS_DIR = order_root .. "/repos/lib.nvim",
    deps = order_root .. "/plugin/.deps/lib.nvim",
    sibling = order_root .. "/lib.nvim",
    lazy = data_home .. "/lazy/lib.nvim",
  }
  for name, path in pairs(places) do
    fake_lib(path, name)
  end
  local order_vars = vim.tbl_extend("force", order_env, {
    LIB_NVIM_DIR = places.LIB_NVIM_DIR,
    LIB_NVIM_PATH = places.LIB_NVIM_PATH,
    REPOS_DIR = order_root .. "/repos",
  })
  for _, name in ipairs({ "LIB_NVIM_DIR", "LIB_NVIM_PATH", "REPOS_DIR", "deps", "sibling", "lazy" }) do
    local found = run_child("", order_vars, probe)
    eq(found.code, 0, name .. ": " .. tostring(found.stderr))
    eq(vim.trim(found.stdout), name, "the first place that holds a lib.nvim wins")
    vim.fn.delete(places[name], "rf")
  end
  local nowhere = run_child("", order_vars, probe)
  eq(nowhere.code, 2, "and with every place gone there is none; stdout " .. nowhere.stdout)
  has(nowhere.stderr, "lib.nvim not found for spec.nvim")

  -- a comma in a folder name does not split a runtimepath entry in two (the second half would be a relative entry
  -- that is looked up in whatever folder the client started in)
  local comma_host = install(dir .. "/comma,plugin", "spec_host_plugin.host", HOST_MODULE)
  local comma_plugin = run_child("", { LIB_NVIM_DIR = lib_dir }, comma_host)
  eq(comma_plugin.code, 0, "a comma in the plugin's folder: " .. tostring(comma_plugin.stderr))
  eq((comma_plugin.stdout:gsub("\r", "")), "ready\t1\n")
  local comma_lib = dir .. "/lib,copy"
  fake_lib(comma_lib, "comma")
  local comma_probe = install(dir .. "/comma-lib", "spec_host_plugin.probe", PROBE_MODULE)
  local comma_found = run_child("", { LIB_NVIM_DIR = comma_lib }, comma_probe)
  eq(comma_found.code, 0, "a comma in the folder of lib.nvim: " .. tostring(comma_found.stderr))
  eq(vim.trim(comma_found.stdout), "comma", "lib.nvim is found in a folder with a comma")

  -- lib.nvim nowhere: exit code 2 and a message that names what to set; the editor's data folder is moved away too
  local empty = dir .. "/empty-data"
  vim.fn.mkdir(empty, "p")
  local lost = run_child("1\thello\t\n", {
    LIB_NVIM_DIR = "",
    LIB_NVIM_PATH = "",
    REPOS_DIR = "",
    XDG_DATA_HOME = empty,
    LOCALAPPDATA = empty,
  })
  eq(lost.code, 2, "no lib.nvim: exit 2; stdout " .. tostring(lost.stdout))
  has(lost.stderr, "lib.nvim not found for spec.nvim")
  has(lost.stderr, "LIB_NVIM_DIR")
  eq(lost.stdout, "", "and nothing on stdout, not even ready")

  vim.fn.delete(dir, "rf")
end
