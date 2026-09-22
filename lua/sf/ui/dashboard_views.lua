-- Registry of view descriptors for the org dashboard right pane.
-- Each descriptor defines how to fetch, render, and act on a view.
-- Adding a new view is just adding an entry to this array.

local org_view = require("sf.ui.org_view")
local org_status = require("sf.sub.org_status")
local rest_api = require("sf.sub.rest_api")

--- Highlight group for a given instance status string.
---@param status string
---@return string
local function status_highlight(status)
  if status == "OK" then
    return "SfSuccess"
  elseif status == "unknown" then
    return "SfWarn"
  end
  return "SfError" -- any incident/maintenance/degraded state
end

local views = {
  {
    id = "details",
    key = "d",
    label = "Details",
    fetch = function(record, callback)
      org_view.fetch_org_display(record, callback)
    end,
    render = function(record, data)
      return org_view.render_detail_lines(record, nil, data, nil)
    end,
    action = nil, -- details view is fetch+render only
  },
  {
    id = "status",
    key = "s",
    label = "Org Status",
    fetch = function(record, callback)
      rest_api.get_session(record.alias, function(session, err)
        if not session then
          return callback(nil, err)
        end
        org_status.fetch(session, callback)
      end)
    end,
    render = function(_, data)
      local lines, line_hls = {}, {}

      local status_line = "Status: " .. data.status
      table.insert(lines, status_line)
      table.insert(line_hls, { { group = status_highlight(data.status), col_start = 0, col_end = #status_line } })

      if data.message then
        table.insert(lines, data.message)
        table.insert(line_hls, {})
      end

      table.insert(lines, "")
      table.insert(line_hls, {})

      if #data.incidents == 0 then
        table.insert(lines, "No incidents reported.")
        table.insert(line_hls, {})
      else
        table.insert(lines, "Incidents:")
        table.insert(line_hls, {})
        for _, incident in ipairs(data.incidents) do
          local incident_line = "  - " .. (incident.message or incident.id or "(no details)")
          table.insert(lines, incident_line)
          table.insert(line_hls, { { group = "SfWarn", col_start = 0, col_end = #incident_line } })
        end
      end

      return lines, line_hls
    end,
    action = nil,
  },
}

return views
