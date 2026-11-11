# `lib.nvim.deps`

External-tool detection, declared-dependency spec parsing, and a
confirmation-gated install handoff, for plugins that degrade gracefully
without optional CLI tools (pandoc, ImageMagick, tesseract, poppler-utils,
…).

**Nothing here executes an install command.** `:Lib deps install` composes
the correct command for the host's package manager, asks first, then opens
a terminal with the command *typed but not submitted* — the user presses
Enter. That way a `sudo` password prompt is answered at a real terminal the
user opened, rather than by a backgrounded job with its prompt swallowed.
Requiring this module registers nothing and touches nothing.

| Submodule | What |
|---|---|
| `deps.health` | `:checkhealth` reporting for executables / Python modules — replaces the hand-rolled `check_exe` loop |
| `deps.spec` | Parse + validate `docs/INSTALL.md` / `docs/install.json`; locate them for any plugin |
| `deps.detect` | Is a declared tool here, under any of the names it goes by? (`gs` / `gswin64c`) -- shared by health, install and view |
| `deps.pm` | Package-manager detection + install-command composition |
| `deps.install` | Install-plan computation (pure) and the confirmed terminal handoff |
| `deps.view` | Render a plugin's tool report into lines / a popup with install keymaps |
| `deps.first_run` | Show a plugin's tool report once, ever — for a consuming plugin's own `setup()` |
| `deps.require_tool` | The failure moment: is this tool here *right now*, and if not, say why it mattered and how to get it |
| `deps.status` | Every declared tool across **every** plugin, merged into one report |
| `deps.project` | The project view: scan a root, report which treesitter parsers and tools its files need and are missing ([README](project/README.md)) |

## `:Lib deps` — the user-facing surface

Registered by `require("lib.nvim_usrcmds").setup()` (opt-in via its `deps`
option, default `true`), as routes on the existing `:Lib` verb rather than a
second top-level command:

```vim
:Lib deps show <plugin>      " tools + why + present/missing + install commands
:Lib deps show               " which plugins ship a spec at all
:Lib deps status             " every plugin's tools at once — what's missing HERE
:Lib deps install <plugin>   " compose, confirm, hand off to a terminal
:Lib deps install            " ... for everything missing, across every plugin
:Lib deps project            " this directory's files: which parsers and tools are missing for them
:Lib deps project install    " ... ask once, then install them
```

`<Tab>` completes plugin names that actually ship a spec.

## `lib.nvim.deps.health` — replace a hand-rolled `check_exe` loop

```lua
local health = require("lib.nvim.deps.health")

health.report({
  { bin = "pdftotext", required = false, hint = "install poppler-utils" },
  { bin = "tesseract",  required = false, hint = "install tesseract-ocr" },
  { python_module = "pdfplumber", hint = "pip install pdfplumber" },
})
```

Reports each entry via `:checkhealth` (`h_ok`/`h_warn`/`h_err`, `h_err` only
when `required = true`). `bin` is probed through `lib.nvim.core.has_exec`
(memoized); `python_module` shells out to `python -c "import <module>"`
against the first of `python3`/`python`/`py` found on `PATH`.

If you already have a parsed spec (see below), skip building the entry list
by hand:

```lua
local spec = require("lib.nvim.deps.spec")
local result = spec.load("docs/INSTALL.md")
require("lib.nvim.deps.health").from_tools(result.tools)
```

## `lib.nvim.deps.spec` — parse a plugin's `docs/INSTALL.md` / `docs/install.json`

Two authoring formats, same validated shape on the other side. Pick
whichever fits: Markdown for something a human reads on GitHub, JSON when
you want richer/longer content (multi-line `why`, extra metadata) or the
fastest possible parse (native `vim.json.decode`, no line-oriented subset
limits). See [`templates/deps/`](../../../../templates/deps/) for a
copy-paste starting point of each.

```lua
local spec = require("lib.nvim.deps.spec")

local result = spec.load("docs/INSTALL.md")   -- or docs/install.json
-- result.tools  : Lib.Deps.Tool[]  (bin, required, why, see?, pkg)
-- result.errors : Lib.Deps.Error[] (validation problems, if any — empty on a clean parse)

for _, err in ipairs(result.errors) do
  vim.notify(("docs/INSTALL.md tool #%d (%s): %s"):format(err.index, err.field or "?", err.message))
end
```

