-- Statusline components: current target org (and, in a later phase, active
-- trace flags). Read-only against the cache in `sf.state` -- never shells
-- out, reads files, or calls `sf.util.get_sf_root()` on every render.
local M = {}

local H = { sf_project_cache = {} }

-- Invalidate the per-cwd "is this an sf project" cache when the cwd changes.
vim.api.nvim_create_autocmd("DirChanged", {
  callback = function()
    H.sf_project_cache = {}
  end,
})

--- Cheap, cached check: is the current cwd inside an sf project? Only
--- touches the filesystem once per cwd (via `U.get_sf_root`), not per render.
---@return boolean
function M.is_sf_project()
  local cwd = vim.fn.getcwd()
  if H.sf_project_cache[cwd] == nil then
    H.sf_project_cache[cwd] = pcall(require("sf.util").get_sf_root)
  end
  return H.sf_project_cache[cwd]
end

--- Highlight group for the current org, colored by type: Salesforce blue
--- for production, white for sandbox, cyan for scratch, else the accent.
---@return string
function M.org_color()
  local org = require("sf.state").get()
  if org.is_prod then
    return "SfStatusProd"
  end
  if org.is_scratch then
    return "SfStatusScratch"
  end
  if org.is_sandbox then
    return "SfStatusSandbox"
  end
  return "SfStatusOrg"
end

--- Plain text for the current target org: a cloud icon (colored per
--- `M.org_color()` by the caller) followed by the alias, or "" if not in an
--- sf project or no org is set yet.
---@return string
function M.org()
  if not M.is_sf_project() then
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
function M.render()
  local text = M.org()
  if text == "" then
    return ""
  end
  return string.format("%%#%s#%s%%*", M.org_color(), text)
end

--- lualine component table for the target org. Usage:
--- `table.insert(opts.sections.lualine_x, 1, require("sf.statusline").lualine())`
---@return table
function M.lualine()
  return {
    M.org,
    cond = M.is_sf_project,
    color = M.org_color,
    on_click = function()
      require("sf").set_target_org()
    end,
  }
end

--- Plain text for active TraceFlags: a clock icon + minutes until the
--- soonest one expires, e.g. " 23m", plus a count badge if more than one
--- is active. "" when none. Read-only against the cache -- no I/O.
---@return string
function M.trace()
  if vim.g.sf and vim.g.sf.statusline and vim.g.sf.statusline.trace_flags == false then
    return ""
  end

  local flags = require("sf.state").get_trace_flags()
  if #flags == 0 then
    return ""
  end

  local soonest = math.huge
  for _, f in ipairs(flags) do
    soonest = math.min(soonest, f.expires_at_epoch)
  end

  local remaining_min = math.max(math.floor((soonest - os.time()) / 60), 0)
  local ui = (vim.g.sf and vim.g.sf.ui) or {}
  local icon = (ui.icons ~= false) and "  " or ""
  local count_suffix = #flags > 1 and (" (" .. #flags .. "x)") or ""

  return icon .. remaining_min .. "m" .. count_suffix
end

--- lualine component table for active trace flags. Clicking asks to
--- enable/disable replay logging for the target org (enable when none
--- active, disable when one or more are).
---@return table
function M.lualine_trace()
  return {
    M.trace,
    cond = function()
      return M.is_sf_project() and M.trace() ~= ""
    end,
    color = "SfStatusTrace",
    on_click = function()
      local Debug = require("sf.debug")
      local flags = require("sf.state").get_trace_flags()
      if #flags > 0 then
        vim.ui.select({ "Yes", "No" }, { prompt = "Disable replay logging for target_org?" }, function(choice)
          if choice == "Yes" then
            Debug.disable_replay_logging()
          end
        end)
      else
        vim.ui.select({ "Yes", "No" }, { prompt = "Enable replay logging for target_org?" }, function(choice)
          if choice == "Yes" then
            Debug.enable_replay_logging()
          end
        end)
      end
    end,
  }
end

return M
