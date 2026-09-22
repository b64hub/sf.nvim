local U = require("sf.util")
local M = {}

M.set_auto_cmd_and_try_set_default_keys = function()
  local sf_group = vim.api.nvim_create_augroup("SF", { clear = true })

  -- Disable "end of line" for relevant filetypes in sf project folder,
  -- Because metadata files retrieved from Salesforce don't have it
  vim.api.nvim_create_autocmd({ "FileType" }, {
    group = sf_group,
    pattern = { "javascript", "apex", "html" },
    callback = function()
      if pcall(require("sf.util").get_sf_root) then
        vim.bo.fixendofline = false
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "FileType" }, {
    group = sf_group,
    pattern = "apex",
    callback = function()
      vim.bo.commentstring = "//%s"
      vim.bo.fixendofline = false

      -- try refresh code coverage signs in the new opened Apex file
      local t = require("sf.test")
      if t.is_sign_enabled() then
        t.refresh_and_place_sign()
      end
    end,
  })

  -- Set hotkeys for the integrated terminal
  vim.api.nvim_create_autocmd({ "FileType" }, {
    group = sf_group,
    pattern = "SFTerm",
    callback = function()
      local nmap = function(keys, func, desc)
        if desc then
          desc = desc .. " [Sf]"
        end
        vim.keymap.set("n", keys, func, { buffer = true, desc = desc })
      end

      -- "q" closes (redundant <leader><leader> here would shadow other
      -- plugins' global <leader><leader> mapping, e.g. fzf-lua, while a
      -- terminal buffer happens to have focus)
      nmap("<C-c>", require("sf").cancel, "cancel running command")
      nmap("q", require("sf").toggle_term, "close terminal")
    end,
  })

  -- Colorschemes clear highlight groups; redefine ours after every switch
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = sf_group,
    callback = function()
      require("sf.ui.highlights").setup()
    end,
  })

  -- Refresh test code coverage info for the current Apex file
  vim.api.nvim_create_autocmd("BufEnter", {
    group = sf_group,
    pattern = { "*.cls" },
    callback = function()
      local ok, content = pcall(require("sf").refresh_current_file_covered_percent)
      if not ok then
        -- swallow error and be silent
      end
    end,
  })

  -- Pick up a target-org change made outside Nvim (e.g. another terminal
  -- running `sf config set target-org`), from disk only, never the CLI.
  vim.api.nvim_create_autocmd({ "FocusGained", "DirChanged" }, {
    group = sf_group,
    callback = function()
      pcall(require("sf").refresh_target_org_from_disk)
    end,
  })

  -- Same, but at startup: neither of the above fire on a fresh session, and
  -- `sf org list`'s `isDefaultUsername` (used by `fetch_org_list` below)
  -- doesn't reflect a project-local `target-org` on current `sf` CLI
  -- versions -- so without this the statusline org stays blank until the
  -- first focus toggle/`:cd`. Cheap file read, so always on regardless of
  -- `fetch_org_list_at_nvim_start`.
  vim.api.nvim_create_autocmd("VimEnter", {
    group = sf_group,
    callback = function()
      pcall(require("sf").refresh_target_org_from_disk)
    end,
  })

  -- Refresh active trace flags on org change, and periodically while Nvim
  -- has focus (never while unfocused -- no point polling if you're away).
  if vim.g.sf.statusline.trace_flags then
    vim.api.nvim_create_autocmd("User", {
      group = sf_group,
      pattern = "SfOrgChanged",
      callback = function()
        pcall(require("sf.state").refresh_trace_flags)
      end,
    })

    local has_focus = true
    local trace_timer = nil

    vim.api.nvim_create_autocmd("FocusGained", {
      group = sf_group,
      callback = function()
        has_focus = true
      end,
    })
    vim.api.nvim_create_autocmd("FocusLost", {
      group = sf_group,
      callback = function()
        has_focus = false
      end,
    })

    local minutes = vim.g.sf.statusline.trace_refresh_minutes or 5
    trace_timer = vim.uv.new_timer()
    trace_timer:start(
      minutes * 60 * 1000,
      minutes * 60 * 1000,
      vim.schedule_wrap(function()
        if has_focus then
          pcall(require("sf.state").refresh_trace_flags)
        end
      end)
    )

    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = sf_group,
      callback = function()
        if trace_timer then
          trace_timer:stop()
          trace_timer:close()
          trace_timer = nil
        end
      end,
    })
  end

  -- Fetch org info in Vim start
  if vim.g.sf.fetch_org_list_at_nvim_start then
    vim.api.nvim_create_autocmd({ "VimEnter" }, {
      group = sf_group,
      desc = "Run sf org cmd and store org info in the plugin",
      callback = function()
        if vim.fn.executable("sf") == 1 then
          require("sf").fetch_org_list()
        end
      end,
    })
  end

  -- Placeholder so an early `:SF` reports why it is unavailable rather than E492
  require("sf.sub.config_user_command").create_placeholder_command()

  local function try_set_keys_and_user_commands()
    if not pcall(require("sf.util").get_sf_root) then
      return
    end

    require("sf.sub.config_user_command").create_user_commands()

    if not vim.g.sf.enable_hotkeys then
      return
    end

    require("sf.sub.config_user_key").set_default_hotkeys()
  end

  -- Set hotkeys and user commands
  vim.api.nvim_create_autocmd({ "BufWinEnter", "FileType", "DirChanged" }, {
    group = sf_group,
    callback = try_set_keys_and_user_commands,
  })

  -- clear diff files retrieved locally when Nvim exists
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = sf_group,
    callback = function()
      local ok, diff_folder = pcall(function()
        return U.get_plugin_folder_path() .. "diffs/"
      end)
      if ok then
        vim.fn.delete(diff_folder, "rf")
      end
    end,
  })
end

return M
