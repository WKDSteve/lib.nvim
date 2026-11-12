# `lib.nvim.cross.detached`

A register of the processes a plugin started detached, so the ones a previous Neovim left behind can be listed and
ended.

A detached child does not die with the editor. When Neovim exits or crashes nothing remembers it: the next session
finds a busy port or a stray process with no hint where it came from. `track` records the pid together with the pid
of the Neovim that started it; `list` says which are still running and whose owner is gone (an *orphan*); `kill`
ends one.

```lua
local run = require("lib.nvim.cross.run")
local detached = require("lib.nvim.cross.detached")

-- recorded for you when the caller asks (opt-in, nothing is tracked otherwise)
run.run_detached({ "node", "relay.js" }, { track = "mdview-relay" })

-- or by hand
detached.track(pid, { name = "mdview-relay", cmd = "node relay.js" })

for _, e in ipairs(detached.list({ orphans = true })) do
  print(e.pid, e.name, e.orphan)
end

-- one question per orphan
detached.kill_orphans(function(e)
  return vim.fn.confirm("Kill " .. e.name .. " (" .. e.pid .. ")?", "&Yes\n&No", 2) == 1
end)
```

| Function | What it does |
|---|---|
| `track(pid, { name?, cmd? })` | Records the process with the owning Neovim's pid and the time. |
| `untrack(pid)` | Forgets it. |
| `list({ orphans? })` | The registered processes that still run; `orphans = true` keeps only those whose owner is gone. A dead one drops out of the register on the way. |
| `kill(pid)` | Ends a *registered* process and its children (`taskkill /T /F` on Windows, the process group elsewhere). Anything not in the register is refused. |
| `kill_orphans(confirm)` | `kill` for every orphan `confirm(entry)` accepts; returns how many. |
| `is_alive(pid)` | Whether a process with that pid exists (signal 0). |
| `path()` | The register file: `stdpath("state")/lib.nvim/detached.json`. |

**Limits.** A pid can be reused by the system after a process ended. Entries older than `MAX_AGE_DAYS` (14) are
dropped instead of listed, and a process is reported while its pid answers a signal 0, but a reused pid that is alive
again cannot be told apart here. That is why `kill_orphans` asks per entry and `kill` only takes registered pids.
