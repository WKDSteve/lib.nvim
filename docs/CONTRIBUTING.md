# Contributing to lib.nvim

Thank you for your interest! Bugs, ideas and questions are welcome in the
[issue tracker](https://github.com/WKDSteve/lib.nvim/issues); pull requests
very welcome.

Read this one first: `lib.nvim` sits under every other plugin in the
collection, so a change here is never local. What is fine in a leaf plugin —
renaming a helper, tightening a signature, adding a require — costs a
coordinated change across the fleet when it happens down here.

## Getting the repository into a session

Clone it and either symlink the checkout into your plugin directory or add it
to the runtime path directly:

```lua
vim.opt.rtp:prepend("/path/to/lib.nvim")
```

There is nothing to `setup()` for the library itself; requiring a module is
enough. `require("lib.nvim_usrcmds").setup({})` is the opt-in for the end-user
commands.

When you are testing a change against a dependent plugin, point that plugin's
suite at this checkout with `$LIB_NVIM_PATH`, or place the two as siblings —
[`templates/`](../templates/README.md) is the resolver they use.

## Ground rules

- Lua only, idiomatic Neovim Lua. 2-space indentation, `.stylua.toml` decides
  the rest.
- **No third-party dependencies.** Only `vim` and this library itself. A helper
  that needs an outside plugin belongs in the plugin that needs it.
- **The dependency direction never reverses.** Nothing here may require a
  sibling plugin, directly or by name. If a helper only makes sense for one
  consumer, it stays in that consumer.
- **`lib.lua.*` does not touch `vim`.** Anything editor-independent goes there
  and stays testable without a Neovim instance;
  [`architecture.md`](architecture.md) is the rule in full.
- **Every module is requireable on its own.** A plugin that needs one helper
  must not pay for the rest, so no module may reach for the aggregator, and
  cross-module requires stay minimal and acyclic.
- **Optional tools degrade to nothing.** Anything external — git, a package
  manager, a CLI — is detected at runtime and its absence costs one function,
  never a load error.
- Type definitions live in `@types/` files, never inline; internal modules are
  prefixed with `_` or live under `internal/`. The rest of the layout rules are
  [`conventions.md`](conventions.md).
- Descriptive commit messages.

## Repository layout

| Path | Contains |
| --- | --- |
| `lua/lib/lua/` | Editor-independent Lua: tables, strings, numerals, time, json, yaml, class, memo, diff, error, uuid, functions, lazy, dump, context_manager, config |
| `lua/lib/nvim/` | Everything that needs `vim` — one directory per module, each with its own `README.md` |
| `lua/lib/nvim/ui/` | The themed UI layer: `kit`, `list`, `hl`, `nerd_font`, `statusline` |
| `lua/lib/nvim/bindings/` | Named keymap actions, autocmd dispatch, and `usercmd/composer/` — the subcommand grammar the whole fleet builds on |
| `lua/lib/nvim/deps/` | Declared optional external tools per plugin: the popup, the report, and the composed install command |
| `lua/lib/strategies/` | How the `lib` aggregator resolves: eager, lazy, metatable, telemetry wrapper |
| `lua/lib/nvim_usrcmds/` | The opt-in `:Lib` end-user commands |
| `lua/lib/@types/`, `lua/lib/config/` | Shared type definitions and the aggregator configuration |
| `doc/` | The `:help lib.nvim*` files, one per documented module, plus the hub |
| `docs/` | The written documentation: index, modules, FEATURES, API, EXAMPLES, guides |
| `templates/` | Test-runner templates for dependent plugins resolving this library |
| `TESTS/` | The spec suite |

## Adding a module

The layout is mechanical on purpose — follow it and the indexes stay correct.

1. Decide the namespace first: `lib.lua.*` if it never touches `vim`,
   `lib.nvim.*` otherwise. [`architecture.md`](architecture.md) is the tiebreak.
2. One directory with `init.lua`; the module path equals the directory path.
   First line of every file is `---@module 'lib.<namespace>.<path>'`.
3. Put `@class` / `@alias` / standalone `@type` declarations in a `@types/`
   file, not inline in the source.
4. Add the per-module `README.md` next to the source — that is the
   authoritative function reference.
5. For `:help`-worthy modules, add `doc/lib.nvim-<module>.txt` tagged
   `*lib.nvim-<module>*`, with a tag per public function.
6. Wire it into the indexes: a row in the namespace tables in
   [`modules.md`](modules.md), a bullet under per-module documentation, and —
   for help files — one `|lib.nvim-<module>|` line in the `doc/lib.nvim.txt`
   hub.
7. Add a spec under `TESTS/`.

The three documentation steps are the ones that get skipped;
[`conventions.md`](conventions.md) states them as the rule.

## Tests

`TESTS/` is a headless spec suite.

```
nvim --headless -u NONE -l TESTS/run.lua
```

Exit 0 is a pass. While working on one module, name its spec after the runner
(`... -l TESTS/run.lua tree_spec.lua`) and only that one runs. [GitHub Actions](../.github/workflows/ci.yml) runs stylua,
luacheck and this suite on every push and pull request to `main`.

**The `ci-verified` branch.** Around thirty repositories check this one out as
a CI dependency. Pointing them at `main` would mean a broken commit here turns
all of them red before anyone traces it back. `ci-verified` is moved to the
commit at `main` only after stylua, luacheck and the suite have all passed,
so consumers pinning `ref: ci-verified` always test against a known-good state.
It only ever moves forward along main (after a force-push to main it is reset to the new verified commit): two overlapping runs cannot swap a newer verified
commit for an older one, and a failed lookup stops the job instead of pushing.
Nothing to do by hand — but it is why a red build here is worth fixing before
anything else.

## Workflow

1. Fork the repository.
2. Branch as `feature/<name>`.
3. Make the change, add a spec, update the module README and the indexes.
4. Open a PR with a clear description of what changed and why — and name the
   dependent plugins it affects, if any.
