local Cfg = {}
local AutoCmd = require("sf.sub.config_auto_cmd")

local default_cfg = {
  -- Unless you want to customize, no need to copy-paste any of these
  -- They are applied automatically

  -- This plugin has many default hotkey mappings supplied
  -- This flag enable/disable these hotkeys defined
  -- It's highly recommended to set this to `false` and define your own key mappings
  -- Set to `true` if you don't mind any potential key mapping conflicts with your own
  enable_hotkeys = false,

  -- When Nvim is initiated, the sf org list is automatically fetched and target_org is set (if available) by `:SF org fetchList`
  -- You can set it to `false` and have a manual control
  fetch_org_list_at_nvim_start = true,

  -- Some hotkeys are on "project level" thus always enabled. Examples: "set default org", "fetch org info".
  -- Other hotkeys are enabled when only metadata filetypes are loaded in the current buffer. Example: "push/retrieve current metadata file"
  -- This list defines what metadata filetypes have the "other hotkeys" enabled.
  -- For example, if you want to push/retrieve css files, it needs to be added into this list.
  hotkeys_in_filetypes = {
    "apex",
    "sosl",
    "soql",
    "javascript",
    "html",
  },

  -- Define what metadata to be listed in `list_md_to_retrieve()` (<leader>ml)
  -- Salesforce has numerous metadata types. We narrow down the scope of `list_md_to_retrieve()`.
  types_to_retrieve = {
    "ApexClass",
    "ApexTrigger",
    "StaticResource",
    "LightningComponentBundle",
  },

  -- Configuration for the integrated terminal
  term_config = {
    ft = "SFTerm", -- term filetype
    blend = 10, -- background transparency: 0 is fully opaque; 100 is fully transparent
    dimensions = {
      height = 0.4, -- proportional of the editor height. 0.4 means 40%.
      width = 0.8, -- proportional of the editor width. 0.8 means 80%.
      -- x/y are unset by default: the float uses `ui.terminal.position` (a
      -- corner) instead. Set both to opt back into the old proportional
      -- "custom" positioning via `get_dimension()` in raw_term.lua.
      -- x = 0.5,
      -- y = 0.9,
    },
    -- `:h jobstart-options` for below options.
    -- `border`/`hl` are unset by default so the new `ui.border` and `Sf*`
    -- highlight groups apply. Set either to keep the old fixed styling.
    -- border = "single",
    -- hl = "Normal",
    clear_env = false,
  },

  -- Restyled UI: float border/accent color and default terminal position.
  ui = {
    accent = "#1B96FF", -- bright "Salesforce blue"; used for border & title
    border = "rounded",
    icons = true, -- set false if you don't have a Nerd Font
    terminal = {
      position = "bottom_right", -- "bottom_right" | "top_right" | "bottom_left" | "top_left" | "center" | "custom"
      width = 0.45, -- fraction of editor columns (or absolute cells if > 1)
      height = 0.35, -- fraction of editor lines (or absolute cells if > 1)
      margin = { row = 1, col = 2 },
    },

    -- quiet progress widget for "progress"-mode tasks (see `task_display`)
    progress = {
      backend = "float", -- "float" | "notify" (vim.notify) | "auto" (notify if snacks/nvim-notify present, else float)
      spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
      interval_ms = 80,
      success_timeout_ms = 3000, -- how long the "✓ done" message stays
      error_timeout_ms = 10000, -- errors stay longer
    },

    -- how each kind of task is shown: "progress" (spinner only) or "terminal" (visible float)
    task_display = {
      default = "progress",
      deploy = "progress",
      retrieve = "progress",
      test = "terminal", -- test output is what you want to read
      query = "terminal",
      anonymous = "terminal",
    },

    expand_on_error = true, -- auto-open the terminal float if a "progress" task fails
  },

  -- The terminal strategy to use for running tasks.
  -- "integrated" - use the integrated terminal.
  -- "overseer" - use overseer.nvim to run terminal tasks. requires overseer.nvim as a dependency.
  terminal = "integrated",

  -- the fallback sf project metadata folder, update this in case you diverged from the default sf folder structure and you
  -- don't have a default package specified in sfdx-project.json.
  default_dir = "/force-app/main/default/",

  -- the folder this plugin uses to store intermediate data. It's under the sf project root directory.
  plugin_folder_name = "/sf_cache/",

  -- after the test running with code coverage completes, display uncovered line sign automatically.
  -- you can set it to `false`, then manually run toggle_sign command.
  -- this also makes existing coverage signs enabled by default on nvim startup
  auto_display_code_sign = true,

  -- code coverage sign icon colors
  code_sign_highlight = {
    covered = { fg = "#b7f071" }, -- set `fg = ""` to disable this sign icon
    uncovered = { fg = "#f07178" }, -- set `fg = ""` to disable this sign icon
  },

  -- wait time for sf commands (in minutes)
  -- running all local tests still defaults to 180 mins, as it is a costly operation
  sf_wait_time = 5,

  -- statusline components (see `lua/sf/statusline.lua`)
  statusline = {
    org = true,
    trace_flags = true,
    trace_refresh_minutes = 5,
  },

  -- Apex Replay Debugger (via nvim-dap). See `doc/sf.txt` / README for setup.
  replay_debugger = {
    -- absolute path to the salesforce apex-replay-debugger adapter's
    -- "apexReplayDebug.js"; nil = auto-detect (stdpath data dir, then
    -- ~/.vscode/extensions/salesforce.salesforcedx-vscode-apex-replay-debugger-*)
    adapter_path = nil,
    node_path = "node",
    stop_on_entry = true,
    -- boolean, or comma list: "all,protocol,logfile,launch,breakpoints"
    trace = false,
    -- ms to wait for apex_ls to answer the `debugger/lineBreakpoints` request
    lsp_timeout = 30000,
    -- default TraceFlag duration for `:SF debug enable` when no minutes are
    -- given (Salesforce caps TraceFlag duration at 24h regardless).
    trace_flag_hours = 1,
    -- where `replay_debug_local_log` looks for logs: entries starting with "/"
    -- are absolute, "<plugin_folder>" resolves to the plugin cache dir,
    -- anything else is relative to the sf project root.
    log_globs = {
      ".sfdx/tools/debug/**/*.log",
      "<plugin_folder>/logs/*.log",
    },
  },

}

local apply_config = function(opt)
  vim.g.sf = vim.tbl_deep_extend("force", default_cfg, opt)
end

local init = function()
  -- Define Salesforce related filetypes
  vim.filetype = on
  vim.filetype.add({
    extension = {
      cls = "apex",
      apex = "apex",
      trigger = "apex",
      soql = "soql",
      sosl = "sosl",
      page = "html",
      log = "sflog",
    },
  })

  require("sf.ui.highlights").setup()
  require("sf.ui.icons").setup_devicons()

  AutoCmd.set_auto_cmd_and_try_set_default_keys()

  -- Initiate the term
  local term_type = vim.g.sf.terminal or "integrated"
  if term_type == "overseer" and not pcall(require, "overseer") then
    -- overseer not found, fall back to integrated terminal
    term_type = "integrated"
  end

  if term_type == "overseer" then
    require("sf.term").overseer_setup(vim.g.sf.overseer)
  else
    require("sf.term").integrated_setup(vim.g.sf.term_config)
  end

  require("sf.test").setup_sign()

  require("sf.debug").setup_dap()
end

Cfg.setup = function(opt)
  opt = opt or {}
  vim.validate({ config = { opt, "table", true } })
  apply_config(opt)

  init()
end

return Cfg