`why` is a **required, non-empty** field on every tool entry — a block
missing it fails validation the same way a malformed `pkg` map would,
rather than silently shipping a nameless "tool missing" report. `bin` and
at least one `pkg` entry are required for the same reason. `required`
defaults to `false`; `see` is optional.

```lua
-- Locate another plugin's spec, manager-agnostic:
local path = spec.find("pdfport.nvim")   --> ".../pdfport.nvim/docs/install.json" (preferred if present)
                                          --> or ".../pdfport.nvim/docs/INSTALL.md"
                                          --> or nil if the plugin ships neither

spec.plugins()                            --> every plugin that ships a spec, sorted
```

### How `find` resolves (and why it needs two steps)

1. **`runtimepath`** — manager-agnostic: packer, vim-plug, mini.deps, a
   symlinked dev checkout, and every *loaded* lazy.nvim plugin.
2. **lazy.nvim's plugin registry**, consulted via `pcall` only if step 1
   missed and lazy.nvim is present.

Step 2 is not redundant: lazy.nvim puts a plugin on `runtimepath` only once
it actually loads. Measured against a real config while building this —
**120 plugins configured, 44 loaded at startup, 76 pending**, and all 76 of
those were resolvable through lazy's `dir` while being absent from
`runtimepath`. A runtimepath-only lookup would therefore have silently
failed for the majority of a lazy-loading user's plugins, and "silently" is
the problem: a spec that can't be found looks exactly like a plugin that
ships none.

### `docs/INSTALL.md` format

Normal Markdown prose, with zero or more ` ```install-tool ` fenced blocks.
Each block's body is decoded with `lib.lua.yaml.simple_parse` — that
module's minimal YAML subset (no anchors, no flow style, no `|`/`>` block
scalars), so keep `why` to one line.

````markdown
```install-tool
bin: pdftotext
required: false
why: "Enables the fast plain-text extraction backend, no Python env needed."
pkg:
  apt: poppler-utils
  brew: poppler
  pacman: poppler
```
````

### `docs/install.json` format

```json
{
  "tools": [
    {
      "bin": "pdftotext",
      "required": false,
      "why": "Enables the fast plain-text extraction backend, no Python env needed.",
      "pkg": { "apt": "poppler-utils", "brew": "poppler", "pacman": "poppler" }
    }
  ]
}
```

### One tool, several spellings — `bin_alternatives`

Ghostscript is `gs` on Linux and macOS and `gswin64c` (or `gswin32c`) on
Windows. Same program, same package, same reason to want it — but a spec that
can only name one of them reports the tool as **missing** on the platform
where it is spelled differently, right next to a capability check that found
it. One `:checkhealth` run, two answers.

```json
{
  "bin": "gs",
  "bin_alternatives": ["gswin64c", "gswin32c"],
  "why": "Last-resort PDF merge fallback when neither qpdf nor pdftk is present.",
  "pkg": { "apt": "ghostscript", "choco": "ghostscript" }
}
```

The Markdown form carries it too — the YAML subset does block lists:

````markdown
```install-tool
bin: gs
bin_alternatives:
  - gswin64c
  - gswin32c
why: Last-resort PDF merge fallback when neither qpdf nor pdftk is present.
pkg:
  apt: ghostscript
