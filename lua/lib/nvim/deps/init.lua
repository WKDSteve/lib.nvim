---@module 'lib.nvim.deps'
--- External-tool detection, declared-dependency spec parsing, and an opt-in
--- `:Lib deps` surface, for plugins that degrade gracefully without optional
--- CLI tools (pandoc, ImageMagick, tesseract, poppler-utils, …). The spec
--- formats are `docs/INSTALL.md` and `docs/install.json`.
---
--- Requiring this module registers nothing and touches nothing. `setup()`
--- registers the `:Lib deps` routes and still executes no install command —
--- only `:Lib deps install`, invoked by hand and confirmed, ever puts a
--- command in front of the user (and even then, in a terminal they submit
--- themselves; see `lib.nvim.deps.install`).

local M = {}

M.spec = require("lib.nvim.deps.spec")
M.detect = require("lib.nvim.deps.detect")
M.health = require("lib.nvim.deps.health")
M.pm = require("lib.nvim.deps.pm")
M.install = require("lib.nvim.deps.install")
M.view = require("lib.nvim.deps.view")
M.first_run = require("lib.nvim.deps.first_run")
M.status = require("lib.nvim.deps.status")
M.project = require("lib.nvim.deps.project")

---Show `plugin_name`'s declared-tools popup once, ever — call from the
---consuming plugin's own `setup()`. See `lib.nvim.deps.first_run` for the
---full contract (persisted "seen" state, when it's a no-op).
---@param plugin_name string
---@param opts? { manager?: Lib.Deps.Manager, cache?: Lib.Cache.Opts }
---@return boolean shown
function M.show_once(plugin_name, opts)
  return M.first_run.show_once(plugin_name, opts)
end

---Is `bin` available for `plugin_name` right now — and if not, report it
---with the plugin's own `why` and the install command for this host.
---
---For the moment a command fails, where every other entry point here is
---read *before* anything breaks. Returns the name to spawn (which differs
---from `bin` when the spec declares `bin_alternatives` and this host
---spells it the other way), or nil:
---
---  local curl = require("lib.nvim.deps").require_tool("language.nvim", "curl")
---  if not curl then return end
---
---Exposed as the function rather than the module — deliberately unlike the
---`M.first_run` / `M.show_once` pair above, since here the call *is* the
---module's purpose and `deps.require_tool(...)` is how it reads at the call
---site. `require("lib.nvim.deps.require_tool")` still reaches `message`
---and `reset`.
--- testing-perf: conditional: only when the tool is missing and `silent` is not set
---@param plugin_name string
---@param bin string
---@param opts? Lib.Deps.RequireTool.Opts
---@return string|nil found_as
function M.require_tool(plugin_name, bin, opts)
  return require("lib.nvim.deps.require_tool").check(plugin_name, bin, opts)
end

---Every plugin on `runtimepath` shipping a deps spec. Convenience re-export
---of `lib.nvim.deps.spec.plugins`.
---@return string[]
function M.plugins()
  return M.spec.plugins()
end

---@internal
---Resolve and parse `plugin_name`'s spec, notifying on the two ways that
---fails (no spec shipped / spec file unreadable).
---@param plugin_name string
---@return Lib.Deps.ParseResult|nil
local function resolve(plugin_name)
  local notify = require("lib.nvim.notify").create("[lib.nvim.deps]")

  local path = M.spec.find(plugin_name)
  if not path then
    notify.warn(
      ("%s ships no docs/install.json or docs/INSTALL.md (or isn't on runtimepath)."):format(
        plugin_name
      )
    )
    return nil
  end

  local result, err = M.spec.load(path)
  if not result then
    notify.error(err or ("could not read " .. path))
    return nil
  end
  return result
end

---Show `plugin_name`'s declared tools, each with its `why` and its status on
---this host, in a scratch split.
---@param plugin_name string
---@return boolean shown
function M.show(plugin_name)
  local result = resolve(plugin_name)
  if not result then
    return false
  end
  M.view.show(plugin_name, result)
  return true
end

---Offer to install whatever `plugin_name` declares and this host is missing.
---Confirmation-gated; see `lib.nvim.deps.install.run`.
---@param plugin_name string
---@return boolean|nil started nil while the question is open
function M.install_for(plugin_name)
  local result = resolve(plugin_name)
  if not result then
    return false
  end
  return M.install.run(M.install.plan(result.tools))
end

---@internal
---Argument type completing plugin names that actually ship a deps spec.
---Registered lazily by `setup()` rather than at require time — registering a
---composer type is a side effect, and this module's contract is that
---requiring it has none.
local function register_argtype()
  require("lib.nvim.bindings.usercmd.composer").register_type("DEPS_PLUGIN", {
    desc = "Plugin that ships a deps spec; omit for all of them",
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(lead)
      return vim.tbl_filter(function(name)
        return name:sub(1, #lead) == lead
      end, M.plugins())
    end,
  })
end

---The `:Lib deps …` routes, for `lib.nvim_usrcmds` to merge into the `:Lib`
---verb it already builds. Exposed as data rather than registered here so
---there is exactly one place that owns the `:Lib` verb.
---@return table[] routes
function M.routes()
  register_argtype()
  return {
    {
      path = { "deps", "show" },
      args = {
        {
          name = "plugin",
          type = "DEPS_PLUGIN",
          optional = true,
          -- Own text: without a plugin this lists the names, it does not show them all.
          desc = "Plugin to inspect; omit to list the plugins with a spec",
        },
      },
      desc = "List a plugin's declared external tools, why each matters, and what's missing",
      run = function(ctx)
        if ctx.args.plugin then
          M.show(ctx.args.plugin)
        else
          local names = M.plugins()
          local notify = require("lib.nvim.notify").create("[lib.nvim.deps]")
          if #names == 0 then
            notify.info("No plugin on runtimepath ships a deps spec.")
          else
            notify.info("Plugins with a deps spec: " .. table.concat(names, ", "))
          end
        end
      end,
    },
    {
      path = { "deps", "status" },
      args = {},
      desc = "Every declared tool across every plugin, and what's missing here",
      run = function()
        M.status.show()
      end,
    },
    {
      path = { "deps", "install" },
      args = { { name = "plugin", type = "DEPS_PLUGIN", optional = true } },
      desc = "Offer to install missing external tools — one plugin's, or every plugin's (asks first)",
      run = function(ctx)
        -- No plugin named: the whole config's worth. Same confirmation and
        -- the same terminal handoff either way; only the tool list differs.
        if ctx.args.plugin then
          M.install_for(ctx.args.plugin)
        else
          M.status.install()
        end
      end,
    },
    {
      path = { "deps", "project" },
      args = {
        {
          name = "action",
          type = "STRING",
          enum = { "refresh", "install" },
          optional = true,
          desc = "refresh: scan again; install: ask once, then install; omit: show",
        },
      },
      desc = "Scan this directory's files and show which treesitter parsers and tools are missing for them",
      run = function(ctx)
        M.project.run(nil, ctx.args.action)
      end,
    },
    {
      path = { "deps", "reset-first-run" },
      args = { { name = "plugin", type = "DEPS_PLUGIN", optional = true } },
      desc = "Forget that a plugin's (or every plugin's) first-run popup was already shown",
      run = function(ctx)
        M.first_run.reset(ctx.args.plugin)
        local notify = require("lib.nvim.notify").create("[lib.nvim.deps]")
        notify.info(
          ctx.args.plugin and (ctx.args.plugin .. " will show its first-run popup again")
            or "every plugin will show its first-run popup again"
        )
      end,
    },
  }
end

---@type Lib.Deps
return M
