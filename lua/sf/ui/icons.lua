-- The one sf.nvim "brand" icon: a cloud, shared between the statusline
-- (colored by org type) and file-explorer integrations (static brand color,
-- via the "SfCloudIcon" highlight group). Single source of truth so both
-- stay in sync. Inherent sf.nvim behavior -- nothing for the user to add to
-- their own config.
local M = {}

M.CLOUD = "\u{f0c2}" -- nf-fa-cloud; present in every Nerd Font variant

--- Register the cloud icon for Apex class files, for whichever icon
--- provider is installed: nvim-web-devicons (real plugin, or the
--- mini.icons compatibility shim), and/or mini.icons directly.
function M.setup_devicons()
  local ui = (vim.g.sf and vim.g.sf.ui) or {}
  if ui.icons == false then
    return
  end

  -- Requiring "nvim-web-devicons" here is also what makes LazyVim's default
  -- mini.icons setup (which preloads "nvim-web-devicons" as a compatibility
  -- shim) load and run mini.icons' own setup() first, so the mini.icons
  -- branch below sees its fully resolved config.
  local ok_dev, devicons = pcall(require, "nvim-web-devicons")
  if ok_dev and type(devicons.set_icon) == "function" then
    devicons.set_icon({
      cls = {
        icon = M.CLOUD,
        color = ui.accent or "#1B96FF",
        cterm_color = "12",
        name = "SalesforceApexClass",
      },
    })
  end

  -- mini.icons only applies extension overrides inside setup(), so merge
  -- ours onto whatever config is already active and re-run it (idempotent).
  local ok_mini, mini_icons = pcall(require, "mini.icons")
  if ok_mini and type(mini_icons.setup) == "function" then
    local cfg = vim.deepcopy(mini_icons.config or {})
    cfg.extension = cfg.extension or {}
    cfg.extension.cls = { glyph = M.CLOUD, hl = "SfCloudIcon" }
    mini_icons.setup(cfg)
  end
end

return M