```
````

**`bin` stays canonical for everything except detection**: it is the tool's
identity, its display label, the key its install state is stored under, and
what `pkg` maps from. `bin_alternatives` only widens the question *is it
here*, and the report names the spelling that answered:

```
gs found (as gswin64c)
```

It is **not** a list of substitutes. A different program that would also do
the job is a different tool with its own `why` and its own `pkg` — `qpdf` and
`pdftk` both merge PDFs and are two entries, not alternatives of each other.
The test is whether one `pkg` map is honest for all of them.

A bare string (`"bin_alternatives": "gswin64c"`) is **rejected** at
validation rather than accepted. It is the obvious way to write it wrong, and
it is the one that would otherwise pass silently: a string iterates as an
empty list, so the alternative would never be probed and the tool would keep
reporting missing on exactly the platform the field was added for.

Detection lives in `lib.nvim.deps.detect` and is shared by all three callers
that ask "is it here" — `health` (the `:checkhealth` line), `install.plan`
(don't plan an install for something already present) and `view` (the `i`
key's already-installed refusal, and clearing the memoized PATH result after
an install, for *every* name rather than just the canonical one).

### Installed, but not on PATH — `paths`

Several GUI installers never extend PATH at all, and this is the *normal*
case on Windows rather than the exception: measured against a real
machine, neither the Chrome nor the LibreOffice installer touches PATH, so
a PATH-only check reports both as missing on a machine where they are
plainly installed. `bin_alternatives` doesn't help here — the binary isn't
spelled differently, it's just nowhere PATH looks.

`paths` names literal install locations to try, once every name in
`bin`/`bin_alternatives` has already missed on PATH — keyed by platform
(`win`/`mac`/`linux`), each entry `$ENVVAR`-expandable so the same
declaration works across accounts with a differently-rooted install:

```json
{
  "bin": "chrome",
  "bin_alternatives": ["google-chrome", "chromium", "chromium-browser", "brave", "msedge"],
  "paths": {
    "win": [
      "$PROGRAMFILES\\Google\\Chrome\\Application\\chrome.exe",
      "$LOCALAPPDATA\\Google\\Chrome\\Application\\chrome.exe"
    ],
    "mac": ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"],
    "linux": ["/usr/bin/google-chrome"]
  },
  "why": "Renders a hovered link as a screenshot instead of previewing it as text.",
  "pkg": { "winget": "Google.Chrome", "scoop": "googlechrome" }
}
```

A `paths` hit is reported by its full resolved path rather than a bare name
— "chrome found (as C:\\...\\chrome.exe)" says exactly where it was found,
which a plain "found" would not. Same validation posture as
`bin_alternatives`: a `paths` value that isn't a per-platform list of
strings is rejected rather than silently iterating as empty.

## `lib.nvim.deps.health.report_for` — the `:checkhealth` hook

The one-line addition a plugin's own `health.lua` makes instead of
re-listing its tools a second time by hand:

```lua
-- inside your plugin's health.lua, in M.check():
require("lib.nvim.deps.health").report_for("pdfport.nvim")
```

Locates and parses the plugin's own spec, reports each tool the same way
`from_tools` does, and adds one line pointing at `:Lib deps show
<plugin>` for the fuller report. Silently does nothing if the plugin ships
no spec — a `:checkhealth` section for a plugin that declares nothing
shouldn't print anything.

**When a plugin already hand-rolls its own per-tool checks** (pdfport.nvim,
images.nvim, mdview.nvim and migrate.nvim all do, each with messages more
specific than a generic tool report — "pandoc producer: ready (engine:
xelatex)" rather than "pandoc found"), call `pointer_for` instead of
`report_for`: same lookup and no-op guards, but only the `:Lib deps show`
line, no per-tool loop. `report_for` on top of an already-complete
hand-rolled report does not add coverage for any tool — it repeats every one
of them a second time in plainer wording, which reads as `:checkhealth`
contradicting itself rather than confirming it.

```lua
-- inside your plugin's health.lua, in M.check(), when every declared tool
-- already has its own hand-rolled check elsewhere in the same function:
require("lib.nvim.deps.health").pointer_for("pdfport.nvim")
```

## `lib.nvim.deps.project` — what this project's files need

`status` answers "what is missing on this machine for the plugins I run";
`project` answers "what is missing for the files in *this directory*": it
scans a root asynchronously (bounded by file count, depth and time, cached
per root), maps the file kinds to
filetypes, treesitter languages and the tools a caller registered for those
filetypes, and reports what is not installed. Installing asks once and uses
the same confirmed ways as everything else here (a terminal with the command
typed, `parser_policy.install`, Mason's registry API). Full description,
including the answer to "can Mason be driven from Lua without UI", in
[`project/README.md`](project/README.md).

```lua
local project = require("lib.nvim.deps.project")
project.register_tools("my.nvim", { lua = { { mason = "stylua" } } })
project.setup({ auto = true })   -- optional: one notification per root with something missing (home and drive roots are skipped)
```

## `lib.nvim.deps.status` — all of it at once

`:Lib deps show <plugin>` answers *"what does this plugin want"*, which is
the right question once you already suspect a plugin. It is the wrong one
after cloning a config onto a new machine, where the question is **"what is
missing here"** and the old answer was to run `show` once per plugin and
hold the results in your head. `:Lib deps show` with no argument didn't help
either — it lists which plugins ship a spec, not what any of them lacks.

```lua
local status = require("lib.nvim.deps.status")

