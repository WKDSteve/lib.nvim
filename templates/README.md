# templates

Copy-paste reference implementations for problems every `lib.nvim`-dependent
plugin's headless test suite runs into. Nothing under this directory is
`require`-able Lua module code (it does not live under `lua/`, on purpose —
see below) and none of it ships to consumers; it exists so the same few lines
don't get silently reinvented (and drift) across a dozen sibling repos.

## Why this can't just be a `lib.nvim` module

A plugin's headless test runner starts with `lib.nvim` absent from
`runtimepath` and `package.path` — that absence is exactly the problem
`resolve_lib_nvim.lua` solves. Anything that resolves it for you must itself
be reachable *before* that resolution happens, so it cannot be reached via
`require("lib.nvim...")`. Hence: a plain file to copy, not a module to
depend on.

## `resolve_lib_nvim.lua`

The `add_lib_nvim()` function: finds `lib.nvim` via `$LIB_NVIM_PATH` → sibling
checkout (`../lib.nvim`) → `stdpath("data")/lazy/lib.nvim`, and puts it on
both `runtimepath` and `package.path`. Copy the function itself into your
`TESTS/run.lua` (or equivalent); then pick **one** of the caller
patterns below depending on how your plugin actually depends on `lib.nvim`.

### Pattern A — hard dependency, fail the whole suite

Use when the modules under test `require("lib.nvim...")` unconditionally, so
nothing can even load without it.

```lua
local lib_path = add_lib_nvim()
if not lib_path then
  print("FAIL  cannot locate lib.nvim (a runtime dependency of <plugin>).")
  print("      Set $LIB_NVIM_PATH, or check it out next to this repo.")
  os.exit(1)
end
```
Examples: `fileops.nvim`, `color_my_ascii.nvim`, `debugging.nvim`,
`diff.nvim`, `markdown.nvim` (all under `TESTS/run.lua`).

### Pattern B — soft/optional dependency, note and continue

Use when the plugin bridges to `lib.nvim` via `pcall(require, ...)` with a
standalone fallback (so the suite is still meaningful without it — it just
exercises the fallback path instead of the bridged one).

```lua
if not add_lib_nvim() then
  print("note  lib.nvim not found — exercising the standalone fallback path.")
  print("      Set $LIB_NVIM_PATH or check it out next to this repo to test the bridge.")
end
```
Example: `buffer-ctx.nvim/TESTS/run.lua`.

### Pattern C — resolve once, skip only the affected specs

Use when most of the suite is dependency-free and only a few spec blocks
touch `lib.nvim`-backed functionality; skip just those rather than the whole
run.

```lua
if not add_lib_nvim() then
  print("  skip <feature> tests (lib.nvim not on runtimepath)")
  return
end
```
Example: `pickers.nvim/TESTS/pickers_spec.lua` (`command.complete`,
`sources.repos`, `selected_index.debounce` blocks).

### Pattern D — don't resolve at all, exclude from scope

Use when wiring up resolution isn't worth it for a given module — typically
because it also hard-requires something heavier than `lib.nvim` alone (e.g.
`telescope.nvim`), making a meaningful headless run impractical anyway. Just
leave the module's spec out of the runner's spec list, with a comment
explaining why, rather than trying to make it load.

Example: `migrate.nvim/TESTS/run.lua` excludes `migrate.opt` /
`migrate.notify` / `migrate.common.*` (hard-require `lib.nvim` *and*
`telescope.nvim`) and only runs the dependency-free specs.

## Adding this to a new plugin

1. Copy `add_lib_nvim()` from `resolve_lib_nvim.lua` into your runner.
2. Pick A/B/C/D above based on how the plugin actually depends on `lib.nvim`.
3. Keep the env var name `$LIB_NVIM_PATH` — it's the one convention every
   existing copy agrees on (a couple of older copies used `$REPOS_DIR`
   instead; prefer `$LIB_NVIM_PATH` for new ones).

## Pinning `lib.nvim` in CI (`ci-verified`)

A consumer's GitHub Actions checkout of `lib.nvim` should not point at
`main`. `main` can go red between commits (WIP push, a fix still in
flight) — pointed there, a consumer's CI turns red for a bug that isn't
in the consumer at all, and whoever's debugging it looks in the wrong repo.

