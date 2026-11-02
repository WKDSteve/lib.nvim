-- TESTS/run.lua — headless test runner for lib.nvim.
--
-- Run from the repo root:
--   nvim -n -i NONE --headless -u NONE -c "set rtp+=." -c "luafile TESTS/run.lua" -c "qa!"
-- or:
--   nvim -n -i NONE --headless -u NONE -l TESTS/run.lua
--
-- Loads every *_spec.lua listed below, runs it against the shared harness,
-- prints a per-spec result, runs EVERY spec even after a failure, and exits non-zero at the end if any failed.

-- Make the repo importable whether invoked via -l (cwd) or luafile.
vim.opt.rtp:append(vim.fn.getcwd())

-- A headless runner never writes the developer's system clipboard: `+` and `*` are two stores in
-- this process. Without a `g:clipboard` the editor finds a tool on the first register access
-- (`win32yank.exe` ships with the Windows build) and every clipboard spec below (copy_to_clipboard_spec
-- writes "lib_spec_copy_to_clipboard_marker_b") lands on the user's clipboard -- seen on two machines
-- while suites ran in the background. The same provider testing.nvim installs in its children
-- (`testing.child.clipboard`); an editor with a UI keeps its clipboard.
if vim.g.clipboard == nil and #vim.api.nvim_list_uis() == 0 then
  local store = { ["+"] = { {}, "v" }, ["*"] = { {}, "v" } }
  local copy, paste = {}, {}
  for _, reg in ipairs({ "+", "*" }) do
    copy[reg] = function(lines, regtype)
      store[reg] = { vim.deepcopy(lines), type(regtype) == "string" and regtype or "v" }
    end
    paste[reg] = function()
      return { vim.deepcopy(store[reg][1]), store[reg][2] }
    end
  end
  vim.g.clipboard =
    { name = "lib-spec-fake-clipboard", copy = copy, paste = paste, cache_enabled = 0 }
end