status.collect()   --> { tools, sources, plugins, failed } — the merge, pure
status.lines()     --> string[]
status.show()      --> the same popup `:Lib deps show` opens, with `i` / `I`
status.install()   --> plan + confirm + terminal, for everything missing
```

**It also fixes a timing problem it doesn't look like it fixes.** The
first-run popup rides on a plugin's `setup()`, so a lazy-loaded plugin shows
it whenever it first happens to load — for a plugin bound to a rare filetype,
possibly weeks after installation. Measured against the config this library
was extracted from: **120 plugins configured, 44 loaded at startup, 76
pending.** `spec.find` already reads lazy.nvim's registry, so all 76 are
reachable from here without waiting for any of them to load.

### The merge

One tool, several declarers — `curl` is wanted by five plugins here, `rg` by
six. It has to appear **once** (a report listing curl five times buries what
else is missing) while still saying who wants it, so merging is per-field
rather than last-one-wins:

| Field | Rule | Why |
|---|---|---|
| `required` | true if **any** declarer requires it | Installing it satisfies everyone; skipping it breaks at least that one plugin outright |
| `pkg` | unioned, first declaration wins a key | Two plugins naming different packages for one binary is a bug in one of them — silently preferring the later would hide it |
| `bin_alternatives` | unioned | A spelling that counts as "found" for one plugin counts for all: it is the same program |
| `paths` | unioned per platform | Same reasoning as `bin_alternatives` — otherwise the aggregate `:Lib deps show`/`install` report would miss a tool the per-plugin view finds |
| `why` | the first declarer's sentence | Concatenating several would produce a paragraph per tool and bury the list |
| `see` | rewritten to `wanted by a.nvim, b.nvim` | Answers "who wants this?" without a renderer change |

**Rendering is `deps.view`'s, unchanged.** The merge produces one tool list
and one `Lib.Deps.ParseResult` — exactly what `view.show` already takes — so
the popup, the `i` / `I` install keymaps, the live output streaming and the
`[missing]` → `[ok]` flip all work here for free instead of existing twice in
slightly different forms.

A plugin that `spec.plugins()` lists but whose spec cannot be read lands in
`failed` and is named in a warning, rather than being dropped: "absent from
the report" and "declares nothing" would otherwise look identical.

## `lib.nvim.deps.require_tool` — the failure moment

Everything else here is forward-looking. `:checkhealth`, the first-run popup
and `:Lib deps show` all answer *"what might I need?"* — read before anything
breaks, which usually means not read at all. The moment that actually reaches
a user is the one where a command does nothing, and that moment used to be
served by whatever string each call site happened to have written by hand:

```
"curl not found"                            -- language.nvim
"curl executable not found on PATH"         -- diff.nvim
"tesseract not found — see :checkhealth images"
```

The third is the best of them and still only points at *another plugin's*
health check. Meanwhile that plugin's own `docs/install.json` holds a
one-sentence `why`, a package name for nine managers, and everything
`deps.pm` needs to compose the exact command for this host — all of it unused
at precisely the moment it answers the question the user now has.

```lua
local curl = require("lib.nvim.deps").require_tool("language.nvim", "curl")
if not curl then return end
-- ... spawn `curl`
```

```
[language.nvim] curl not found — Enables the google/deepl translate engines.
  install:  sudo apt install curl
  or run:   :Lib deps install language.nvim
