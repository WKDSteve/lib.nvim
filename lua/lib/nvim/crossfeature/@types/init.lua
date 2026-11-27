---@meta
---@module 'lib.nvim.crossfeature.@types'

---Whether the connection exists.
---@alias Lib.CrossFeature.Status
---| "present"  it is there: found by the scan of the workshop, or written down with its proof
---| "planned"  an open task builds it (`tasks`)
---| "idea"     proposed, no open task (a parked one may be named)

---How the one side uses the other. The scan of the workshop finds the first six; the rest are
---written down by hand. A runtime `register` may use any other word.
---@alias Lib.CrossFeature.Kind
---| "requires"   a Lua `require` the plugin cannot do without
---| "optional"   a guarded `require` (pcall, probe, safe, package.loaded): used when installed
---| "engine"     an app runs the plugin as its engine (engine.lock)
---| "serves"     an app serves the page of another (mobile.lock)
---| "launches"   one starts the other (the hub)
---| "built-on"   an app stands on appkit
---| "reads"      reads a file or export of the other
---| "talks-to"   sends requests to the other (HTTP, a socket)
---| "publishes"  writes what the other reads
---| "sources"    takes data from the other
---| "names"      only names the other (a link, a command line)
---| "event"      listens to a `User` event of the other
---| "menu"       adds an entry to the context menu of the other
---| "unknown"    in the source, but not found by the scan on the machine that wrote the data

---A repository of the workshop.
---@class Lib.CrossFeature.Repo
---@field name     string   catalogue name: `images` for images.nvim (as in the context-menu catalogue), apps by repo name
---@field repo     string   repository name, `images.nvim`
---@field kind     string   "plugin", "app", "desktop", "web", "mobile", "kit", ...
---@field module?  string   plugins: the main Lua module, what `available` requires
---@field visibility? "private"  a private repo: never named in a published overview (public ones leave it out)

---Where the connection shows.
---@class Lib.CrossFeature.Evidence
---@field repo string  the repository that holds the file
---@field file string  path inside that repository

---One connection between two repos of the workshop.
---@class Lib.CrossFeature.Entry
---@field id        string                    unique: `from>to`, a planned or idea one `from>to#<idea>`
---@field from      string                    the side that uses (catalogue name)
---@field to        string                    the side that is used (catalogue name)
---@field kind      Lib.CrossFeature.Kind|string
---@field status    Lib.CrossFeature.Status
---@field text      string                    one sentence: what the one does with the other
---@field evidence? Lib.CrossFeature.Evidence the file that shows it (present ones)
---@field ideas?    string[]                  the ideas it comes from: "1".."10" and "K-n" of the cross-feature analysis (2026-11-17)
---@field tasks?    string[]                  task ids of the vault that build or built it
---@field visibility? "private"            runtime entries only: a side is private (built-in ones take it from the repos)

---The generated built-in data (`crossfeature/data.lua`).
---@class Lib.CrossFeature.Data
---@field repos   Lib.CrossFeature.Repo[]
---@field entries Lib.CrossFeature.Entry[]

---What `list` can filter on; every given field must match.
---@class Lib.CrossFeature.Filter
---@field plugin?    string   either side
---@field from?      string
---@field to?        string
---@field kind?      string
---@field status?    Lib.CrossFeature.Status
---@field idea?      string   one of `ideas`
---@field task?      string   one of `tasks`
---@field visibility? "private"|"public"  "private": only entries with a private side; "public": only the others
---@field available? boolean  true: only entries whose two sides are installed here