-- runtime-analysis.nvim is a runtime dependency of telemetry_wrap_spec.lua
-- only (the thin caller instrumenting `require("lib")` now lives there) —
-- the same three-candidate search runtime-analysis.nvim's own run.lua uses
-- to find lib.nvim, mirrored back. Not fatal if missing: that one spec fails
-- with a clear `require` error rather than the whole runner refusing to start.
local function add_runtime_analysis()
  if pcall(require, "runtime-analysis.telemetry") then
    return
  end
  local candidates = {}
  if vim.env.RUNTIME_ANALYSIS_DIR and vim.env.RUNTIME_ANALYSIS_DIR ~= "" then
    candidates[#candidates + 1] = vim.env.RUNTIME_ANALYSIS_DIR
  end
  candidates[#candidates + 1] = vim.fn.getcwd() .. "/.deps/runtime-analysis.nvim"
  candidates[#candidates + 1] = vim.fs.dirname(vim.fn.getcwd()) .. "/runtime-analysis.nvim"
  for _, dir in ipairs(candidates) do
    if dir and vim.fn.isdirectory(dir) == 1 then
      vim.opt.rtp:append(dir)
      if pcall(require, "runtime-analysis.telemetry") then
        return
      end
    end
  end
end

add_runtime_analysis()

local dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local H = dofile(dir .. "harness.lua")

local specs = {
  "harness_spec.lua",
  "polymorphic_rootresolver_spec.lua",
  "logger_spec.lua",
  "notify_popup_spec.lua",
  "echo_spec.lua",
  "messages_spec.lua",
  "output_spec.lua",
  "output_viewer_spec.lua",
  "progress_echo_style_spec.lua",
  "progress_float_style_spec.lua",
  "progress_kit_style_spec.lua",
  "autocmd_spec.lua",
  "keymap_registry_spec.lua",
  "keymap_cheatsheet_spec.lua",
  "registry_spec.lua",
  "debounce_spec.lua",
  "explorer_spec.lua",
  "count_spec.lua",
  "lastcmd_spec.lua",
  "keymap_modifier_spec.lua",
  "autocmd_dispatcher_spec.lua",
  "autocmd_docs_spec.lua",
  "usercmd_registry_spec.lua",
  "bindings_audit_spec.lua",
  "keymap_portability_spec.lua",
  "keymap_tap_spec.lua",
  "keymap_runtime_spec.lua",
  "dev_duplicates_spec.lua",
  "dev_notify_scan_spec.lua",
  "dev_handrolled_scan_spec.lua",
  "dev_handrolled_scan_restart_spec.lua",
  "dev_pattern_usage_spec.lua",
  "patterns_usage_gate_spec.lua",
  "listeners_spec.lua",
  "ordered_map_spec.lua",
  "hooks_equivalence_spec.lua",
  "progress_fanout_spec.lua",
  "dev_deprecations_spec.lua",
  "dev_reload_spec.lua",
  "markdown_table_spec.lua",
  "strings_trim_spec.lua",
  "strings_nul_safe_spec.lua",
  "strings_safe_spec.lua",
  "strings_utf8_spec.lua",
  "strings_case_style_spec.lua",
  "scoring_spec.lua",
  "window_matches_spec.lua",
  "window_best_target_spec.lua",
  "tab_buffers_spec.lua",
  "ts_regions_spec.lua",
  "terminal_capabilities_spec.lua",
  "terminal_spawn_spec.lua",
  "terminal_ask_spec.lua",
  "fs_read_bounded_spec.lua",
  "frontmatter_spec.lua",
  "markdown_link_cursor_spec.lua",
  "window_previous_spec.lua",
  "run_argv_spec.lua",
  "run_spec.lua",
  "spawn_env_spec.lua",
  "async_spec.lua",
  "async_walk_spec.lua",
  "async_map_limit_spec.lua",
  "wslpath_spec.lua",
  "system_job_spec.lua",
  "system_job_kill_tree_spec.lua",
  "run_argv_taps_spec.lua",
  "system_lines_spec.lua",
  "system_rpc_pipe_spec.lua",
  "ui_kit_spec.lua",
  "ui_kit_preview_command_spec.lua",
  "ui_kit_message_log_spec.lua",
  "ui_kit_history_spec.lua",
  "ui_kit_create_on_missing_spec.lua",
  "ui_kit_form_back_spec.lua",
  "ui_kit_sheet_spec.lua",
  "ui_kit_winfixbuf_spec.lua",
  "ui_kit_insert_chain_spec.lua",
  "ui_kit_insert_detour_spec.lua",
  "ui_kit_secret_traces_spec.lua",
  "ui_kit_oneline_spec.lua",
  "ui_kit_nul_spec.lua",
  "ui_kit_chip_scheme_retint_spec.lua",
  "ui_kit_ask_spec.lua",
  "ui_kit_confirm_answers_spec.lua",
  "ui_kit_confirm_layout_spec.lua",
  "ui_kit_confirm_keys_spec.lua",
  "ui_kit_confirm_hotkeys_spec.lua",
  "ui_kit_ask_modal_spec.lua",
  "ui_kit_dialog_hook_spec.lua",
  "ui_kit_lazy_spec.lua",
  "window_close_on_focus_lost_spec.lua",
  "ui_dialog_spec.lua",
  "ui_kit_async_spec.lua",
  "ui_kit_viewer_keys_spec.lua",
  "ui_kit_status_tokens_spec.lua",
  "ui_kit_conceal_spec.lua",
  "ui_kit_secret_buffer_spec.lua",
  "ui_kit_prompt_hooks_spec.lua",
  "ui_kit_path_completion_spec.lua",
  "ui_kit_marks_order_spec.lua",
  "ui_kit_sidebar_spec.lua",
  "icons_spec.lua",
  "ui_hl_persist_spec.lua",
  "ui_winhighlight_spec.lua",
  "copy_to_clipboard_spec.lua",
  "copy_image_to_clipboard_spec.lua",
  "ui_list_spec.lua",
  "statusline_spec.lua",
  "lua_helpers_spec.lua",
  "memo_spec.lua",
  "patterns_result_spec.lua",
  "patterns_specification_spec.lua",
  "patterns_middleware_spec.lua",
  "patterns_circuit_breaker_spec.lua",
  "patterns_state_machine_spec.lua",
  "patterns_object_pool_spec.lua",
  "patterns_event_bus_spec.lua",
  "patterns_retry_backoff_spec.lua",
  "patterns_throttle_spec.lua",
  "patterns_builder_spec.lua",
  "patterns_factory_method_spec.lua",
  "patterns_prototype_spec.lua",
  "patterns_singleton_spec.lua",
  "patterns_abstract_factory_spec.lua",
  "patterns_adapter_spec.lua",
  "patterns_bridge_spec.lua",
  "patterns_composite_spec.lua",
  "patterns_decorator_spec.lua",
  "patterns_facade_spec.lua",
  "patterns_flyweight_spec.lua",
  "patterns_chain_of_responsibility_spec.lua",
  "patterns_command_spec.lua",
  "patterns_interpreter_spec.lua",
  "patterns_iterator_spec.lua",
  "patterns_mediator_spec.lua",
  "patterns_state_spec.lua",
  "patterns_strategy_spec.lua",
  "patterns_template_method_spec.lua",
  "patterns_visitor_spec.lua",
  "patterns_dependency_injection_spec.lua",
  "patterns_repository_spec.lua",
  "patterns_reducer_spec.lua",
  "patterns_unit_of_work_spec.lua",
  "patterns_saga_spec.lua",
  "patterns_hardening_spec.lua",
  "patterns_rules_spec.lua",
  "functions_varargs_spec.lua",
  "progress_resolve_style_spec.lua",
  "nvim_helpers_spec.lua",
  "window_spec.lua",
  "focus_helpers_spec.lua",
  "selection_spec.lua",
  "context_spec.lua",
  "cache_spec.lua",
  "cache_invocation_spec.lua",
  "frecency_spec.lua",
  "cwd_spec.lua",
  "project_store_spec.lua",
  "harvest_spec.lua",
  "mutate_spec.lua",
  "lock_spec.lua",
  "neotree_watch_spec.lua",
  "watch_spec.lua",
  "composer_spec.lua",
  "composer_help_spec.lua",
  "composer_quotes_spec.lua",
  "usrcmds_help_spec.lua",
  "telemetry_wrap_spec.lua",
  "git_spec.lua",
  "git_status_spec.lua",
  "git_show_spec.lua",
  "git_run_spec.lua",
  "git_log_spec.lua",
  "git_hash_describe_spec.lua",
  "git_checkout_spec.lua",
  "git_skip_worktree_spec.lua",
  "git_sync_spec.lua",
  "git_sync_cancel_spec.lua",
  "git_remote_spec.lua",
  "curl_spec.lua",
  "curl_cached_spec.lua",
  "net_github_spec.lua",
  "deps_spec.lua",
  "deps_project_spec.lua",
  "contextmenu_spec.lua",
  "is_subpath_spec.lua",
  "to_absolute_spec.lua",
  "normkey_spec.lua",
  "stdpath_config_root_spec.lua",
  "fs_roots_spec.lua",
  "cross_powershell_spec.lua",
  "cross_bash_spec.lua",
  "globbable_spec.lua",
  "vregex_spec.lua",
  "range_spec.lua",
  "apply_edits_spec.lua",
  "checkpoint_spec.lua",
  "config_repo_file_spec.lua",
  "normalize_switch_group_spec.lua",
  "json_sanitize_spec.lua",
  "diff_word_ranges_spec.lua",
  "spawn_shell_spec.lua",
  "hooks_spec.lua",
  "fs_portable_spec.lua",
  "resolve_lib_nvim_spec.lua",
  "relpath_spec.lua",
  "config_spec.lua",
  "config_merge_spec.lua",
  "config_schema_spec.lua",
  "config_new_spec.lua",
  "cross_executable_spec.lua",
  "cross_open_default_spec.lua",
  "cross_open_default_container_spec.lua",
  "cross_is_wsl_spec.lua",
  "which_key_spec.lua",
  "json_canonical_spec.lua",
  "contract_errors_spec.lua",
  "fs_create_exclusive_spec.lua",
  "fs_json_write_spec.lua",
  "fs_etag_spec.lua",
  "fs_latest_file_spec.lua",
  "clipboard_image_spec.lua",
  "fs_with_lock_spec.lua",
  "contract_doc_spec.lua",
  "contract_api_spec.lua",
  "contract_ops_spec.lua",
  "contract_host_spec.lua",
  "terminal_host_osc_spec.lua",
  "shell_quote_spec.lua",
  "companion_launch_spec.lua",
  "companion_protocol_spec.lua",
  "companion_headless_spec.lua",
  "data_classes_spec.lua",
  "data_classes_cases_spec.lua",
}

--- Straight to stdout rather than through `print`.
---
--- `print` in a headless Neovim goes through the message area, and a spec that
--- opens a window forces a redraw that swallows the pending newline — two spec
--- results then run together on one line, which is exactly as confusing as it
--- sounds when a run is being read for a failure. A headless runner's output
--- is meant to be read by a person or a log, not rendered in a UI.
---@param s string
local function say(s)
  io.stdout:write(s, "\n")
end

local failed = {}
for _, name in ipairs(specs) do
  local run = dofile(dir .. name)
  local ok, err = pcall(run, H)
  if ok then
    say(("ok    %s"):format(name))
  else
    failed[#failed + 1] = name
    say(("FAIL  %s\n      %s"):format(name, tostring(err)))
  end
end

if #failed > 0 then
  say("\n" .. H.summary(failed))
  -- `cquit`, not `os.exit`: only a regular exit lets Neovim delete its per-instance temp
  -- directory, and every `tempname()` fixture of every spec lives in it -- `os.exit(1)` left
  -- all of them behind. Same exit code.
  vim.cmd("cquit 1")
end

say("\nLIB_TESTS_OK")