```

**It returns the name, not a boolean.** A tool declaring `bin_alternatives`
is `gs` on Linux and `gswin64c` on Windows, and a caller that has just been
told "yes, it's here" still has to know which spelling to spawn. Returning
the found name answers both questions at once and stays truthy for the
`if not … then return end` guard that is the point.

**Nothing here installs anything.** The message names the command and points
at `:Lib deps install`, which remains the only route that touches the system.
Offering to install *at* the failure moment would answer a question the user
did not ask — they wanted to translate a paragraph, not administer their
machine.

| Option | Effect |
|---|---|
| `silent` | Answer without reporting — for a caller collecting several failures into one summary |
| `throttle_ms` | How long this (plugin, tool) pair stays quiet after a report (default 5000; `<= 0` disables) |
| `manager` | Compose the install line for this manager instead of the detected one |

The throttle is a **burst guard, not a mute**: a caller checking one tool per
file across a 200-file batch would otherwise produce 200 identical
notifications, while a user who runs `:Translate`, reads the message and runs
it again a minute later has deliberately asked twice and should be told
twice. A short window separates those without having to tell them apart.

**Works before the plugin ships a spec.** With no spec entry the check still
runs and still reports — it just has no `why` and no install command to add.
A plugin can therefore move its call sites over first and declare its tools
afterwards, rather than needing both at once.

**Not every failure path notifies.** A callback taking `(value, err)`, a
`result.errors` list, an `on_done({ ok = false, err = … })` — those hand the
error *upwards*, and there `check`'s notification would be a second message
next to the one the caller is already about to show. `lines` gives the same
wording with nothing attached:

```lua
local rt = require("lib.nvim.deps.require_tool")
on_done({ ok = false, err = table.concat(rt.lines("nvim", "pandoc"), " ") })
```

`require_tool.reset(plugin?)` forgets the throttle state and the memoized
specs behind it — for tests, and after an install has changed the answer.

## `lib.nvim.deps.first_run` — "tell me on first install, not from the README"

The flow this exists for: install a plugin via lazy.nvim, restart Neovim,
and the *first* time that plugin's `setup()` runs, see a popup explaining
which tools it wants and why — instead of reading the README and copying
install commands by hand. Every subsequent restart, `:Lib deps show
<plugin>` is the ongoing way to see the same report.

```lua
-- inside your plugin's own setup(), typically near the end:
function M.setup(opts)
  ...
  require("lib.nvim.deps").show_once("pdfport.nvim")
end
```

`show_once` is a no-op after its first call for a given plugin name — the
"seen" state persists across restarts (`lib.nvim.cache.disk`, namespace
`lib.nvim.deps.first_run`), and past-tense-only: nothing here re-checks or
re-notifies later just because a tool that was present becomes missing.
It's also a no-op, but still marks the plugin as seen, when there's simply
nothing to show — no spec file, an empty spec, or (once shown) a spec whose
declared tools are all already present.

This is the one call in `lib.nvim.deps` reachable from a place that isn't a
`:Lib deps` command — deliberately safe to be, since the trigger is still
an explicit action by the consuming plugin (`setup()`), never `require`,
and the popup itself only ever *shows* — installing anything still goes
through the same `i`/confirm/terminal path as `:Lib deps show` always has.

`:Lib deps reset-first-run [plugin]` clears the "seen" state (one plugin,
or every plugin with no argument) — mainly useful for testing this exact
flow without reinstalling the plugin.

### Opting out

Set either of these — anywhere in your own config, no
`require("lib.nvim.deps")` call needed:

```lua
vim.g.lib_nvim_deps_disable_first_run = true              -- every plugin, everywhere
vim.g.lib_nvim_deps_disabled_plugins = { "gopath.nvim" }   -- just these
```

**Where** matters less than it might seem: `vim.g` is a plain global, read
fresh on every `show_once` call, so it works no matter when or where it's
set relative to the plugin that calls `show_once` — the top of `init.lua`,
inside that plugin's own lazy.nvim `config = function() ... end`, anywhere.
This is deliberate: a user who installed, say, `gopath.nvim` alone (with
`lib.nvim` pulled in only as its transitive dependency) has no `lib.nvim`
config block of their own to put a `setup({ ... })` option into — a
`vim.g` toggle needs no such block to exist. Both variables are also worth
mentioning explicitly in **every consuming plugin's own README**, next to
its `docs/install.json` blurb — that's where a user who only installed
*that one plugin* will actually be looking when they want to turn the
popup off, not this file.

Neither variable is retroactive: it stops **future** `show_once` calls, it
does not mark anything as already-seen — so removing the opt-out later
picks up exactly where it would have without one, rather than having
silently consumed the "first run" while disabled.

**Future direction, not yet built:** a plugin could additionally expose
its *own* `setup({ deps_popup = false })`-style option that internally sets
the per-plugin `vim.g` entry (or simply skips its own `show_once` call) —
that would put the toggle in the one place a user is even more likely to
look first (that plugin's own `setup()` call) and matches how other
opt-in/opt-out flags already work across this ecosystem (e.g.
`lib.nvim_usrcmds`' `deps = true/false`). Deliberately not retrofitted into
every consuming plugin right now — the `vim.g` toggle already covers the
need with zero per-plugin code, and adding a redundant second knob to each
plugin's config schema is a cost worth paying only if the `vim.g` form
turns out not to be discoverable enough in practice.

## `lib.nvim.deps.pm` — package managers

```lua
local pm = require("lib.nvim.deps.pm")