`ci-verified` is a branch this repo's own CI moves, but only *after*
`stylua` + `luacheck` + `tests` have all passed on `main` (and only
forward, never back to an older commit) — so it always names a commit that
was actually green here. Point consumer checkouts at it instead:

```yaml
- uses: actions/checkout@v5
  with:
    repository: WKDSteve/lib.nvim
    path: lib.nvim
    ref: ci-verified
```

Same convention for `hover.nvim`, `lsp.nvim` and `runtime-analysis.nvim`
if a plugin checks those out too.

## `deps/` — declaring optional external tools

Two starting points for a plugin's `docs/INSTALL.md` or `docs/install.json`
— the declared-dependency spec `lib.nvim.deps.spec` parses (see
[`lua/lib/nvim/deps/README.md`](../lua/lib/nvim/deps/README.md) for the full
design). Unlike the test-runner boilerplate above, these two
*are* meant to be copied verbatim into a consuming plugin's own `docs/`
directory and filled in, not adapted:

- [`deps/INSTALL.md`](deps/INSTALL.md) — Markdown + fenced `install-tool`
  blocks; readable as plain prose on GitHub.
- [`deps/install.json`](deps/install.json) — same fields, JSON; no
  line-oriented parsing limits (multi-line `why`, extra metadata), parsed
  natively via `vim.json.decode`. `lib.nvim.deps.spec.find` prefers this one
  when a plugin ships both.

Both require the same three things per tool: `bin`, a non-empty `why`
(validation fails without one — see the roadmap doc's "Describing tools"
section for why that's enforced, not just documented), and at least one
`pkg` entry.

## `cli_script.lua` — the command line of a plugin without the editor

The script behind `nvim --headless -u NONE -l scripts/<plugin>.lua <command> [options]`, for a scheduler, CI or a
hook: it puts the plugin and `lib.nvim` on the runtimepath (the same six places, in the same order, as
`contract_host.lua` below), hands the arguments to `MODULE.run(argv)` and exits with the number it returns. Copy it to
`scripts/<plugin>.lua` and replace the two names at its top (`MODULE`, `PLUGIN`); every rule stays in the plugin's
`lua/` (the CLI module parses the arguments and does the work), the script holds none.

The exit codes of the fleet's command lines: `0` done, `1` the work found or hit a failure (a red check, a failed
fetch), `2` usage or configuration, `3` the environment. The module returns `0`–`2` (or `3` for what it detects itself,
a missing program, a timeout); the script adds `3` for `lib.nvim` not found and for an error the module raised (printed
to stderr). Results go to stdout, messages to stderr, so `--format=json` stays parseable. The pattern is the one of
`tasks.nvim`'s `scripts/tasks.lua` and `testing.nvim`'s `scripts/testing.lua`; the first copy is `github_stats.nvim`'s
`scripts/github_stats.lua`. `TESTS/cli_script_template_spec.lua` runs this very file in a child Neovim.

## `contract_host.lua` — the persistent engine script of a machine contract

The script behind `nvim --headless -u NONE -i NONE -n -l scripts/<plugin>-host.lua`:
it puts the plugin and `lib.nvim` on the runtimepath (`$LIB_NVIM_DIR`,
`$LIB_NVIM_PATH`, `$REPOS_DIR/lib.nvim`, the plugin's `.deps/lib.nvim`, a sibling
checkout, lazy.nvim's data folder, in that order; each as one runtimepath entry,
so a comma in a folder name is escaped and does not split the path), then calls
`require(MODULE).serve(io.stdin, io.stdout)`. Copy it to `scripts/<plugin>-host.lua`
and replace the two names at its top (`MODULE`, `PLUGIN`); `MODULE` is the Lua
module that returns [`contract.host`](../lua/lib/nvim/contract/host/README.md)'s
`make({ api = api })`. Exit code `0` when the input ended, `2` when `lib.nvim` is
not found (stderr names what to set, stdout stays empty). It is a copy and not a
module for the same reason as `resolve_lib_nvim.lua`: it runs before `lib.nvim`
can be reached. `TESTS/contract_host_spec.lua` runs this very file in a child
Neovim.
