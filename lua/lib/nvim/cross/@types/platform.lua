---@meta
---@module 'lib.nvim.cross.@types.platform'

---@class Lib.Cross.Platform
---@field is_windows fun(): boolean
---@field is_wsl fun(): boolean
---@field is_macos fun(): boolean
---@field is_linux fun(): boolean
---@field case_blind fun(): boolean
---@field is fun(platform?: Lib.Cross.Platform.PlatformName): boolean|Lib.Cross.Platform.PlatformName

return {}
