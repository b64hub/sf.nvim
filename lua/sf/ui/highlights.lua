-- Highlight groups for the restyled sf.nvim UI. All groups are `default =
-- true` so colorschemes and user configs can override them freely.
-- Re-run `M.setup()` on `ColorScheme` since colorschemes clear hl groups.
local M = {}

--- Darken (factor < 1) or lighten (factor > 1) a hex color by multiplying
--- each RGB channel. factor=1 is identity, extremes are clamped to 0-255.
---@param hex string #RRGGBB
---@param factor number darkening or lightening factor
---@return string #RRGGBB result
local function shade(hex, factor)
  -- Parse #RRGGBB
  local r = tonumber(hex:sub(2, 3), 16)
  local g = tonumber(hex:sub(4, 5), 16)
  local b = tonumber(hex:sub(6, 7), 16)

  -- Scale each channel by factor, clamp to 0-255
  r = math.min(255, math.max(0, math.floor(r * factor)))
  g = math.min(255, math.max(0, math.floor(g * factor)))
  b = math.min(255, math.max(0, math.floor(b * factor)))

  return string.format("#%02x%02x%02x", r, g, b)
end

--- Mix two hex colors at a weighted interpolation: weight=0 returns hex_a,
--- weight=1 returns hex_b.
---@param hex_a string #RRGGBB
---@param hex_b string #RRGGBB
---@param weight number 0-1
---@return string #RRGGBB result
local function mix(hex_a, hex_b, weight)
  local r_a = tonumber(hex_a:sub(2, 3), 16)
  local g_a = tonumber(hex_a:sub(4, 5), 16)
  local b_a = tonumber(hex_a:sub(6, 7), 16)

  local r_b = tonumber(hex_b:sub(2, 3), 16)
  local g_b = tonumber(hex_b:sub(4, 5), 16)
  local b_b = tonumber(hex_b:sub(6, 7), 16)

  local r = math.floor(r_a + (r_b - r_a) * weight)
  local g = math.floor(g_a + (g_b - g_a) * weight)
  local b = math.floor(b_a + (b_b - b_a) * weight)

  return string.format("#%02x%02x%02x", r, g, b)
end

-- Export for testing
M._shade = shade
M._mix = mix

--- @param name string
--- @param opts table passed to `nvim_set_hl` (without `default`)
local function set(name, opts)
  opts.default = true
  vim.api.nvim_set_hl(0, name, opts)
end

function M.setup()
  local ui = (vim.g.sf and vim.g.sf.ui) or {}
  local accent = ui.accent or "#1B96FF"

  -- Derive chrome colors from accent
  local accent_darkened = shade(accent, 0.08) -- for high contrast on accent background
  local accent_dimmed = mix(accent, "#1a1a1a", 0.4) -- reduce saturation
  local accent_lightened = shade(accent, 1.45) -- light tint for secondary items
  local accent_muted = shade(accent, 0.72) -- darker shade for recessive items

  set("SfBorder", { fg = accent })
  set("SfTitle", { fg = accent_darkened, bg = accent, bold = true })
  set("SfTableHeader", { fg = shade(accent, 1.25), bold = true, underline = true })
  set("SfDim", { fg = accent_dimmed })
  set("SfFooter", { link = "Comment" })
  set("SfNormal", { link = "NormalFloat" })
  set("SfSpinner", { fg = accent })
  set("SfCloudIcon", { fg = accent }) -- the shared sf.nvim cloud icon (statusline + file explorers)
  set("SfSuccess", { link = "DiagnosticOk" })
  set("SfError", { link = "DiagnosticError" })
  set("SfWarn", { link = "DiagnosticWarn" })
  set("SfStatusOrg", { fg = accent, bold = true })
  set("SfStatusProd", { fg = accent, bold = true }) -- most saturated; production is critical
  set("SfStatusSandbox", { fg = accent_lightened }) -- light tint
  set("SfStatusScratch", { fg = accent_muted }) -- darker shade
  set("SfStatusTrace", { link = "DiagnosticWarn" })
end

return M
