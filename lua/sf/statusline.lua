-- Statusline components: current target org (and, in a later phase, active
-- trace flags). Read-only against the cache in `sf.state` -- never shells
-- out, reads files, or calls `sf.util.get_sf_root()` on every render.
local statusline = {}

local helpers = { sf_project_cache = {} }

-- Invalidate the per-cwd "is this an sf project" cache when the cwd changes.
vim.api.nvim_create_autocmd("DirChanged", {
  callback = function()
    helpers.sf_project_cache = {}
  end,
})

--- Cheap, cached check: is the current cwd inside an sf project? Only
--- touches the filesystem once per cwd (via `U.get_sf_root`), not per render.
---@return boolean
function statusline.is_sf_project()
  local cwd = vim.fn.getcwd()
  if helpers.sf_project_cache[cwd] == nil then
    helpers.sf_project_cache[cwd] = pcall(require("sf.util").get_sf_root)
  end
  return helpers.sf_project_cache[cwd]
end

--- Highlight group for the current org, colored by type: Salesforce blue
--- for production, white for sandbox, cyan for scratch, else the accent.
---@return string
function statusline.org_color()
  return require("sf.org_model").highlight_group(require("sf.state").get())
end

--- Plain text for the current target org: a cloud icon (colored per
--- `statusline.org_color()` by the caller) followed by the alias, or "" if not in an
--- sf project or no org is set yet.
---@return string
function statusline.org()
  if not statusline.is_sf_project() then
    return ""
  end

  local org = require("sf.state").get()
  if not org.alias or org.alias == "" then
    return ""
  end

  local ui = (vim.g.sf and vim.g.sf.ui) or {}
  local icon = (ui.icons ~= false) and (require("sf.ui.icons").CLOUD .. "  ") or "" -- 2 spaces: many Nerd Font PUA glyphs render 2 cells wide even though Nvim counts 1

  return icon .. org.alias
end

--- Statusline string with `%#Group#` highlights, for plain `'statusline'`
--- users, e.g. `vim.o.statusline = "...%{%v:lua.require'sf.statusline'.render()%}"`.
---@return string
function statusline.render()
  local text = statusline.org()
  if text == "" then
    return ""
  end
  return string.format("%%#%s#%s%%*", statusline.org_color(), text)
end

--- lualine component table for the target org. Usage:
--- `table.insert(opts.sections.lualine_x, 1, require("sf.statusline").lualine())`
---@return table
function statusline.lualine()
  return {
    statusline.org,
    cond = statusline.is_sf_project,
    color = statusline.org_color,
    on_click = function()
      require("sf").open_org_dashboard()
    end,
  }
end

--- Plain text for active TraceFlags: a clock icon + minutes until the
--- soonest one expires, e.g. " 23m", plus a count badge if more than one
--- is active. Just the icon (or "trace" without icons) when the feature is
--- on but nothing is active yet -- needed so the lualine component stays
--- clickable to *enable* logging, not just to disable it. "" only when the
--- feature is turned off entirely. Read-only against the cache -- no I/O.
---@return string
function statusline.trace()
  if vim.g.sf and vim.g.sf.statusline and vim.g.sf.statusline.trace_flags == false then
    return ""
  end

  local ui = (vim.g.sf and vim.g.sf.ui) or {}
  local icon = (ui.icons ~= false) and "  " or "trace"

  local flags = require("sf.state").get_trace_flags()
  if #flags == 0 then
    return icon
  end

  local soonest = math.huge
  for _, f in ipairs(flags) do
    soonest = math.min(soonest, f.expires_at_epoch)
  end

  local remaining_min = math.max(math.floor((soonest - os.time()) / 60), 0)
  local count_suffix = #flags > 1 and (" (" .. #flags .. "x)") or ""

  return icon .. remaining_min .. "m" .. count_suffix
end

--- lualine component table for active trace flags. Clicking asks to
--- enable/disable replay logging for the target org (enable when none
--- active, disable when one or more are).
---@return table
function statusline.lualine_trace()
  return {
    statusline.trace,
    cond = function()
      return statusline.is_sf_project() and statusline.trace() ~= ""
    end,
    color = "SfStatusTrace",
    on_click = function()
      require("sf.debug").toggle_replay_logging()
    end,
  }
end

return statusline
