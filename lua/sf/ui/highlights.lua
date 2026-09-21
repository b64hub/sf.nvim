-- Highlight groups for the restyled sf.nvim UI. All groups are `default =
-- true` so colorschemes and user configs can override them freely.
-- Re-run `M.setup()` on `ColorScheme` since colorschemes clear hl groups.
local M = {}

--- @param name string
--- @param opts table passed to `nvim_set_hl` (without `default`)
local function set(name, opts)
  opts.default = true
  vim.api.nvim_set_hl(0, name, opts)
end

function M.setup()
  local ui = (vim.g.sf and vim.g.sf.ui) or {}
  local accent = ui.accent or "#1B96FF"

  set("SfBorder", { fg = accent })
  set("SfTitle", { fg = "#101418", bg = accent, bold = true })
  set("SfFooter", { link = "Comment" })
  set("SfNormal", { link = "NormalFloat" })
  set("SfSpinner", { fg = accent })
  set("SfCloudIcon", { fg = accent }) -- the shared sf.nvim cloud icon (statusline + file explorers)
  set("SfSuccess", { link = "DiagnosticOk" })
  set("SfError", { link = "DiagnosticError" })
  set("SfWarn", { link = "DiagnosticWarn" })
  set("SfStatusOrg", { fg = accent, bold = true })
  set("SfStatusProd", { fg = accent, bold = true }) -- Salesforce blue
  set("SfStatusSandbox", { fg = "white", bold = true })
  set("SfStatusScratch", { fg = "cyan", bold = true })
  set("SfStatusTrace", { link = "DiagnosticWarn" })
end

return M
