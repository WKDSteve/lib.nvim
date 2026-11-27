# lib.nvim.crossfeature

The catalogue of cross-features: every connection where one plugin or app of this ecosystem uses
another. Ask it instead of searching the repositories: what does images.nvim give and take, which
connections are only planned, which would work on this machine.

Overview of all public entries: [docs/CROSSFEATURE-CATALOG.md](../../../../docs/CROSSFEATURE-CATALOG.md).

## Entry

| field | meaning |
| --- | --- |
| `id` | `from>to`; a planned or idea one `from>to#<idea>` |
| `from`, `to` | `from` uses `to`. Plugins by the name of the context-menu catalogue (`images` for images.nvim), apps by repo name (`hub-desktop`) |
| `kind` | how: `requires`, `optional` (a guarded require), `engine`, `serves`, `launches`, `built-on`, `reads`, `talks-to`, `publishes`, `sources`, `names`, `event`, `menu` |
| `status` | `present`, `planned` (an open task builds it), `idea` |
| `text` | one sentence: what the one does with the other |
| `evidence` | `{ repo, file }`: the file that shows it (present ones) |
| `ideas`, `tasks` | the ideas of the cross-feature analysis (`"1"`..`"10"`, `"K-n"`) and the task ids of the workshop vault |

## Asking

```lua
local cf = require("lib.nvim.crossfeature")

cf.list({ plugin = "images" })                    -- either side
cf.list({ from = "casedesk", kind = "optional" })
cf.list({ status = "planned" })                   -- what is being built
cf.list({ idea = "K-6" })                         -- what an idea of the analysis became
cf.list({ task = "ALL/verwaiste-events-anschliessen" })
cf.list({ visibility = "public" })                -- without the private repos
cf.list({ status = "planned", available = true }) -- both sides installed here

local ok, missing = cf.available("hover>images")  -- missing: names of the sides not installed
cf.repo("tasks")                                  -- { repo = "tasks.nvim", kind = "plugin", module = "tasks_nvim" }

-- the context-menu catalogue and the connections point at each other
cf.for_menu("filetree.ocr")                       -- the connections behind a menu entry with `cross`
cf.menu_entries("filetree>images")                -- the menu entries that bring a connection in
cf.unlinked_menu_entries()                        -- menu entries with `cross` but no connection: gaps

cf.register({ from = "myplugin", to = "images", kind = "optional", status = "present",
  text = "myplugin previews pictures with images.nvim." })   -- at runtime; id defaults to from>to
```

A plugin counts as installed when its main module (`repo(name).module`, else the name) `require`s;
an app when a command of its name is executable (the native apps install one).

## Where the data comes from

`data.lua` is **generated**: the one source is `TOOLS/scripts/app-icons/integrations.json` of the
workshop vault (`edges` found by the scan of `graph-data.mjs`, `manual` ones with their proof,
`meta` with ideas and tasks, `proposed` for planned ones and ideas). `node crossfeature.mjs` there
writes `data.lua`, `--check` fails while it is out of date. Then regenerate the overview:

```sh
nvim -n -i NONE --headless -u NONE -l scripts/gen-crossfeature-catalog.lua
```

`TESTS/crossfeature_catalog_spec.lua` fails when the overview is out of date, and when a menu entry
with `cross` has no present connection. Private repos are in the data
(`visibility = "private"`); the overview leaves their connections out.
