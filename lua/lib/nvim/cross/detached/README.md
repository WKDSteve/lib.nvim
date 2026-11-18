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
| `start_time(pid)` | When that process started, seconds since the epoch; `nil` when there is none or it can not be read. |
| `path()` | The register file: `stdpath("state")/lib.nvim/detached.json`. |

**A pid is not an identity.** The system hands a pid out again once its process ended (Windows quickly, after a
reboot anything goes). `track` therefore also records the process's start time, and `list` and `kill` accept an entry
only while a process with that pid **and** that start time runs (within `START_TOLERANCE`, 2 s). Everything else
counts as ended and drops out of the register, and `kill` refuses it without touching the process:

- a reused pid (another start time),
- a start time that can not be read (no rights, no `ps`, a Lua without ffi on Windows),
- an entry from before this check (no `proc_start`).

The owner is judged the same way: a reused owner pid still leaves an orphan.

| System | Where the start time comes from |
|---|---|
| Windows | `GetProcessTimes` through LuaJIT's ffi (`PROCESS_QUERY_LIMITED_INFORMATION`, no PowerShell started) |
| Linux | `/proc/<pid>/stat` field 22 plus `btime` from `/proc/stat` |
| macOS, BSD | `ps -o lstart= -p <pid>` (with `LC_ALL=C`) |

Entries older than `MAX_AGE_DAYS` (14) are dropped as well, and `kill_orphans` still asks per entry.

The register is one JSON file written atomically; two Neovims registering in the same instant can lose one entry (a read-modify-write
without a lock), which only means that process is not listed later.
