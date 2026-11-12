---@meta
---Types of `lib.nvim.cross.detached`.

---One registered detached process.
---@class Lib.Cross.Detached.Entry
---@field pid integer the detached process
---@field owner integer the Neovim (pid) that started it
---@field name string a label for humans ("mdview-relay"), may be empty
---@field cmd string the command line it was started with, may be empty
---@field started integer `os.time()` at registration

---A registered process that is still running.
---@class Lib.Cross.Detached.Listed : Lib.Cross.Detached.Entry
---@field orphan boolean the owning Neovim is gone

return {}