pm.detect()      --> the manager to use here, or nil
pm.available()   --> every manager present, in this OS's preference order
pm.get("apt")    --> a manager definition by id, installed or not

pm.commands(pm.get("brew"), { "poppler", "tesseract" })
--> { { "brew", "install", "poppler", "tesseract" } }
pm.render({ "brew", "install", "poppler" })   --> "brew install poppler"
```

Known ids (the same keys a tool's `pkg` map uses): `apt`, `dnf`, `pacman`,
`zypper`, `apk`, `brew`, `winget`, `scoop`, `choco`, plus the language-level
`pipx` and `pip` (`pip install --user`). Those two are never what `detect()`
answers; `pm.resolve(tool)` falls back to them when the host's OS manager has
no package for the tool and the tool declares one:

```json
{ "bin": "whisper-ctranslate2", "why": "...", "pkg": { "pipx": "whisper-ctranslate2" } }
```

`:Lib deps show` and the install plan then list the `pipx install ...` line
(only if `pipx`/`pip` is on PATH). A `pkg` map of only `pipx`/`pip` passes
validation like any other. Preference order is
per-OS; WSL is treated as plain Linux, since inside WSL the distro's own
manager is the right answer.

`commands` returns a **list** of argv lists, not one: `winget` can't take
several packages per invocation (extra tokens become query terms), so it
gets one command per package while everything else gets one combined
command. Two deliberate omissions:

- **No `-y`/`--noconfirm`.** The package manager's own confirmation prompt
  is kept. The user runs this in a visible terminal anyway; seeing what apt
  is about to pull in beats suppressing it for tidiness.
- **No elevation logic beyond a `sudo` prefix** (added only when the manager
  needs root, the process isn't already root, and `sudo` is on PATH). On
  Windows, elevation is the manager's own business.

## `lib.nvim.deps.install` — plan and handoff

```lua
local install = require("lib.nvim.deps.install")

local plan = install.plan(result.tools)
-- plan.manager / present / missing / installable / unsupported / packages / commands

install.run(plan)   -- asks, then opens a terminal with the command typed, not submitted
```

`plan()` is pure — it probes PATH and detects the package manager, and
returns what *would* happen. `installable` vs. `unsupported` splits the
missing tools by whether this host's manager has a declared package name for
them, so a tool that simply has no `brew` entry is reported rather than
quietly dropped from the command.

`run()` refuses (returning `false`, with a notification) when there's no
package manager, nothing missing, or nothing installable — it only ever
opens a terminal when there is a real command to hand over.

## `lib.nvim.deps.view` — the report, and installing from it

```lua
local view = require("lib.nvim.deps.view")

view.lines("pdfport.nvim", result)         --> string[]  (pure, testable)
view.show("pdfport.nvim", result)          --> popup (kit.viewer) or a scratch split fallback
view.render("pdfport.nvim", result, opts, ui)  --> { lines, line_tools } — the overlay `show` builds on
```

Missing-and-required sorts first, then merely-missing, then present — the
reason to open this view is to find what isn't there. A `why` under 20
characters gets a visible nudge: the parser can enforce that `why` exists,
but not that it says anything useful, so that judgement is surfaced where a
plugin author will see it rather than pretended to be validation.

`show()` opens a `lib.nvim.ui.kit` `viewer` popup when kit is installed
(soft dependency — falls back to a plain read-only scratch split,
`view.show_split`, otherwise), with three keymaps:

| Key | Effect |
|---|---|
| `i` | Install the tool under the cursor |
| `<CR>` | Expand/collapse that tool's install output |
| `I` | Install everything missing |
| `q` / `<Esc>` | Close |

`i` does not always run inline. A package manager that needs root
(`pm.needs_terminal`) has no interactive stdin to answer a `sudo` password
prompt from a plain backgrounded job, so that case still confirms and hands
off to a real terminal via `deps.install.run` — the same safety rule as the
bulk install, just reached from a different key. Only managers that don't
need elevation (brew, scoop, most winget) install inline, streaming
stdout/stderr into the popup live via `lib.nvim.cross.uv.spawn_stream`, and
flip that tool's line from `[missing]` to `[ok]` the moment the install
finishes.
